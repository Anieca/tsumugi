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

    private let llm: LlamaRunner
    private let eos: llama_token
    /// 直前の変換結果。次の変換の「当て推量」として 1 回の評価でまとめて検証する。
    private var lastOutput: [llama_token] = []
    private let lock = NSLock()

    /// 読みの続きを予測するとき、1 トークンごとに必要な確信度。
    public var predictionTokenThreshold: Float = 0.4
    /// 予測全体 (各トークンの確率の積) に必要な確信度。
    public var predictionThreshold: Float = 0.2
    public init?(path: String, useGPU: Bool = false) {
        guard let llm = LlamaRunner(path: path, useGPU: useGPU) else { return nil }
        self.llm = llm
        // zenz の文末は "</s>"。語彙に設定された EOS とは一致しないことがあるので文字列から引く
        let t = llm.tokenize("</s>", addSpecial: false, parseSpecial: true)
        eos = t.count == 1 ? t[0] : llm.eos
    }

    private func tokenize(_ text: String) -> [llama_token] {
        // zenz のトークナイザに合わせ、空白は全角に、改行は取り除く
        let t = llm.tokenize(text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: ""), addSpecial: true)
        return t.isEmpty ? [llm.bos] : t
    }

    private func piece(_ token: llama_token) -> [UInt8] { llm.piece(token) }
    private func decode(_ tokens: [llama_token], logitsFrom: Int) -> Bool { llm.decode(tokens, logitsFrom: logitsFrom) }
    private func logits(at pos: Int) -> UnsafeMutablePointer<Float>? { llm.logits(at: pos) }
    private func logits(_ tokens: [llama_token]) -> UnsafeMutablePointer<Float>? { llm.logits(tokens) }
    private func argmax(_ logits: UnsafeMutablePointer<Float>) -> (llama_token, Float) { llm.argmax(logits) }

    /// 左文脈として渡す文字数。40 → 80 字で先読みの的中が上がり、それ以上では変わらなかった (Tools/eval)。
    private static let contextLength = 100

    private func contextPrefix(_ left: String) -> String {
        let trimmed = String(left.suffix(Self.contextLength))
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

    public func predict(readingPrefix: String, leftContext: String, habit: HabitHint?, isCancelled: () -> Bool) -> NeuralPrediction? {
        lock.lock(); defer { lock.unlock() }
        let prompt = contextPrefix(leftContext) + Self.inputTag + readingPrefix.katakana
        var tokens = tokenize(prompt)
        var continuation: [UInt8] = []
        var confidence: Float = 1
        // 読みの続きを、確信が続くかぎり伸ばす。句読点・入力の終わり・自信のない文字の手前で止める。
        for _ in 0..<24 {
            if isCancelled() { return nil }
            guard let l = logits(tokens) else { return nil }
            var (tok, p) = argmax(l)
            // 自分の書き癖を混ぜる: 混ぜた確率 = (1 - w) × LLM + w × 書き癖
            let soFar = readingPrefix + String(decoding: continuation, as: UTF8.self).hiragana
            if let h = habit?(soFar), h.weight > 0 {
                let llmChoice = String(decoding: piece(tok), as: UTF8.self).hiragana
                p = (1 - h.weight) * p + h.weight * (llmChoice.count == 1 ? h.next[llmChoice.first!] ?? 0 : 0)
                for (kana, share) in h.next {
                    guard let t = token(for: kana), t != tok else { continue }
                    let mixed = (1 - h.weight) * llm.probability(of: t, in: l) + h.weight * share
                    if mixed > p { (tok, p) = (t, mixed) }
                }
            }
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

    /// かな 1 文字に対応するトークン (zenz は読みをカタカナ 1 文字ずつ扱う)。
    private var kanaTokens: [Character: llama_token?] = [:]

    private func token(for kana: Character) -> llama_token? {
        if let t = kanaTokens[kana] { return t }
        let t = llm.tokenize(String(kana).katakana, addSpecial: false)
        let one = t.count == 1 ? t[0] : nil
        kanaTokens[kana] = one
        return one
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

    /// 採点のしかた。
    public enum Scoring {
        /// 文章そのものの自然さ。
        case text
        /// 読み (かな) の並びの自然さ。
        case reading
        /// 与えた読みが、その表記に変換される確からしさ。
        case surface(reading: String)
    }

    /// 文の各トークンをモデルがどれだけ確からしいと見ているか (確率) を返す。
    public func score(_ text: String, leftContext: String = "", as scoring: Scoring) -> [(String, Float)] {
        lock.lock(); defer { lock.unlock() }
        let head: String, body: String
        switch scoring {
        case .text: (head, body) = (Self.contextTag + String(leftContext.suffix(Self.contextLength)), text)
        case .reading: (head, body) = (contextPrefix(leftContext) + Self.inputTag, text.katakana)
        case .surface(let reading): (head, body) = (contextPrefix(leftContext) + Self.inputTag + reading.katakana + Self.outputTag, text)
        }
        let start = tokenize(head).count
        var tokens = tokenize(head + body)
        if case .surface = scoring { tokens.append(eos) }
        guard tokens.count > start, decode(tokens, logitsFrom: start - 1) else { return [] }
        var out: [(String, Float)] = []
        for i in start..<tokens.count {
            guard let l = logits(at: i - 1) else { break }
            out.append((String(decoding: piece(tokens[i]), as: UTF8.self), llm.probability(of: tokens[i], in: l)))
        }
        return out
    }

    /// 対数確率の合計。採点できなければ nil。
    public func logProbability(_ text: String, leftContext: String = "", as scoring: Scoring) -> Float? {
        let r = score(text, leftContext: leftContext, as: scoring)
        return r.isEmpty ? nil : r.reduce(Float(0)) { $0 + log(max($1.1, 1e-30)) }
    }
}

// MARK: 読み直し

extension ZenzModel: ProofreadScorer {
    /// 読み全体を変換し直す。打鍵中の変換とは別に動くので、そちらの当て推量 (lastOutput) には触れない。
    public func reconvert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        var tokens = tokenize(contextPrefix(leftContext) + Self.inputTag + reading.katakana + Self.outputTag)
        var out: [llama_token] = []
        let limit = reading.count * 2 + 8
        while out.count < limit {
            if isCancelled() { return nil }
            guard let l = logits(tokens) else { return nil }
            let tok = argmax(l).0
            if tok == eos { break }
            out.append(tok)
            tokens.append(tok)
        }
        let s = String(decoding: out.flatMap(piece), as: UTF8.self)
        return s.isEmpty || s.unicodeScalars.contains(where: { (0xEE00...0xEE0F).contains($0.value) || $0.value == 0xFFFD }) ? nil : s
    }

    public func logProbability(surface: String, reading: String, leftContext: String) -> Float? {
        logProbability(surface, leftContext: leftContext, as: .surface(reading: reading))
    }

    public func logProbability(text: String, leftContext: String) -> Float? {
        logProbability(text, leftContext: leftContext, as: .text)
    }
}
