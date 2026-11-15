import Foundation
import TsumugiCore
import TsumugiLLM

/// 読み直しの計測。1 行 1 文のファイルを順に書いていく想定で、行ごとに直しの提案を出す。
/// 出力は「行番号 <TAB> 確からしさの伸び <TAB> 直す前 <TAB> 直した後」。
enum ProofreadEval {
    static func run(path: String, model: ZenzModel, converter: Converter) throws {
        let proofreader = Proofreader(converter: converter, scorer: model)
        let env = ProcessInfo.processInfo.environment
        if let v = env["TSUMUGI_PROOF_GAIN"].flatMap(Float.init) { proofreader.minimumGain = v }
        if let v = env["TSUMUGI_PROOF_TEXT"].flatMap(Float.init) { proofreader.minimumTextGain = v }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        var left = ""
        var count = 0
        for (n, line) in lines.enumerated() {
            // 1 文に複数あれば、直したものとして続けて探す
            var text = left + line
            var seen = Set<String>()
            while let c = proofreader.check(text, ignoring: seen) {
                print("\(n + 1)\t\(String(format: "%.2f", c.gain))\t\(c.from)\t\(c.to)")
                count += 1
                seen.insert(c.key)
                text = String(text.dropLast(c.tail.count)) + c.fixedTail
            }
            left = String((left + line + "\n").suffix(200))
        }
        print("\(lines.count) 文に \(count) 件")
    }
}
