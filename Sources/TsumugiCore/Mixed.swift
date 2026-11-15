import Foundation

/// 自分が書いたことのある英単語の語彙。日本語モードのまま打った英単語を見分けるのに使う。
/// 文章そのものは持たず、単語とその回数だけをこの Mac に保存する。
public final class LatinLexicon {
    struct Entry: Codable {
        /// 表記 (大文字小文字の違い) ごとの回数。
        var forms: [String: Int] = [:]
        /// かなとして打ったのに英字にされた、と直された回数。
        var rejected = 0
        var count: Int { forms.values.reduce(0, +) }
    }

    private var words: [String: Entry] = [:]
    private let fileURL: URL?
    private let lock = NSLock()
    private var saveScheduled = false

    public static func defaultURL() -> URL {
        UserModel.defaultURL().deletingLastPathComponent().appendingPathComponent("latin_words.json")
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            words = loaded
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return words.count }

    /// 英単語として扱ってよい語なら、ふだんの表記と回数。
    /// 1 回見かけただけの語は、切り分けの誤りかもしれないので、まだ語彙に数えない。
    public func lookup(_ lower: String) -> (form: String, count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = words[lower] else { return nil }
        let n = e.count - e.rejected * 2
        guard n >= 2, let form = e.forms.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return (form, n)
    }

    /// - Parameter weight: 自分で英字だと示した語 (大文字ではじめた・英数キーで直した) は 2 以上にして、すぐ語彙に入れる。
    public func learn(_ surface: String, weight: Int = 1) {
        let lower = surface.lowercased()
        guard lower.count >= 2, lower.count <= 30, lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "'") }) else { return }
        lock.lock()
        words[lower, default: Entry()].forms[surface, default: 0] += weight
        lock.unlock()
        scheduleSave()
    }

    /// 英字にされたのを、かなに直された。
    public func reject(_ lower: String) {
        lock.lock()
        if words[lower] != nil { words[lower]!.rejected += 1 }
        lock.unlock()
        scheduleSave()
    }

    public func forgetAll() {
        lock.lock()
        words.removeAll()
        lock.unlock()
        save()
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        let already = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
    }

    public func save() {
        guard let fileURL else { return }
        lock.lock()
        saveScheduled = false
        let snapshot = words
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// OS に付属する英単語の一覧 (初めて打つ語の手がかり)。
    public static let systemWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
}

/// 打鍵列を切り分けた 1 区間。
public struct MixedPiece: Equatable {
    public var isEnglish: Bool
    /// 打鍵そのまま。
    public var raw: String
    /// 英字なら表示する表記、かななら読み。
    public var text: String
}

public struct MixedPlan: Equatable {
    public var pieces: [MixedPiece]
    /// まだかなになっていない末尾のローマ字。
    public var pending: String
    public var hasEnglish: Bool { pieces.contains(where: \.isEnglish) }
}

/// 日本語モードのまま続けて打った打鍵列 ("tabdenaosu") を、英単語の区間とかなの区間に切り分ける。
///
/// 英字とみなす手がかりは 4 つ: 自分が書いたことのある語、大文字ではじめた語、ローマ字として成り立たない綴り、
/// OS 付属の単語表にある語。どの切り方がよいかは、かなの区間を辞書で変換したときの確からしさと比べて決める。
/// 費用の値は自分の過去の入力 (英字まじりの句 522 個) で合わせた (docs/DESIGN.md)。
public final class MixedSegmenter {
    private let converter: Converter
    public let lexicon: LatinLexicon
    /// OS 付属の単語表を使うか (読み込みに少しかかるので、計測やテストでは切れるようにしてある)。
    public var usesSystemWords = true

    var userBase = 3500.0, userLog = 300.0, userFloor = 1500.0
    var systemCost = 7000.0, unknownBase = 3000.0, unknownPer = 1500.0
    var shortPenalty = 2500.0, switchCost = 1000.0, capitalBase = 1500.0
    /// かなとしてもふつうの語 (メモ / memo) を英字にするときの上乗せ。
    var ambiguousPenalty = 2500.0
    /// 打っている途中の末尾の語を英字にするときの上乗せ。
    var tailPenalty = 3000.0

