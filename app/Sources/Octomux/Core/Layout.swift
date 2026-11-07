import AppKit
import SwiftUI

/// Layouts: which parts of the window show, in what order, and what a few defaults are — one choice for the whole
/// app (global setting `ui.layout`), never per workspace. Terminal is today's window and the default; every other
/// layout and every change is opt-in, so the default look never moves.
///
/// Stored as `{"layout": "agents", "custom": {"agents": {"regions": {"statusRight": [{"id": "usage", "on": false}, …]},
/// "statusBar": true, "chat": true}}}`: each layout keeps only what was changed in it, so a later version's
/// change to a built-in layout still reaches everyone who didn't touch that part. Anything unreadable falls back
/// to the built-in values (a wrong type, an unknown layout or item), never to a broken window.
enum LayoutPreset: String, CaseIterable, Identifiable, Codable {
    case terminal, agents, workday, minimal, editor, tasks, aquarium
    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .workday: return "Workday"
        case .minimal: return "Minimal"
        case .editor: return "Editor"
        case .tasks: return "Tasks"
        case .aquarium: return "Aquarium"
        }
    }
    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .agents: return "sparkles"
        case .workday: return "sun.max"
        case .minimal: return "rectangle"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .tasks: return "checklist"
        case .aquarium: return "fish"
        }
    }
    var summary: String {
        switch self {
        case .terminal: return "Octomux as it comes: projects and their sessions, terminals first."
        case .agents: return "Agents up front: a rail of every agent by what it needs from you, a Home to start one and answer the ones waiting; new agents open as chats."
        case .workday: return "The agents' window with your day as its Home: who needs you, what happened while you were away, your pull requests and issues with their next step."
        case .minimal: return "Only the panes: no sidebar, no status bar, a quiet top bar."
        case .editor: return "Code next to its agent: the agent's chat on the left, the file in the middle with its changed lines marked, the files it touched on the right. Notes on lines go to the agent."
        case .tasks: return "Work in tasks: your tasks on the left by what they need, the assistant (or the picked task's agent) in the middle, the picked task in detail on the right."
        case .aquarium: return "Every agent as an octopus above the panes: swimming while it works, \"!\" when it waits, asleep when it finished. Click one to open it below."
        }
    }
    /// ⌃⌘1…
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// The parts of the window whose items can be turned off and put in another order.
enum LayoutRegion: String, CaseIterable, Identifiable, Codable {
    case sidebar, sidebarFooter, statusLeft, statusRight, topBar, paneHeader, views
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .sidebarFooter: return "Sidebar bottom"
        case .statusLeft: return "Status bar, left"
        case .statusRight: return "Status bar, right"
        case .topBar: return "Top bar, right"
        case .paneHeader: return "Pane header"
        case .views: return "Panels and editor"
        }
    }
    var desc: String {
        switch self {
        case .sidebar: return "Rows and sections under the workspace name, top to bottom. With Agents above Projects, the agent list opens at the top."
        case .sidebarFooter: return "The buttons in the sidebar's bottom row, left to right."
        case .statusLeft: return "What the status bar starts with, left to right."
        case .statusRight: return "What the status bar ends with, left to right."
        case .topBar: return "Project-wide buttons after the tabs, left to right."
        case .paneHeader: return "What a pane's title row shows besides its name."
        case .views: return "Extra parts of the Files panel and the code editor."
        }
    }
    /// Items added after the default look was set: off in Terminal (the default look never changes), each other
    /// layout turns on what it wants.
    var optIn: Set<String> {
        switch self {
        case .sidebar: return ["tasks"]
        case .statusRight: return ["aquarium"]
        case .paneHeader: return ["work"]
        case .views: return ["touched", "marks", "notes", "tasks", "aquarium"]
        default: return []
        }
    }
    /// Every item this region knows, in Terminal's order.
    var items: [String] {
        switch self {
        case .sidebar: return ["search", "inbox", "projects", "agents", "tasks"]
        case .sidebarFooter: return ["add", "workspaces", "settings"]
        case .statusLeft: return ["agents", "git"]
        case .statusRight: return ["layout", "keepAwake", "usage", "actions", "aquarium", "dock"]
        case .topBar: return ["diff", "openIn", "git", "rightPanel"]
        case .paneHeader: return ["work"]
        case .views: return ["touched", "marks", "notes", "tasks", "aquarium"]
        }
    }
    static func itemTitle(_ id: String, in region: LayoutRegion) -> String {
        switch (region, id) {
        case (.sidebar, "search"): return "Search"
        case (.sidebar, "inbox"): return "Inbox"
        case (.sidebar, "projects"): return "Projects"
        case (.sidebar, "agents"): return "Agents"
        case (_, "add"): return "New (+)"
        case (_, "workspaces"): return "Workspace dots"
        case (_, "settings"): return "Settings"
        case (.statusLeft, "agents"): return "Agents working and waiting"
        case (.statusLeft, "git"): return "Branch and Compare with"
        case (_, "layout"): return "Layout"
        case (_, "keepAwake"): return "Keep Mac awake"
        case (_, "usage"): return "Usage limits"
        case (_, "actions"): return "Actions"
        case (_, "dock"): return "Terminal (dock)"
        case (_, "diff"): return "Changed lines (+ −)"
        case (_, "openIn"): return "Open in"
        case (.topBar, "git"): return "Commit / Push / PR"
        case (_, "rightPanel"): return "Right panel button"
        case (.paneHeader, "work"): return "Pull request and issue chips"
        case (.views, "touched"): return "Files: what the agent touched this turn"
        case (.views, "marks"): return "Editor: changed lines in the gutter"
        case (.views, "notes"): return "Editor: note on a line → agent"
        case (.views, "tasks"): return "Right panel: Tasks tab"
        case (.views, "aquarium"): return "Aquarium above the panes"
        case (_, "aquarium"): return "Aquarium"
        case (.sidebar, "tasks"): return "Tasks"
        default: return id
        }
    }
}

