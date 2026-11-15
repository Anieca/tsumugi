import Foundation

/// 読み直しに使う採点役 (LLM)。
public protocol ProofreadScorer: AnyObject {
    /// 読み全体を、左文脈を踏まえて変換し直す。
    func reconvert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String?
    /// 読みがその表記に変換される確からしさ (対数確率)。
    func logProbability(surface: String, reading: String, leftContext: String) -> Float?
    /// 文章そのものの自然さ (対数確率)。
    func logProbability(text: String, leftContext: String) -> Float?
}

/// 確定済みの文章への直しの提案 1 件。
public struct Correction: Equatable {
    /// 表示用: 直す前と直した後 (どこの話かわかるよう、前後 1 文字を添える)。
    public var from: String
    public var to: String
    /// 直す箇所の先頭からカーソルまでの、いまの文章。入力先を書き換える前に、これと一致するか確かめる。
    public var tail: String
    /// 同じ範囲の、直した後の文章。
    public var fixedTail: String
    /// 読みに対する確からしさが、直すとどれだけ上がるか。
    public var gain: Float

    /// 同じ提案かどうかを見分ける鍵 (見送った提案を覚えるのに使う)。
    public var key: String { from + "→" + to }

    public init(from: String, to: String, tail: String, fixedTail: String, gain: Float) {
        self.from = from
        self.to = to
        self.tail = tail
        self.fixedTail = fixedTail
        self.gain = gain
    }
}

/// 確定した文を、文全体の読みでもう一度変換し直し、そのほうがはっきり確からしい箇所を直しとして挙げる。
///
/// 打っている最中の変換は、その時点までの読みしか知らない。句ごとに確定していくと、あとに続く言葉で
/// 決まるはずの同音異義語 (仕様率 / 使用率) を取り違えたままになる。文がまとまってから読み直せば拾える。
/// 助詞の誤りや言い回しには手を出さない (意味を変えてしまうため)。
public final class Proofreader {
    private let converter: Converter
    private let scorer: ProofreadScorer

    /// 読みに対する確からしさの伸び (対数) がこれ以上で、
    public var minimumGain: Float = 3
    /// かつ文章としての自然さの伸びもこれ以上のときだけ提案する。
    /// 自分の過去の文章 538 文で、提案 16 件のうち誤提案 3 件・表記の好み 3 件に収まった値 (docs/DESIGN.md)。
    public var minimumTextGain: Float = 2

    private var cache: [String: [Found]] = [:]
    private let lock = NSLock()

    public init(converter: Converter, scorer: ProofreadScorer) {
        self.converter = converter
        self.scorer = scorer
    }

    private struct Found {
        var range: Range<Int>      // 一続きの日本語 (run) の中での位置
        var replacement: String
        var gain: Float
    }

    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n", "\r"]
    /// 一度に読み直す長さの上限 (文字)。
    private static let maxSentence = 120
    /// 入力先から読める文脈の長さ。これ以上あるときは、先頭の語が途中で切れているかもしれない。
    private static let contextLimit = 290

    /// カーソルより前の文章のうち、最後の文を読み直す。
    /// - Parameter ignoring: 提案しない直しの鍵 (`Correction.key`)。
    /// - Returns: いちばん確からしい直し。なければ nil。
    public func check(_ text: String, ignoring: Set<String> = [], isCancelled: () -> Bool = { false }) -> Correction? {
        let chars = Array(text)
        var end = chars.count
        while end > 0, Self.terminators.contains(chars[end - 1]) || chars[end - 1].isWhitespace { end -= 1 }
        var start = end
        while start > 0, !Self.terminators.contains(chars[start - 1]), end - start < Self.maxSentence { start -= 1 }
        let cutMidway = start > 0 && !Self.terminators.contains(chars[start - 1]) || start == 0 && chars.count >= Self.contextLimit

        var best: Correction?
        var i = start
        var first = true
        while i < end {
            guard Self.isJapanese(chars[i]) else { i += 1; continue }
            var j = i
            while j < end, Self.isJapanese(chars[j]) { j += 1 }
            defer { i = j; first = false }
            // 途中から始まっている語は読みを取り違えるので見ない
            if first && cutMidway && i == start { continue }
            guard j - i >= 3 else { continue }
            if isCancelled() { return nil }
            let run = Array(chars[i..<j])
            for f in found(run: String(run), left: String(chars[..<i].suffix(100)), isCancelled: isCancelled) {
                let lo = max(0, f.range.lowerBound - 1), hi = min(run.count, f.range.upperBound + 1)
                let c = Correction(
                    from: String(run[lo..<hi]),
                    to: String(run[lo..<f.range.lowerBound]) + f.replacement + String(run[f.range.upperBound..<hi]),
                    tail: String(chars[(i + f.range.lowerBound)...]),
                    fixedTail: f.replacement + String(chars[(i + f.range.upperBound)...]),
                    gain: f.gain)
                if !ignoring.contains(c.key), best == nil || c.gain > best!.gain { best = c }
            }
        }
        return best
    }