    private var conversions: [String: Conversion?] = [:]
    private var parses: [String: (kana: String, pending: String)?] = [:]

    public init(converter: Converter, lexicon: LatinLexicon) {
        self.converter = converter
        self.lexicon = lexicon
    }

    public func setCost(_ name: String, _ value: Double) {
        switch name {
        case "user": userBase = value
        case "system": systemCost = value
        case "unknown": unknownBase = value
        case "unknownPer": unknownPer = value
        case "short": shortPenalty = value
        case "switch": switchCost = value
        case "capital": capitalBase = value
        case "ambiguous": ambiguousPenalty = value
        case "tail": tailPenalty = value
        default: break
        }
    }

    // MARK: かな

    /// 打鍵列がきれいにかなになるなら、そのかなと、末尾の打ちかけ。
    private func parse(_ raw: String, allowPending: Bool) -> (kana: String, pending: String)? {
        let key = (allowPending ? "p" : "f") + raw
        if let hit = parses[key] { return hit }
        var result: (kana: String, pending: String)?
        if !raw.contains(where: \.isUppercase) {
            var c = Composer()
            for ch in raw { c.input(ch) }
            if !allowPending { c.flush() }
            let kana = c.kana
            if !kana.contains(where: \.isASCII), !(kana.isEmpty && c.pending.isEmpty) { result = (kana, c.pending) }
        }
        if parses.count > 20000 { parses.removeAll() }
        parses[key] = result
        return result
    }

    private func conversion(_ kana: String) -> Conversion? {
        if let hit = conversions[kana] { return hit }
        let c = converter.convert(kana).first
        if conversions.count > 5000 { conversions.removeAll() }
        conversions[kana] = c
        return c
    }

    // MARK: 英字

    private static let suffixes = ["ing", "ed", "es", "er", "ly", "s", "d"]