struct LayoutItem: Equatable, Codable {
    var id: String
    var on: Bool
}

/// What a layout resolves to: the regions' items, and the few switches.
struct LayoutConfig: Equatable {
    var preset: LayoutPreset
    var regions: [LayoutRegion: [LayoutItem]]
    /// The status bar shows.
    var statusBar: Bool
    /// New agent sessions open in the chat view (when the agent has one).
    var chat: Bool
    /// The project's agent in a column beside the work area (its chat, or its terminal's summary).
    var sideChat = false
    /// A layout you saved or imported (Settings → Layout → Your layouts): its id and name; nil = a built-in one.
    var userId: String? = nil
    var userName: String? = nil
    /// The layout's name as people see it.
    var title: String { userName ?? preset.title }

    func items(_ r: LayoutRegion) -> [LayoutItem] { regions[r] ?? LayoutConfig.builtIn(preset).regions[r] ?? [] }
    /// The ids shown in a region, in order.
    func shown(_ r: LayoutRegion) -> [String] { items(r).filter(\.on).map(\.id) }
    func has(_ id: String, in r: LayoutRegion) -> Bool { items(r).contains { $0.id == id && $0.on } }

    static let `default` = builtIn(.terminal)

    /// A layout as it ships.
    static func builtIn(_ p: LayoutPreset) -> LayoutConfig {
        /// A region's items: all on, but `off` and the opt-in items the layout doesn't turn on (`with`).
        func items(_ r: LayoutRegion, with: Set<String> = [], off: Set<String> = [], order: [String]? = nil) -> [LayoutItem] {
            let hidden = off.union(r.optIn.subtracting(with))
            let ids = order.map { o in o + r.items.filter { !o.contains($0) } } ?? r.items
            return ids.map { LayoutItem(id: $0, on: !hidden.contains($0)) }
        }
        var regions: [LayoutRegion: [LayoutItem]] = [:]
        for r in LayoutRegion.allCases { regions[r] = items(r) }
        // Terminal: today's window. The Layout button stays out of its status bar (the window looks as it always did);
        // the other layouts show it, so the way back is in sight.
        regions[.statusRight] = items(.statusRight, off: ["layout"])
        switch p {
        case .terminal:
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: false)
        case .agents:
            regions[.statusRight] = items(.statusRight)
            regions[.paneHeader] = items(.paneHeader, with: ["work"])
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: true)
        case .workday:
            regions[.sidebar] = items(.sidebar, order: ["inbox", "search", "projects", "agents"])
            regions[.statusRight] = items(.statusRight)
            regions[.paneHeader] = items(.paneHeader, with: ["work"])
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: false)
        case .minimal:
            regions[.topBar] = items(.topBar, off: ["diff", "openIn"])
            regions[.statusRight] = items(.statusRight)
            return LayoutConfig(preset: p, regions: regions, statusBar: false, chat: false)
        case .editor:
            regions[.statusRight] = items(.statusRight)
            regions[.paneHeader] = items(.paneHeader, with: ["work"])
            regions[.views] = items(.views, with: ["touched", "marks", "notes"])
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: true, sideChat: true)
        case .tasks:
            regions[.statusRight] = items(.statusRight)
            regions[.paneHeader] = items(.paneHeader, with: ["work"])
            regions[.views] = items(.views, with: ["tasks"])
            regions[.sidebar] = items(.sidebar, with: ["tasks"], order: ["search", "inbox", "tasks", "projects", "agents"])
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: true)
        case .aquarium:
            regions[.statusRight] = items(.statusRight)   // the aquarium is on screen already
            regions[.paneHeader] = items(.paneHeader, with: ["work"])
            regions[.views] = items(.views, with: ["aquarium"])
            return LayoutConfig(preset: p, regions: regions, statusBar: true, chat: true)
        }
    }

    /// Reads the stored setting; anything it can't read falls back to the built-in values. A saved layout
    /// (`"user": "<id>"`, one of `saved`) is its base with the file's settings, then what you changed in it.
    static func resolve(_ stored: JSONValue?, saved: [String: LayoutFile] = [:]) -> LayoutConfig {
        guard case .object(let o)? = stored else { return .default }
        let customs = LayoutEdit.object(o["custom"])
        if let id = o["user"]?.string, let f = saved[id] {
            var c = builtIn(f.base)
            apply(f.settings, to: &c)
            apply(LayoutEdit.object(customs[LayoutEdit.userKey(id)]), to: &c)
            c.userId = id
            c.userName = f.name
            return c
        }
        let preset = o["layout"]?.string.flatMap(LayoutPreset.init(rawValue:)) ?? .terminal
        var c = builtIn(preset)
        apply(LayoutEdit.object(customs[preset.rawValue]), to: &c)
        return c
    }

    /// A layout's changes (`regions`, the switches) over `c`.
    static func apply(_ mine: [String: JSONValue], to c: inout LayoutConfig) {
        if case .object(let regions)? = mine["regions"] {
            for r in LayoutRegion.allCases {
                if case .array(let list)? = regions[r.rawValue] { c.regions[r] = merge(list, into: c.items(r), known: r.items) }
            }
        }
        if let b = mine["statusBar"]?.bool { c.statusBar = b }
        if let b = mine["chat"]?.bool { c.chat = b }
        if let b = mine["sideChat"]?.bool { c.sideChat = b }
    }

    /// The layout's parts as a saved layout keeps them: every region whole, and the switches.
    var settings: [String: JSONValue] {
        var regions: [String: JSONValue] = [:]
        for r in LayoutRegion.allCases { regions[r.rawValue] = LayoutEdit.encode(items(r)) }
        return ["regions": .object(regions), "statusBar": .bool(statusBar), "chat": .bool(chat), "sideChat": .bool(sideChat)]
    }

    /// A stored item list over the built-in one: its known items in its order (each once), then any item it
    /// doesn't mention (one a later version added) where the built-in list has it.
    static func merge(_ list: [JSONValue], into base: [LayoutItem], known: [String]) -> [LayoutItem] {
        var out: [LayoutItem] = []
        for v in list {
            guard case .object(let o) = v, let id = o["id"]?.string, known.contains(id), !out.contains(where: { $0.id == id }) else { continue }
            out.append(LayoutItem(id: id, on: o["on"]?.bool ?? true))
        }
        for (i, b) in base.enumerated() where !out.contains(where: { $0.id == b.id }) {
            // After the item that precedes it in the built-in list, or first.
            let prev = base[..<i].last { p in out.contains { $0.id == p.id } }
            let at = prev.flatMap { p in out.firstIndex { $0.id == p.id } }.map { $0 + 1 } ?? 0
            out.insert(b, at: at)
        }
        return out
    }
}