    private func found(run: String, left: String, isCancelled: () -> Bool) -> [Found] {
        let key = left.suffix(40) + "\u{0}" + run
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        guard let result = evaluate(run: run, left: left, isCancelled: isCancelled) else { return [] }  // 中断時は覚えない
        lock.lock()
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }

    /// - Returns: 中断されたら nil。
    private func evaluate(run: String, left: String, isCancelled: () -> Bool) -> [Found]? {
        let reading = Self.reading(of: run)
        guard !reading.isEmpty, reading.allSatisfy({ $0.isKana }) else { return [] }
        guard let again = scorer.reconvert(reading: reading, leftContext: left, isCancelled: isCancelled) else {
            return isCancelled() ? nil : []
        }
        guard again != run, again.allSatisfy(Self.isJapanese),
              converter.match(reading: reading, surface: again) != nil,
              let base = scorer.logProbability(surface: run, reading: reading, leftContext: left),
              let baseText = scorer.logProbability(text: run, leftContext: left) else { return [] }
        let a = Array(run)
        var out: [Found] = []
        for h in Self.hunks(a, Array(again)).prefix(6) {
            if isCancelled() { return nil }
            let fixed = String(a[..<h.range.lowerBound]) + h.replacement + String(a[h.range.upperBound...])
            guard let p = scorer.logProbability(surface: fixed, reading: reading, leftContext: left), p - base >= minimumGain,
                  let t = scorer.logProbability(text: fixed, leftContext: left), t - baseText >= minimumTextGain else { continue }
            out.append(Found(range: h.range, replacement: h.replacement, gain: p - base))
        }
        return out
    }

    // MARK: 部品

    static func isJapanese(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) || v == 0x3005
    }

    /// 文章の読み (ひらがな) を推定する。確定済みの文章には読みが残っていないので、OS の形態素解析に尋ねる。
    static func reading(of text: String) -> String {
        let ns = text as NSString
        let tok = CFStringTokenizerCreate(nil, ns, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWordBoundary,
                                          Locale(identifier: "ja") as CFLocale)
        var out = ""
        var pos = 0
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > pos { out += ns.substring(with: NSRange(location: pos, length: r.location - pos)).hiragana }
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            var reading = surface.hiragana
            if surface.contains(where: { !$0.isKana }),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let m = NSMutableString(string: latin)
                CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
                reading = m as String
            }
            out += reading
            pos = r.location + r.length
        }
        if pos < ns.length { out += ns.substring(from: pos).hiragana }
        return out
    }

    struct Hunk: Equatable {
        var range: Range<Int>
        var replacement: String
    }

    /// a を b に変えるための、連続した置き換えの一覧 (文字単位の最長共通部分列による)。
    static func hunks(_ a: [Character], _ b: [Character]) -> [Hunk] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0, si = 0, sj = 0
        func flush() {
            if si < i || sj < j { out.append(Hunk(range: si..<i, replacement: String(b[sj..<j]))) }
        }
        while i < n, j < m {
            if a[i] == b[j] {
                flush()
                i += 1; j += 1
                si = i; sj = j
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = n; j = m
        flush()
        return out
    }
}
