import Carbon
import Cocoa
import InputMethodKit
import TsumugiCore
import TsumugiUI

// Tsumugi 入力メソッドのエントリポイント。
//   TsumugiIME             入力メソッドとして常駐する (システムが起動する)
//   TsumugiIME --register    この .app を入力ソースとして登録し、入力メニューに追加する
//   TsumugiIME --unregister  入力メニューから外す

/// この .app が提供する入力ソース (本体と ひらがな / 英字 の各モード)。
func tsumugiInputSources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: Bundle.main.bundleIdentifier ?? ""] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

func isEnableCapable(_ source: TISInputSource) -> Bool {
    guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnableCapable) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}

if CommandLine.arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    guard status == noErr else {
        print("register failed: \(status)")
        exit(1)
    }
    let sources = tsumugiInputSources().filter(isEnableCapable)
    for source in sources { TISEnableInputSource(source) }
    print("registered: \(Bundle.main.bundlePath) (\(sources.count) 個の入力ソースを有効化)")
    exit(0)
}

if CommandLine.arguments.contains("--unregister") {
    for source in tsumugiInputSources() { TISDisableInputSource(source) }
    print("unregistered")
    exit(0)
}

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "Tsumugi_1_Connection"
guard let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    NSLog("Tsumugi: IMKServer を開始できませんでした")
    exit(1)
}
_ = server
_ = Engine.shared   // 辞書と LLM を先に読み込んでおく
let assistPanel = AssistPanel()
NSApplication.shared.run()

@objc(TsumugiInputController)
final class TsumugiInputController: IMKInputController {
    private static let romanMode = "com.apple.inputmethod.Roman"

    private var session: Session?
    private var hadMarkedText = false
    private var directInput = false

