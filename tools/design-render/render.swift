// swift tools/design-render/render.swift <dir> <file.dc.html> <out.png> <width> <height>
// Renders one of our design files offscreen (WebKit) using tools/design-render/support.js.
import AppKit
import WebKit
let a = CommandLine.arguments
let dir = URL(fileURLWithPath: a[1]), out = a[3]
let w = CGFloat(Double(a[4])!), h = CGFloat(Double(a[5])!)
_ = NSApplication.shared
let cfg = WKWebViewConfiguration()
cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
let win = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = web
web.loadFileURL(dir.appendingPathComponent(a[2]), allowingReadAccessTo: dir)
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    web.evaluateJavaScript("document.documentElement.getAttribute('data-rendered') + ' / ' + document.querySelectorAll('*').length + ' nodes'") { r, e in
        print("render:", r ?? "nil", e.map { "\($0)" } ?? "")
        let c = WKSnapshotConfiguration(); c.rect = web.bounds
        web.takeSnapshot(with: c) { img, _ in
            if let img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out)); print("wrote", out)
            }
            exit(0)
        }
    }
}
NSApplication.shared.run()
