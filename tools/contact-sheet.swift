// swift tools/contact-sheet.swift out.png cols img1 img2 … — labelled grid of screenshots (for review).
import AppKit
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, files = Array(a[3...])
let cellW: CGFloat = 660, cellH: CGFloat = 430, label: CGFloat = 22
let rows = (files.count + cols - 1) / cols
let size = NSSize(width: CGFloat(cols) * cellW, height: CGFloat(rows) * (cellH + label))
let img = NSImage(size: size)
img.lockFocus()
NSColor(white: 0.5, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
for (i, f) in files.enumerated() {
    let c = i % cols, r = i / cols
    let x = CGFloat(c) * cellW, top = size.height - CGFloat(r) * (cellH + label)
    (URL(fileURLWithPath: f).lastPathComponent as NSString).draw(at: NSPoint(x: x + 6, y: top - label + 4),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
    if let im = NSImage(contentsOfFile: f) {
        let s = min((cellW - 8) / im.size.width, (cellH - 8) / im.size.height)
        im.draw(in: NSRect(x: x + 4, y: top - label - cellH + 4 + (cellH - 8 - im.size.height * s), width: im.size.width * s, height: im.size.height * s))
    }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
