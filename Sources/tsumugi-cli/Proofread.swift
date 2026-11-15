import Foundation
import TsumugiCore
import TsumugiLLM

/// 読み直しの計測。
enum ProofreadEval {
    /// 1 行 1 文のファイルを順に書いていく想定で、行ごとに直しの提案を出す。
    /// 出力は「行番号 <TAB> 確からしさの伸び <TAB> 直す前 <TAB> 直した後」。
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

    /// 正しい文に同音の取り違えを 1 つ仕込み、見つけて元に戻せるかを測る。しきい値を決めるための生の数字を出す。
    /// 出力 (しきい値で絞る前の候補すべて):
    ///   clean  <行> <伸び> <自然さの伸び>                 … 手を加えていない文への候補 (出れば誤提案)
    ///   inject <行> <仕込み> <伸び> <自然さの伸び> <ok|ng>  … 仕込んだ文への候補 (ok = 元の文に戻る)
    ///   inject <行> <仕込み> - - none                     … 候補なし
    static func inject(path: String, model: ZenzModel, converter: Converter) throws {
        let proofreader = Proofreader(converter: converter, scorer: model)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        func f(_ v: Float) -> String { String(format: "%.2f", v) }
        var left = ""
        for (n, line) in lines.enumerated() {
            defer { left = String((left + line + "\n").suffix(200)) }
            for c in proofreader.candidates(left + line) { print("clean\t\(n + 1)\t\(f(c.gain))\t\(f(c.textGain))\t\(c.from)→\(c.to)") }
            // 文末の、かな・漢字が続く範囲から語を 1 つ選び、同じ読みの別の表記に差し替える
            let chars = Array(line)
            var end = chars.count
            while end > 0, !chars[end - 1].isLetter || chars[end - 1].isASCII { end -= 1 }
            var start = end
            while start > 0, chars[start - 1].isLetter, !chars[start - 1].isASCII { start -= 1 }
            let run = String(chars[start..<end])
            guard run.count >= 5, let conv = converter.match(reading: Proofreader.reading(of: run), surface: run) else { continue }
            var offset = 0
            var planted: (range: Range<Int>, wrong: String)?
            for seg in conv.segments {
                defer { offset += seg.surface.count }
                guard planted == nil, seg.surface.count >= 2, seg.surface != seg.reading,
                      seg.surface.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { continue }
                // 同じ品詞で、かなり使われる別の語だけを選ぶ (珍しい語を仕込んでも現実の誤りに似ない)
                let alt = converter.segmentCandidates(seg.reading, limit: 12).first {
                    $0.surface != seg.surface && $0.lid == seg.lid && $0.surface.count == seg.surface.count
                        && $0.surface.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
                }
                if let alt { planted = (offset..<(offset + seg.surface.count), alt.surface) }
            }
            guard let planted else { continue }
            let r = Array(run)
            let wrongRun = String(r[..<planted.range.lowerBound]) + planted.wrong + String(r[planted.range.upperBound...])
            let wrongLine = String(chars[..<start]) + wrongRun + String(chars[end...])
            let label = "\(String(r[planted.range]))→\(planted.wrong)"
            let found = proofreader.candidates(left + wrongLine)
            if found.isEmpty { print("inject\t\(n + 1)\t\(label)\t-\t-\tnone") }
            for c in found {
                let fixed = String((left + wrongLine).dropLast(c.tail.count)) + c.fixedTail
                print("inject\t\(n + 1)\t\(label)\t\(f(c.gain))\t\(f(c.textGain))\t\(fixed == left + line ? "ok" : "ng")")
            }
        }
    }
}
