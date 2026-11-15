import AppKit
import TsumugiCore
import TsumugiUI

// 入力メソッドとして登録しなくても、同じエンジン・同じ UI を 1 つのウインドウで試せる検証用アプリ。
//   TsumugiPlayground                     ウインドウを開く
//   TsumugiPlayground --snapshot <dir>    パネルの見た目を PNG に書き出して終了

final class EditorView: NSView {
    var session: Session?
    private var committed = ""
    let panel = AssistPanel()
    private let font = NSFont.systemFont(ofSize: 20)
    private var caretRect = NSRect.zero
    private var focusRect = NSRect.zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func attach(_ session: Session) {
        self.session = session
        session.onCommit = { [weak self] in self?.committed += $0 }
        session.onAsyncUpdate = { [weak self] in self?.refresh() }
        session.contextProvider = { [weak self] in self.map { String($0.committed.suffix(300)) } }
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if let key = KeyMapping.key(for: event), session.handle(key) {
            refresh()
            return
        }
        // セッションが処理しなかったキーは、ふつうのテキスト欄と同じように扱う
        switch event.keyCode {
        case 36, 76: committed += "\n"
        case 51: if !committed.isEmpty { committed.removeLast() }
        default:
            if let s = event.characters, !event.modifierFlags.contains(.command),
               s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) {
                committed += s
            }
        }
        refresh()
    }

    /// 検証用: キーを直接流し込む。
    func feed(_ key: Key) {
        guard let session else { return }
        if !session.handle(key), case .char(let c) = key { committed.append(c) }
        refresh()
    }

    func refresh() {
        needsDisplay = true
        displayIfNeeded()
        guard let session, let window else { return }
        let view = session.view
        let content = AssistContent(view: view)
        let local = view.focus != nil ? focusRect : caretRect
        let anchor = view.isComposing ? NSRect(x: view.focus != nil ? focusRect.minX : composeStart.x, y: local.minY, width: 1, height: local.height) : caretRect
        let inWindow = convert(anchor, to: nil)
        panel.show(content, at: window.convertToScreen(inWindow))
    }

    private var composeStart = NSPoint.zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let view = session?.view ?? SessionView()
        let text = NSMutableAttributedString(string: committed, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let composeLocation = text.length
        var focusRange: NSRange?
        for (i, seg) in view.segments.enumerated() {
            let focused = view.focus == i
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .underlineStyle: (focused ? NSUnderlineStyle.thick : NSUnderlineStyle.single).rawValue,
                .underlineColor: focused ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            if focused { focusRange = NSRange(location: text.length, length: (seg as NSString).length) }
            text.append(NSAttributedString(string: seg, attributes: attrs))
        }
        let inset: CGFloat = 28
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: bounds.width - inset * 2, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let origin = NSPoint(x: inset, y: inset)
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: origin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)

        func rect(at index: Int) -> NSRect {
            let lineHeight = layout.defaultLineHeight(for: font)
            if text.length == 0 { return NSRect(x: origin.x, y: origin.y, width: 1, height: lineHeight) }
            if index >= text.length {
                let extra = layout.extraLineFragmentRect
                if extra.height > 0 { return NSRect(x: origin.x + extra.minX, y: origin.y + extra.minY, width: 1, height: lineHeight) }
                let last = layout.boundingRect(forGlyphRange: NSRange(location: layout.numberOfGlyphs - 1, length: 1), in: container)
                return NSRect(x: origin.x + last.maxX, y: origin.y + last.minY, width: 1, height: last.height)
            }
            let g = layout.glyphIndexForCharacter(at: index)
            let r = layout.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
            return NSRect(x: origin.x + r.minX, y: origin.y + r.minY, width: 1, height: r.height)
        }
        caretRect = rect(at: text.length)
        composeStart = rect(at: composeLocation).origin
        focusRect = focusRange.map { rect(at: $0.location) } ?? caretRect
        NSColor.controlAccentColor.setFill()
        NSRect(x: caretRect.minX, y: caretRect.minY + 2, width: 1.5, height: caretRect.height - 4).fill()

        if committed.isEmpty && !view.isComposing {
            let hint = "ここに日本語を入力してみてください (ローマ字入力)\n\nSpace 変換 ・ Tab 先読みを確定 ・ ←→ 文節移動 ・ Shift+←→ 文節の伸縮 ・ Esc 取り消し"
            (hint as NSString).draw(at: NSPoint(x: inset + 8, y: inset + 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        if let session = Engine.shared.makeSession() {
            editor.attach(session)
        }
        window = NSWindow(contentRect: editor.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tsumugi Playground"
        window.contentView = editor
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), CommandLine.arguments.count > i + 1 {
            runDemo(editor, dir: CommandLine.arguments[i + 1])
        }
    }

    /// 検証用: 決まった打鍵を流し、各場面のスクリーンショットを撮って終了する。
    private func runDemo(_ editor: EditorView, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let steps: [(String, [Key])] = [
            ("1-live", Array("kyouhakaiginosiryouwo").map(Key.char)),
            ("2-ghost", [.enter] + Array("arigatougo").map(Key.char)),
            ("3-accepted", [.tab] + Array("kousei").map(Key.char)),
            ("4-candidates", [.space, .space, .space]),
            ("5-segments", [.enter] + Array("kyouhaisyaniiku").map(Key.char) + [.right, .shiftLeft]),
        ]
        var index = 0
        func next() {
            guard index < steps.count else { NSApp.terminate(nil); return }
            let (name, keys) = steps[index]
            index += 1
            var k = 0
            func typeNext() {
                if k < keys.count {
                    editor.feed(keys[k]); k += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: typeNext)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.capture(editor, to: "\(dir)/\(name).png")
                        next()
                    }
                }
            }
            typeNext()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: next)
    }

    /// 画面収録の権限なしで撮れるよう、ウインドウの中身とパネルを自前で 1 枚に合成する。
    private func capture(_ editor: EditorView, to path: String) {
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else { return }
        editor.cacheDisplay(in: editor.bounds, to: rep)
        let image = NSImage(size: editor.bounds.size)
        image.lockFocus()
        rep.draw(in: editor.bounds)
        let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let pf = editor.panel.visibleFrame, let content = MainActor.assumeIsolated({ editor.panel.renderContent(dark: dark) }) {
            let origin = editor.window!.convertFromScreen(pf).origin   // ウインドウ座標 (左下原点)
            content.draw(in: NSRect(origin: origin, size: pf.size))
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.userModel.saveNow()
    }
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    MainActor.assumeIsolated {
        let cands = ["構成", "校正", "厚生", "公正", "後世", "更生", "恒星", "攻勢", "抗生", "こうせい", "コウセイ"]
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            AssistPanel.snapshot(.candidates(cands, selected: 1), dark: dark, to: dir.appendingPathComponent("candidates\(suffix).png"))
            AssistPanel.snapshot(.ghost(Ghost(text: "ありがとうございます", reading: "ありがとうございます", source: .neural), typed: "ありがとうご"),
                                 dark: dark, to: dir.appendingPathComponent("ghost-neural\(suffix).png"))
            AssistPanel.snapshot(.ghost(Ghost(text: "お世話になっております", reading: "おせわになっております", source: .history), typed: "お世話"),
                                 dark: dark, to: dir.appendingPathComponent("ghost-history\(suffix).png"))
        }
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
