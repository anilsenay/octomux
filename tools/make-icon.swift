// Draws Octomux's app icon: the purple pixel octopus (design/brand/octomux-logo.html, "Detaylı piksel")
// on a lavender squircle. Sprite cells snap to whole device pixels so edges stay crisp at every size.
// Output: app/Resources/AppIcon.icns (+ AppIcon-1024.png). usage: swift tools/make-icon.swift [repo-root]
import AppKit

let sprite = [
    ".....######.....",
    "...#hhh######...",
    "..#hhh########..",
    ".##hh#########s.",
    ".#############s.",
    ".###we####we##s.",
    ".###ee####ee##s.",
    ".###ee####ee##s.",
    ".#c##########cs.",
    "..###########s..",
    ".##.##.##.##.##.",
    "##..#..##..#..##",
    "#...#..##..#...#",
].map { Array($0) }

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let palette: [Character: CGColor] = [
    "#": rgb(0x8b5cf6), "h": rgb(0xc4b5fd), "s": rgb(0x6d28d9),
    "e": rgb(0x1e1b4b), "w": rgb(0xffffff), "c": rgb(0xf9a8d4),
]

/// Renders the icon into a `px`×`px` bitmap. Coordinates are top-left based (the context is flipped).
func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let size = CGFloat(px), s = size / 1024
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)
    // macOS icon grid: 824pt body centered in 1024, with room for the drop shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(squircle); ctx.setFillColor(rgb(0xd9cffd)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xefeaff), rgb(0xd9cffd)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(squircle); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.06)); ctx.setLineWidth(max(1, 4 * s)); ctx.strokePath()

    // Sprite: 62% of the body wide, centered slightly below the middle (as in the brand page).
    let cols = sprite[0].count, rows = sprite.count
    let cell = max(1, (body.width * 0.62 / CGFloat(cols)).rounded())
    let ox = (body.midX - CGFloat(cols) * cell / 2).rounded()
    let oy = (body.minY + body.height * 0.51 - CGFloat(rows) * cell / 2).rounded()
    ctx.setShouldAntialias(false)
    for (y, row) in sprite.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = palette[ch] else { continue }
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: cell, height: cell))
        }
    }
    return rep
}

/// Below ~32px a 16-column sprite can't get a whole pixel per cell; downsample the 1024 render instead.
func image(px: Int, master: NSBitmapImageRep) -> NSBitmapImageRep {
    if CGFloat(px) * 824 / 1024 * 0.62 / 16 >= 1 { return render(px: px) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.draw(master.cgImage!, in: CGRect(x: 0, y: 0, width: px, height: px))
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Octomux.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = render(px: 1024)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = px == 1024 ? master : image(px: px, master: master)
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("app/Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
let png = root.appendingPathComponent("app/Resources/AppIcon-1024.png")
try? FileManager.default.removeItem(at: png)
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: png)
print(out.path)
