import Foundation

/// 文章の 1 トークンと、モデルから見たその確からしさ。
public struct ScoredToken {
    public var text: String
    public var probability: Float
    /// その位置でモデルが続きそうだと見ているトークン (確率の高い順)。
    public var alternatives: [(text: String, probability: Float)]

    public init(text: String, probability: Float, alternatives: [(text: String, probability: Float)]) {
        self.text = text
        self.probability = probability
        self.alternatives = alternatives
    }
}

/// 文章の自然さを採点する役 (LLM)。
public protocol TextScorer: AnyObject {
    /// 文章をトークンごとに採点する。採点できなければ空。
    func tokens(text: String, leftContext: String, alternatives: Int) -> [ScoredToken]
    /// 文章そのものの自然さ (対数確率)。
    func logProbability(text: String, leftContext: String) -> Float?
}

/// 確定した文の、機械的な書き損じ (助詞の重複・取り違え、脱字、同じ語の繰り返し) を挙げる。
///
/// モデルが「ここは不自然」と見ている箇所のまわりで、繰り返しの削除、ひらがな 1 文字の補い、助詞どうしの入れ替えを試し、
/// 文全体の自然さがはっきり上がるものだけを残す。漢字やカタカナの語には手を出さない。
///
/// 入れ替えを助詞どうしに限るのは、脱字を「別の文字への入れ替え」で直そうとして意味を変えてしまうのを避けるため
/// (できすっけ → できたっけ)。自分の過去の文章 260 文で、手を加えていない文への提案は 0 件、仕込んだ書き損じのうち
/// 助詞の重複 75%・語の繰り返し 79%・脱字 38%・助詞の取り違え 23% を正しく直し、誤った直しは脱字の 4% だった (docs/DESIGN.md)。
public final class GrammarChecker {
    public enum Kind: String { case duplicate, substitute, insert }

    public struct Candidate {
        public var kind: Kind
        public var correction: Correction
    }

    private let scorer: TextScorer
    /// この確率を下回るトークンのまわりを疑う。
    public var suspicion: Float = 0.03
    /// 種類ごとの、自然さの伸び (対数) の下限。
    public var minimumGain: [Kind: Float] = [.duplicate: 4, .substitute: 6, .insert: 5]

    public init(scorer: TextScorer) { self.scorer = scorer }

    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n", "\r"]
    private static let maxSentence = 120
    /// 入れ替えを試す助詞。
    private static let particles: Set<Character> = ["を", "が", "に", "で", "は", "と", "も", "へ"]

    /// - Parameter startsMidway: 文章が入力欄の途中から始まっている (先頭の語が切れているかもしれない)。
    public func check(_ text: String, startsMidway: Bool = false, ignoring: Set<String> = [], isCancelled: () -> Bool = { false }) -> Correction? {
        candidates(text, startsMidway: startsMidway, isCancelled: isCancelled)
            .filter { $0.correction.gain >= (minimumGain[$0.kind] ?? 5) && !ignoring.contains($0.correction.key) }
            .max { $0.correction.gain < $1.correction.gain }?.correction
    }

    /// 最後の文への候補すべて (しきい値で絞る前)。
    public func candidates(_ text: String, startsMidway: Bool = false, isCancelled: () -> Bool = { false }) -> [Candidate] {
        let chars = Array(text)
        var end = chars.count
        while end > 0, Self.terminators.contains(chars[end - 1]) || chars[end - 1].isWhitespace { end -= 1 }
        var start = end
        while start > 0, !Self.terminators.contains(chars[start - 1]), end - start < Self.maxSentence { start -= 1 }
        // 文が途中から始まっているなら、先頭は語の途中かもしれないので触らない
        let cutMidway = start > 0 ? !Self.terminators.contains(chars[start - 1]) : startsMidway
        let firstSite = cutMidway ? 4 : 1
        let complete = end < chars.count
        guard end - start >= 4 else { return [] }
        let s = Array(chars[start..<end])
        let left = String(chars[..<start].suffix(100))
        let tokens = scorer.tokens(text: String(s), leftContext: left, alternatives: 4)
        guard !tokens.isEmpty, tokens.map(\.text).joined() == String(s) else { return [] }
        let base = tokens.reduce(Float(0)) { $0 + log(max($1.probability, 1e-30)) }

        // トークンの文字位置
        var offsets: [Int] = []
        var o = 0
        for t in tokens { offsets.append(o); o += t.text.count }

        var sites = Set<Int>()
        for (i, t) in tokens.enumerated() where t.probability < suspicion {
            sites.insert(i)
            if i > 0 { sites.insert(i - 1) }
        }
        var edits: [String: (Kind, Range<Int>, String)] = [:]   // 直した文 → (種類, 置き換える範囲, 置き換え)
        func add(_ kind: Kind, _ range: Range<Int>, _ rep: String) {
            let fixed = String(s[..<range.lowerBound]) + rep + String(s[range.upperBound...])
            if edits[fixed] == nil { edits[fixed] = (kind, range, rep) }
        }
        for i in sites.sorted() {
            let t = tokens[i], at = offsets[i]
            guard at >= firstSite else { continue }
            // 同じ並びの繰り返し (直前の n 文字と同じ) を 1 つにする
            for n in 1...6 where at >= n && at + n <= s.count && s[(at - n)..<at] == s[at..<(at + n)] {
                if n == 1 ? !Self.isHiragana(s[at]) : !s[at..<(at + n)].allSatisfy(Proofreader.isJapanese) { continue }
                add(.duplicate, at..<(at + n), "")
            }
            let particle = t.text.count == 1 && Self.particles.contains(t.text.first!)
            let last = i == tokens.count - 1
            for alt in t.alternatives where alt.text.count == 1 && Self.isHiragana(alt.text.first!) && alt.text != t.text {
                // 文が終わっていないとき、末尾の文字は続きしだいなので入れ替えない
                if particle && Self.particles.contains(alt.text.first!) && (!last || complete) { add(.substitute, at..<(at + 1), alt.text) }
                // 日本語の続きにだけ補う (文頭や英数字のあとには補わない)
                if Proofreader.isJapanese(s[at - 1]) { add(.insert, at..<at, alt.text) }
            }
        }
        var out: [Candidate] = []
        for (fixed, e) in edits {
            if isCancelled() { return [] }
            guard let p = scorer.logProbability(text: fixed, leftContext: left) else { continue }
            let (kind, range, rep) = e
            let lo = max(0, range.lowerBound - 2), hi = min(s.count, range.upperBound + 2)
            let c = Correction(
                from: String(s[lo..<hi]),
                to: String(s[lo..<range.lowerBound]) + rep + String(s[range.upperBound..<hi]),
                tail: String(chars[(start + range.lowerBound)...]),
                fixedTail: rep + String(chars[(start + range.upperBound)...]),
                gain: p - base, textGain: p - base)
            out.append(Candidate(kind: kind, correction: c))
        }
        return out
    }

    static func isHiragana(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x3096).contains(v)
    }
}