/// Changes to the stored layout (pure: JSON in, JSON out), used by the app and by tests.
enum LayoutEdit {
    static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    /// The layout in use becomes `p`; what was changed in each layout stays.
    static func choose(_ p: LayoutPreset, in stored: JSONValue?) -> JSONValue {
        var o = object(stored)
        o["layout"] = .string(p.rawValue)
        o["user"] = nil
        return .object(o)
    }

    /// A saved layout becomes the one in use (`base` is its built-in base, kept as `layout` so an older version, or
    /// one without the saved layout, opens its base).
    static func chooseUser(_ id: String, base: LayoutPreset, in stored: JSONValue?) -> JSONValue {
        var o = object(stored)
        o["layout"] = .string(base.rawValue)
        o["user"] = .string(id)
        return .object(o)
    }

    /// Where a saved layout's changes are kept in `custom`.
    static func userKey(_ id: String) -> String { "user:" + id }

    /// The key of the layout in use in `custom`: its preset's, or a saved layout's.
    static func activeKey(_ o: [String: JSONValue]) -> String {
        if let id = o["user"]?.string { return userKey(id) }
        return (o["layout"]?.string.flatMap(LayoutPreset.init(rawValue:)) ?? .terminal).rawValue
    }

    /// The current layout's custom part, changed by `f`.
    static func custom(in stored: JSONValue?, _ f: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var o = object(stored)
        let p = o["layout"]?.string.flatMap(LayoutPreset.init(rawValue:)) ?? .terminal
        o["layout"] = .string(p.rawValue)
        let key = activeKey(o)
        var customs = object(o["custom"])
        var mine = object(customs[key])
        f(&mine)
        customs[key] = mine.isEmpty ? nil : .object(mine)
        o["custom"] = customs.isEmpty ? nil : .object(customs)
        return .object(o)
    }

