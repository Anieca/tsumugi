import Foundation
import TsumugiCore
import TsumugiLLM

// 開発用 CLI。変換エンジンと LLM を端末から試す。
//   tsumugi-cli convert <読み>...        辞書だけで変換 (上位 5 件)
//   tsumugi-cli llm <読み> [左文脈]      LLM で変換し、ラティスで検証
//   tsumugi-cli predict <読みの頭> [左文脈]  続きの予測 (生の出力と確率)
//   tsumugi-cli type <ローマ字>          セッションに打鍵を流す
//   tsumugi-cli eval [-v] [コーパス]     先読みの省打鍵率と的中率を測る
//   tsumugi-cli proofread <ファイル>     確定済みの文を読み直して直しの提案を出す
//   tsumugi-cli score text|kana [-v] <文>...  文の自然さ (対数確率) を出す

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
    print("usage: tsumugi-cli convert|llm|predict|type|eval ...")
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
case "score":
    // 例: tsumugi-cli score text|kana <文>...   文ごとの自然さ (対数確率) を出す。-v でトークンごと。
    guard let model = ZenzModel(path: modelPath) else { fatalError("model load failed") }
    let verbose = args.contains("-v")
    let asReading = args[1] == "kana"
    for text in args.dropFirst(2) where text != "-v" {
        let r = model.score(text, as: asReading ? .reading : .text)
        let sum = r.reduce(Float(0)) { $0 + log($1.1) }
        print(String(format: "%8.2f  %6.2f  %2d  ", sum, sum / Float(max(1, r.count)), r.count) + text)
        if verbose { print("      " + r.map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }.joined(separator: " ")) }
    }
case "proofread":
    // 例: tsumugi-cli proofread <1 行 1 文のファイル>   確定済みの文を読み直して直しの提案を出す
    //     --inject を付けると、同音の取り違えを仕込んで見つけられるかを測る (しきい値を決める用)
    guard let model = ZenzModel(path: modelPath) else { fatalError("model load failed") }
    if args.contains("--inject") {
        try ProofreadEval.inject(path: args[1], model: model, converter: converter)
    } else {
        try ProofreadEval.run(path: args[1], model: model, converter: converter)
    }
case "learn-words":
    // 例: tsumugi-cli learn-words <文章のファイル>...   自分が書いた文章から英単語の語彙を読み込む
    //     日本語を含む行に出てくる英単語だけを数え、単語と回数だけを保存する (文章は保存しない)
    let lexicon = LatinLexicon(fileURL: LatinLexicon.defaultURL())
    let before = lexicon.count
    for path in args.dropFirst() {
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            for chunk in MixedEval.chunks(String(line)) where chunk.contains(where: { MixedEval.isJa($0.first!) }) {
                for w in chunk where MixedEval.isLetter(w.first!) { lexicon.learn(w) }
            }
        }
    }
    lexicon.save()
    print("語彙 \(before) → \(lexicon.count) 語  (\(LatinLexicon.defaultURL().path))")
case "plan":
    // 例: tsumugi-cli plan <打鍵列>...   英字とかなの切り分けを見る (語彙は保存済みのものを使う)
    let seg = MixedSegmenter(converter: converter, lexicon: LatinLexicon(fileURL: LatinLexicon.defaultURL()))
    for raw in args.dropFirst() {
        let p = seg.plan(raw: raw, final: true)
        print(raw, "→", p.map { $0.pieces.map { ($0.isEnglish ? "[" + $0.text + "]" : $0.text) }.joined(separator: " ") } ?? "(英字なし)")
    }
case "mixed":
    // 試作の計測: tsumugi-cli mixed [-v] <評価する文> <語彙を学ぶ文>...
    let rest = args.dropFirst().filter { $0 != "-v" }
    try MixedEval.run(train: Array(rest.dropFirst()), test: rest[0], converter: converter, verbose: args.contains("-v"))