    /// いま見せている直しの提案。次の打鍵で消える (Shift+Tab なら適用する)。
    private var correction: Correction?
    /// 読み直しの世代。打鍵のたびに進め、古い読み直しを打ち切る。
    private let proofTicket = Ticket()
    private static let proofQueue = DispatchQueue(label: "tsumugi.proofread", qos: .utility)

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        session = Engine.shared.makeSession()
        session?.onCommit = { [weak self] text in
            self?.textClient?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            self?.hadMarkedText = false
            self?.scheduleProofread()
        }
        session?.onAsyncUpdate = { [weak self] in self?.render() }
        session?.contextProvider = { [weak self] in self?.textBeforeCursor() }
    }

    /// カーソルより前の文章 (最大 300 字)。先読みと変換の文脈にだけ使い、保存はしない。
    /// 位置や文章を教えてくれないアプリでは nil。
    private func textBeforeCursor() -> String? {
        guard let client = textClient else { return nil }
        let sel = client.selectedRange()
        var text: String?
        // 文章を読めないアプリは位置 0 を返すことがあるので、0 は「わからない」として扱う
        if sel.location != NSNotFound, sel.location > 0 {
            let n = min(sel.location, 300)
            text = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string
        }
        ContextProbe.record(app: client.bundleIdentifier(), location: sel.location, read: text?.count)
        return text
    }

    private var textClient: IMKTextInput? { client() }

    // MARK: イベント

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        // 英数 (102) / かな (104): モードの切り替えはシステムが済ませている。
        // このキーイベントは文字として空白を持つので、アプリへ流すと空白が入力されてしまう。
        if event.keyCode == 102 || event.keyCode == 104 { return true }
        guard let session else { return false }
        proofTicket.advance()
        if let c = correction {
            correction = nil
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 48, mods == .shift, !session.isComposing, apply(c) { return true }
            assistPanel.hide()
        }
        // 英字モードで何も入力していなければ、打鍵はそのままアプリへ
        if directInput && !session.isComposing {
            assistPanel.hide()
            return false
        }
        guard let key = KeyMapping.key(for: event) else {
            // ショートカットなどはアプリへ。先読みは消しておく
            if !session.isComposing { assistPanel.hide() }
            return false
        }
        let before = session.view
        let handled = session.handle(key)
        render()
        ContextProbe.trace("キー \(ContextProbe.name(key))\t文節 \(before.segments.count)→\(session.view.segments.count)\t字数 \(before.segments.joined().count)→\(session.view.segments.joined().count)\t\(handled ? "処理" : "素通し")")
        return handled
    }

    /// 英数 / かな キーや入力メニューでのモード切り替え。
    /// 入力中の文字列は確定しない (英字モードでは続く打鍵を半角のまま足し、Enter でまとめて確定する)。
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if let mode = value as? String {
            let roman = mode == Self.romanMode
            if roman != directInput {
                directInput = roman
                session?.setDirectInput(roman)
                render()
            }
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    override func commitComposition(_ sender: Any!) {
        ContextProbe.trace("アプリから確定の指示")
        session?.commitAll()
        render()
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        session?.predictionEnabled = Engine.shared.predictionEnabled
    }

    override func deactivateServer(_ sender: Any!) {
        ContextProbe.trace("入力先から離れた")
        proofTicket.advance()
        correction = nil
        session?.commitAll()
        session?.resetContext()
        render()
        assistPanel.hide()
        Engine.shared.userModel.saveNow()
        super.deactivateServer(sender)
    }

    // MARK: 表示

    private func render() {
        guard let session, let client = textClient else { return }
        let view = session.view
        let none = NSRange(location: NSNotFound, length: NSNotFound)
        var focusOffset = 0
        if view.isComposing {
            let text = NSMutableAttributedString()
            for (i, seg) in view.segments.enumerated() {
                let style = view.focus == i ? kTSMHiliteSelectedConvertedText : kTSMHiliteConvertedText
                let range = NSRange(location: 0, length: (seg as NSString).length)
                let attrs = (mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any]) ?? [:]
                if view.focus == i { focusOffset = text.length }
                text.append(NSAttributedString(string: seg, attributes: attrs))
            }
            client.setMarkedText(text, selectionRange: NSRange(location: text.length, length: 0), replacementRange: none)
            hadMarkedText = true
        } else if hadMarkedText {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: none)
            hadMarkedText = false
        }

        let content = AssistContent(view: view)
        guard content != .hidden else {
            // 直しの提案を出している間は、裏から届いた更新で消さない
            if correction == nil { assistPanel.hide() }
            return
        }
        correction = nil   // 先読みや候補を出すときは、そちらを優先する
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: focusOffset, lineHeightRectangle: &rect)
        // 位置を教えてくれないアプリでは、前回の位置のまま出す
        assistPanel.show(content, at: rect == .zero ? nil : rect)
    }

    // MARK: 直し

    /// 確定のあと手が止まったら、いまの文を読み直して変換の取り違えを探す。
    private func scheduleProofread() {
        let engine = Engine.shared
        guard engine.proofreadEnabled, engine.isNeuralReady, let proofreader = engine.proofreader,
              !Self.unreliableApps.contains(textClient?.bundleIdentifier() ?? "") else { return }
        let ticket = proofTicket.advance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.proofTicket.value == ticket, self.session?.isComposing == false,
                  let text = self.textBeforeCursor() else { return }
            let ignoring = engine.ignoredCorrections
            Self.proofQueue.async { [weak self] in
                let found = proofreader.check(text, ignoring: ignoring) { self?.proofTicket.value != ticket }
                DispatchQueue.main.async {
                    // 確定直後の先読みが出ているときは、そちらを優先して出さない
                    guard let self, let found, self.proofTicket.value == ticket, self.session?.isComposing == false,
                          self.session?.view.ghost == nil,
                          self.textBeforeCursor()?.hasSuffix(found.tail) == true, let client = self.textClient else { return }
                    self.correction = found
                    engine.noteShown(found)
                    ContextProbe.trace("直しを提案\t\(found.from.count) 字")
                    let sel = client.selectedRange()
                    var rect = client.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
                    if rect == .zero { client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) }
                    assistPanel.show(.correction(from: found.from, to: found.to), at: rect == .zero ? nil : rect)
                }
            }
        }
    }

    /// 直しを入力先に反映する。直す箇所からカーソルまでをまとめて置き換えるので、カーソルは元の位置に残る。
    /// 入力先の文章が提案したときと変わっていたら何もしない。
    /// - Returns: 反映したら true。
    private func apply(_ c: Correction) -> Bool {
        guard let client = textClient else { return false }
        let sel = client.selectedRange()
        let length = (c.tail as NSString).length
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= length else { return false }
        let range = NSRange(location: sel.location - length, length: length)
        guard client.attributedSubstring(from: range)?.string == c.tail else { return false }
        client.insertText(c.fixedTail, replacementRange: range)
        ContextProbe.trace("直しを適用")
        assistPanel.hide()
        // 範囲を指定した置き換えを正しく扱わないアプリがありうる。置き換えたあとの文章を読み直し、
        // 想定どおりでなければ、そのアプリでは以後この起動中は提案しない (文章を壊し続けないため)。
        let ticket = proofTicket.advance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.proofTicket.value == ticket, let client = self.textClient else { return }
            let now = client.selectedRange()
            let n = (c.fixedTail as NSString).length
            let ok = now.location != NSNotFound && now.location >= n
                && client.attributedSubstring(from: NSRange(location: now.location - n, length: n))?.string == c.fixedTail
            if ok {
                self.scheduleProofread()   // 同じ文にまだあれば続けて出す
            } else {
                Self.unreliableApps.insert(client.bundleIdentifier() ?? "")
                ContextProbe.trace("直しの反映を確認できず\t\(client.bundleIdentifier() ?? "?")")
            }
        }
        return true
    }

    /// 置き換えが想定どおりにならなかったアプリ。
    private static var unreliableApps = Set<String>()

    // MARK: メニュー

    // 入力メニューの項目。システムは打鍵のたびに menu() を呼ぶので 1 度だけ作って使い回す。
    // すべての項目にアクションを持たせる (アクションのない項目や区切り線は入れない)。
    private lazy var statsItem = NSMenuItem(title: "", action: #selector(showStats(_:)), keyEquivalent: "")
    private lazy var predictItem = NSMenuItem(title: "続きを先読みする", action: #selector(togglePrediction(_:)), keyEquivalent: "")
    private lazy var proofreadItem = NSMenuItem(title: "変換の取り違えを指摘する", action: #selector(toggleProofread(_:)), keyEquivalent: "")
    private lazy var pauseItem = NSMenuItem(title: "学習を一時停止", action: #selector(toggleLearning(_:)), keyEquivalent: "")
    private lazy var inputMenu: NSMenu = {
        let menu = NSMenu(title: "Tsumugi")
        menu.addItem(statsItem)
        menu.addItem(predictItem)
        menu.addItem(proofreadItem)
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "学習した内容をすべて消去…", action: #selector(forgetAll(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Tsumugi について…", action: #selector(showAbout(_:)), keyEquivalent: ""))
        return menu
    }()

    override func menu() -> NSMenu! {
        let engine = Engine.shared
        let stats = engine.userModel.stats
        statsItem.title = "覚えた変換 \(stats.words) 件・言い回し \(stats.phrases) 件"
        predictItem.state = engine.predictionEnabled ? .on : .off
        proofreadItem.state = engine.proofreadEnabled ? .on : .off
        pauseItem.state = engine.learningPaused ? .on : .off
        return inputMenu
    }

    @objc func showStats(_ sender: Any?) {}

    /// 版と、同梱している辞書・モデルの作者とライセンスを表示する (CC BY-SA 4.0 の表示義務を含む)。
    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Tsumugi \(version)"
        alert.informativeText = """
        ローカル LLM を内蔵した日本語入力メソッド。入力内容はこの Mac の外に送られません。
        MIT License · https://github.com/Anieca/tsumugi

        同梱しているデータとソフトウェア
        ・辞書: Mozc OSS 辞書 (Google, BSD 3-Clause。IPAdic 由来のデータを含む)
        ・変換モデル: zenz-v3.2-small (Keita Miwa, CC BY-SA 4.0)
          基盤モデル ku-nlp/gpt2-small-japanese-char (CC BY-SA 4.0)
        ・推論: llama.cpp (MIT)
        詳細はアプリ内の NOTICE.md を参照してください。
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "GitHub を開く")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: "https://github.com/Anieca/tsumugi") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func togglePrediction(_ sender: Any?) {
        Engine.shared.predictionEnabled.toggle()
        session?.predictionEnabled = Engine.shared.predictionEnabled
    }

    @objc func toggleProofread(_ sender: Any?) {
        Engine.shared.proofreadEnabled.toggle()
        proofTicket.advance()
        correction = nil
        assistPanel.hide()
    }

    @objc func toggleLearning(_ sender: Any?) {
        Engine.shared.learningPaused.toggle()
    }

    @objc func forgetAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "学習した内容をすべて消去しますか？"
        alert.informativeText = "覚えた変換と言い回しの履歴がこの Mac から削除されます。取り消せません。"
        alert.addButton(withTitle: "消去")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Engine.shared.userModel.forgetAll()
        }
    }
}

/// 読み直しの世代を、メインスレッドと読み直しのスレッドの両方から見るための入れ物。
final class Ticket {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        stored += 1
        return stored
    }
}

/// どのアプリで文章を読めているかを調べるための記録。文章そのものは書き出さず、文字数だけを残す。
/// `defaults write io.github.anieca.inputmethod.Tsumugi ContextProbe -bool YES` で有効になる。
enum ContextProbe {
    private static let enabled = UserDefaults.standard.bool(forKey: "ContextProbe")
    private static let url = UserModel.defaultURL().deletingLastPathComponent().appendingPathComponent("context-probe.log")

    static func record(app: String?, location: Int, read: Int?) {
        guard enabled else { return }
        let loc = location == NSNotFound ? "不明" : String(location)
        trace("\(app ?? "?")\t位置 \(loc)\t\(read.map { "\($0) 字" } ?? "読めず")")
    }

    /// 打った文字は残さず、キーの種類だけを名前にする。
    static func name(_ key: Key) -> String {
        if case .char = key { return "文字" }
        return String(describing: key)
    }

    static func trace(_ message: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
