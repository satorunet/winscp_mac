// DMG を開いたときの背景: 左のアプリから右の「アプリケーション」への矢印と案内
// 使い方: swift scripts/make_dmg_bg.swift <出力.png> <倍率 1|2>
// 窓は 640×400。アイコンは アプリ (170,190)・アプリケーション (470,190) (bundle.sh と合わせる)
import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args.count > 2 ? args[2] : "1") ?? 1)
let W: CGFloat = 640, H: CGFloat = 400
func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: color(0xF7F9FC), ending: color(0xE3E9F2))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

func text(_ s: String, size: CGFloat, bold: Bool, color c: NSColor, centerY: CGFloat) {
    let font = NSFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) ?? NSFont.systemFont(ofSize: size)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
    let sz = a.size()
    a.draw(at: NSPoint(x: (W - sz.width) / 2, y: centerY - sz.height / 2))
}
text("WinSCP Mac", size: 24, bold: true, color: color(0x1B2A4A), centerY: H - 48)

// 矢印 (アイコンの中心は上から 190)
let y: CGFloat = H - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 252, y: y)); arrow.line(to: NSPoint(x: 372, y: y))
arrow.lineWidth = 9; arrow.lineCapStyle = .round
color(0x2B6CD9).setStroke(); arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 392, y: y)); head.line(to: NSPoint(x: 362, y: y + 22)); head.line(to: NSPoint(x: 362, y: y - 22)); head.close()
head.lineJoinStyle = .round; head.lineWidth = 6
color(0x2B6CD9).setFill(); head.fill(); head.stroke()

text("左のアイコンを、右の「アプリケーション」へドラッグしてください", size: 14, bold: false, color: color(0x3A4558), centerY: 70)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
