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

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        session = Engine.shared.makeSession()
        session?.onCommit = { [weak self] text in
            self?.textClient?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            self?.hadMarkedText = false
        }
        session?.onAsyncUpdate = { [weak self] in self?.render() }
        session?.contextProvider = { [weak self] in self?.textBeforeCursor() }
    }

    /// カーソルより前の文章 (最大 300 字)。先読みと変換の文脈にだけ使い、保存はしない。
    /// 位置や文章を教えてくれないアプリでは nil。
    private func textBeforeCursor() -> String? {
        guard let client = textClient else { return nil }
        let sel = client.selectedRange()
        // 文章を読めないアプリは位置 0 を返すことがあるので、0 は「わからない」として扱う
        guard sel.location != NSNotFound, sel.location > 0 else { return nil }
        let n = min(sel.location, 300)
        return client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string
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
        guard let session, !directInput else { return false }
        guard let key = KeyMapping.key(for: event) else {
            // ショートカットなどはアプリへ。先読みは消しておく
            if !session.isComposing { assistPanel.hide() }
            return false
        }
        let handled = session.handle(key)
        render()
        return handled
    }

    /// 英数 / かな キーや入力メニューでのモード切り替え。
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if let mode = value as? String {
            let roman = mode == Self.romanMode
            if roman != directInput {
                session?.commitAll()
                render()
                directInput = roman
            }
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    override func commitComposition(_ sender: Any!) {
        session?.commitAll()
        render()
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        session?.predictionEnabled = Engine.shared.predictionEnabled
    }

    override func deactivateServer(_ sender: Any!) {
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
            assistPanel.hide()
            return
        }
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: focusOffset, lineHeightRectangle: &rect)
        // 位置を教えてくれないアプリでは、前回の位置のまま出す
        assistPanel.show(content, at: rect == .zero ? nil : rect)
    }

    // MARK: メニュー

    // 入力メニューの項目。システムは打鍵のたびに menu() を呼ぶので 1 度だけ作って使い回す。
    // すべての項目にアクションを持たせる (アクションのない項目や区切り線は入れない)。
    private lazy var statsItem = NSMenuItem(title: "", action: #selector(showStats(_:)), keyEquivalent: "")
    private lazy var predictItem = NSMenuItem(title: "続きを先読みする", action: #selector(togglePrediction(_:)), keyEquivalent: "")
    private lazy var pauseItem = NSMenuItem(title: "学習を一時停止", action: #selector(toggleLearning(_:)), keyEquivalent: "")
    private lazy var inputMenu: NSMenu = {
        let menu = NSMenu(title: "Tsumugi")
        menu.addItem(statsItem)
        menu.addItem(predictItem)
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
