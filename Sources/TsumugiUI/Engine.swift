import AppKit
import Foundation
import TsumugiCore
import TsumugiLLM

/// 辞書・学習モデル・LLM をプロセス内で 1 つだけ持ち、セッションを作る。
public final class Engine {
    public static let shared = Engine()

    public let userModel: UserModel
    public let converter: Converter?
    /// 自分が書いたことのある英単語 (日本語モードのまま打った英単語を見分けるのに使う)。
    public let latinLexicon: LatinLexicon
    private var segmenter: MixedSegmenter?
    private let neural = NeuralProxy()
    private let defaults = UserDefaults.standard

    private init() {
        let env = ProcessInfo.processInfo.environment
        // TSUMUGI_USER_MODEL=none でメモリ上のみ (検証用)、パス指定で別ファイル
        switch env["TSUMUGI_USER_MODEL"] {
        case "none"?: userModel = UserModel(fileURL: nil)
        case let path?: userModel = UserModel(fileURL: URL(fileURLWithPath: path))
        case nil: userModel = UserModel(fileURL: UserModel.defaultURL())
        }
        latinLexicon = LatinLexicon(fileURL: env["TSUMUGI_USER_MODEL"] == nil ? LatinLexicon.defaultURL() : nil)
        let dictURL = Self.locate(resource: "system", ext: "dict", env: env["TSUMUGI_DICT"], dev: "build/system.dict")
        if let dictURL, let dict = try? SystemDictionary(url: dictURL) {
            converter = Converter(dictionary: dict, userModel: userModel)
        } else {
            converter = nil
            NSLog("Tsumugi: 辞書が見つかりません")
        }
        segmenter = converter.map { MixedSegmenter(converter: $0, lexicon: latinLexicon) }
        // 単語表は最初に使うときに読み込まれる。打鍵を待たせないよう、先に読んでおく
        DispatchQueue.global(qos: .utility).async { _ = LatinLexicon.systemWords }
        userModel.isPaused = defaults.bool(forKey: "learningPaused")
        // モデルの読み込みは裏で行い、終わるまでは辞書だけで変換する
        if let modelURL = Self.locate(resource: "zenz", ext: "gguf", env: env["TSUMUGI_MODEL"], dev: "vendor/models/zenz-v3.2-small-Q5_K_M.gguf") {
            DispatchQueue.global(qos: .userInitiated).async { [neural] in
                neural.model = ZenzModel(path: modelURL.path)
                if neural.model == nil { NSLog("Tsumugi: LLM を読み込めませんでした") }
            }
        }
    }

