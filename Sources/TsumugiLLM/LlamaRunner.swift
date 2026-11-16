import CLlama
import Foundation

/// llama.cpp のモデル 1 つと、その評価状態。トークン列を評価して次のトークンの確率を読む。
/// スレッド安全ではないので、使う側でロックする。
final class LlamaRunner {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    let vocab: OpaquePointer
    private var batch: llama_batch
    let nVocab: Int
    private let capacity: Int
    /// 直前に評価したトークン列。共通の接頭辞は KV キャッシュを再利用する。
    private var cached: [llama_token] = []
    private var batchStart = 0

    private static let backend: Void = {
        if ProcessInfo.processInfo.environment["TSUMUGI_LLM_LOG"] == nil { llama_log_set({ _, _, _ in }, nil) }
        llama_backend_init()
    }()

    init?(path: String, useGPU: Bool, contextSize: Int = 512) {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = useGPU ? 99 : 0
        guard let model = llama_model_load_from_file(path, mp) else { return nil }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextSize)
        cp.n_batch = UInt32(contextSize)
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
        capacity = contextSize
        vocab = llama_model_get_vocab(model)
        nVocab = Int(llama_vocab_n_tokens(vocab))
        batch = llama_batch_init(Int32(contextSize), 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    var bos: llama_token { llama_vocab_bos(vocab) }
    var eos: llama_token { llama_vocab_eos(vocab) }
    /// 一度に評価できるトークン数の上限。
    var maxTokens: Int { capacity - 12 }

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool = false) -> [llama_token] {
        let cap = text.utf8.count + 4
        var buf = [llama_token](repeating: 0, count: cap)
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &buf, Int32(cap), addSpecial, parseSpecial)
        return n > 0 ? Array(buf[0..<Int(n)]) : []
    }

    func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, 64, 0, true)
        return n > 0 ? buf[0..<Int(n)].map { UInt8(bitPattern: $0) } : []
    }

    /// tokens を評価する。位置 logitsFrom 以降のロジットが `logits(at:)` で読めるようになる。
    func decode(_ tokens: [llama_token], logitsFrom: Int) -> Bool {
        guard !tokens.isEmpty, tokens.count < maxTokens else { return false }
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
    func logits(at pos: Int) -> UnsafeMutablePointer<Float>? {
        llama_get_logits_ith(ctx, Int32(pos - batchStart))
    }

    /// tokens を評価して最後の位置のロジットを返す。
    func logits(_ tokens: [llama_token]) -> UnsafeMutablePointer<Float>? {
        decode(tokens, logitsFrom: tokens.count - 1) ? logits(at: tokens.count - 1) : nil
    }

    /// 最尤のトークンとその確率。
    func argmax(_ logits: UnsafeMutablePointer<Float>) -> (llama_token, Float) {
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

    /// あるトークンの確率。
    func probability(of token: llama_token, in logits: UnsafeMutablePointer<Float>) -> Float {
        var maxLogit = logits[0]
        for i in 1..<nVocab where logits[i] > maxLogit { maxLogit = logits[i] }
        var sum: Float = 0
        for i in 0..<nVocab { sum += exp(logits[i] - maxLogit) }
        return exp(logits[Int(token)] - maxLogit) / sum
    }

    /// 確率の高い順に k 個のトークンと、その確率。
    func top(_ logits: UnsafeMutablePointer<Float>, count k: Int) -> [(llama_token, Float)] {
        var maxLogit = logits[0]
        for i in 1..<nVocab where logits[i] > maxLogit { maxLogit = logits[i] }
        var sum: Float = 0
        var best: [(Int, Float)] = []
        for i in 0..<nVocab {
            let v = logits[i]
            sum += exp(v - maxLogit)
            if best.count < k || v > best[best.count - 1].1 {
                let at = best.firstIndex { $0.1 < v } ?? best.count
                best.insert((i, v), at: at)
                if best.count > k { best.removeLast() }
            }
        }
        return best.map { (llama_token($0.0), exp($0.1 - maxLogit) / sum) }
    }
}
