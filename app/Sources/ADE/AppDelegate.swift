import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var mainWindow: NSWindow?
    private var swipeAccum: CGFloat = 0

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
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildMenu()
        Notifier.shared.start()
        AppModel.shared.start()
        openMainWindow()
        installSwipeMonitor()
        DebugActions.register()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    func openMainWindow() {
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "ADE"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("ADE.main")
        w.contentView = NSHostingView(rootView: MainView().environmentObject(AppModel.shared))
        w.minSize = NSSize(width: 640, height: 400)
        if !w.setFrameUsingName("ADE.main") { w.center() }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        mainWindow = w
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = AppModel.shared.focusedSessionId { AppModel.shared.markRead(id) }
    }

    /// Two-finger horizontal swipe over the sidebar switches workspaces.
    private func installSwipeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let win = event.window, win === self.mainWindow, AppModel.shared.sidebarVisible,
                  event.locationInWindow.x < 250, event.hasPreciseScrollingDeltas else { return event }
            if event.phase == .began { self.swipeAccum = 0 }
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                self.swipeAccum += event.scrollingDeltaX
            }
            if event.phase == .ended || event.phase == .cancelled {
                if abs(self.swipeAccum) > 60 {
                    AppModel.shared.cycleWorkspace(self.swipeAccum < 0 ? 1 : -1)
                }
                self.swipeAccum = 0
            }
            return event
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ADE", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ADE", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ADE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = submenu(main, "File")
        file.addItem(item("New Terminal Tab", #selector(newTerminal(_:)), "t"))
        file.addItem(item("New Agent Tab", #selector(newAgent(_:)), "T"))
        file.addItem(item("Split Right", #selector(splitRight(_:)), "d"))
        file.addItem(item("Split Down", #selector(splitDown(_:)), "D"))
        file.addItem(.separator())
        file.addItem(item("Add Project…", #selector(addProject(_:)), "O"))
        file.addItem(item("Open Project in Default App", #selector(openInDefault(_:)), "o"))
        file.addItem(.separator())
        file.addItem(item("Close Pane", #selector(closePane(_:)), "w"))

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let session = submenu(main, "Session")
        session.addItem(item("Next Waiting for Input", #selector(nextWaiting(_:)), "U"))
        session.addItem(item("Stop Session", #selector(stopSession(_:)), "."))
        session.addItem(item("Rename Session", #selector(renameSession(_:)), ""))
        session.addItem(item("Toggle Chat View", #selector(toggleChat(_:)), "C"))
        session.addItem(.separator())
        for (title, sel, key, mods) in [("Focus Left", #selector(focusLeft(_:)), NSLeftArrowFunctionKey, NSEvent.ModifierFlags([.command, .option])),
                                        ("Focus Right", #selector(focusRight(_:)), NSRightArrowFunctionKey, [.command, .option]),
                                        ("Focus Up", #selector(focusUp(_:)), NSUpArrowFunctionKey, [.command, .option]),
                                        ("Focus Down", #selector(focusDown(_:)), NSDownArrowFunctionKey, [.command, .option])] {
            let i = item(title, sel, String(Character(UnicodeScalar(key)!)))
            i.keyEquivalentModifierMask = mods
            session.addItem(i)
        }

        let view = submenu(main, "View")
        view.addItem(item("Toggle Sidebar", #selector(toggleSidebar(_:)), "b"))
        view.addItem(item("Toggle Dock", #selector(toggleDock(_:)), "j"))
        let rp = item("Toggle Changes Panel", #selector(toggleRightPanel(_:)), "b")
        rp.keyEquivalentModifierMask = [.command, .option]
        view.addItem(rp)
        view.addItem(.separator())
        let prev = item("Previous Tab", #selector(prevTab(_:)), "{")
        view.addItem(prev)
        view.addItem(item("Next Tab", #selector(nextTab(_:)), "}"))
        for n in 1...9 {
            let i = item("Tab \(n)", #selector(goToTab(_:)), "\(n)")
            i.tag = n
            view.addItem(i)
        }
        view.addItem(.separator())
        let pw = item("Previous Workspace", #selector(prevWorkspace(_:)), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        pw.keyEquivalentModifierMask = [.command, .control]
        view.addItem(pw)
        let nw = item("Next Workspace", #selector(nextWorkspace(_:)), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        nw.keyEquivalentModifierMask = [.command, .control]
        view.addItem(nw)
        for n in 1...9 {
            let i = item("Workspace \(n)", #selector(goToWorkspace(_:)), "\(n)")
            i.keyEquivalentModifierMask = [.control]
            i.tag = n
            view.addItem(i)
        }

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(item("Main Window", #selector(showMain(_:)), "0"))
        NSApp.windowsMenu = window

        let palette = item("Command Palette…", #selector(showPalette(_:)), "k")
        view.insertItem(palette, at: 0)
        view.insertItem(.separator(), at: 1)

        NSApp.mainMenu = main
        KeyBindings.shared.capture(main)
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let it = NSMenuItem()
        let m = NSMenu(title: title)
        it.submenu = m
        main.addItem(it)
        return m
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key.lowercased() == key ? key : key.lowercased())
        if key != key.lowercased() || ["{", "}", "U", "T", "D", "O", "C"].contains(key) {
            i.keyEquivalent = key == "{" ? "[" : key == "}" ? "]" : key.lowercased()
            i.keyEquivalentModifierMask = [.command, .shift]
        }
        i.target = self
        i.identifier = NSUserInterfaceItemIdentifier("cmd." + title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: "-"))
        return i
    }

    var model: AppModel { AppModel.shared }

    @objc func showSettings(_ s: Any?) { SettingsWindow.show() }
    @objc func showPalette(_ s: Any?) {
        openMainWindow()
        model.paletteVisible.toggle()
    }
    @objc func showMain(_ s: Any?) { openMainWindow() }
    @objc func newTerminal(_ s: Any?) { model.newSession(profileId: nil) }
    @objc func newAgent(_ s: Any?) { model.newSession(profileId: (model.pinnedProfiles.first ?? model.enabledProfiles.first)?.id) }
    @objc func splitRight(_ s: Any?) { model.newSession(profileId: nil, split: .right) }
    @objc func splitDown(_ s: Any?) { model.newSession(profileId: nil, split: .down) }
    @objc func addProject(_ s: Any?) { model.addProject() }
    @objc func openInDefault(_ s: Any?) { if let p = model.currentProject { OpenIn.open(p.path, appId: OpenIn.defaultAppId) } }
    @objc func closePane(_ s: Any?) {
        if NSApp.keyWindow === mainWindow { model.closeFocusedPane() } else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func nextWaiting(_ s: Any?) { model.nextNeedingInput() }
    @objc func stopSession(_ s: Any?) { if let id = model.focusedSessionId { model.stop(id) } }
    @objc func renameSession(_ s: Any?) { model.renamingSessionId = model.focusedSessionId }
    @objc func toggleChat(_ s: Any?) { model.toggleChat() }
    @objc func toggleSidebar(_ s: Any?) { model.toggleSidebar() }
    @objc func toggleDock(_ s: Any?) { model.toggleDock() }
    @objc func toggleRightPanel(_ s: Any?) { model.rightPanelVisible.toggle() }
    @objc func prevTab(_ s: Any?) { model.cycleTab(-1) }
    @objc func nextTab(_ s: Any?) { model.cycleTab(1) }
    @objc func goToTab(_ s: NSMenuItem) { model.selectTab(index: s.tag == 9 ? -1 : s.tag - 1) }
    @objc func prevWorkspace(_ s: Any?) { model.cycleWorkspace(-1) }
    @objc func nextWorkspace(_ s: Any?) { model.cycleWorkspace(1) }
    @objc func goToWorkspace(_ s: NSMenuItem) {
        let ws = model.state.workspaces.sorted { $0.sort < $1.sort }
        if s.tag - 1 < ws.count { model.selectWorkspace(ws[s.tag - 1].id) }
    }
    @objc func focusLeft(_ s: Any?) { TerminalHost.shared.focusNeighbor(.minX) }
    @objc func focusRight(_ s: Any?) { TerminalHost.shared.focusNeighbor(.maxX) }
    @objc func focusUp(_ s: Any?) { TerminalHost.shared.focusNeighbor(.maxY) }
    @objc func focusDown(_ s: Any?) { TerminalHost.shared.focusNeighbor(.minY) }
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