    private func inSystem(_ w: String) -> Bool {
        guard usesSystemWords, w.count >= 4 else { return false }
        let words = LatinLexicon.systemWords
        if words.contains(w) { return true }
        // 活用形 (単語表に載っていないことが多い)
        for suffix in Self.suffixes where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            let stem = String(w.dropLast(suffix.count))
            if words.contains(stem) || words.contains(stem + "e") || lexicon.lookup(stem) != nil { return true }
            if stem.count >= 4, stem.last == stem.dropLast().last, words.contains(String(stem.dropLast())) { return true }
        }
        return false
    }

    /// 英単語とみなす費用。語彙にも単語表にもなければ nil。
    private func wordCost(_ w: String) -> Double? {
        var cost: Double
        if let e = lexicon.lookup(w), w.count >= 3 || e.count >= 3 {
            cost = max(userFloor, userBase - userLog * log(Double(e.count))) + (w.count <= 2 ? shortPenalty : 0)
        } else if inSystem(w) {
            cost = systemCost
        } else {
            return nil
        }
        // かなとして打っても 1 語のふつうの言葉になるなら、英字にするのは控えめに
        if let p = parse(w, allowPending: false), let c = conversion(p.kana), c.segments.count == 1, c.cost < 6000 {
            cost += ambiguousPenalty
        }
        return switchCost + cost
    }

    /// 英字の区間を表示する表記。
    public func form(_ raw: String) -> String {
        if raw.contains(where: \.isUppercase) { return raw }
        return lexicon.lookup(raw)?.form ?? raw
    }

    // MARK: 切り分け

    private struct Span: Hashable { var lo: Int; var hi: Int }

    /// - Parameters:
    ///   - pins: 英字だと指定された区間 (打鍵列の中の位置)。
    ///   - final: 変換・確定の直前。打ちかけのローマ字を残さない。
    /// - Returns: 英字の区間がなければ nil (これまでどおりの変換に任せる)。
    public func plan(raw: String, pins: [Range<Int>] = [], final: Bool = false) -> MixedPlan? {
        let chars = Array(raw)
        guard !chars.isEmpty, chars.count <= 160 else { return nil }
        // 長音 (-) はかなの一部なので、英字と同じ並びとして扱う
        func isWordChar(_ c: Character) -> Bool { c.isASCII && c.isLetter || c == "-" }
        var pieces: [MixedPiece] = []
        var pending = ""
        var i = 0
        while i < chars.count {
            var j = i
            let word = isWordChar(chars[i])
            while j < chars.count, isWordChar(chars[j]) == word { j += 1 }
            let part = String(chars[i..<j])
            let last = j == chars.count
            if word {
                let local = pins.compactMap { p -> Range<Int>? in
                    p.lowerBound >= i && p.upperBound <= j ? (p.lowerBound - i)..<(p.upperBound - i) : nil
                }
                if let solved = solve(part, pins: local, allowPending: last && !final) {
                    pieces += solved.pieces
                    pending = solved.pending
                    i = j
                    continue
                }
            }
            do {
                // 記号や数字は、これまでどおりローマ字入力の規則に通す (, → 、)
                var c = Composer()
                for ch in part { c.input(ch) }
                if last && !final { pending = c.pending } else { c.flush() }
                pieces.append(MixedPiece(isEnglish: false, raw: part, text: c.kana))
            }
            i = j
        }
        // 隣り合うかなは 1 つにまとめて、続けて変換する
        var merged: [MixedPiece] = []
        for p in pieces where !p.raw.isEmpty {
            if let lastPiece = merged.last, lastPiece.isEnglish == p.isEnglish {
                merged[merged.count - 1].raw += p.raw
                // 空白なしで続く英字は 1 語
                merged[merged.count - 1].text = p.isEnglish ? form(merged[merged.count - 1].raw) : lastPiece.text + p.text
            } else {
                merged.append(p)
            }
        }
        let plan = MixedPlan(pieces: merged.filter { !$0.text.isEmpty }, pending: pending)
        return plan.hasEnglish ? plan : nil
    }

    private func solve(_ raw: String, pins: [Range<Int>], allowPending: Bool) -> (pieces: [MixedPiece], pending: String)? {
        let r = Array(raw)
        let n = r.count
        let lower = Array(raw.lowercased())
        func sub(_ a: Int, _ b: Int) -> String { String(r[a..<b]) }

        var eng: [Span: Double] = [:]
        func add(_ s: Span, _ c: Double) { if c < eng[s] ?? .infinity { eng[s] = c } }
        for i in 0..<n {
            for j in (i + 2)...max(i + 2, min(n, i + 20)) where j <= n {
                if let c = wordCost(String(lower[i..<j])) { add(Span(lo: i, hi: j), c) }
            }
        }
        // 大文字ではじめた語: そこから英字。どこまでかは後ろの日本語の収まりで決める
        for i in 0..<n where r[i].isUppercase && (i == 0 || !r[i - 1].isUppercase) {
            for j in (i + 1)...min(n, i + 20) {
                let known = j - i >= 2 && wordCost(String(lower[i..<j])) != nil
                add(Span(lo: i, hi: j), switchCost + capitalBase + (known ? 0 : unknownPer * Double(j - i)))
            }
        }
        // かなにならない打鍵のまわり: 語彙にない英単語として、割高に認める
        var c = Composer()
        var bad: [Int] = []
        for (i, ch) in lower.enumerated() {
            c.input(ch)
            if c.kana.contains(where: \.isASCII) { bad.append(i); c = Composer() }
        }
        if !allowPending, !c.pending.isEmpty, c.pending != "n" { bad.append(n - 1) }
        for b in Set(bad.flatMap { [$0, max(0, $0 - 1)] }) {
            for i in max(0, b - 14)...b {
                for j in (b + 1)...min(n, b + 14) where j - i >= 2 && j - i <= 20 {
                    add(Span(lo: i, hi: j), switchCost + unknownBase + unknownPer * Double(j - i))
                }
            }
        }
        // 打っている途中: 末尾の語がかなとしても読めるうちは、まだ日本語を打っている途中かもしれない。
        // 英字にするのを控えめにして、表示が英字とかなの間で揺れないようにする
        if allowPending {
            // 末尾: 語のあとに、打ちかけのローマ字 (まだかなになっていない 1〜2 打鍵) しかないところも含める
            var tails: Set<Int> = [n]
            for t in max(0, n - 3)..<n {
                if let p = parse(String(lower[t..<n]), allowPending: true), p.kana.isEmpty { tails.insert(t) }
            }
            for (s, cost) in eng where tails.contains(s.hi) && parse(String(lower[s.lo..<n]), allowPending: true) != nil {
                eng[s] = cost + tailPenalty
            }
        }
        // 指定された区間は必ず英字にし、それと食い違う候補は捨てる
        if !pins.isEmpty {
            eng = eng.filter { s, _ in !pins.contains { $0.overlaps(s.lo..<s.hi) } }
            for p in pins where p.lowerBound < p.upperBound && p.upperBound <= n { eng[Span(lo: p.lowerBound, hi: p.upperBound)] = 0 }
        }
        guard !eng.isEmpty else { return nil }

        var starts = Set(eng.keys.map(\.lo)); starts.insert(n)
        var ends = Set(eng.keys.map(\.hi)); ends.insert(0)
        // best[位置][0: 直前がかな, 1: 直前が英字 (または先頭)]
        var best = [[Double]](repeating: [.infinity, .infinity], count: n + 1)
        var back = [[(from: Int, state: Int)?]](repeating: [nil, nil], count: n + 1)
        best[0][1] = 0
        let byLo = Dictionary(grouping: eng.keys, by: \.lo)
        let pinned = { (a: Int, b: Int) in pins.contains { $0.overlaps(a..<b) } }
        for i in 0..<n {
            for state in 0...1 where best[i][state] < .infinity {
                let b = best[i][state]
                for s in byLo[i] ?? [] {
                    let total = b + eng[s]!
                    if total < best[s.hi][1] { best[s.hi][1] = total; back[s.hi][1] = (i, state) }
                }
                guard state == 1, ends.contains(i) else { continue }
                for j in starts where j > i && !pinned(i, j) {
                    guard let p = parse(sub(i, j), allowPending: allowPending && j == n) else { continue }
                    var cost = 300.0   // 打ちかけだけの区間
                    if !p.kana.isEmpty {
                        guard let conv = conversion(p.kana) else { continue }
                        cost = Double(conv.cost)
                    }
                    let total = b + cost
                    if total < best[j][0] { best[j][0] = total; back[j][0] = (i, 1) }
                }
            }
        }
        var state = best[n][0] <= best[n][1] ? 0 : 1
        guard best[n][state] < .infinity else { return nil }
        var pieces: [MixedPiece] = []
        var pending = ""
        var pos = n
        while pos > 0, let prev = back[pos][state] {
            let rawPart = sub(prev.from, pos)
            if state == 1 {
                pieces.append(MixedPiece(isEnglish: true, raw: rawPart, text: form(rawPart)))
            } else if let p = parse(rawPart, allowPending: allowPending && pos == n) {
                if pos == n { pending = p.pending }
                pieces.append(MixedPiece(isEnglish: false, raw: rawPart, text: p.kana))
            }
            pos = prev.from
            state = prev.state
        }
        guard pieces.contains(where: \.isEnglish) else { return nil }
        return (pieces.reversed(), pending)
    }

    /// 「末尾は英単語だ」と指定されたときの、語のはじまりの候補 (確からしい順)。
    public func tailStarts(raw: String, pins: [Range<Int>] = []) -> [Int] {
        let chars = Array(raw)
        let n = chars.count
        var lo = n
        while lo > 0, chars[lo - 1].isASCII, chars[lo - 1].isLetter, n - lo < 24 { lo -= 1 }
        lo = max(lo, pins.map(\.upperBound).filter { $0 <= n }.max() ?? 0)
        guard n - lo >= 1 else { return [] }
        var scored: [(Int, Double)] = []
        for start in lo..<n where n - start >= 1 {
            let word = String(chars[start..<n]).lowercased()
            // 手前がかなとして成り立つこと
            var before = 0.0
            if start > lo {
                guard let p = parse(String(chars[lo..<start]), allowPending: false), let conv = conversion(p.kana) else { continue }
                before = Double(conv.cost)
            }
            let known = word.count >= 2 ? wordCost(word) : nil
            let cost = known ?? (unknownBase + unknownPer * Double(word.count) + (word.count < 3 ? shortPenalty * 2 : 0))
            scored.append((start, before + cost))
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