case "predict":
    guard let model = ZenzModel(path: modelPath) else { fatalError("model load failed") }
    let prefix = args.count > 1 ? args[1] : ""
    let left = args.count > 2 ? args[2] : ""
    var raw: [(String, Float)] = []
    let t = ms { raw = model.debugPredict(readingPrefix: prefix, leftContext: left) }
    print(raw.map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }.joined(separator: " "), String(format: " [%.0fms]", t))
    let p = model.predict(readingPrefix: prefix, leftContext: left, habit: nil) { false }
    print("predict:", p.map { "\($0.reading) → \($0.surface ?? "-")  conf=\($0.confidence)" } ?? "nil")
case "type":
    // 例: tsumugi-cli type "kyouhaiitenkidesune" "<space>" "<enter>"
    let useLLM = ProcessInfo.processInfo.environment["TSUMUGI_NO_LLM"] == nil
    let model = useLLM ? ZenzModel(path: modelPath) : nil
    // TSUMUGI_USER_MODEL=<学習ファイルの写し> を渡すと、その学習内容と保存済みの英単語で試す (学習は止めるので書き換えない)
    let userPath = ProcessInfo.processInfo.environment["TSUMUGI_USER_MODEL"]
    let user = UserModel(fileURL: userPath.map { URL(fileURLWithPath: $0) })
    user.isPaused = userPath != nil
    let session = Session(converter: Converter(dictionary: dict, userModel: user), userModel: user, neural: model)
    session.runsNeuralInline = true
    if userPath != nil {
        session.mixed = MixedSegmenter(converter: converter, lexicon: LatinLexicon(fileURL: LatinLexicon.defaultURL()))
    }
    // TSUMUGI_WORDS=notion,Tab のように渡すと、その語を知っているものとして英字まじりの入力を試す
    if let words = ProcessInfo.processInfo.environment["TSUMUGI_WORDS"] {
        let lexicon = LatinLexicon(fileURL: nil)
        for w in words.split(separator: ",") { lexicon.learn(String(w), weight: 2) }
        session.mixed = MixedSegmenter(converter: converter, lexicon: lexicon)
    }
    session.onCommit = { print("  ⏎ commit: \(Spacing.spaced($0))") }
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
case "eval":
    // 例: tsumugi-cli eval [-v] [コーパス]   先読みの省打鍵率と的中率
    let rest = args.dropFirst().filter { $0 != "-v" }
    let docs = try PredictionEval.load(rest.first ?? root + "/Tools/eval/corpus.tsv")
    let model = ProcessInfo.processInfo.environment["TSUMUGI_NO_LLM"] == nil ? ZenzModel(path: modelPath) : nil
    let env = ProcessInfo.processInfo.environment
    if let v = env["TSUMUGI_TOKEN_P"].flatMap(Float.init) { model?.predictionTokenThreshold = v }
    if let v = env["TSUMUGI_TOTAL_P"].flatMap(Float.init) { model?.predictionThreshold = v }
    var ev = PredictionEval()
    ev.verbose = args.contains("-v")
    var total = PredictionEval.Tally()
    // 学習つきの計測 (TSUMUGI_EVAL_LEARN=1): 1 人の利用者が文書を順に書いていく想定で、学習内容を持ち越す。
    // 名前が warmup- で始まる文書は「これまでに書いた文章」として打つだけで、成績には数えない。
    let learns = env["TSUMUGI_EVAL_LEARN"] != nil
    let shared = UserModel(fileURL: nil)
    for doc in docs {
        let warmup = doc.name.hasPrefix("warmup-")
        if warmup && !learns { continue }
        let user = learns ? shared : UserModel(fileURL: nil)
        user.isPaused = !learns
        let session = Session(converter: Converter(dictionary: dict, userModel: user), userModel: user, neural: warmup ? nil : model)
        session.runsNeuralInline = true
        session.usesHabit = env["TSUMUGI_NO_HABIT"] == nil
        if ev.verbose && !warmup { print(doc.name) }
        var quiet = ev
        if warmup { quiet.verbose = false }
        let t = quiet.run(doc, session: session)
        if warmup { continue }
        total.add(t)
        print(doc.name.padding(toLength: 16, withPad: " ", startingAt: 0), t.line)
    }
    print("合計".padding(toLength: 16, withPad: " ", startingAt: 0), total.line)
default:
    print("unknown command")
}
