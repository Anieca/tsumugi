import CLlama
import Foundation
import TsumugiCore

/// かな漢字変換に特化した超小型 GPT-2 モデル zenz (v3 系) を llama.cpp で動かす。
///
/// プロンプト書式 (v3):  [\u{EE02}左文脈] \u{EE00}カタカナの読み \u{EE01}変換結果 </s>
public final class ZenzModel: NeuralAssist {
    private static let inputTag = "\u{EE00}"
    private static let outputTag = "\u{EE01}"
    private static let contextTag = "\u{EE02}"

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let nVocab: Int
    private let eos: llama_token
    /// 直前に評価したトークン列。共通の接頭辞は KV キャッシュを再利用する。
    private var cached: [llama_token] = []
    private var batchStart = 0
    /// 直前の変換結果。次の変換の「当て推量」として 1 回の評価でまとめて検証する。
    private var lastOutput: [llama_token] = []
    private let lock = NSLock()

    /// 読みの続きを予測するとき、1 トークンごとに必要な確信度。
    public var predictionTokenThreshold: Float = 0.4
    /// 予測全体 (各トークンの確率の積) に必要な確信度。
    public var predictionThreshold: Float = 0.2

    private static let backend: Void = {
        if ProcessInfo.processInfo.environment["TSUMUGI_LLM_LOG"] == nil { llama_log_set({ _, _, _ in }, nil) }
        llama_backend_init()
    }()

    public init?(path: String, useGPU: Bool = false) {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = useGPU ? 99 : 0
        guard let model = llama_model_load_from_file(path, mp) else { return nil }
        var cp = llama_context_default_params()
        cp.n_ctx = 512
        cp.n_batch = 512
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0)
        let threads = Int32(max(1, min(4, perf > 0 ? Int(perf) : ProcessInfo.processInfo.activeProcessorCount / 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.no_perf = true
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            return nil
        }
        self.model = model
        self.ctx = ctx
        vocab = llama_model_get_vocab(model)
        nVocab = Int(llama_vocab_n_tokens(vocab))
        // zenz の文末は "</s>"。語彙に設定された EOS とは一致しないことがあるので文字列から引く
        var buf = [llama_token](repeating: 0, count: 8)
        let n = llama_tokenize(vocab, "</s>", 4, &buf, 8, false, true)
        eos = n == 1 ? buf[0] : llama_vocab_eos(vocab)
        batch = llama_batch_init(512, 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: 低レベル

    private func tokenize(_ text: String) -> [llama_token] {
        // zenz のトークナイザに合わせ、空白は全角に、改行は取り除く
        let t = text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
        let cap = t.utf8.count + 2
        var buf = [llama_token](repeating: 0, count: cap)
        let n = llama_tokenize(vocab, t, Int32(t.utf8.count), &buf, Int32(cap), true, false)
        return n > 0 ? Array(buf[0..<Int(n)]) : [llama_vocab_bos(vocab)]
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, 64, 0, true)
        return n > 0 ? buf[0..<Int(n)].map { UInt8(bitPattern: $0) } : []
    }

    /// tokens を評価する。位置 logitsFrom 以降のロジットが `logits(at:)` で読めるようになる。
    private func decode(_ tokens: [llama_token], logitsFrom: Int) -> Bool {
        guard !tokens.isEmpty, tokens.count < 500 else { return false }
        var common = 0
        while common < min(cached.count, tokens.count), cached[common] == tokens[common] { common += 1 }
        common = min(common, logitsFrom, tokens.count - 1)
        _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, Int32(common), -1)
        batch.n_tokens = 0
        for i in common..<tokens.count {
            let k = Int(batch.n_tokens)
            batch.token[k] = tokens[i]
            batch.pos[k] = Int32(i)
            batch.n_seq_id[k] = 1
            batch.seq_id[k]![0] = 0
            batch.logits[k] = i >= logitsFrom ? 1 : 0
            batch.n_tokens += 1
        }
        batchStart = common
        guard llama_decode(ctx, batch) == 0 else {
            cached = []
            _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, 0, -1)
            return false
        }
        cached = tokens
        return true
    }

    /// 直前の decode で評価した位置 pos のロジット。
    private func logits(at pos: Int) -> UnsafeMutablePointer<Float>? {
        llama_get_logits_ith(ctx, Int32(pos - batchStart))
    }

