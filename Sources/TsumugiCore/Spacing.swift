import Foundation

/// 英字と日本語のあいだに半角の空白を入れる書き方 (「Tab で直す」) を、打ち忘れたときに補う。
///
/// 対象は英字 (A-Z, a-z) と、かな・漢字が隣り合うところだけ。数字や記号は人によって流儀が割れるので触らない。
/// 英字 1 文字だけの語 (T シャツ、X 線) は、ひと続きの語であることが多いので空けない。
public enum Spacing {
    static func isLatin(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (0x41...0x5A).contains(a) || (0x61...0x7A).contains(a)
    }

    /// かな・漢字 (句読点や括弧、中黒は含めない)。
    static func isJapanese(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x3096).contains(v) || (0x30A1...0x30FA).contains(v) || v == 0x30FC
            || (0x4E00...0x9FFF).contains(v) || v == 0x3005
    }

    /// これから入れる文字の前に空白が要るか。
    /// - Parameters:
    ///   - before: 入力先の、カーソルより前の文章の末尾 (2 文字あれば足りる)。
    ///   - next: これから入れる文章。
    ///   - betweenWords: 英単語を 1 語ずつ確定しているとき。英字のあとに英字が続くなら、別の語として空ける。
    public static func needsSpace(after before: String, before next: String, betweenWords: Bool = false) -> Bool {
        guard let p = before.last, let n = next.first else { return false }
        if betweenWords, isLatin(p), isLatin(n) { return true }
        if isLatin(p) && isJapanese(n) {
            // 英字 1 文字だけなら空けない
            return before.dropLast().last.map(isLatin) ?? false
        }
        if isJapanese(p) && isLatin(n) {
            // 続きがまだわからない (1 文字ずつ打っている) ときは空ける
            return next.count == 1 || isLatin(next[next.index(after: next.startIndex)])
        }
        return false
    }

    /// 文章の中の、英字と日本語が隣り合うところに空白を入れる。
    public static func spaced(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count >= 2 else { return text }
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 {
                let p = chars[i - 1]
                if isLatin(p) && isJapanese(c) {
                    if i >= 2, isLatin(chars[i - 2]) { out.append(" ") }
                } else if isJapanese(p) && isLatin(c) {
                    if i + 1 < chars.count, isLatin(chars[i + 1]) { out.append(" ") }
                }
            }
            out.append(c)
        }
        return out
    }
}
