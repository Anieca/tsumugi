import AppKit
import Foundation
import TsumugiCore
import TsumugiLLM

/// 辞書・学習モデル・LLM をプロセス内で 1 つだけ持ち、セッションを作る。
public final class Engine {
    public static let shared = Engine()

    public let userModel: UserModel
    public let converter: Converter?
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
        let dictURL = Self.locate(resource: "system", ext: "dict", env: env["TSUMUGI_DICT"], dev: "build/system.dict")
        if let dictURL, let dict = try? SystemDictionary(url: dictURL) {
            converter = Converter(dictionary: dict, userModel: userModel)
        } else {
            converter = nil
            NSLog("Tsumugi: 辞書が見つかりません")
        }
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
        return s
    }

    public var isNeuralReady: Bool { neural.model != nil }

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
