// Draws ADE's app icon (original design): an ink squircle with an inset terminal card,
// a prompt chevron and a coral three-stroke mark. Output: app/Resources/AppIcon.icns
// usage: swift tools/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824pt body centered in 1024 with shadow room.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor(white: 0, alpha: 0.35).cgColor)
    NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    // Subtle top light.
    ctx.saveGState()
    squircle.addClip()
    let grad = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
    grad.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()
    // Inset terminal card.
    let card = CGRect(x: 190 * s, y: 210 * s, width: 644 * s, height: 520 * s)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 62 * s, yRadius: 62 * s)
    NSColor(srgbRed: 0.106, green: 0.106, blue: 0.122, alpha: 1).setFill()
    cardPath.fill()
    NSColor(white: 1, alpha: 0.09).setStroke()
    cardPath.lineWidth = 6 * s
    cardPath.stroke()
    // Prompt chevron.
    let chev = NSBezierPath()
    chev.move(to: CGPoint(x: 280 * s, y: 560 * s))
    chev.line(to: CGPoint(x: 390 * s, y: 470 * s))
    chev.line(to: CGPoint(x: 280 * s, y: 380 * s))
    chev.lineWidth = 46 * s
    chev.lineCapStyle = .round
    chev.lineJoinStyle = .round
    NSColor(srgbRed: 0.86, green: 0.86, blue: 0.88, alpha: 1).setStroke()
    chev.stroke()
    // Cursor line.
    let cursor = NSBezierPath(roundedRect: CGRect(x: 440 * s, y: 360 * s, width: 140 * s, height: 44 * s), xRadius: 22 * s, yRadius: 22 * s)
    NSColor(white: 0.86, alpha: 0.35).setFill()
    cursor.fill()
    // Coral mark (three strokes) at top-right of the card.
    let c = CGPoint(x: 690 * s, y: 600 * s), r: CGFloat = 78 * s
    let mark = NSBezierPath()
    for a in [90.0, 30.0, -30.0] {
        let t = a * .pi / 180
        mark.move(to: CGPoint(x: c.x - cos(t) * r, y: c.y - sin(t) * r))
        mark.line(to: CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r))
    }
    mark.lineWidth = 34 * s
    mark.lineCapStyle = .round
    NSColor(srgbRed: 0.922, green: 0.541, blue: 0.369, alpha: 1).setStroke()
    mark.stroke()
    img.unlockFocus()
    return img
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("ADE.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("app/Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: root.appendingPathComponent("app/Resources/AppIcon-1024.png"))
print(out.path)
