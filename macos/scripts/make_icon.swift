import AppKit
// 元の WinSCP のアイコン (source/resource/Application.ico) から AppIcon.iconset を作る
//   swift scripts/make_icon.swift ../source/resource/Application.ico <出力.iconset>
let ico = CommandLine.arguments[1], out = CommandLine.arguments[2]
guard let img = NSImage(contentsOfFile: ico) else { fatalError("ico を読めません") }
// いちばん大きい絵 (256px) を元にする。小さいサイズは ico の中の同じ大きさの絵があればそれを使う
let reps = img.representations.compactMap { $0 as? NSBitmapImageRep }
func best(_ px: Int) -> NSBitmapImageRep {
    // 余白をとった後の絵の大きさに近いものを選ぶ
    if px <= 32, let small = reps.filter({ $0.pixelsWide >= px * 824 / 1024 && $0.bitsPerPixel >= 32 }).min(by: { $0.pixelsWide < $1.pixelsWide }) { return small }
    if let exact = reps.filter({ $0.pixelsWide == px && $0.bitsPerPixel >= 32 }).first { return exact }
    return reps.max(by: { $0.pixelsWide < $1.pixelsWide })!
}
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let src = best(px)
    let dst = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: dst)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    // macOS のアイコンは周りに余白がある (1024 中 824 ほどが絵)。ico は端いっぱいなので縮めて中央に置く
    let inset = CGFloat(px) * 100.0 / 1024.0
    src.draw(in: NSRect(x: inset, y: inset, width: CGFloat(px) - inset * 2, height: CGFloat(px) - inset * 2), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    try! dst.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