    /// A saved layout's changes forgotten (it is deleted, or replaced).
    static func forget(user id: String, in stored: JSONValue?) -> JSONValue? {
        guard stored != nil else { return nil }
        var o = object(stored)
        var customs = object(o["custom"])
        customs[userKey(id)] = nil
        o["custom"] = customs.isEmpty ? nil : .object(customs)
        if o["user"]?.string == id { o["user"] = nil }
        return .object(o)
    }

    static func encode(_ items: [LayoutItem]) -> JSONValue {
        .array(items.map { .object(["id": .string($0.id), "on": .bool($0.on)]) })
    }

    /// A region's items, stored whole (order and on/off).
    static func set(_ r: LayoutRegion, _ items: [LayoutItem], in stored: JSONValue?) -> JSONValue {
        custom(in: stored) { mine in
            var regions = object(mine["regions"])
            regions[r.rawValue] = encode(items)
            mine["regions"] = .object(regions)
        }
    }

    static func toggle(_ id: String, in r: LayoutRegion, on: Bool, stored: JSONValue?, saved: [String: LayoutFile] = [:]) -> JSONValue {
        var items = LayoutConfig.resolve(stored, saved: saved).items(r)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].on = on }
        return set(r, items, in: stored)
    }

    /// Moves an item one place up (-1) or down (+1).
    static func move(_ id: String, in r: LayoutRegion, by d: Int, stored: JSONValue?, saved: [String: LayoutFile] = [:]) -> JSONValue {
        var items = LayoutConfig.resolve(stored, saved: saved).items(r)
        guard let i = items.firstIndex(where: { $0.id == id }), items.indices.contains(i + d) else { return stored ?? .object([:]) }
        items.swapAt(i, i + d)
        return set(r, items, in: stored)
    }

    static func flag(_ key: String, _ value: Bool, stored: JSONValue?) -> JSONValue {
        custom(in: stored) { $0[key] = .bool(value) }
    }

    /// The current layout as it ships (its changes forgotten).
    static func reset(stored: JSONValue?) -> JSONValue {
        custom(in: stored) { $0 = [:] }
    }

    /// Whether the current layout has changes.
    static func isCustomized(_ stored: JSONValue?) -> Bool {
        let o = object(stored)
        return !object(object(o["custom"])[activeKey(o)]).isEmpty
    }

    /// The old per-Mac "hide the cup" switch becomes the Keep Mac awake item turned off in Terminal's status bar.
    /// Only when nothing is stored yet (the first launch of this version); nil = nothing to write.
    static func migrate(stored: JSONValue?, keepAwakeHidden: Bool) -> JSONValue? {
        guard stored == nil, keepAwakeHidden else { return nil }
        return toggle("keepAwake", in: .statusRight, on: false, stored: .object(["layout": .string(LayoutPreset.terminal.rawValue)]))
    }
}

