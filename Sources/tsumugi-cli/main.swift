import Foundation
import TsumugiCore
import TsumugiLLM

// 開発用 CLI。変換エンジンと LLM を端末から試す。
//   tsumugi-cli convert <読み>...        辞書だけで変換 (上位 5 件)
//   tsumugi-cli llm <読み> [左文脈]      LLM で変換し、ラティスで検証
//   tsumugi-cli predict <読みの頭> [左文脈]  続きの予測 (生の出力と確率)
//   tsumugi-cli type <ローマ字>          セッションに打鍵を流す

let args = Array(CommandLine.arguments.dropFirst())
let root = FileManager.default.currentDirectoryPath
let dictPath = ProcessInfo.processInfo.environment["TSUMUGI_DICT"] ?? root + "/build/system.dict"
let modelPath = ProcessInfo.processInfo.environment["TSUMUGI_MODEL"] ?? root + "/vendor/models/zenz-v3.2-small-Q5_K_M.gguf"

func ms(_ body: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

guard let cmd = args.first else {
    print("usage: tsumugi-cli convert|llm|predict|type ...")
    exit(1)
}
let dict = try SystemDictionary(url: URL(fileURLWithPath: dictPath))
let converter = Converter(dictionary: dict)

func describe(_ c: Conversion) -> String {
    c.segments.map(\.surface).joined(separator: "|") + "  (\(c.cost))"
}

switch cmd {
case "convert":
    for reading in args.dropFirst() {
        var result: [Conversion] = []
        let t = ms { result = converter.convert(reading, nbest: 5) }
        print("\(reading)  [\(String(format: "%.1f", t))ms]")
        for c in result { print("   " + describe(c)) }
    }
case "llm":
    let useGPU = ProcessInfo.processInfo.environment["TSUMUGI_GPU"] == "1"
    guard let model = ZenzModel(path: modelPath, useGPU: useGPU) else { fatalError("model load failed") }
    let reading = args[1]
    let left = args.count > 2 ? args[2] : ""
    for round in 0..<2 {
        var out: String?
        let t = ms { out = model.convert(reading: reading + (round == 1 ? "" : ""), leftContext: left) { false } }
        let verified = out.flatMap { converter.match(reading: reading, surface: $0) }
        print("llm[\(round)]: \(out ?? "nil")  [\(String(format: "%.0f", t))ms]  verified: \(verified.map(describe) ?? "NO")")
    }
    print("dict: " + (converter.convert(reading).first.map(describe) ?? "nil"))
case "predict":
    guard let model = ZenzModel(path: modelPath) else { fatalError("model load failed") }
    let prefix = args.count > 1 ? args[1] : ""
    let left = args.count > 2 ? args[2] : ""
    var raw: [(String, Float)] = []
    let t = ms { raw = model.debugPredict(readingPrefix: prefix, leftContext: left) }
    print(raw.map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }.joined(separator: " "), String(format: " [%.0fms]", t))
    let p = model.predict(readingPrefix: prefix, leftContext: left) { false }
    print("predict:", p.map { "\($0.reading) → \($0.surface ?? "-")  conf=\($0.confidence)" } ?? "nil")
case "type":
    // 例: tsumugi-cli type "kyouhaiitenkidesune" "<space>" "<enter>"
    let useLLM = ProcessInfo.processInfo.environment["TSUMUGI_NO_LLM"] == nil
    let model = useLLM ? ZenzModel(path: modelPath) : nil
    let user = UserModel(fileURL: nil)
    let session = Session(converter: Converter(dictionary: dict, userModel: user), userModel: user, neural: model)
    session.runsNeuralInline = true
    session.onCommit = { print("  ⏎ commit: \($0)") }
    func show() {
        let v = session.view
        var line = "  [" + v.segments.enumerated().map { $0.offset == v.focus ? "【\($0.element)】" : $0.element }.joined(separator: "|") + "]"
        if let g = v.ghost { line += "   ⇥ \(g.text) (\(g.source))" }
        if !v.candidates.isEmpty { line += "   候補: " + v.candidates.prefix(9).enumerated().map { ($0.offset == v.candidateIndex ? "*" : "") + $0.element }.joined(separator: " ") }
        print(line)
    }
    let named: [String: Key] = ["<space>": .space, "<enter>": .enter, "<tab>": .tab, "<esc>": .escape, "<bs>": .backspace,
                                "<left>": .left, "<right>": .right, "<s-left>": .shiftLeft, "<s-right>": .shiftRight,
                                "<kata>": .katakana, "<hira>": .hiragana, "<latin>": .latin, "<up>": .up, "<down>": .down]
    for token in args.dropFirst() {
        if let k = named[token] {
            let t = ms { session.handle(k) }
            print("\(token) [\(String(format: "%.0f", t))ms]")
            show()
        } else {
            var worst = 0.0
            for c in token { worst = max(worst, ms { session.handle(.char(c)) }) }
            print("\(token) [max \(String(format: "%.0f", worst))ms/key]")
            show()
        }
    }
default:
    print("unknown command")
}
