import AppKit
import SwiftUI
import UserNotifications

/// UI-level debug methods (dev only): drive the app like a user and read back what it shows.
enum DebugActions {
    static func register() {
        registerMenuBar()
        let d = DebugServer.shared
        let m = AppModel.shared
        d.register("ui_state") { _ in
            [
                "connected": m.connected,
                "power": "\(m.power)",
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
            case "zoom_pane": m.toggleZoom()
            case "split_down": m.newSession(profileId: p["profile_id"] as? String, split: .down)
            case "select_session": if let id { m.selectSession(id) }
            case "select_workspace": if let id { m.selectWorkspace(id) }
            case "cycle_workspace": m.cycleWorkspace((p["delta"] as? Int) ?? 1)
            case "select_tab": if let id { m.selectTab(id) }
            case "select_project": if let id { m.selectProject(id) }
            case "stop": if let id { m.stop(id, confirm: false) }
            case "restart": if let id { m.restart(id) }
            case "remove": if let id { m.remove(id, confirm: false) }
            case "close_pane":
                if let id = m.focusedSessionId { m.closePane(id) }
            case "discard":   // ChangesModel.discardFiles without the question; value: work path, files: [rel]
                if let wp = p["value"] as? String, let files = p["files"] as? [String] {
                    let staged = p["staged"] as? Bool ?? false
                    DispatchQueue.global().async { NSLog("discard: %@", ChangesModel.discardFiles(files, staged: staged, in: wp, remote: false) ? "ok" : "failed") }
                }
            case "close_tab": if let t = id ?? m.activeTabId { m.closeTab(t, confirm: false) }
            case "reset_hints": UserDefaults.standard.removeObject(forKey: "octomux.hint.closedTabKeepsSessions"); m.hint = nil
            case "running_work":   // what "Ask before stopping a running program" would list for a tab (to the app log)
                let ids = id.flatMap { t in m.state.tabs.first { $0.id == t }?.layout.sessions } ?? [id].compactMap { $0 }
                m.runningWork(ids) { w in
                    NSLog("running_work: %@", w.map { "\($0.session.id) \($0.short)" }.joined(separator: "; "))
                    // The question it would ask, as text (showing it would block this server).
                    if !w.isEmpty {
                        let a = AppModel.closeAlert(w, noun: "session", many: (p["many"] as? Int) ?? 1, button: "Stop", verb: "Stopping")
                        NSLog("running_work alert: %@ | %@", a.messageText, a.informativeText.replacingOccurrences(of: "\n", with: " / "))
                    }
                }
            case "toggle_sidebar": m.toggleSidebar()
            case "toggle_dock": m.toggleDock()
            case "toggle_right_panel": m.toggleRightPanel()
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
            case "remove_worktree":   // the real removal without its question: teardown, then {"drop_branch": "<b>"}
                if let id, let proj = m.project(id), let path = p["value"] as? String {
                    m.performWorktreeRemoval(project: proj, path: path, locked: false, dropBranch: p["drop_branch"] as? String)
                }
            case "remove_worktree_noconfirm":
                if let id, let proj = m.project(id), let path = p["value"] as? String {
                    for s in m.state.sessions where s.worktree == path { m.remove(s.id, confirm: false) }
                    _ = Worktrees.remove(project: proj.path, path: path, force: true)
                }
            case "right_tab":
                UserDefaults.standard.set(p["value"] as? String ?? "Changes", forKey: "octomux.rightTab")
                m.rightPanelVisible = true
            case "panel_select":
                NotificationCenter.default.post(name: .adeDebugPanel, object: nil, userInfo: p["info"] as? [String: Any] ?? [:])
            case "add_host":
                // {"value": {"id","name","kind","target","cli","prefix"}}
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
            case "move_tab": if let id, let to = p["value"] as? String { m.moveTab(id, to: to) }
            case "move_project_before": if let id, let to = p["value"] as? String { m.moveProject(id, before: to) }
            case "toggle_changes": m.toggleChangesPanel()
            case "open_file":
                if let v = p["value"] as? String {
                    if p["preview"] as? Bool == true { m.openDoc(.file(v), preview: true) } else { m.openFile(v, line: p["line"] as? Int) }
                }
            case "open_changes": m.openChanges(scrollTo: p["value"] as? String)
            case "open_commit": if let v = p["value"] as? String { m.openCommit(v, subject: p["subject"] as? String ?? "") }
            case "doc_js": if let d = m.activeDoc, let v = p["value"] as? String { DocHost.shared.controller(for: d).web.evaluateJavaScript(v) }
            case "drop_preview", "drop":
                // value: edge; id: target session; for "drop", kind + source in p["kind"], p["source"].
                let edge = AppModel.PaneEdge(rawValue: p["value"] as? String ?? "") ?? .right
                if name == "drop", let k = p["kind"] as? String, let src = p["source"] as? String, let id {
                    m.drop(kind: k, id: src, onPane: id, edge: edge)
                } else {
                    func walk(_ v: NSView) { if let pv = v as? PaneView, pv.sessionId == id { pv.debugShowDrop(p["value"] == nil ? nil : edge) }; v.subviews.forEach(walk) }
                    walk(TerminalHost.shared.container)
                }
            case "pane_to_tab": if let id { m.movePaneToNewTab(id) }
            case "close_tabs": if let id { m.closeTabs(m.tabs(p["value"] as? String == "others" ? .others : p["value"] as? String == "left" ? .left : p["value"] as? String == "all" ? .all : .right, of: id)) }
            case "branch_picker": NotificationCenter.default.post(name: .adeDebugPanel, object: nil, userInfo: ["branchPicker": p["value"] as? String ?? "checkout"])
            case "pin_tab":
                let t = id.flatMap { tid in m.state.tabs.first { $0.id == tid } } ?? m.activeTab
                if let t { m.setPinned(t, (p["value"] as? Bool) ?? !m.isPinned(t)) }
            case "new_chat": m.openNewChat()
            case "scene":
                let scope = (p["scope"] as? String).map { $0 == "workspace" ? "workspace:\(m.selectedWorkspaceId ?? "")" : $0 } ?? "global"
                m.setScene(p["value"] as? String, scope: scope)
            case "scene_template": UserScenes.writeTemplate()
            case "scene_picker": if (p["value"] as? Bool) ?? true { ScenePickerPanel.shared.show() } else { ScenePickerPanel.shared.close() }
            case "scene_preview": if let v = p["value"] as? String { ThemeStore.shared.preview(Scenes.scene(v)) } else { ThemeStore.shared.endPreview() }
            case "chat_picker": NotificationCenter.default.post(name: .adeDebugPanel, object: nil, userInfo: ["chatPicker": p["value"] as? String ?? ""])
            case "new_chat_send":
                if let pid = m.currentProject?.id {
                    let prof = m.enabledProfiles(forProject: pid).first { $0.kind == .claude }
                    let doc = m.activeDocId
                    let text = p["value"] as? String ?? "hello"
                    m.newSession(profileId: prof?.id, projectId: pid, prompt: text, chat: true) { id in
                        ChatFirstMessage.set(id, text)
                        if let doc { m.closeDoc(doc) }
                    }
                }
            case "sidebar_agents": m.sidebarAgents = (p["value"] as? Bool) ?? !m.sidebarAgents
            case "notifications": NotificationCenter.default.post(name: .adeDebugPanel, object: nil, userInfo: ["notifications": (p["value"] as? Bool) ?? true])
            case "compare_base": if let wp = m.currentWorkPath { GitInfo.shared.setCompareBase(p["value"] as? String, for: wp) }
            case "close_doc": if let d = m.activeDocId { m.closeDoc(d) }
            case "right_tab": UserDefaults.standard.set(p["value"] as? String ?? "Changes", forKey: "octomux.rightTab"); m.rightPanelVisible = true
            case "sidebar_peek": m.sidebarPeek = (p["value"] as? Bool) ?? true
            case "quick_composer":   // {"value": true|false, "text": "…"}
                if (p["value"] as? Bool) ?? true { QuickComposer.shared.show(); if let t = p["text"] as? String { QuickComposer.shared.state.text = t } }
                else { QuickComposer.shared.close() }
                if let path = p["path"] as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard let w = QuickComposer.shared.debugWindow,
                              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            case "quick_composer_send":   // as Return (false) or ⌘Return (true)
                QuickComposer.shared.debugSend(show: (p["value"] as? Bool) ?? false)
            case "commit_message":   // runs ✨ for the current project; the result goes to the app log
                if let path = m.currentWorkPath {
                    CommitMessageGen.generate(path: path, projectId: m.currentProject?.id, model: m) { r in
                        switch r {
                        case .success(let t): NSLog("commit_message ok: %@", t.replacingOccurrences(of: "\n", with: " / "))
                        case .failure(let e): NSLog("commit_message failed: %@", e.localizedDescription)
                        }
                    }
                }
            case "ui_scale": ThemeStore.shared.set(scale: CGFloat((p["value"] as? Double) ?? 1))
            case "pull_request": PullRequestWindow.show(model: m)
            case "pr_text":   // ✨ for the PR of the current folder against {"value": base}; result to the app log
                if let path = m.currentWorkPath {
                    _ = PullRequest.generate(path: path, base: p["value"] as? String ?? "main", project: m.currentProject?.id, model: m) { r in
                        switch r {
                        case .success(let (t, b)): NSLog("pr_text ok: %@ || %@", t, b.replacingOccurrences(of: "\n", with: " / "))
                        case .failure(let e): NSLog("pr_text failed: %@", e.localizedDescription)
                        }
                    }
                }
            case "usage_left": UserDefaults.standard.set((p["value"] as? Bool) ?? true, forKey: UsageReading.showsLeftKey)
            case "usage_popover": m.usagePopoverOpen = (p["value"] as? Bool) ?? true
            case "dock_position": UserDefaults.standard.set(p["value"] as? String ?? "bottom", forKey: "octomux.dockPosition")
            case "hover_project": m.debugHoverProject = id
            case "fan_stack": m.debugFanStack = id
            case "drag":
                // Left drag between window points (top-left origin): x, y → x2, y2, through AppKit.
                if let w = (NSApp.delegate as? AppDelegate)?.mainWindow, let x = p["x"] as? Double, let y = p["y"] as? Double,
                   let x2 = p["x2"] as? Double, let y2 = p["y2"] as? Double {
                    let h = w.contentView!.bounds.height
                    func ev(_ t: NSEvent.EventType, _ px: Double, _ py: Double) -> NSEvent? {
                        NSEvent.mouseEvent(with: t, location: NSPoint(x: px, y: h - py), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    }
                    // NSSplitView tracks the drag in a loop pulling events from the queue: post them, then send the down.
                    for i in 1...8 { if let e = ev(.leftMouseDragged, x + (x2 - x) * Double(i) / 8, y + (y2 - y) * Double(i) / 8) { NSApp.postEvent(e, atStart: false) } }
                    if let e = ev(.leftMouseUp, x2, y2) { NSApp.postEvent(e, atStart: false) }
                    if let e = ev(.leftMouseDown, x, y) { w.sendEvent(e) }
                }
            case "click":
                // Left click at window point (top-left origin), through AppKit hit testing. "window": "settings"
                // targets the Settings window, "key" the key window (a sheet such as a confirmation dialog).
                let target: NSWindow? = switch p["window"] as? String {
                case "settings": SettingsWindow.window
                case "sheet": SettingsWindow.window?.attachedSheet
                case "key": NSApp.keyWindow
                default: (NSApp.delegate as? AppDelegate)?.mainWindow
                }
                if let w = target, let x = p["x"] as? Double, let y = p["y"] as? Double {
                    let pt = NSPoint(x: x, y: w.contentView!.bounds.height - y)
                    // "count": 2 sends a double click (a second down/up with click count 2). The up is queued
                    // before the down is sent: a view that tracks the mouse inside mouseDown (a split divider)
                    // pulls it from the queue; sent after, it would wait forever.
                    func ev(_ t: NSEvent.EventType, _ n: Int) -> NSEvent? {
                        NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)
                    }
                    for n in 1...max(1, (p["count"] as? Int) ?? 1) {
                        if let up = ev(.leftMouseUp, n) { NSApp.postEvent(up, atStart: false) }
                        if let down = ev(.leftMouseDown, n) { w.sendEvent(down) }
                    }
                }
            // What Settings → Stop Octomux (after its confirmation) and the Start buttons call.
            case "stop_octomux": m.stopOctomux()
            // Shows the unreachable-daemon banner as if the daemon had been gone for 10 s (until the next state).
            case "fake_disconnect": m.disconnectedSince = Date().addingTimeInterval(-10)
            case "start_octomux": m.startOctomux()
            case "sidebar_width": m.sidebarWidth = CGFloat((p["value"] as? Double) ?? 252)
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
            case "settings_scroll":
                func find(_ v: NSView) -> NSScrollView? {
                    if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > s.contentView.bounds.height + 50 { return s }
                    for c in v.subviews { if let s = find(c) { return s } }
                    return nil
                }
                if let root = SettingsWindow.window?.contentView, let sv = find(root) {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: CGFloat((p["value"] as? Double) ?? 0)))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            case "settings_scope": SettingsWindow.selection.scope = p["value"] as? String ?? "global"
            // Types into Settings' search field; "row" with "value" opens a page at a row, like picking a result.
            case "settings_search": SettingsWindow.selection.query = p["value"] as? String ?? ""
            case "settings_jump":
                if let s = SettingsSection(rawValue: p["value"] as? String ?? "") { SettingsWindow.show(section: s); SettingsWindow.selection.open(s, row: p["row"] as? String) }
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
            case "icons":
                view = AnyView(HStack(spacing: 24) {
                    ForEach(["claude", "codex", "gemini", "terminal"], id: \.self) { i in
                        VStack(spacing: 10) { AgentIcon(icon: i, size: 64); AgentIcon(icon: i, size: 13); Text(i).font(.caption) }
                    }
                }.padding(24).background(T.surface))
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
        d.register("split_frames") { _ in
            var out: [[String: Any]] = []
            func walk(_ v: NSView, _ depth: Int) {
                if let sv = v as? RatioSplitView {
                    out.append(["depth": depth, "vertical": sv.isVertical, "ratio": sv.ratio, "bounds": NSStringFromRect(sv.bounds),
                                "children": sv.arrangedSubviews.map { NSStringFromRect($0.frame) },
                                "constraints": sv.arrangedSubviews.map { $0.constraints.count }])
                }
                for c in v.subviews where !(c is TerminalSurfaceView) { walk(c, depth + 1) }
            }
            walk(TerminalHost.shared.container, 0)
            return ["splits": out]
        }
        d.register("keybindings") { _ in
            KeyBindings.shared.commands.map { c in
                ["id": c.id, "title": c.title, "shortcut": KeyBindings.shared.current(c.id)?.display ?? "",
                 "menu_key": c.item?.keyEquivalent ?? "", "menu_mods": Int(c.item?.keyEquivalentModifierMask.rawValue ?? 0)] as [String: Any]
            }
        }
        // Buttons of the dialog attached to Settings (title, frame in sheet points, top-left origin), and
        // pressing one by title (performClick: no hit testing).
        d.register("sheet_buttons") { p in
            // "window": "settings" lists the Settings window's own buttons instead of its sheet's.
            let win = (p["window"] as? String) == "settings" ? SettingsWindow.window : SettingsWindow.window?.attachedSheet
            guard let sheet = win, let root = sheet.contentView else { return ["buttons": []] }
            var out: [[String: Any]] = []
            func walk(_ v: NSView) {
                if let b = v as? NSButton {
                    let r = b.convert(b.bounds, to: nil)
                    out.append(["title": b.title, "x": r.midX, "y": root.bounds.height - r.midY, "w": r.width, "h": r.height, "enabled": b.isEnabled])
                    if let t = p["press"] as? String, b.title == t { b.performClick(nil) }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            return ["buttons": out, "sheet_class": String(describing: type(of: sheet))]
        }
        d.register("key_window") { _ in
            guard let w = NSApp.keyWindow else { return ["key": NSNull()] }
            return ["title": w.title, "is_sheet": w.isSheet, "width": w.frame.width, "height": w.frame.height,
                    "settings_sheet": SettingsWindow.window?.attachedSheet != nil]
        }
        d.register("screenshot_settings") { p in
            // "sheet": true captures the dialog attached to Settings (a confirmation) instead of the window.
            let win = (p["sheet"] as? Bool) == true ? SettingsWindow.window?.attachedSheet : SettingsWindow.window
            guard let path = p["path"] as? String, let w = win, w.isVisible,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
            else { throw DebugServer.DebugError.bad("settings not visible") }
            let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: path))
            return ["path": path]
        }
    }

    static func registerMenuBar() {
        let d = DebugServer.shared
        // Reads the System Settings notification status; "show" forces one for screenshots (nothing is changed in macOS).
        d.register("notification_permission") { p in
            let np = NotificationPermission.shared
            if let v = p["show"] as? String { np.debugShow(v, soundOff: (p["sound_off"] as? Bool) ?? false) }
            else { np.refresh() }
            return ["status": np.debugName, "sound_off": np.soundOff]
        }
        // Quits the app normally (applicationWillTerminate runs: an update set to install on quit installs).
        d.register("quit") { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return ["ok": true]
        }
        // Update toast in a given state: {"show": "available|downloading|ready|failed|uptodate|checking|hide"}.
        d.register("update_toast") { p in
            let u = Updater.shared
            switch p["show"] as? String ?? "" {
            case "available": u.debugShow(.available(version: "0.2.0"))
            case "downloading": u.debugShow(.downloading((p["progress"] as? Double) ?? 0.42))
            case "ready": u.debugShow(.ready(version: "0.2.0"))
            case "failed": u.debugShow(.failed("The update could not be verified."))
            case "uptodate": u.debugShow(.upToDate)
            case "checking": u.debugShow(.checking)
            case "check": u.checkNow()
            case "install": u.install()
            default: u.toastVisible = false
            }
            return ["phase": String(describing: u.phase), "enabled": u.isEnabled, "feed": u.feedURL ?? ""]
        }
        // Clicks the menu bar icon (opens or closes its panel); "screenshot" with "path" captures the icon or the panel.
        d.register("menubar") { p in
            let c = StatusItemController.shared
            if (p["click"] as? Bool) == true { c.debugClick() }
            guard let path = p["path"] as? String else { return c.debugState() }
            if (p["what"] as? String) == "icon" {
                // The status bar's window can't be captured by number; draw the button's image at 8× instead.
                guard let img = c.debugImage else { throw DebugServer.DebugError.bad("no icon") }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width * 8), pixelsHigh: Int(img.size.height * 8), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return ["path": path]
            }
            guard let w = c.debugPanelWindow, w.isVisible, w.windowNumber > 0,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
            else { throw DebugServer.DebugError.bad("not visible") }
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