// MARK: - In the app

extension AppModel {
    static let layoutKey = "ui.layout"
    static let rightPanelDefaultWidth: CGFloat = 320
    static let rightPanelWidths: ClosedRange<CGFloat> = 260...900

    var layoutStored: JSONValue? { settingValue(Self.layoutKey, scope: "global") }
    var savedLayoutsStored: JSONValue? { settingValue(SavedLayouts.key, scope: "global") }
    /// The layouts you saved or imported, by id.
    var savedLayouts: [String: LayoutFile] { LayoutCache.get(layoutStored, saved: savedLayoutsStored).saved }
    /// The layout in use, read from the setting once per change (views ask for it on every draw).
    var layout: LayoutConfig { LayoutCache.get(layoutStored, saved: savedLayoutsStored).config }
    /// The window the layout engine draws for the layout in use; nil = the classic window.
    var shellTree: ShellTree? { LayoutCache.get(layoutStored, saved: savedLayoutsStored).tree }

    /// Stores the layout (global only) and shows it right away.
    func storeLayout(_ v: JSONValue) {
        setSettingLocally(Self.layoutKey, v, scope: "global")
        setSetting(Self.layoutKey, v.any, scope: "global")
        DocHost.shared.refreshFeatures()
    }

    func editLayout(_ f: (JSONValue?) -> JSONValue) { storeLayout(f(layoutStored)) }

    func storeSavedLayouts(_ v: JSONValue?) {
        setSettingLocally(SavedLayouts.key, v, scope: "global")
        setSetting(SavedLayouts.key, v?.any, scope: "global")
        (NSApp.delegate as? AppDelegate)?.refreshLayoutMenu()   // their ⌃⌘8 / ⌃⌘9 work before the menu is opened
    }

    /// Switches the whole app to a layout and sets the window up for it (panels open or closed, their sizes).
    func chooseLayout(_ p: LayoutPreset) {
        storeLayout(LayoutEdit.choose(p, in: layoutStored))
        arrangeWindow(for: p)
    }

    /// Switches to a saved layout: its window set up as its base's.
    func chooseSavedLayout(_ id: String) {
        guard let f = savedLayouts[id] else { return }
        storeLayout(LayoutEdit.chooseUser(id, base: f.base, in: layoutStored))
        arrangeWindow(for: f.base)
    }

    /// The window as layout `p` starts: panels open or closed, their sizes, its Home.
    private func arrangeWindow(for p: LayoutPreset) {
        withAnimation(.easeOut(duration: 0.18)) {
            switch p {
            case .terminal:
                sidebarVisible = true
                sidebarAgents = false
                rightPanelVisible = false
                rightPanelWidth = Self.rightPanelDefaultWidth
            case .agents:
                sidebarVisible = true
                sidebarAgents = false   // the home lists them
                rightPanelVisible = false
            case .workday:
                sidebarVisible = true
                sidebarAgents = false
                rightPanelVisible = false
            case .minimal:
                sidebarVisible = false
                rightPanelVisible = false
            case .editor:
                sidebarVisible = false
                sidebarAgents = false
                UserDefaults.standard.set(RightTab.files.rawValue, forKey: "octomux.rightTab")
                rightPanelWidth = 300
                rightPanelVisible = true
            case .aquarium:
                sidebarVisible = true
                sidebarAgents = false
                rightPanelVisible = false
            case .tasks:
                sidebarVisible = true      // the tasks rail
                sidebarAgents = false
                rightPanelVisible = true   // the picked task's detail
            }
        }
        sidebarPeek = false
        saveSelection()
        // The Agents and Workday layouts are the engine's window: their Home is a mode, not a tab (the tab of the
        // same page is closed if it was in front).
        if p == .agents || p == .workday {
            switch activeDoc?.kind {
            case .agents?, .workday?: activeDocId = nil
            default: break
            }
            shellHome = true
        }
        // The Tasks window opens on its assistant (the middle), no task picked.
        if p == .tasks {
            shellTaskId = nil
            // After the window's first frame: making the assistant's terminal doesn't hold up the switch.
            if let a = assistantSession(workspace: selectedWorkspaceId) { DispatchQueue.main.async { [weak self] in self?.selectSession(a.id) } }
        }
    }

