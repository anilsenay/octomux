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
