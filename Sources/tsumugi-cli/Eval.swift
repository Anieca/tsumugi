import Foundation
import TsumugiCore

/// 先読みの評価。文書を頭から打鍵し、正しい先読みが出たら Tab で受け入れる利用者を模して、
/// 省けた打鍵数と、出した先読みの的中率を測る。
struct PredictionEval {
    struct Doc {
        var name: String
        var chunks: [(surface: String, reading: String)]
    }

    struct Tally {
        var baseKeys = 0, keys = 0
        var shown = 0, accepted = 0, wrong = 0, wrongSurface = 0, small = 0
        var idleShown = 0, idleAccepted = 0
        var acceptedKana = 0
        var misconverted = 0, chunks = 0
        var worstMs = 0.0, totalMs = 0.0, strokes = 0

        mutating func add(_ o: Tally) {
            baseKeys += o.baseKeys; keys += o.keys
            shown += o.shown; accepted += o.accepted; wrong += o.wrong; wrongSurface += o.wrongSurface; small += o.small
            idleShown += o.idleShown; idleAccepted += o.idleAccepted
            acceptedKana += o.acceptedKana
            misconverted += o.misconverted; chunks += o.chunks
            worstMs = max(worstMs, o.worstMs); totalMs += o.totalMs; strokes += o.strokes
        }

        var line: String {
            let saved = baseKeys == 0 ? 0 : 100 * Double(baseKeys - keys) / Double(baseKeys)
            let precision = shown == 0 ? 0 : 100 * Double(shown - wrong - wrongSurface) / Double(shown)
            return String(format: "打鍵 %4d → %4d (%5.1f%% 減)  提案 %3d 件: 採用 %3d / 小さい %2d / 読み違い %2d / 表記違い %2d (的中 %3.0f%%)  確定直後 %d/%d  誤変換 %d/%d  %.0fms/鍵 (最悪 %.0f)",
                          baseKeys, keys, saved, shown, accepted, small, wrong, wrongSurface, precision,
                          idleAccepted, idleShown, misconverted, chunks, strokes == 0 ? 0 : totalMs / Double(strokes), worstMs)
        }
    }

    static func load(_ path: String) throws -> [Doc] {
        var docs: [Doc] = []
        var cur: Doc?
        func close() { if let c = cur, !c.chunks.isEmpty { docs.append(c) }; cur = nil }
        for raw in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { close(); continue }
            if line.hasPrefix("#") {
                if cur == nil || cur!.chunks.isEmpty { cur = Doc(name: String(line.dropFirst(2)), chunks: []) }
                continue
            }
            let cols = line.components(separatedBy: "\t")
            guard cols.count == 2 else { continue }
            if cur == nil { cur = Doc(name: "doc\(docs.count + 1)", chunks: []) }
            cur!.chunks.append((cols[0], cols[1]))
        }
        close()
        return docs
    }

    /// 受け入れる価値があるとみなす、省ける打鍵数の下限。
    var minGain = 3
    var verbose = false

    func run(_ doc: Doc, session: Session) -> Tally {
        var t = Tally()
        let reading = Array(doc.chunks.map(\.reading).joined())
        let surface = Array(doc.chunks.map(\.surface).joined())
        var rEnds: [Int] = [], sEnds: [Int] = []
        for c in doc.chunks {
            rEnds.append((rEnds.last ?? 0) + c.reading.count)
            sEnds.append((sEnds.last ?? 0) + c.surface.count)
        }
        t.baseKeys = doc.chunks.reduce(0) { $0 + Romaji.keys(for: $1.reading).count + 1 }
        t.chunks = doc.chunks.count
        var committed = ""
        session.onCommit = { committed += $0 }
        session.resetContext()

        var r = 0, s = 0            // いまの未確定文字列の開始位置
        var lastGhost: Ghost?

        func press(_ key: Key) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            session.handle(key)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            t.keys += 1; t.strokes += 1; t.totalMs += ms; t.worstMs = max(t.worstMs, ms)
        }

        /// いま出ている先読みを見て、正しければ受け入れる。受け入れたら true。
        func consider(typedKeys: Int, remainingKeys: () -> Int, idle: Bool) -> Bool {
            guard let g = session.view.ghost else { lastGhost = nil; return false }
            let isNew = g != lastGhost
            lastGhost = g
            let gr = Array(g.reading), gs = Array(g.text)
            let readingOK = r + gr.count <= reading.count && reading[r..<(r + gr.count)].elementsEqual(gr)
            let surfaceOK = s + gs.count <= surface.count && surface[s..<(s + gs.count)].elementsEqual(gs)
            // Tab で省ける打鍵数: 先読みの読みを打ち切るのに必要な残りの打鍵 - Tab の 1 打鍵
            let gain = Romaji.keys(for: g.reading).count - typedKeys - 1
            if isNew {
                t.shown += 1
                if idle { t.idleShown += 1 }
                if !readingOK { t.wrong += 1 } else if !surfaceOK { t.wrongSurface += 1 } else if gain < minGain { t.small += 1 }
                if verbose {
                    let mark = !readingOK ? "✗" : !surfaceOK ? "△" : gain < minGain ? "・" : "○"
                    print("    \(mark) \(String(surface[..<s]).suffix(12))｜\(g.text)  (\(g.source), +\(gain))")
                }
            }
            guard readingOK, surfaceOK, gain >= minGain else { return false }
            press(.tab)
            t.accepted += 1
            if idle { t.idleAccepted += 1 }
            t.acceptedKana += gr.count
            r += gr.count
            s += gs.count
            lastGhost = nil
            return true
        }

        while r < reading.count {
            // 確定直後の先読み
            if consider(typedKeys: 0, remainingKeys: { 0 }, idle: true) { continue }
            guard let ci = rEnds.firstIndex(where: { $0 > r }) else { break }
            let keys = Array(Romaji.keys(for: String(reading[r..<rEnds[ci]])))
            var acceptedMidway = false
            for (i, k) in keys.enumerated() {
                press(.char(k))
                if i < keys.count - 1, consider(typedKeys: i + 1, remainingKeys: { keys.count - i - 1 }, idle: false) {
                    acceptedMidway = true
                    break
                }
            }
            if acceptedMidway { continue }
            let before = committed.count
            press(.enter)
            let out = String(committed.dropFirst(before))
            let want = String(surface[s..<sEnds[ci]])
            if out != want {
                t.misconverted += 1
                if verbose { print("    誤変換: \(out) ≠ \(want)") }
            }
            r = rEnds[ci]
            s = sEnds[ci]
            lastGhost = nil
        }
        return t
    }
}
