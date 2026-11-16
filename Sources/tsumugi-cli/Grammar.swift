import Foundation
import TsumugiCore
import TsumugiLLM

/// 文法の見直しの計測。
enum GrammarEval {
    /// 出力:
    ///   clean  <行> <種類> <伸び> <直す前→直した後>               … 手を加えていない文への候補 (伸び 2 以上)
    ///   inject <行> <仕込みの種類> <仕込み> <種類> <伸び> <ok|ng>   … 仕込んだ文への候補のうち伸びが最大のもの
    ///   inject <行> <仕込みの種類> <仕込み> - - none
    static func run(path: String, model: ZenzModel, inject: Bool) throws {
        let checker = GrammarChecker(scorer: model)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        func f(_ v: Float) -> String { String(format: "%.2f", v) }
        var rng = SystemRandomNumberGenerator()
        var seed: UInt64 = 42
        func rand(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        _ = rng.next()
        var left = ""
        var ms: [Double] = []
        for (n, line) in lines.enumerated() {
            defer { left = String((left + line + "\n").suffix(200)) }
            let t0 = Date()
            let found = checker.candidates(left + line + "\n")
            ms.append(Date().timeIntervalSince(t0) * 1000)
            for c in found where c.correction.gain >= 2 {
                print("clean\t\(n + 1)\t\(c.kind.rawValue)\t\(f(c.correction.gain))\t\(c.correction.from)→\(c.correction.to)")
            }
            guard inject else { continue }
            let chars = Array(line)
            guard chars.count >= 8 else { continue }
            for (label, wrong, note) in plant(chars, rand: rand) {
                let text = left + wrong + "\n"
                let found = checker.candidates(text).filter { $0.correction.gain >= 3 }
                if found.isEmpty { print("inject\t\(n + 1)\t\(label)\t\(note)\t-\t-\tnone"); continue }
                for best in found {
                    let fixed = String(text.dropLast(best.correction.tail.count)) + best.correction.fixedTail
                    print("inject\t\(n + 1)\t\(label)\t\(note)\t\(best.kind.rawValue)\t\(f(best.correction.gain))\t\(fixed == left + line + "\n" ? "ok" : "ng")\t\(best.correction.from)→\(best.correction.to)")
                }
            }
        }
        let sorted = ms.sorted()
        if !sorted.isEmpty {
            FileHandle.standardError.write("時間 (ms): 中央 \(Int(sorted[sorted.count / 2]))  90% \(Int(sorted[sorted.count * 9 / 10]))  最大 \(Int(sorted.last!))\n".data(using: .utf8)!)
        }
    }

    private static let particles: [Character] = ["を", "が", "に", "は", "で", "と", "も", "の"]
    private static let swaps: [Character: [Character]] = ["を": ["が", "に"], "が": ["を"], "に": ["を", "で"], "で": ["に", "を"]]

    private static func isHira(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x3041...0x3096).contains($0.value) } ?? false }
    private static func isContent(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) || (0x30A1...0x30FA).contains($0.value) || $0.isASCII && c.isLetter } ?? false
    }

    /// 1 文に、種類ごとに 1 つずつ書き損じを仕込む。
    static func plant(_ s: [Character], rand: (Int) -> Int) -> [(String, String, String)] {
        var out: [(String, String, String)] = []
        func make(_ range: Range<Int>, _ rep: String) -> String { String(s[..<range.lowerBound]) + rep + String(s[range.upperBound...]) }
        // 語のあとの助詞 (次も語の始まり)
        let ps = s.indices.filter { $0 > 0 && $0 < s.count - 1 && particles.contains(s[$0]) && isContent(s[$0 - 1]) && isContent(s[$0 + 1]) }
        if !ps.isEmpty {
            let i = ps[rand(ps.count)]
            out.append(("dup-particle", make(i..<i, String(s[i])), "\(s[i])\(s[i])"))
        }
        let sw = ps.filter { swaps[s[$0]] != nil }
        if !sw.isEmpty {
            let i = sw[rand(sw.count)]
            let to = swaps[s[i]]![rand(swaps[s[i]]!.count)]
            out.append(("swap-particle", make(i..<(i + 1), String(to)), "\(s[i])→\(to)"))
        }
        // 脱字: ひらがなが 3 つ以上続くところの、真ん中の 1 文字を落とす
        let mids = s.indices.filter { $0 > 0 && $0 < s.count - 1 && isHira(s[$0]) && isHira(s[$0 - 1]) && isHira(s[$0 + 1]) && s[$0] != s[$0 - 1] && s[$0] != s[$0 + 1] }
        if !mids.isEmpty {
            let i = mids[rand(mids.count)]
            out.append(("drop", make(i..<(i + 1), ""), "\(s[i - 1])[\(s[i])]\(s[i + 1])"))
        }
        // 同じ並びの繰り返し: 2〜4 文字
        if s.count > 6 {
            let n = 2 + rand(3)
            let i = rand(s.count - n)
            let chunk = String(s[i..<(i + n)])
            if chunk.allSatisfy({ isHira($0) || isContent($0) }) { out.append(("repeat", make(i..<i, chunk), chunk + chunk)) }
        }
        return out
    }
}
