import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard GhosttyRuntime.shared.start() else {
            let alert = NSAlert()
            alert.messageText = "Terminal engine failed to start"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        DebugServer.shared.start()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--proto") {
            ProtoWindow.open(sessions: Array(args[(i + 1)...]), into: &windows)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Prototype A: a window with N side-by-side panes, each attached to a session.
enum ProtoWindow {
    static func open(sessions: [String], into windows: inout [NSWindow]) {
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 700),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "ADE prototype A"
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for id in sessions {
            let v = TerminalSurfaceView(sessionId: id, command: "\(Paths.adeBinary) attach \(id)",
                                        env: ["ADE_HOME": Paths.home.path])
            TerminalRegistry.shared.add(v)
            split.addArrangedSubview(v)
        }
        win.contentView = split
        win.makeKeyAndOrderFront(nil)
        if let first = split.arrangedSubviews.first { win.makeFirstResponder(first) }
        windows.append(win)
    }
}
