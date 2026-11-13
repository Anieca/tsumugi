import Foundation

/// ローマ字 → かな の変換表。
enum RomajiTable {
    static let table: [String: String] = build()
    /// 表のキーの真の接頭辞 (続きの入力を待つべき文字列) の集合。
    static let prefixes: Set<String> = {
        var s = Set<String>()
        for key in table.keys {
            var p = key
            p.removeLast()
            while !p.isEmpty {
                s.insert(p)
                p.removeLast()
            }
        }
        return s
    }()

    private static func build() -> [String: String] {
        var t: [String: String] = [:]
        let vowels = ["a", "i", "u", "e", "o"]
        func row(_ prefix: String, _ kana: [String]) {
            for (v, k) in zip(vowels, kana) where !k.isEmpty { t[prefix + v] = k }
        }
        row("", ["あ", "い", "う", "え", "お"])
        row("k", ["か", "き", "く", "け", "こ"])
        row("s", ["さ", "し", "す", "せ", "そ"])
        row("t", ["た", "ち", "つ", "て", "と"])
        row("n", ["な", "に", "ぬ", "ね", "の"])
        row("h", ["は", "ひ", "ふ", "へ", "ほ"])
        row("m", ["ま", "み", "む", "め", "も"])
        row("y", ["や", "", "ゆ", "いぇ", "よ"])
        row("r", ["ら", "り", "る", "れ", "ろ"])
        row("w", ["わ", "うぃ", "う", "うぇ", "を"])
        row("g", ["が", "ぎ", "ぐ", "げ", "ご"])
        row("z", ["ざ", "じ", "ず", "ぜ", "ぞ"])
        row("d", ["だ", "ぢ", "づ", "で", "ど"])
        row("b", ["ば", "び", "ぶ", "べ", "ぼ"])
        row("p", ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"])
        row("f", ["ふぁ", "ふぃ", "ふ", "ふぇ", "ふぉ"])
        row("j", ["じゃ", "じ", "じゅ", "じぇ", "じょ"])
        row("v", ["ゔぁ", "ゔぃ", "ゔ", "ゔぇ", "ゔぉ"])
        row("c", ["か", "し", "く", "せ", "こ"])
        row("q", ["くぁ", "くぃ", "く", "くぇ", "くぉ"])
        row("l", ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"])
        row("x", ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"])
        // 拗音
        let youon: [(String, String)] = [
            ("ky", "き"), ("sy", "し"), ("ty", "ち"), ("ny", "に"), ("hy", "ひ"), ("my", "み"),
            ("ry", "り"), ("gy", "ぎ"), ("zy", "じ"), ("dy", "ぢ"), ("by", "び"), ("py", "ぴ"),
            ("jy", "じ"), ("cy", "ち"), ("fy", "ふ"),
        ]
        for (p, k) in youon { row(p, [k + "ゃ", k + "ぃ", k + "ゅ", k + "ぇ", k + "ょ"]) }
        row("sh", ["しゃ", "し", "しゅ", "しぇ", "しょ"])
        row("ch", ["ちゃ", "ち", "ちゅ", "ちぇ", "ちょ"])
        row("ts", ["つぁ", "つぃ", "つ", "つぇ", "つぉ"])
        row("th", ["てゃ", "てぃ", "てゅ", "てぇ", "てょ"])
        row("dh", ["でゃ", "でぃ", "でゅ", "でぇ", "でょ"])
        row("wh", ["うぁ", "うぃ", "う", "うぇ", "うぉ"])
        row("tw", ["とぁ", "とぃ", "とぅ", "とぇ", "とぉ"])
        row("dw", ["どぁ", "どぃ", "どぅ", "どぇ", "どぉ"])
        row("kw", ["くぁ", "くぃ", "くぅ", "くぇ", "くぉ"])
        row("gw", ["ぐぁ", "ぐぃ", "ぐぅ", "ぐぇ", "ぐぉ"])
        row("ly", ["ゃ", "ぃ", "ゅ", "ぇ", "ょ"])
        row("xy", ["ゃ", "ぃ", "ゅ", "ぇ", "ょ"])
        for (k, v) in [
            "nn": "ん", "n'": "ん", "xn": "ん",
            "ltu": "っ", "xtu": "っ", "ltsu": "っ", "xtsu": "っ",
            "lwa": "ゎ", "xwa": "ゎ", "lka": "ヵ", "xka": "ヵ", "lke": "ヶ", "xke": "ヶ",
            "wi": "うぃ", "we": "うぇ", "ye": "いぇ",
            "-": "ー", ",": "、", ".": "。", "/": "・", "[": "「", "]": "」",
            "?": "？", "!": "！", "~": "〜",
            "z.": "…", "z,": "‥", "z-": "〜", "z/": "・", "z[": "『", "z]": "』",
            "zh": "←", "zj": "↓", "zk": "↑", "zl": "→",
        ] { t[k] = v }
        return t
    }
}

/// 打鍵を受け取って「かな + 未確定ローマ字」を管理する。
public struct Composer: Equatable {
    struct Unit: Equatable {
        var kana: String
        var raw: String
        /// かなにできず英字のまま取り込んだ打鍵 (例: "ds" の "d")。後ろを消したら打ちかけに戻す。
        var stray = false
    }

    private var units: [Unit] = []
    /// まだかなになっていないローマ字 (例: "k", "sh")。
    public private(set) var pending: String = ""

    public init() {}

    public var isEmpty: Bool { units.isEmpty && pending.isEmpty }
    /// かなに確定している部分 (変換対象の読み)。
    public var kana: String { units.map(\.kana).joined() }
    /// 打鍵そのまま (英数変換用)。
    public var raw: String { units.map(\.raw).joined() + pending }

    /// 大文字を打つと、その未確定文字列の間は英字をそのまま入力する (例: "Apple")。
    private var latinMode = false

    public mutating func input(_ c: Character) {
        if c.isUppercase, c.isASCII {
            flush()
            latinMode = true
        }
        if latinMode, c.isASCII, c.isLetter || c.isNumber || c == " " || c == "'" || c == "." || c == "-" {
            emit(String(c), raw: String(c))
            return
        }
        pending.append(c)
        resolve()
    }

    public mutating func backspace() {
        if !pending.isEmpty {
            pending.removeLast()
        } else if var last = units.popLast() {
            last.kana.removeLast()
            if !last.kana.isEmpty { units.append(last) }
        }
        reclaimStray()
        if units.isEmpty && pending.isEmpty { latinMode = false }
    }

    /// 末尾に残った英字を打ちかけのローマ字へ戻す。"d" "s" 削除 "e" を「で」にするため。
    private mutating func reclaimStray() {
        guard pending.isEmpty else { return }
        while let last = units.last, last.stray, RomajiTable.prefixes.contains(last.raw + pending) {
            pending = last.raw + pending
            units.removeLast()
        }
    }

    /// 変換や確定の直前に呼ぶ。末尾の "n" を「ん」にし、残った英字はそのまま文字として取り込む。
    public mutating func flush() {
        if pending == "n" {
            emit("ん", raw: "n")
            pending = ""
        }
        while let c = pending.first {
            emit(String(c), raw: String(c))
            pending.removeFirst()
        }
    }

    public mutating func clear() {
        units.removeAll()
        pending = ""
        latinMode = false
    }

    private mutating func emit(_ kana: String, raw: String) {
        units.append(Unit(kana: kana, raw: raw))
    }

    private mutating func resolve() {
        while !pending.isEmpty {
            if let k = RomajiTable.table[pending], !RomajiTable.prefixes.contains(pending) {
                emit(k, raw: pending)
                pending = ""
                return
            }
            if RomajiTable.prefixes.contains(pending) { return }
            // これ以上伸ばしても表に当たらない。
            if let k = RomajiTable.table[pending] {
                emit(k, raw: pending)
                pending = ""
                return
            }
            // 最後の 1 文字を除いた部分が完成形ならそこで切る (例: "n" + "k")。
            let first = pending.first!
            let rest = pending.dropFirst()
            if let second = rest.first {
                if first == "n", !"aiueoyn'".contains(second) {
                    emit("ん", raw: "n")
                    pending.removeFirst()
                    continue
                }
                if first == second, first.isLetter, first.isLowercase, !"aiueon".contains(first) {
                    emit("っ", raw: String(first))
                    pending.removeFirst()
                    continue
                }
                // 先頭から最長一致で切り出す
                var cut = pending
                cut.removeLast()
                var matched = false
                while !cut.isEmpty {
                    if let k = RomajiTable.table[cut] {
                        emit(k, raw: cut)
                        pending.removeFirst(cut.count)
                        matched = true
                        break
                    }
                    cut.removeLast()
                }
                if matched { continue }
            }
            // 変換できない文字はそのまま文字として取り込む
            if rest.isEmpty, RomajiTable.prefixes.contains(String(first)) { return }
            units.append(Unit(kana: String(first), raw: String(first), stray: true))
            pending.removeFirst()
        }
    }
}

public extension String {
    /// ひらがな → カタカナ
    var katakana: String {
        String(String.UnicodeScalarView(unicodeScalars.map { s in
            (0x3041...0x3096).contains(s.value) ? Unicode.Scalar(s.value + 0x60)! : s
        }))
    }

    /// カタカナ → ひらがな
    var hiragana: String {
        String(String.UnicodeScalarView(unicodeScalars.map { s in
            (0x30A1...0x30F6).contains(s.value) ? Unicode.Scalar(s.value - 0x60)! : s
        }))
    }
}

extension Character {
    var isKana: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
    }
}
