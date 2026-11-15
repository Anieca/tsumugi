import Foundation
import TsumugiCore

/// 試作: 日本語モードのまま、切り替えなしで英単語を打てるかの計測。
/// 過去の文を「空白なし・小文字のローマ字の打鍵列」に戻し、英字の区間とかなの区間に切り分け直せるかを数える。
enum MixedEval {
    struct Span: Hashable { var lo: Int; var hi: Int }

    static func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    static func isJa(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) || v == 0x3005
    }

    /// 文を、日本語・英単語・空白だけでできた塊に分ける。
    static func chunks(_ line: String) -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        var tok = ""
        var kind = 0   // 1 日本語 2 英字
        func endTok() { if !tok.isEmpty { cur.append(tok); tok = "" }; kind = 0 }
        func endChunk() { endTok(); if !cur.isEmpty { out.append(cur); cur = [] } }
        for c in line {
            let k = isJa(c) ? 1 : isLetter(c) ? 2 : 0
            if k == 0 {
                if c == " " { endTok() } else { endChunk() }
                continue
            }
            if k != kind { endTok(); kind = k }
            tok.append(c)
        }
        endChunk()
        return out
    }

    static func run(train: [String], test: String, converter: Converter, verbose: Bool) throws {
        let lexicon = LatinLexicon(fileURL: nil)
        let seg = MixedSegmenter(converter: converter, lexicon: lexicon)
        let env = ProcessInfo.processInfo.environment
        for name in ["user", "system", "unknown", "unknownPer", "short", "switch", "capital", "ambiguous", "tail"] {
            if let v = env["MX_" + name.uppercased()].flatMap(Double.init) { seg.setCost(name, v) }
        }
        seg.usesSystemWords = env["MX_NOSYS"] == nil
        let keepCase = env["MX_LOWER"] == nil
        for path in train {
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                for chunk in chunks(String(line)) {
                    for w in chunk where isLetter(w.first!) { lexicon.learn(w) }
                }
            }
        }
        var prefixes = 0, prefixBad = 0
        var mixed = 0, mixedOK = 0, caseOK = 0, ja = 0, jaOK = 0, words = 0, wordsOK = 0, unseen = 0, unseenOK = 0, skipped = 0
        for line in try String(contentsOfFile: test, encoding: .utf8).split(separator: "\n") {
            for chunk in chunks(String(line)) {
                guard chunk.contains(where: { isJa($0.first!) }) else { continue }
                var raw = ""
                var gold: [Span] = []
                var ok = true
                var prevEng = false
                for tok in chunk {
                    if isLetter(tok.first!) {
                        if prevEng { raw += " " }   // 英単語どうしの空白は打つものとする
                        gold.append(Span(lo: raw.count, hi: raw.count + tok.count))
                        raw += keepCase ? tok : tok.lowercased()
                        prevEng = true
                    } else {
                        let reading = Proofreader.reading(of: tok)
                        guard !reading.isEmpty, reading.allSatisfy({ c in c.unicodeScalars.first.map { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC } ?? false }) else { ok = false; break }
                        let keys = Romaji.keys(for: reading)
                        guard keys.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { ok = false; break }
                        raw += keys
                        prevEng = false
                    }
                }
                guard ok, raw.count <= 80 else { skipped += 1; continue }
                // 空白で区切られた部分ごとに切り分ける
                var sys: [Span] = []
                var forms: [Span: String] = [:]
                var offset = 0
                for part in raw.split(separator: " ", omittingEmptySubsequences: false) {
                    var at = offset
                    for piece in seg.plan(raw: String(part), final: true)?.pieces ?? [] {
                        if piece.isEnglish {
                            let s = Span(lo: at, hi: at + piece.raw.count)
                            sys.append(s)
                            forms[s] = piece.text
                        }
                        at += piece.raw.count
                    }
                    offset += part.count + 1
                }
                let r = Array(raw)
                func word(_ s: Span) -> String { String(r[s.lo..<s.hi]) }
                if gold.isEmpty, env["MX_PREFIX"] != nil {
                    // 打っている途中の見え方: 日本語だけの句を 1 打鍵ずつ進め、途中で英字が出る回数を数える
                    for k in 1...r.count {
                        prefixes += 1
                        if let p = seg.plan(raw: String(r[..<k])) {
                            prefixBad += 1
                            if verbose { print("途中\t\(String(r[..<k]))\t\(p.pieces.filter(\.isEnglish).map(\.text))") }
                        }
                    }
                }
                if gold.isEmpty {
                    ja += 1
                    if sys.isEmpty { jaOK += 1 } else if verbose { print("誤爆\t\(chunk.joined())\t\(sys.map(word))") }
                } else {
                    mixed += 1
                    let hit = Set(sys) == Set(gold)
                    if hit { mixedOK += 1 }
                    else if verbose { print("外れ\t\(chunk.joined(separator: " "))\t\(raw)\t\(sys.map(word))") }
                    let sysSet = Set(sys)
                    var cased = hit
                    for (g, tok) in zip(gold, chunk.filter { isLetter($0.first!) }) {
                        words += 1
                        let known = lexicon.lookup(tok.lowercased()) != nil
                        if !known { unseen += 1 }
                        if sysSet.contains(g) { wordsOK += 1; if !known { unseenOK += 1 } }
                        if forms[g] != tok { cased = false }
                    }
                    if cased { caseOK += 1 }
                }
            }
        }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%d/%d (%.1f%%)", a, b, 100 * Double(a) / Double(b)) }
        print("語彙 \(lexicon.count) 語  読めず・長すぎで除外 \(skipped) 塊")
        print("英字まじりの塊を正しく切り分け  \(pct(mixedOK, mixed))")
        print("  大文字小文字まで一致          \(pct(caseOK, mixed))")
        print("英単語ごと                      \(pct(wordsOK, words))")
        print("  うち初めて見る語              \(pct(unseenOK, unseen))")
        print("日本語だけの塊に誤爆なし        \(pct(jaOK, ja))")
        if prefixes > 0 { print("日本語を打っている途中に英字が出る  \(pct(prefixBad, prefixes))") }
    }
}