    /// tokens を評価して最後の位置のロジットを返す。
    private func logits(_ tokens: [llama_token]) -> UnsafeMutablePointer<Float>? {
        decode(tokens, logitsFrom: tokens.count - 1) ? logits(at: tokens.count - 1) : nil
    }

    /// 最尤のトークンとその確率。
    private func argmax(_ logits: UnsafeMutablePointer<Float>) -> (llama_token, Float) {
        var best = 0
        var maxLogit = logits[0]
        for i in 1..<nVocab where logits[i] > maxLogit {
            maxLogit = logits[i]
            best = i
        }
        var sum: Float = 0
        for i in 0..<nVocab { sum += exp(logits[i] - maxLogit) }
        return (llama_token(best), 1 / sum)
    }

    private func contextPrefix(_ left: String) -> String {
        let trimmed = String(left.suffix(40))
        return trimmed.isEmpty ? "" : Self.contextTag + trimmed
    }

    // MARK: NeuralAssist

    public func convert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        let prompt = contextPrefix(leftContext) + Self.inputTag + reading.katakana + Self.outputTag
        let promptTokens = tokenize(prompt)
        var tokens = promptTokens
        var out: [llama_token] = []
        let limit = reading.count * 2 + 8
        var next: llama_token?
        // 打鍵ごとに読みは 1 文字ずつしか伸びないので、前回の出力の大半は今回も正しい。
        // 前回の出力を続けて 1 バッチで評価し、モデルの選択と一致するところまでを一気に採用する。
        if !lastOutput.isEmpty {
            let guess = Array(lastOutput.prefix(limit))
            let p = promptTokens.count
            if decode(promptTokens + guess, logitsFrom: p - 1) {
                var agreed = 0
                while true {
                    guard let l = logits(at: p - 1 + agreed) else { break }
                    let (tok, _) = argmax(l)
                    if agreed < guess.count, tok == guess[agreed] {
                        agreed += 1
                    } else {
                        next = tok
                        break
                    }
                }
                out = Array(guess[0..<agreed])
                tokens += out
            }
        }
        while out.count < limit {
            if isCancelled() { return nil }
            let tok: llama_token
            if let n = next {
                tok = n
                next = nil
            } else {
                guard let l = logits(tokens) else { return nil }
                tok = argmax(l).0
            }
            if tok == eos { break }
            out.append(tok)
            tokens.append(tok)
        }
        lastOutput = out
        let s = String(decoding: out.flatMap(piece), as: UTF8.self)
        return s.isEmpty || s.unicodeScalars.contains(where: { (0xEE00...0xEE0F).contains($0.value) || $0.value == 0xFFFD }) ? nil : s
    }

    public func predict(readingPrefix: String, leftContext: String, isCancelled: () -> Bool) -> NeuralPrediction? {
        lock.lock(); defer { lock.unlock() }
        let prompt = contextPrefix(leftContext) + Self.inputTag + readingPrefix.katakana
        var tokens = tokenize(prompt)
        var continuation: [UInt8] = []
        var confidence: Float = 1
        // 読みの続きを、確信が続くかぎり伸ばす。句読点・入力の終わり・自信のない文字の手前で止める。
        for _ in 0..<24 {
            if isCancelled() { return nil }
            guard let l = logits(tokens) else { return nil }
            let (tok, p) = argmax(l)
            let bytes = piece(tok)
            if tok == eos || bytes.first == 0xEE || p < predictionTokenThreshold || confidence * p < predictionThreshold { break }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains(where: { "、。！？!?,.\u{3000} ".contains($0) }) { break }
            confidence *= p
            continuation += bytes
            tokens.append(tok)
        }
        let more = String(decoding: continuation, as: UTF8.self).hiragana
        guard !more.isEmpty, !more.unicodeScalars.contains("\u{FFFD}") else { return nil }
        return NeuralPrediction(reading: readingPrefix + more, surface: nil, confidence: confidence)
    }

    /// 検証・計測用: 続きの予測を閾値なしで出す。
    public func debugPredict(readingPrefix: String, leftContext: String) -> [(String, Float)] {
        lock.lock(); defer { lock.unlock() }
        var tokens = tokenize(contextPrefix(leftContext) + Self.inputTag + readingPrefix.katakana)
        var out: [(String, Float)] = []
        for _ in 0..<40 {
            guard let l = logits(tokens) else { break }
            let (tok, p) = argmax(l)
            if tok == eos { out.append(("<EOS>", p)); break }
            out.append((String(decoding: piece(tok), as: UTF8.self), p))
            tokens.append(tok)
        }
        return out
    }
}
