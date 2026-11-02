import AppKit
import SwiftUI
import UserNotifications

/// UI-level debug methods (dev only): drive the app like a user and read back what it shows.
enum DebugActions {
    static func register() {
        let d = DebugServer.shared
        let m = AppModel.shared
        d.register("ui_state") { _ in
            [
                "connected": m.connected,
                "workspace": m.workspace?.name ?? NSNull(),
                "workspaces": m.state.workspaces.map { $0.name },
                "sidebar_visible": m.sidebarVisible,
                "projects": m.projects.map { p in
                    ["id": p.id, "name": p.name, "color": p.color, "icon": p.icon.kind,
                     "sessions": m.sessions(ofProject: p.id).map { s in
                        ["id": s.id, "title": s.displayTitle, "kind": s.kind.rawValue, "state": s.state.rawValue,
                         "activity": s.activity.rawValue, "unread": s.unread, "dimmed": s.isDormant] as [String: Any]
                     }] as [String: Any]
                },
                "current_project": m.currentProject?.name ?? NSNull(),
                "tabs": m.currentTabs.map { t in ["id": t.id, "sessions": t.layout.sessions, "active": t.id == m.activeTabId] as [String: Any] },
                "focused_session": m.focusedSessionId ?? NSNull(),
                "dock_open": m.isDockOpen(m.currentProject?.id),
                "dock_sessions": m.dockSessions(m.currentProject?.id).map { ["id": $0.id, "title": $0.displayTitle, "kind": $0.kind.rawValue, "state": $0.state.rawValue] },
                "dock_selected": m.dockSelection(m.currentProject?.id) ?? NSNull(),
                "actions": m.actions(m.currentProject?.id).map { $0.name },
                "first_responder_session": (NSApp.mainWindow?.firstResponder as? TerminalSurfaceView)?.sessionId ?? NSNull(),
                "pinned_profiles": m.pinnedProfiles.map { $0.name },
                "profiles": m.enabledProfiles.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] },
                "dock_badge": NSApp.dockTile.badgeLabel ?? NSNull(),
                "last_error": m.lastError ?? NSNull(),
                "settings_open": SettingsWindow.window?.isVisible ?? false,
                "recent_notifications": Notifier.shared.recent.prefix(10).map { ["kind": $0.0.kind, "title": $0.0.title, "body": $0.0.body] },
            ] as [String: Any]
        }
        d.register("ui_action") { p in
            let name = p["name"] as? String ?? ""
            let id = p["id"] as? String
            switch name {
            case "new_terminal": m.newSession(profileId: nil, projectId: id)
            case "new_agent": m.newSession(profileId: p["profile_id"] as? String, projectId: id)
            case "split_right": m.newSession(profileId: p["profile_id"] as? String, split: .right)
            case "split_down": m.newSession(profileId: p["profile_id"] as? String, split: .down)
            case "select_session": if let id { m.selectSession(id) }
            case "select_workspace": if let id { m.selectWorkspace(id) }
            case "cycle_workspace": m.cycleWorkspace((p["delta"] as? Int) ?? 1)
            case "select_tab": if let id { m.selectTab(id) }
            case "select_project": if let id { m.selectProject(id) }
            case "stop": if let id { m.stop(id) }
            case "restart": if let id { m.restart(id) }
            case "remove": if let id { m.remove(id, confirm: false) }
            case "close_pane": if let id = m.focusedSessionId { m.remove(id, confirm: false) }
            case "toggle_sidebar": m.toggleSidebar()
            case "toggle_dock": m.toggleDock()
            case "toggle_right_panel": m.rightPanelVisible.toggle()
            case "add_action":
                guard let pid = m.currentProject?.id else { throw DebugServer.DebugError.bad("no project") }
                m.saveActions(pid, m.actions(pid) + [ProjectAction(name: p["value"] as? String ?? "Test", icon: "flask", command: p["command"] as? String ?? "echo hi")])
            case "run_action":
                guard let a = m.actions(m.currentProject?.id).first(where: { $0.name == (p["value"] as? String) }) ?? m.lastAction(m.currentProject?.id)
                else { throw DebugServer.DebugError.bad("no action") }
                m.runAction(a)
            case "add_project":
                guard let path = p["path"] as? String, let ws = m.selectedWorkspaceId else { throw DebugServer.DebugError.bad("path") }
                m.addProject(path: path, workspaceId: ws)
            case "create_workspace": m.createWorkspace(name: p["value"] as? String ?? "Work")
            case "palette":
                m.paletteVisible = true
                m.paletteQuery = p["value"] as? String ?? ""
            case "close_palette": m.paletteVisible = false
            case "new_worktree":
                if let id, let proj = m.project(id) {
                    m.newWorktree(project: proj, branch: p["value"] as? String ?? "feat/x", open: p["profile_id"] as? String)
                }
            case "remove_worktree_noconfirm":
                if let id, let proj = m.project(id), let path = p["value"] as? String {
                    for s in m.state.sessions where s.worktree == path { m.remove(s.id, confirm: false) }
                    _ = Worktrees.remove(project: proj.path, path: path, force: true)
                }
            case "right_tab":
                UserDefaults.standard.set(p["value"] as? String ?? "Changes", forKey: "ade.rightTab")
                m.rightPanelVisible = true
            case "panel_select":
                NotificationCenter.default.post(name: .adeDebugPanel, object: nil, userInfo: p["info"] as? [String: Any] ?? [:])
            case "add_host":
                // {"value": {"id","name","kind","target","ade","prefix"}}
                if let d = p["value"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d),
                   let h = try? JSONDecoder().decode(Host.self, from: data) {
                    var all = HostStore.all
                    all.removeAll { $0.id == h.id }
                    all.append(h)
                    HostStore.all = all
                }
            case "switch_host": m.switchHost(p["value"] as? String ?? "local")
            case "attach_host": m.setAttached(p["value"] as? String ?? "", (p["on"] as? Bool) ?? true)
            case "add_project_path":
                if let ws = m.selectedWorkspaceId, let path = p["value"] as? String { m.addProject(path: path, workspaceId: ws) }
            case "add_project_on_host":
                if let ws = m.selectedWorkspaceId, let h = p["host"] as? String, let path = p["value"] as? String {
                    m.addProject(path: path, onExtraHost: h, workspaceId: ws)
                }
            case "move_project": if let id, let ws = p["value"] as? String { m.moveProject(id, toWorkspace: ws) }
            case "toggle_chat": m.toggleChat(id)
            case "chat_send": if let id { m.sendToSession(id, text: p["value"] as? String ?? "") }
            case "usage_popover": m.usagePopoverOpen = (p["value"] as? Bool) ?? true
            case "palette_run":
                // Runs the top result for `value`, like typing it and pressing Return.
                let r = PaletteSource.search(p["value"] as? String ?? "", model: m)
                m.paletteVisible = false
                r.first?.run()
            case "open_settings":
                SettingsWindow.show(section: SettingsSection(rawValue: p["value"] as? String ?? "Workspaces"))
            case "close_settings": SettingsWindow.window?.orderOut(nil)
            case "settings_scope": SettingsWindow.selection.scope = p["value"] as? String ?? "global"
            case "next_waiting": m.nextNeedingInput()
            case "focus": if let dir = p["value"] as? String {
                TerminalHost.shared.focusNeighbor(["left": .minX, "right": .maxX, "up": .maxY, "down": .minY][dir] ?? .maxX)
            }
            case "menu":
                // Invoke a main-menu item by title (exercises the real shortcut targets).
                guard let title = p["value"] as? String, let item = findMenuItem(title, in: NSApp.mainMenu) else { throw DebugServer.DebugError.bad("no menu item") }
                if let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }
            default: throw DebugServer.DebugError.bad("unknown action \(name)")
            }
            return ["ok": true]
        }
        d.register("notif_status") { _ in
            var status = "unknown"
            let sem = DispatchSemaphore(value: 0)
            if Notifier.shared.available {
                UNUserNotificationCenter.current().getNotificationSettings { st in
                    status = "\(st.authorizationStatus.rawValue)"
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 2)
            }
            var out: [String: Any] = [:]
            out["available"] = Notifier.shared.available
            out["authorized"] = Notifier.shared.authorized
            out["status"] = status + " (0=notDetermined 1=denied 2=authorized 3=provisional)"
            out["error"] = Notifier.shared.lastAuthError ?? "none"
            out["bundle_id"] = Bundle.main.bundleIdentifier ?? "none"
            out["bundle_url"] = Bundle.main.bundleURL.path
            return out
        }
        d.register("delivered_notifications") { _ in
            var list: [[String: Any]] = []
            let sem = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getDeliveredNotifications { ns in
                list = ns.map { ["title": $0.request.content.title, "body": $0.request.content.body] }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2)
            return list
        }
        d.register("open_in_info") { _ in
            ["installed": OpenIn.installed.map { $0.name }, "default": OpenIn.defaultAppId]
        }
        d.register("open_in_run") { p in
            guard let path = p["path"] as? String else { throw DebugServer.DebugError.bad("path") }
            OpenIn.open(path, appId: p["app"] as? String ?? OpenIn.defaultAppId)
            return ["ok": true]
        }
        d.register("render_view") { p in
            // Renders a popover-type view offscreen (popovers are separate windows).
            guard let path = p["path"] as? String else { throw DebugServer.DebugError.bad("path") }
            let name = p["view"] as? String ?? "usage"
            let dark = (p["dark"] as? Bool) ?? false
            let view: AnyView
            switch name {
            case "usage": view = AnyView(UsagePopover().environmentObject(AppModel.shared))
            case "action_editor":
                view = AnyView(ActionEditor(action: ProjectAction(name: "Test", icon: "flask", command: "cargo test"), done: {}).environmentObject(AppModel.shared).background(T.surface))
            case "new_worktree":
                guard let proj = AppModel.shared.currentProject else { throw DebugServer.DebugError.bad("no project") }
                view = AnyView(NewWorktreeSheet(project: proj, done: {}).environmentObject(AppModel.shared))
            case "profile_editor":
                guard let prof = AppModel.shared.state.profiles.first(where: { $0.kind == .claude }) else { throw DebugServer.DebugError.bad("no claude profile") }
                view = AnyView(ProfileEditor(profile: prof, done: {}).environmentObject(AppModel.shared).background(T.surface))
            case "host_editor":
                view = AnyView(HostEditor(host: Host(id: "x", name: "devbox", kind: "ssh", target: "me@devbox", sshOptions: "-p 2222"), done: { _ in }))
            default: throw DebugServer.DebugError.bad("unknown view")
            }
            var out: [String: Any] = ["path": path]
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    out["ok"] = true
                }
            }
            return out
        }
        // Real confirmation alerts: each modal window is captured, then confirmed with its first button.
        d.register("remove_worktree_ui") { p in
            guard let id = p["id"] as? String, let proj = AppModel.shared.project(id), let path = p["value"] as? String else { throw DebugServer.DebugError.bad("id/value") }
            var shots = p["shots"] as? [String] ?? []
            var seen = Set<Int>()
            let start = Date()
            let t = Timer(timeInterval: 0.5, repeats: true) { t in
                if Date().timeIntervalSince(start) > 20 { t.invalidate(); return }
                guard let w = NSApp.modalWindow, !seen.contains(w.windowNumber) else { return }
                seen.insert(w.windowNumber)
                if let out = shots.first {
                    shots.removeFirst()
                    if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                       let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                    }
                }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
            RunLoop.main.add(t, forMode: .common)
            AppModel.shared.removeWorktree(project: proj, path: path)
            return ["ok": true]
        }
        // Opens a main-menu submenu, captures its window while it is open, then closes it.
        d.register("menu_shot") { p in
            guard let title = p["menu"] as? String, let out = p["path"] as? String,
                  let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu, let view = (NSApp.delegate as? AppDelegate)?.mainWindow?.contentView
            else { throw DebugServer.DebugError.bad("menu/path") }
            var done = false
            var layers: [Int] = []
            let t = Timer(timeInterval: 0.4, repeats: true) { t in
                let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
                layers = mine.compactMap { $0[kCGWindowLayer as String] as? Int }
                if let win = mine.first(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) >= 20 && ($0[kCGWindowLayer as String] as? Int ?? 0) != 25 }),
                   let num = win[kCGWindowNumber as String] as? UInt32,
                   let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, num, [.boundsIgnoreFraming, .bestResolution]),
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    done = true
                }
                menu.cancelTracking()
                t.invalidate()
            }
            RunLoop.main.add(t, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 300, y: view.bounds.height - 60), in: view)
            return ["captured": done, "layers": layers]
        }
        // Drives the real New Worktree sheet: types the branch into its field and presses Return
        // (the sheet's default action = Create). Captures the sheet before submitting.
        d.register("worktree_sheet_ui") { p in
            guard let id = p["id"] as? String, let proj = AppModel.shared.project(id), let branch = p["value"] as? String,
                  let main = (NSApp.delegate as? AppDelegate)?.mainWindow else { throw DebugServer.DebugError.bad("id/value") }
            AppModel.shared.newWorktreeFor = proj
            let shot = p["path"] as? String
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let sheet = main.attachedSheet ?? main.sheets.first else { NSLog("no sheet"); return }
                func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(fields) }
                if let f = fields(sheet.contentView!).first(where: { $0.isEditable }) {
                    sheet.makeFirstResponder(f)
                    (sheet.fieldEditor(true, for: f) as? NSTextView)?.insertText(branch, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let shot, let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                       let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: shot))
                    }
                    let ev = { (type: NSEvent.EventType) in
                        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                    }
                    sheet.sendEvent(ev(.keyDown))
                    sheet.sendEvent(ev(.keyUp))
                }
            }
            return ["ok": true]
        }
        // Opens a SwiftUI pop-up menu (found as an NSPopUpButton by its tooltip) and captures it.
        d.register("popup_shot") { p in
            guard let out = p["path"] as? String, let main = (NSApp.delegate as? AppDelegate)?.mainWindow else { throw DebugServer.DebugError.bad("path") }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            // Pop-up buttons ordered left→right, top→bottom on screen.
            let pops = all(main.contentView!).compactMap { $0 as? NSPopUpButton }.sorted { a, b in
                let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
                return abs(fa.minY - fb.minY) > 8 ? fa.minY > fb.minY : fa.minX < fb.minX
            }
            let i = p["index"] as? Int ?? 0
            guard i < pops.count else { return ["captured": false, "count": pops.count] }
            let b = pops[i]
            var done = false
            let t = Timer(timeInterval: 0.4, repeats: false) { _ in
                let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                if let win = info.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }),
                   let num = win[kCGWindowNumber as String] as? UInt32,
                   let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, num, [.boundsIgnoreFraming, .bestResolution]),
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    done = true
                }
                b.menu?.cancelTracking()
            }
            RunLoop.main.add(t, forMode: .common)
            b.performClick(nil)
            let f = b.convert(b.bounds, to: nil)
            return ["captured": done, "count": pops.count, "x": Int(f.minX), "y": Int(f.minY), "title": b.menu?.items.first?.title ?? ""]
        }
        // Right-clicks at a window point (top-left based) to open a SwiftUI context menu, captures it, closes it.
        d.register("context_shot") { p in
            guard let out = p["path"] as? String, let x = p["x"] as? Double, let yTop = p["y"] as? Double,
                  let main = (NSApp.delegate as? AppDelegate)?.mainWindow else { throw DebugServer.DebugError.bad("x/y/path") }
            let pt = NSPoint(x: x, y: main.contentView!.bounds.height - yTop)
            var done = false
            let t = Timer(timeInterval: 0.5, repeats: false) { _ in
                let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                if let win = info.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }),
                   let num = win[kCGWindowNumber as String] as? UInt32,
                   let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, num, [.boundsIgnoreFraming, .bestResolution]),
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    done = true
                }
                // Close the menu: an Escape key event into the tracking loop.
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(esc, atStart: true)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            let down = NSEvent.mouseEvent(with: .rightMouseDown, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: main.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            main.sendEvent(down)
            return ["captured": done]
        }
        d.register("keybindings") { _ in
            KeyBindings.shared.commands.map { c in
                ["id": c.id, "title": c.title, "shortcut": KeyBindings.shared.current(c.id)?.display ?? "",
                 "menu_key": c.item?.keyEquivalent ?? "", "menu_mods": Int(c.item?.keyEquivalentModifierMask.rawValue ?? 0)] as [String: Any]
            }
        }
        d.register("screenshot_settings") { p in
            guard let path = p["path"] as? String, let w = SettingsWindow.window, w.isVisible,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
            else { throw DebugServer.DebugError.bad("settings not visible") }
            let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: path))
            return ["path": path]
        }
    }

    static func findMenuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for i in menu.items {
            if i.title == title { return i }
            if let f = findMenuItem(title, in: i.submenu) { return f }
        }
        return nil
    }
}
