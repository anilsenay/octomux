// Draws the "Octomux Dev" icon: the app icon with a DEV band across the bottom, so the Dev variant is easy to
// tell apart in the Dock and the app switcher. usage: swift tools/dev-icon.swift <AppIcon-1024.png> <out.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let base = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: dev-icon.swift <AppIcon-1024.png> <out.icns>\n".data(using: .utf8)!)
    exit(1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    // The band sits inside the squircle (macOS icons leave a ~10% margin).
    let band = NSRect(x: s * 0.2, y: s * 0.115, width: s * 0.6, height: s * 0.155)
    NSColor(srgbRed: 0.97, green: 0.55, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: band, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    let font = NSFont.systemFont(ofSize: s * 0.11, weight: .heavy)
    let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: s * 0.012])
    let size = text.size()
    text.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2 + s * 0.004))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("octomux-dev-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", args[2]]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