    /// The first state after this version starts: the old "hide the cup" switch moves into the layout.
    func migrateLayoutIfNeeded() {
        guard !Self.layoutMigrated, !host.isRemote else { return }
        Self.layoutMigrated = true
        let hidden = UserDefaults.standard.bool(forKey: KeepAwake.hiddenKey)
        if let v = LayoutEdit.migrate(stored: layoutStored, keepAwakeHidden: hidden) { storeLayout(v) }
        if hidden { UserDefaults.standard.removeObject(forKey: KeepAwake.hiddenKey) }
    }
    nonisolated(unsafe) static var layoutMigrated = false

    /// The status bar's cup on or off (its panel's Hide, Settings → Sessions).
    func setKeepAwakeShown(_ on: Bool) {
        let saved = savedLayouts
        editLayout { LayoutEdit.toggle("keepAwake", in: .statusRight, on: on, stored: $0, saved: saved) }
    }

    /// A new agent session opens as a chat in a layout that wants it (when the agent has a chat view).
    func layoutWantsChat(profileId: String?) -> Bool {
        guard layout.chat, (setting("features.chat")?.bool ?? true), let p = profile(profileId) else { return false }
        return p.kind == .claude || p.kind == .codex || p.icon == "claude" || p.icon == "codex"
    }
}

/// The resolved layout for the stored settings, kept until they change.
enum LayoutCache {
    /// Layouts drawn by the layout engine. Terminal keeps the classic window: drawn by the engine it was not the same
    /// to the pixel (the sidebar's list sat a point lower with a file open), and the default look never moves. Its
    /// tree (terminal.json) is the starting point of a layout saved from Terminal.
    static let engine: Set<LayoutPreset> = [.agents, .workday, .minimal, .editor, .tasks, .aquarium]
    typealias Entry = (config: LayoutConfig, tree: ShellTree?, saved: [String: LayoutFile])
    nonisolated(unsafe) private static var last: (stored: JSONValue?, savedStored: JSONValue?, entry: Entry)?
    nonisolated(unsafe) static var misses = 0

    static func get(_ stored: JSONValue?, saved savedStored: JSONValue? = nil) -> Entry {
        if let l = last, l.stored == stored, l.savedStored == savedStored { return l.entry }
        misses += 1
        let saved = SavedLayouts.parse(savedStored)
        let c = LayoutConfig.resolve(stored, saved: saved)
        let custom = LayoutEdit.object(LayoutEdit.object(LayoutEdit.object(stored)["custom"])[LayoutEdit.activeKey(LayoutEdit.object(stored))])
        var tree: ShellTree?
        if let id = c.userId, let f = saved[id] {
            // A saved layout: your changes to its window, its own window, else its base's (as the base draws it).
            tree = custom["tree"].flatMap { try? ShellTree.parse($0).get() } ?? f.tree
                ?? (engine.contains(f.base) ? ShellTree.builtIn(f.base.rawValue) : nil)
            if tree != nil, case .object(let sizes)? = custom["sizes"] {
                tree = ShellTree.resolve(preset: f.base, custom: ["tree": tree!.json, "sizes": .object(sizes)])
            }
        } else if engine.contains(c.preset) {
            tree = ShellTree.resolve(preset: c.preset, custom: custom)
        }
        let e: Entry = (c, tree, saved)
        last = (stored, savedStored, e)
        return e
    }

    static func reset() { last = nil }
}
