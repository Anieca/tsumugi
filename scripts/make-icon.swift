// 入力メニュー用のテンプレートアイコン (16pt, 1x/2x/3x) を描く。 usage: make-icon.swift ja|roman <出力.tiff>
// 角丸の四角を塗り、印を抜く。テンプレート画像なので、色は置かれる場所に合わせて OS が決める
// (メニューバーでは黒か白、切り替えの青い表示の上では白い四角に青い印)。
// 日本語の印は、アプリのアイコンと同じ「つ」の形の糸。
import AppKit
let mode = CommandLine.arguments[1], out = CommandLine.arguments[2]

/// アプリのアイコンの糸をなぞった形 (16×16 の座標、y は上向き)。
func thread() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 2.6, y: 9.6))
    p.curve(to: NSPoint(x: 9.6, y: 12.5), controlPoint1: NSPoint(x: 4.6, y: 11.6), controlPoint2: NSPoint(x: 7.4, y: 11.4))
    p.curve(to: NSPoint(x: 13.5, y: 8.5), controlPoint1: NSPoint(x: 12.0, y: 13.0), controlPoint2: NSPoint(x: 13.5, y: 11.0))
    p.curve(to: NSPoint(x: 7.6, y: 3.6), controlPoint1: NSPoint(x: 13.5, y: 5.6), controlPoint2: NSPoint(x: 10.6, y: 3.8))
    p.curve(to: NSPoint(x: 3.9, y: 4.5), controlPoint1: NSPoint(x: 6.2, y: 3.5), controlPoint2: NSPoint(x: 4.9, y: 3.9))
    p.curve(to: NSPoint(x: 10.9, y: 8.5), controlPoint1: NSPoint(x: 7.6, y: 4.9), controlPoint2: NSPoint(x: 10.9, y: 5.9))
    p.curve(to: NSPoint(x: 9.4, y: 10.2), controlPoint1: NSPoint(x: 10.9, y: 9.7), controlPoint2: NSPoint(x: 10.4, y: 10.3))
    p.curve(to: NSPoint(x: 3.2, y: 8.2), controlPoint1: NSPoint(x: 7.4, y: 9.9), controlPoint2: NSPoint(x: 4.8, y: 9.4))
    p.curve(to: NSPoint(x: 2.6, y: 9.6), controlPoint1: NSPoint(x: 2.5, y: 8.3), controlPoint2: NSPoint(x: 2.1, y: 9.0))
    p.close()
    return p
}

func rep(_ scale: Int) -> NSBitmapImageRep {
    let px = 16 * scale
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    r.size = NSSize(width: 16, height: 16)
    let ctx = NSGraphicsContext(bitmapImageRep: r)!
    NSGraphicsContext.current = ctx
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 15, height: 15), xRadius: 3.6, yRadius: 3.6).fill()
    ctx.compositingOperation = .destinationOut
    if mode == "ja" {
        thread().fill()
    } else {
        let base = NSFont.systemFont(ofSize: 12, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let s = "A" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2), withAttributes: attrs)
    }
    ctx.flushGraphics()
    return r
}
let image = NSImage(size: NSSize(width: 16, height: 16))
for scale in 1...3 { image.addRepresentation(rep(scale)) }
try! image.tiffRepresentation!.write(to: URL(fileURLWithPath: out))
