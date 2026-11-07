import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.exportVariant()
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
        // Opened from the disk image or Downloads: move to /Applications first (relaunches from there).
        if AppLocation.offerMoveIfNeeded() { return }
        // Another copy already open (say the dev build and the installed one): only one may run.
        if AppLocation.resolveOtherCopy() { return }
        buildMenu()
        Notifier.shared.start()
        GlobalHotKey.shared.action = { QuickComposer.shared.toggle() }
        GlobalHotKey.shared.apply()
        AppModel.shared.start()
        BrowserUI.start()
        TabSwitcher.shared.start()
        if InboxStore.shared.anyConnected { InboxStore.shared.start() }
        Updater.shared.start()
        openMainWindow()
        installSwipeMonitor()
        DebugActions.register()
        // Saved layouts' menu items (and their ⌃⌘8 / ⌃⌘9) once the daemon's settings are in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshLayoutMenu() }
        // The layout engine's blocks, drawn once off screen while idle (the first layout switch is then quick).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ShellPrewarm.run() }
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
        w.title = Paths.appName
        w.isReleasedWhenClosed = false
        // With a full-size content view the title-bar strip moves the window on any mouse-down, even over
        // our tabs, so tabs could never be dragged. Only `WindowDragArea` (empty top-bar space) moves it.
        w.isMovable = false
        w.setFrameAutosaveName("Octomux.main")
        w.contentView = ContentHostingView(rootView: MainView().environmentObject(AppModel.shared))
        w.minSize = NSSize(width: 640, height: 400)
        if !w.setFrameUsingName("Octomux.main") { w.center() }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        mainWindow = w
        ThemeStore.applyWindowGlass()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = AppModel.shared.focusedSessionId { AppModel.shared.markRead(id) }
    }

    /// Two-finger horizontal swipe over the sidebar switches workspaces.
    private func installSwipeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Scrolling over the workspace switcher steps through workspaces.
            if let win = event.window, let content = win.contentView {
                let p = event.locationInWindow
                let topLeft = CGPoint(x: p.x, y: content.bounds.height - p.y)
                if WorkspaceScroller.shared.rects[ObjectIdentifier(win)]?.contains(topLeft) == true {
                    WorkspaceScroller.shared.handle(event)
                    return nil
                }
            }
            guard let self, let win = event.window, win === self.mainWindow, AppModel.shared.sidebarVisible,
                  event.locationInWindow.x < AppModel.shared.sidebarWidth, event.hasPreciseScrollingDeltas else { return event }
            // A horizontal swipe drags the project list toward the next workspace; vertical scrolling passes.
            return WorkspacePager.shared.handle(event) ? nil : event
        }
    }

    // MARK: Menu

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkNow() }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Paths.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updater.shared.feedURL != nil { appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates(_:)), "")) }
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(Paths.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(Paths.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = submenu(main, "File")
        file.addItem(item("New Terminal Tab", #selector(newTerminal(_:)), "t"))
        file.addItem(item("New Agent Tab", #selector(newAgent(_:)), "T"))
        file.addItem(item("New Chat", #selector(newChat(_:)), "n"))
        file.addItem(item("Quick Composer", #selector(quickComposer(_:)), ""))
        file.addItem(item("Split Right", #selector(splitRight(_:)), "d"))
        file.addItem(item("Split Down", #selector(splitDown(_:)), "D"))
        let zoom = item("Zoom Pane", #selector(zoomPane(_:)), "")
        zoom.keyEquivalent = "\r"; zoom.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(zoom)
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
        let ag = item("Toggle Agents View", #selector(toggleAgentsView(_:)), "a")
        ag.keyEquivalentModifierMask = [.command, .option]
        view.addItem(ag)
        view.addItem(item("Change Scene…", #selector(changeScene(_:)), ""))
        view.addItem(item("Open Agents Home", #selector(openAgentsHome(_:)), ""))
        view.addItem(item("Open Workday", #selector(openWorkday(_:)), ""))
        view.addItem(item("Show Tasks", #selector(showTasks(_:)), ""))
        view.addItem(item("Open Aquarium", #selector(openAquarium(_:)), ""))
        view.addItem(item("Open Assistant", #selector(openAssistant(_:)), ""))
        view.addItem(.separator())
        for p in LayoutPreset.allCases {   // ⌃⌘1…4
            let i = item("\(p.title) Layout", #selector(chooseLayout(_:)), "\(p.number)")
            i.keyEquivalentModifierMask = [.control, .command]
            i.tag = p.number
            view.addItem(i)
        }
        view.addItem(item("Customize Layout…", #selector(customizeLayout(_:)), ""))
        view.delegate = self   // your saved layouts go under the built-in ones (menuNeedsUpdate)
        view.addItem(.separator())
        let prev = item("Previous Tab", #selector(prevTab(_:)), "{")
        view.addItem(prev)
        view.addItem(item("Next Tab", #selector(nextTab(_:)), "}"))
        // The engine window's own: ⌘[ / ⌘] step through the rail (hidden and off in the classic window, so the keys
        // reach the terminal and the browser there as before).
        view.addItem(item("Previous Agent", #selector(prevAgent(_:)), "["))
        view.addItem(item("Next Agent", #selector(nextAgent(_:)), "]"))
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
    @objc func showMain(_ s: Any?) {
        openMainWindow()
        if model.shellListNav { model.shellGoHome() }   // ⌘0 in the engine window: Home (the assistant in Tasks)
    }
    @objc func chooseLayout(_ s: Any?) {
        guard let n = (s as? NSMenuItem)?.tag, LayoutPreset.allCases.indices.contains(n - 1) else { return }
        model.chooseLayout(LayoutPreset.allCases[n - 1])
    }
    @objc func customizeLayout(_ s: Any?) { SettingsWindow.show(section: .layout) }
    @objc func chooseSavedLayout(_ s: NSMenuItem) { if let id = s.representedObject as? String { model.chooseSavedLayout(id) } }

    /// Saved layouts in the View menu, under the built-in ones (⌃⌘8 and ⌃⌘9 for the first two), the one in use ticked.
    func refreshLayoutMenu() {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        // The View menu asks before every key equivalent: rebuild only when the saved layouts or the one in use changed.
        let sorted = SavedLayouts.sorted(model.savedLayouts)
        let signature = sorted.map { $0.id + "\u{1}" + $0.file.name }.joined(separator: "\u{2}") + "\u{3}" + (model.layout.userId ?? "")
        if signature == layoutMenuSignature, view.items.contains(where: { $0.tag >= Self.savedLayoutTag }) == !sorted.isEmpty { return }
        layoutMenuSignature = signature
        for it in view.items where it.tag >= Self.savedLayoutTag { view.removeItem(it) }
        guard let at = view.items.firstIndex(where: { $0.action == #selector(customizeLayout(_:)) }) else { return }
        for (i, e) in sorted.enumerated() {
            let it = NSMenuItem(title: e.file.name, action: #selector(chooseSavedLayout(_:)), keyEquivalent: i < 2 ? "\(8 + i)" : "")
            if i < 2 { it.keyEquivalentModifierMask = [.control, .command] }
            it.target = self
            it.tag = Self.savedLayoutTag + i
            it.representedObject = e.id
            it.state = model.layout.userId == e.id ? .on : .off
            view.insertItem(it, at: at + i)
        }
    }
    static let savedLayoutTag = 9000
    nonisolated(unsafe) private static var lastLayoutMenu = ""
    private var layoutMenuSignature: String { get { Self.lastLayoutMenu } set { Self.lastLayoutMenu = newValue } }
    @objc func openAgentsHome(_ s: Any?) { openMainWindow(); model.openAgentsHome() }
    @objc func openWorkday(_ s: Any?) { openMainWindow(); model.openWorkday() }
    @objc func showTasks(_ s: Any?) { openMainWindow(); model.showTasks() }
    @objc func openAquarium(_ s: Any?) { openMainWindow(); model.openAquarium() }
    @objc func openAssistant(_ s: Any?) { openMainWindow(); model.openAssistant() }
    @objc func newTerminal(_ s: Any?) {
        if model.shellListNav { openMainWindow(); model.shellNew(); return }   // the engine window: Home's composer, a new task
        model.newSession(profileId: nil)
    }
    @objc func newAgent(_ s: Any?) { model.newSession(profileId: (model.profile(model.lastNewSessionProfile) ?? model.pinnedProfiles.first ?? model.enabledProfiles.first)?.id) }
    @objc func splitRight(_ s: Any?) { model.newSession(profileId: nil, split: .right) }
    @objc func splitDown(_ s: Any?) { model.newSession(profileId: nil, split: .down) }
    @objc func zoomPane(_ s: Any?) { model.toggleZoom() }
    @objc func newChat(_ s: Any?) { model.openNewChat() }
    @objc func quickComposer(_ s: Any?) { QuickComposer.shared.show() }
    @objc func changeScene(_ s: Any?) { ScenePickerPanel.shared.toggle() }

    @objc func toggleAgentsView(_ s: Any?) {
        if model.shellListNav { RailKeys.shared.active = true; return }   // the engine window: the rail takes the keys
        withAnimation(.easeOut(duration: 0.15)) { model.sidebarAgents.toggle() }
        if !model.sidebarVisible { model.toggleSidebar() }
    }
    @objc func addProject(_ s: Any?) { model.addProject() }
    @objc func openInDefault(_ s: Any?) { if let p = model.currentProject { OpenIn.open(p.path, appId: OpenIn.defaultAppId) } }
    @objc func closePane(_ s: Any?) {
        if NSApp.keyWindow === mainWindow {
            // On the engine window's Home no pane shows: nothing to close.
            if model.shellNav == .agents && model.shellHomeShown { return }
            model.closeFocusedPane()
        } else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func nextWaiting(_ s: Any?) { model.nextNeedingInput() }
    @objc func stopSession(_ s: Any?) { if let id = model.focusedSessionId { model.stop(id) } }
    @objc func renameSession(_ s: Any?) { model.renamingSessionId = model.focusedSessionId }
    @objc func toggleChat(_ s: Any?) { model.toggleChat() }
    @objc func toggleSidebar(_ s: Any?) { model.toggleSidebar() }
    @objc func toggleDock(_ s: Any?) { model.toggleDock() }
    @objc func toggleRightPanel(_ s: Any?) { model.toggleRightPanel() }
    @objc func prevTab(_ s: Any?) { if !shellStep(-1) { model.cycleTab(-1) } }
    @objc func prevAgent(_ s: Any?) { _ = shellStep(-1) }
    @objc func nextAgent(_ s: Any?) { _ = shellStep(1) }
    @objc func nextTab(_ s: Any?) { if !shellStep(1) { model.cycleTab(1) } }
    @objc func goToTab(_ s: NSMenuItem) {
        if model.shellListNav {   // the engine window: the rail's agents (tasks) instead of tabs
            if let id = ShellKeys.goTo(s.tag, rail: model.shellList) { model.shellOpen(id) }
            return
        }
        model.selectTab(index: s.tag == 9 ? -1 : s.tag - 1)
    }
    /// The engine window: previous / next on the rail. False when the classic window should cycle tabs.
    private func shellStep(_ d: Int) -> Bool {
        guard model.shellListNav else { return false }
        if let id = ShellKeys.step(d, current: model.shellListCurrent, rail: model.shellList) { model.shellOpen(id) }
        return true
    }
    @objc func prevWorkspace(_ s: Any?) { stepWorkspace(-1) }
    @objc func nextWorkspace(_ s: Any?) { stepWorkspace(1) }
    private func stepWorkspace(_ d: Int) {
        WorkspacePager.shared.slide(d)
    }
    @objc func goToWorkspace(_ s: NSMenuItem) {
        let ws = model.orderedWorkspaces
        if s.tag - 1 < ws.count { WorkspacePager.shared.go(to: ws[s.tag - 1].id) }
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
        win.title = "Octomux prototype A"
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for id in sessions {
            let v = TerminalSurfaceView(sessionId: id, command: "\(Paths.cliBinary) attach \(id)",
                                        env: [Paths.homeVar: Paths.home.path])
            TerminalRegistry.shared.add(v)
            split.addArrangedSubview(v)
        }
        win.contentView = split
        win.makeKeyAndOrderFront(nil)
        if let first = split.arrangedSubviews.first { win.makeFirstResponder(first) }
        windows.append(win)
    }
}

/// Root hosting view: clicks never move the window by themselves (the top bar's empty space does that
/// through `WindowDragArea`), so tabs and rows can be dragged and title-bar buttons get every click.
final class ContentHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { if menu.title == "View" { refreshLayoutMenu() } }
}

/// The menu speaks the engine window's language: agents and Home instead of tabs (the classic window keeps its names).
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let nav = model.shellNav ?? .tabs
        if let name = ShellKeys.menuName(item.action, tag: item.tag, nav: nav) { item.title = name }
        if ShellKeys.shellOnly(item.action) { return model.shellListNav }   // off with tabs: the keys go on to the terminal
        return true
    }
}
