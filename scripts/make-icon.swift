// メニューバー用のテンプレートアイコン (16pt, 1x/2x) を描く。 usage: make-icon.swift <文字> <出力.tiff>
import AppKit
let glyph = CommandLine.arguments[1], out = CommandLine.arguments[2]
func rep(_ scale: Int) -> NSBitmapImageRep {
    let px = 16 * scale
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    r.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.black]
    let s = glyph as NSString
    let size = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2), withAttributes: attrs)
    NSGraphicsContext.current?.flushGraphics()
    return r
}
let image = NSImage(size: NSSize(width: 16, height: 16))
image.addRepresentation(rep(1))
image.addRepresentation(rep(2))
try! image.tiffRepresentation!.write(to: URL(fileURLWithPath: out))
