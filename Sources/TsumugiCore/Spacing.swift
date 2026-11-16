import Foundation

/// 半角の英数字と日本語のあいだに半角の空白を入れる書き方 (「Tab で直す」「3 件」) を、打ち忘れたときに補う。
///
/// Microsoft の日本語スタイル ガイドの「全角文字と半角文字の間には原則として半角スペースを入れる。ただし句読点、
/// かっこ、スラッシュ、? ! : の前後には入れない」に沿い、自分の過去の文章での割合 (docs/DESIGN.md) で細部を決めている。
///
/// - 英字・数字と、かな・漢字のあいだは空ける (英字のあと 92%、数字のあと 80% が空けていた)。数字に付いた % も数字として扱う。
/// - 句読点・かっこ・スラッシュなどの記号の前後は空けない (記号には触らない)。
/// - 日付や大きな数の単位 (年月日、万億) も例外にしない (過去の文章では半々だったので、ガイドに合わせて空ける)。
/// - 英字 1 文字だけの語は、カタカナ・漢字と続くなら空けない (T シャツではなく Tシャツ)。ひらがなとのあいだは空ける (A の場合)。
/// - コードを囲むバッククォートの外側は空ける (過去の文章ではすべて空けていた)。
public enum Spacing {
    static func isLatin(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (0x41...0x5A).contains(a) || (0x61...0x7A).contains(a)
    }

    static func isDigit(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (0x30...0x39).contains(a)
    }

    static func isAlnum(_ c: Character) -> Bool { isLatin(c) || isDigit(c) }

    static func isHiragana(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x3096).contains(v)
    }

    /// かな・漢字 (句読点や括弧、中黒は含めない)。
    static func isJapanese(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x3096).contains(v) || (0x30A1...0x30FA).contains(v) || v == 0x30FC
            || (0x4E00...0x9FFF).contains(v) || v == 0x3005
    }

    /// 半角の語 (英数字、数字に付いた %、閉じのバッククォート) のあとに日本語が続くとき、空けるか。
    /// - Parameter before: 日本語の直前までの文章 (末尾の 2 文字を見る)。
    private static func spaceAfterHalf(_ before: Substring, japanese n: Character) -> Bool {
        guard let p = before.last else { return false }
        let pp = before.dropLast().last
        if p == "`" {
            // 閉じのバッククォート (直前がコードの中身) のあとだけ空ける。開きのあとは中身なので空けない
            return pp.map { $0.isASCII && !$0.isWhitespace && $0 != "`" } ?? false
        }
        if p == "%" { return pp.map(isDigit) ?? false }
        guard isAlnum(p) else { return false }
        if isDigit(p) { return true }
        // 英字 1 文字だけの語は、ひらがなとのあいだだけ空ける
        if !(pp.map(isAlnum) ?? false) { return isHiragana(n) }
        return true
    }

    /// 日本語のあとに半角の語が続くとき、空けるか。
    /// - Parameters:
    ///   - before: 半角の語の直前までの文章 (末尾の 2 文字を見る)。
    ///   - next: 続く文章 (先頭の 2 文字を見る)。1 文字だけなら、その先はまだわからないものとして扱う。
    private static func spaceBeforeHalf(_ before: Substring, _ next: Substring) -> Bool {
        guard let p = before.last, let n = next.first else { return false }
        guard isAlnum(n) else { return false }
        if isDigit(n) { return true }
        guard let nn = next.dropFirst().first else { return true }
        if isAlnum(nn) { return true }
        // 英字 1 文字だけの語は、ひらがなとのあいだだけ空ける。カタカナ・漢字が続くなら、ひと続きの語 (A型)
        return isHiragana(p) && !(isJapanese(nn) && !isHiragana(nn))
    }

    /// これから入れる文字の前に空白が要るか。
    /// - Parameters:
    ///   - before: 入力先の、カーソルより前の文章の末尾 (2 文字あれば足りる)。
    ///   - next: これから入れる文章。
    ///   - betweenWords: 英単語を 1 語ずつ確定しているとき。英字のあとに英字が続くなら、別の語として空ける。
    public static func needsSpace(after before: String, before next: String, betweenWords: Bool = false) -> Bool {
        guard let p = before.last, let n = next.first else { return false }
        if betweenWords, isLatin(p), isLatin(n) { return true }
        if isJapanese(n) { return spaceAfterHalf(before[...], japanese: n) }
        if isJapanese(p) {
            // 文章の中のバッククォートは開きか閉じかがここではわからないので、1 文字ずつ打っているときだけ開きとみなす
            if n == "`" { return next.count == 1 }
            return spaceBeforeHalf(before[...], next[...])
        }
        return false
    }

    /// 文章の中の、半角の語と日本語が隣り合うところに空白を入れる。
    public static func spaced(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count >= 2 else { return text }
        var out = ""
        var insideCode = false
        for (i, c) in chars.enumerated() {
            if i > 0 {
                let p = chars[i - 1]
                if isJapanese(c) {
                    if p == "`" ? !insideCode : spaceAfterHalf(Substring(chars[max(0, i - 2)..<i]), japanese: c) { out.append(" ") }
                } else if isJapanese(p) {
                    if c == "`" ? !insideCode : spaceBeforeHalf(Substring(chars[max(0, i - 2)..<i]), Substring(chars[i..<min(chars.count, i + 2)]) + (i + 1 < chars.count ? "" : " ")) {
                        out.append(" ")
                    }
                }
            }
            if c == "`" { insideCode.toggle() }
            out.append(c)
        }
        return out
    }
}
