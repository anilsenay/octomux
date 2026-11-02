import AppKit

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
            case "add_project":
                guard let path = p["path"] as? String, let ws = m.selectedWorkspaceId else { throw DebugServer.DebugError.bad("path") }
                m.addProject(path: path, workspaceId: ws)
            case "create_workspace": m.createWorkspace(name: p["value"] as? String ?? "Work")
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
