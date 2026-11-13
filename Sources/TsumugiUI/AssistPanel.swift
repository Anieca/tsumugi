import AppKit
import SwiftUI
import TsumugiCore

/// カーソルのそばに出す小さなパネルの中身。先読みのピルか、候補リストのどちらか。
public enum AssistContent: Equatable {
    case hidden
    /// typed: いま未確定で表示されている文字列 (先読みのうち、すでに打った部分を薄く見せる)
    case ghost(Ghost, typed: String)
    case candidates([String], selected: Int)

    public init(view: SessionView) {
        if !view.candidates.isEmpty {
            self = .candidates(view.candidates, selected: view.candidateIndex)
        } else if let g = view.ghost {
            self = .ghost(g, typed: view.markedText)
        } else {
            self = .hidden
        }
    }
}

final class AssistModel: ObservableObject {
    @Published var content = AssistContent.hidden
}

// MARK: - SwiftUI

private struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// 先読み。打った部分は薄く、Tab で増える部分ははっきりと。
struct GhostPill: View {
    let ghost: Ghost
    let typed: String

    var body: some View {
        let shared = ghost.text.commonPrefix(with: typed)
        let rest = String(ghost.text.dropFirst(shared.count))
        HStack(spacing: 7) {
            Image(systemName: ghost.source == .history ? "clock.arrow.circlepath" : "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ghost.source == .history ? Color.secondary : Color.accentColor)
            (Text(shared).foregroundColor(.secondary) + Text(rest).foregroundColor(.primary))
                .font(.system(size: 14))
                .lineLimit(1)
            Keycap(label: "tab")
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 28)
        .fixedSize()
    }
}

struct CandidateList: View {
    let items: [String]
    let selected: Int
    static let pageSize = 9

    var body: some View {
        let page = selected / Self.pageSize
        let start = page * Self.pageSize
        let visible = Array(items[start..<min(items.count, start + Self.pageSize)])
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(visible.enumerated()), id: \.offset) { i, text in
                let isSelected = start + i == selected
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.8))
                        .frame(width: 12)
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isSelected ? Color.accentColor : Color.clear))
            }
            if items.count > Self.pageSize {
                HStack {
                    Spacer()
                    Text("\(selected + 1) / \(items.count)")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 3)
                .padding(.bottom, 1)
            }
        }
        .padding(5)
        .frame(minWidth: 140)
        .fixedSize()
    }
}

struct AssistRoot: View {
    @ObservedObject var model: AssistModel

    var body: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .ghost(let g, let typed):
            GhostPill(ghost: g, typed: typed)
        case .candidates(let items, let selected):
            CandidateList(items: items, selected: selected)
        }
    }
}

// MARK: - パネル

/// キーボードフォーカスを奪わずにカーソルのそばへ浮かぶパネル。
public final class AssistPanel {
    private let panel: NSPanel
    private let model = AssistModel()
    private let hosting: NSHostingView<AssistRoot>
    private let effect = NSVisualEffectView()

    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hosting = NSHostingView(rootView: AssistRoot(model: model))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.addSubview(hosting)
        panel.contentView = effect
    }

    /// - Parameter caret: 対象の文字位置の矩形 (スクリーン座標)。nil なら位置は変えない。
    public func show(_ content: AssistContent, at caret: NSRect?) {
        guard content != .hidden else {
            hide()
            return
        }
        model.content = content
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        if case .ghost = content {
            effect.layer?.cornerRadius = size.height / 2
        } else {
            effect.layer?.cornerRadius = 10
        }
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        var origin = panel.frame.origin
        if let caret {
            let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var x = caret.minX - 6
            var y = caret.minY - size.height - 5
            if y < visible.minY { y = caret.maxY + 5 }   // 下に収まらなければ上へ
            x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
            origin = NSPoint(x: x, y: y)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    public func hide() {
        if panel.isVisible { panel.orderOut(nil) }
        model.content = .hidden
    }

    /// 検証用: いま表示中のパネルの位置 (スクリーン座標) と描画内容。
    public var visibleFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// 検証用: いま表示中の内容を、パネルと同じ形の画像として描く (画面収録の権限が不要)。
    @MainActor
    public func renderContent(dark: Bool) -> NSImage? {
        guard panel.isVisible else { return nil }
        let m = AssistModel()
        m.content = model.content
        let isGhost: Bool
        if case .ghost = model.content { isGhost = true } else { isGhost = false }
        let shape = RoundedRectangle(cornerRadius: isGhost ? 14 : 10, style: .continuous)
        let v = AssistRoot(model: m)
            .background(dark ? Color(white: 0.17) : Color(white: 0.97))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: v)
        r.scale = 2
        return r.nsImage
    }

    /// 検証用: パネルの見た目を PNG に描き出す。
    @MainActor
    public static func snapshot(_ content: AssistContent, dark: Bool, to url: URL) {
        let m = AssistModel()
        m.content = content
        let isGhost: Bool
        if case .ghost = content { isGhost = true } else { isGhost = false }
        let bg = dark ? Color(white: 0.17) : Color(white: 0.97)
        let page = dark ? Color(white: 0.08) : Color.white
        let v = AssistRoot(model: m)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: isGhost ? 14 : 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: isGhost ? 14 : 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(18)
            .background(page)
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