    /// アプリのリソース → 環境変数 → 開発時の作業ディレクトリ の順に探す。
    private static func locate(resource: String, ext: String, env: String?, dev: String) -> URL? {
        if let url = Bundle.main.url(forResource: resource, withExtension: ext) { return url }
        let candidates = [env, FileManager.default.currentDirectoryPath + "/" + dev].compactMap { $0 }
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func makeSession() -> Session? {
        guard let converter else { return nil }
        let s = Session(converter: converter, userModel: userModel, neural: neural)
        s.predictionEnabled = predictionEnabled
        s.mixed = mixedInputEnabled ? segmenter : nil
        return s
    }

    public var isNeuralReady: Bool { neural.model != nil }

    /// 確定した文を読み直して、変換の取り違えを挙げる。
    public private(set) lazy var proofreader: Proofreader? = converter.map { Proofreader(converter: $0, scorer: neural) }
    public private(set) lazy var grammarChecker = GrammarChecker(scorer: neural)

    // MARK: 設定

    public var learningPaused: Bool {
        get { userModel.isPaused }
        set {
            userModel.isPaused = newValue
            defaults.set(newValue, forKey: "learningPaused")
        }
    }

    public var predictionEnabled: Bool {
        get { defaults.object(forKey: "predictionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "predictionEnabled") }
    }

    public var proofreadEnabled: Bool {
        get { defaults.object(forKey: "proofreadEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "proofreadEnabled") }
    }

    /// 英字と日本語のあいだの空白を、打ち忘れたときに補うか。
    public var autoSpacingEnabled: Bool {
        get { defaults.object(forKey: "autoSpacingEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSpacingEnabled") }
    }

    /// 打った文章の記録 (文体の直しを作るための材料)。ふだんは無効。
    public private(set) lazy var writingLog: WritingLog = {
        let extra = defaults.stringArray(forKey: "writingLogExcludedApps") ?? []
        return WritingLog(directory: ProcessInfo.processInfo.environment["TSUMUGI_USER_MODEL"] == nil ? WritingLog.defaultDirectory() : nil,
                          isEnabled: defaults.bool(forKey: "writingLogEnabled"),
                          excludedApps: WritingLog.defaultExcludedApps.union(extra))
    }()

    public var writingLogEnabled: Bool {
        get { writingLog.isEnabled }
        set {
            writingLog.isEnabled = newValue
            defaults.set(newValue, forKey: "writingLogEnabled")
        }
    }

    /// 日本語モードのまま打った英単語を見分けるか。
    public var mixedInputEnabled: Bool {
        get { defaults.object(forKey: "mixedInputEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mixedInputEnabled") }
    }

    /// セッションに渡す切り分け役 (設定で切っていれば nil)。
    public var mixedSegmenter: MixedSegmenter? { mixedInputEnabled ? segmenter : nil }

    // MARK: 見送った直し

    /// 同じ直しを何度見せたら「見送り」とみなすか。
    public static let correctionShowLimit = 3
    private var shownCorrections: [String: Int] = [:]

    /// もう提案しない直し (`Correction.key`)。出しても採用されなかったものを覚えておく。
    public private(set) lazy var ignoredCorrections = Set(defaults.stringArray(forKey: "ignoredCorrections") ?? [])

    /// 直しを見せたことを数える。上限まで見せても採用されなければ、以後は提案しない。
    public func noteShown(_ correction: Correction) {
        let n = (shownCorrections[correction.key] ?? 0) + 1
        shownCorrections[correction.key] = n
        guard n >= Self.correctionShowLimit else { return }
        ignoredCorrections.insert(correction.key)
        // 古いものから忘れる必要が出るほどは溜まらない想定だが、際限なくは持たない
        if ignoredCorrections.count > 2000 { ignoredCorrections.removeAll() }
        defaults.set(Array(ignoredCorrections), forKey: "ignoredCorrections")
    }
}

/// モデルの読み込みが終わるまでは何もしない NeuralAssist。
final class NeuralProxy: NeuralAssist {
    private let lock = NSLock()
    private var stored: ZenzModel?

    var model: ZenzModel? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func convert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
        model?.convert(reading: reading, leftContext: leftContext, isCancelled: isCancelled)
    }

    func predict(readingPrefix: String, leftContext: String, habit: HabitHint?, isCancelled: () -> Bool) -> NeuralPrediction? {
        model?.predict(readingPrefix: readingPrefix, leftContext: leftContext, habit: habit, isCancelled: isCancelled)
    }
}

extension NeuralProxy: ProofreadScorer {
    func reconvert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
        model?.reconvert(reading: reading, leftContext: leftContext, isCancelled: isCancelled)
    }

    func logProbability(surface: String, reading: String, leftContext: String) -> Float? {
        model?.logProbability(surface: surface, reading: reading, leftContext: leftContext)
    }

    func logProbability(text: String, leftContext: String) -> Float? {
        model?.logProbability(text: text, leftContext: leftContext)
    }
}

extension NeuralProxy: TextScorer {
    func tokens(text: String, leftContext: String, alternatives: Int) -> [ScoredToken] {
        model?.tokens(text: text, leftContext: leftContext, alternatives: alternatives) ?? []
    }
}

/// NSEvent をセッションのキーに変換する。
public enum KeyMapping {
    public static func key(for e: NSEvent) -> Key? {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) || mods.contains(.option) { return nil }
        let shift = mods.contains(.shift)
        if mods.contains(.control) {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "j": return .hiragana
            case "k": return .katakana
            case "l", ";": return .latin
            case "h": return .backspace
            case "m": return .enter
            case "n": return .down
            case "p": return .up
            case "g": return .escape
            default: return nil
            }
        }
        switch e.keyCode {
        case 36, 76: return .enter
        case 48: return .tab
        case 49: return shift ? .shiftSpace : .space
        case 51: return .backspace
        case 53: return .escape
        case 123: return shift ? .shiftLeft : .left
        case 124: return shift ? .shiftRight : .right
        case 125: return .down
        case 126: return .up
        case 97: return .hiragana   // F6
        case 98: return .katakana   // F7
        case 109: return .latin     // F10
        default: break
        }
        if let s = e.characters, s.count == 1, let c = s.first, let a = c.asciiValue, (0x21...0x7E).contains(a) {
            return .char(c)
        }
        return nil
    }
}
