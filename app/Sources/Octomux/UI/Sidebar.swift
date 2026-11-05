import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    /// Floating (revealed from the left edge while hidden): no room needed for the traffic lights.
    var floating = false
    @ObservedObject var wt = Worktrees.shared
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "octomux.collapsed") ?? [])

    var body: some View {
        GeometryReader { geo in
        VStack(spacing: 0) {
            header
            InboxSidebarRow()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { i, p in
                        ProjectRow(project: p, collapsed: collapsed.contains(p.id)) {
                            if collapsed.contains(p.id) { collapsed.remove(p.id) } else { collapsed.insert(p.id) }
                            UserDefaults.standard.set(Array(collapsed), forKey: "octomux.collapsed")
                        }
                        .reorderable("project", id: p.id) { model.moveProject($0, before: $1) }
                        .padding(.top, i == 0 ? 0 : 6)
                        if !collapsed.contains(p.id) {
                            let all = model.sessions(ofProject: p.id)
                            ForEach(tabGroups(all.filter { $0.worktree == nil }), id: \.first!.id) { group in
                                SessionGroup(sessions: group, indent: 18)
                                    .reorderable("session:\(p.id)", id: group[0].id) { a, b in
                                        if let ta = model.tab(containing: a), let tb = model.tab(containing: b) { model.moveTab(ta.id, to: tb.id) }
                                    }
                            }
                            ForEach((model.setting("features.worktrees")?.bool ?? true) ? worktreeGroups(p, all) : [], id: \.path) { g in
                                WorktreeRow(project: p, path: g.path, branch: g.branch, sessions: g.sessions)
                                ForEach(tabGroups(g.sessions), id: \.first!.id) { group in SessionGroup(sessions: group, indent: 32) }
                            }
                            let dock = model.state.sessions.filter { $0.projectId == p.id && $0.placement == .dock }
                            if !dock.isEmpty {
                                DockCountRow(project: p, count: dock.count)
                            }
                        }
                    }
                    if model.projects.isEmpty {
                        SidebarEmptyState()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .modifier(WorkspacePaged())
            .frame(maxHeight: .infinity)
            AgentsPanel(maxHeight: max(AgentsPanel.minHeight, geo.size.height - 260))
            footer
        }
        }
    }

    struct WorktreeGroup { let path: String; let branch: String; let sessions: [Session] }

    /// Linked git worktrees of the project, plus worktrees sessions still point at.
    private func worktreeGroups(_ p: Project, _ sessions: [Session]) -> [WorktreeGroup] {
        var out: [WorktreeGroup] = []
        var seen = Set<String>()
        for w in wt.linked(p.path) {
            seen.insert(w.path)
            out.append(WorktreeGroup(path: w.path, branch: w.label, sessions: sessions.filter { $0.worktree == w.path }))
        }
        for path in Set(sessions.compactMap(\.worktree)) where !seen.contains(path) {
            out.append(WorktreeGroup(path: path, branch: (path as NSString).lastPathComponent, sessions: sessions.filter { $0.worktree == path }))
        }
        return out
    }

    private var header: some View {
        VStack(spacing: 8) {
            WindowDragArea().frame(height: floating ? 6 : 38)  // traffic lights row: drags the window
            Menu {
                ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                    let a = model.attention(workspace: w.id)
                    let note = attentionText(a)
                    Button((w.id == model.selectedWorkspaceId ? "✓ " : "") + w.name + (note.isEmpty ? "" : "   ·  " + note)) { model.selectWorkspace(w.id) }
                }
                Divider()
                if (model.setting("features.remote")?.bool ?? true) || model.host.isRemote { Section("Host") {
                    ForEach(HostStore.withLocal) { h in
                        Button((h.id == model.hostId ? "✓ " : "") + h.name) { model.switchHost(h.id) }
                    }
                    Button("Manage Hosts…") { SettingsWindow.show(section: .hosts) }
                } }
                Divider()
                Button("Workspace Settings…") { SettingsWindow.show(section: .workspaces) }
            } label: {
                HStack(spacing: 8) {
                    if let w = model.workspace { WorkspaceIcon(workspace: w, size: 12).frame(width: 14) }
                    Text(model.workspace?.name ?? "Octomux").font(T.headline).foregroundStyle(T.text)
                    Spacer()
                    let elsewhere = model.attentionElsewhere
                    if elsewhere.waiting + elsewhere.unread > 0 {
                        AttentionDot(attention: elsewhere).help("Other workspaces: " + attentionText(elsewhere))
                    }
                    if !model.connected {
                        Image(systemName: "bolt.horizontal.circle").foregroundStyle(T.amber).help("Reconnecting to the Octomux daemon…")
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: T.k * 9, weight: .semibold)).foregroundStyle(T.text3)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(T.hover))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .pointerCursor()
            .help("Switch workspace (⌃⌘← →, or swipe) or host")
            if model.host.isRemote {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: T.k * 10))
                    Text(model.host.name).font(T.caption)
                    Text(model.host.subtitle).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Circle().fill(model.connected ? T.green : T.amber).frame(width: 6, height: 6)
                }
                .foregroundStyle(T.text2)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(T.selection))
                .help(model.connected ? "Connected to \(model.host.name)" : "Connecting to \(model.host.name)…")
            }
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            AddMenu()
            Spacer(minLength: 4)
            WorkspaceSwitcher()
            Spacer(minLength: 4)
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: {
                Image(systemName: "gearshape").font(.system(size: T.k * 13))
            }.buttonStyle(IconButtonStyle(size: 26)).help("Settings (⌘,)")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

/// Sidebar footer "+": new project (on a chosen host when hosts are side by side) or workspace.
struct AddMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            if model.extraHosts.isEmpty {
                Button("New Project…") { model.addProject() }
            } else {
                Button("New Project on \(model.host.name)…") { model.addProject() }
                ForEach(model.extraHosts) { h in
                    Button("New Project on \(h.name)…") { model.addProject(onHost: h.id) }
                }
            }
            Button("New Workspace…") { WorkspaceEditor.create() }
        } label: {
            Image(systemName: "plus").font(.system(size: T.k * 13, weight: .medium)).foregroundStyle(T.text2).menuHitBox(26, 26)
        }
        .plainMenu()
        .frame(width: 26, height: 26)
        .hoverHighlight(radius: 5)
        .help("New project or workspace")
        .disabled(!model.canManage)
    }
}

/// Workspace buttons in the sidebar footer: icon (or color dot) per workspace, selected one in a pill.
struct WorkspaceSwitcher: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.state.workspaces.sorted { $0.sort < $1.sort }.enumerated()), id: \.element.id) { i, w in
                WorkspaceButton(workspace: w, selected: w.id == model.selectedWorkspaceId, index: i + 1)
            }
        }
        .background(WindowRectReporter { win, rect in WorkspaceScroller.shared.rects[ObjectIdentifier(win)] = rect.insetBy(dx: -6, dy: -6) })
    }
}

/// Reports a view's rectangle in its window (top-left origin), for event monitors.
struct WindowRectReporter: NSViewRepresentable {
    let report: (NSWindow, CGRect) -> Void
    final class V: NSView {
        var report: ((NSWindow, CGRect) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); send() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); send() }
        override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); send() }
        override func setFrameOrigin(_ p: NSPoint) { super.setFrameOrigin(p); send() }
        func send() {
            guard let win = window, let content = win.contentView else { return }
            let r = convert(bounds, to: nil)
            report?(win, CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height))
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.report = report; return v }
    func updateNSView(_ v: V, context: Context) { v.report = report; DispatchQueue.main.async { v.send() } }
}

/// Wheel / trackpad scrolling over the workspace switcher: one workspace per gesture (trackpad) or per
/// burst of wheel clicks, so spinning the wheel does not race through every workspace.
final class WorkspaceScroller {
    static let shared = WorkspaceScroller()
    var rects: [ObjectIdentifier: CGRect] = [:]
    private var accum: CGFloat = 0
    private var locked = false
    private var lastWheel = Date.distantPast

    func handle(_ e: NSEvent) {
        let d = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : -e.scrollingDeltaX
        if e.hasPreciseScrollingDeltas {
            if !e.momentumPhase.isEmpty { return }               // ignore the coast after lifting fingers
            if e.phase == .began || e.phase == .mayBegin { accum = 0; locked = false }
            if !locked {
                accum += d
                if abs(accum) > 22 { step(accum < 0 ? 1 : -1) }
            }
            if e.phase == .ended || e.phase == .cancelled { accum = 0; locked = false }
        } else {
            let now = Date()
            if now.timeIntervalSince(lastWheel) > 0.35 { locked = false }   // wheel must pause before the next step
            lastWheel = now
            if !locked && d != 0 { step(d < 0 ? 1 : -1) }
        }
    }

    var onStep: (Int) -> Void = { d in WorkspacePager.shared.slide(d) }

    private func step(_ delta: Int) {
        locked = true
        onStep(delta)
    }
}

struct WorkspaceButton: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    let selected: Bool
    var index = 0
    @State private var hover = false

    var body: some View {
        let a = model.attention(workspace: workspace.id)
        let note = attentionText(a)
        // Another workspace that wants you (something waits for input, or finished and not looked at yet).
        MarkedWorkspaceIcon(workspace: workspace, mark: WorkspaceMark.current(model), attention: !selected && !note.isEmpty ? a : nil,
                            dimmed: !selected && !hover, width: selected ? 40 : 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? T.raised : hover ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? T.border : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
            .onTapGesture { WorkspacePager.shared.go(to: workspace.id) }
            .help((index >= 1 && index <= 9 ? "\(workspace.name)  ⌃\(index)   (⌃⌘← → or scroll to switch)" : workspace.name) + (note.isEmpty ? "" : "\n" + note))
            .contextMenu { WorkspaceMenu(workspace: workspace) }
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

struct WorkspaceMenu: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace

    var body: some View {
        Button("Rename…") { WorkspaceEditor.rename(workspace) }
        Menu("Icon") {
            Button("None (color dot)") { model.updateWorkspace(workspace.id, ["icon": ""]) }
            Divider()
            ForEach(WorkspaceIcon.symbols, id: \.self) { sym in
                Button { model.updateWorkspace(workspace.id, ["icon": sym]) } label: { Label(sym, systemImage: sym) }
            }
            Divider()
            Button("Emoji…") { WorkspaceEditor.emoji(workspace) }
        }
        Menu("Color") {
            ForEach(Palette.colors, id: \.self) { c in
                Button(ProjectMenu.colorName(c)) { model.updateWorkspace(workspace.id, ["color": c]) }
            }
        }
        Divider()
        Button("Workspace Settings…") { SettingsWindow.show(section: .workspaces) }
        Button("Delete Workspace", role: .destructive) { model.deleteWorkspace(workspace.id) }
            .disabled(model.state.workspaces.count <= 1)
    }
}

enum WorkspaceEditor {
    private static func ask(_ title: String, _ value: String, width: CGFloat = 240, button: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        let tf = NSTextField(string: value)
        tf.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func create() {
        if let n = ask("New workspace", "", button: "Create") { AppModel.shared.createWorkspace(name: n) }
    }

    static func rename(_ w: Workspace) {
        if let n = ask("Rename workspace", w.name, button: "Rename") { AppModel.shared.updateWorkspace(w.id, ["name": n]) }
    }

    static func emoji(_ w: Workspace) {
        let current = w.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? $0 : nil } ?? ""
        if let e = ask("Workspace emoji", current, width: 80, button: "Set"), let ch = e.first {
            AppModel.shared.updateWorkspace(w.id, ["icon": String(ch)])
        }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared
    let project: Project
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        let m = T.m
        let sessions = model.sessions(ofProject: project.id)
        let waiting = sessions.filter { $0.activity == .needsInput }.count
        let unread = sessions.filter { $0.unread && $0.activity != .needsInput }.count
        HStack(spacing: 8) {
            ProjectIconView(project: project, size: 18)
            Text(project.name).font(T.headline).foregroundStyle(T.text).lineLimit(1)
            if model.owner[project.id] != nil {
                HStack(spacing: 3) {
                    Image(systemName: "server.rack").font(.system(size: T.k * 8.5))
                    Text(model.host(for: project.id).name).font(.system(size: T.k * 10, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(T.text3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(T.hover))
                .help("On \(model.host(for: project.id).name)")
            }
            if collapsed && !sessions.isEmpty {
                Text("\(sessions.count)").font(T.caption).foregroundStyle(T.text3)
                    .help(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
            }
            Spacer(minLength: 4)
            if hover || model.debugHoverProject == project.id {
                ProjectQuickActions(project: project)
            } else {
                if waiting > 0 { Badge(text: "\(waiting)").help(waiting == 1 ? "1 session needs your input" : "\(waiting) sessions need your input") }
                else if collapsed && unread > 0 {
                    Circle().fill(T.green).frame(width: 6, height: 6)
                        .help(unread == 1 ? "1 session finished, not looked at yet" : "\(unread) sessions finished, not looked at yet")
                }
                if let b = git.branch(for: project.path) {
                    Text(b).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).frame(maxWidth: 80, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: m.rowH)
        .background(RoundedRectangle(cornerRadius: m.rowR, style: .continuous).fill(hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture(count: 1) { toggle(); model.selectProject(project.id) }
        .contextMenu { ProjectMenu(project: project) }
    }
}

/// A linked git worktree under its project: branch, session count, new-session menu.
struct WorktreeRow: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    let path: String
    let branch: String
    let sessions: [Session]
    @ObservedObject private var wt = Worktrees.shared
    @State private var hover = false

    var body: some View {
        let info = wt.info(path)
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10.5, weight: .medium)).foregroundStyle(T.text3).frame(width: 14)
            Text(branch).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
            if let info, info.detached {
                Text(info.head.isEmpty ? "detached" : "@\(info.head)").font(T.mono(10)).foregroundStyle(T.text3).fixedSize()
            }
            if info?.locked != nil {
                Image(systemName: "lock.fill").font(.system(size: T.k * 8.5)).foregroundStyle(T.text3)
            }
            Spacer(minLength: 4)
            if hover {
                Menu {
                    Button("Terminal") { model.newSession(profileId: nil, projectId: project.id, worktree: path) }
                    ForEach(model.enabledProfiles) { p in
                        Button(p.name) { model.newSession(profileId: p.id, projectId: project.id, worktree: path) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text2).menuHitBox(20, 20) }
                    .plainMenu().frame(width: 20, height: 20).hoverHighlight(radius: 5)
            } else if sessions.isEmpty {
                Text("empty").font(T.caption).foregroundStyle(T.text3)
            }
        }
        .padding(.leading, 18).padding(.trailing, 8)
        .frame(height: max(22, T.m.rowH - 6))
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(tooltip(info))
        .contextMenu {
            Button("New Terminal Here") { model.newSession(profileId: nil, projectId: project.id, worktree: path) }
            ForEach(model.enabledProfiles) { p in
                Button("New \(p.name) Here") { model.newSession(profileId: p.id, projectId: project.id, worktree: path) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            OpenInMenu(path: path)
            Button("Copy Path") { copy(path) }
            Divider()
            Button("Hide from Sidebar") { wt.hide(path) }
            Button("Remove Worktree…", role: .destructive) { model.removeWorktree(project: project, path: path) }
        }
    }

    private func tooltip(_ w: Worktree?) -> String {
        var lines = [path]
        if let w, w.detached { lines.append("Detached HEAD at \(w.head) (no branch)") }
        if let lock = w?.locked { lines.append("Locked" + (lock.isEmpty ? "" : ": \(lock)")) }
        if !Worktrees.isOurs(project: project.path, path: path) { lines.append("Not created by Octomux") }
        return lines.joined(separator: "\n")
    }
}

struct ProjectMenu: View {
    @EnvironmentObject var model: AppModel
    let project: Project

    var body: some View {
        Button("New Terminal") { model.newSession(profileId: nil, projectId: project.id) }
        ForEach(model.enabledProfiles) { p in
            Button("New \(p.name)") { model.newSession(profileId: p.id, projectId: project.id) }
        }
        if model.setting("features.worktrees")?.bool ?? true {
            Button("New Worktree…") { model.newWorktreeFor = project }
            let hidden = Worktrees.shared.hiddenPaths(of: project.path)
            if !hidden.isEmpty {
                Button("Show \(hidden.count) Hidden Worktree\(hidden.count == 1 ? "" : "s")") { Worktrees.shared.unhide(hidden) }
            }
        }
        Divider()
        Button("Rename…") { ProjectEditor.rename(project) }
        Button("Project Settings…") { SettingsWindow.show(section: .projects); SettingsWindow.selection.project = project.id }
        Menu("Color") {
            ForEach(Palette.colors, id: \.self) { c in
                Button { model.updateProject(project.id, ["color": c]) } label: { Text(Self.colorName(c)) }
            }
        }
        Menu("Icon") {
            Button("Folder") { model.updateProject(project.id, ["icon": ["kind": "folder"]]) }
            Menu("Mascot") {
                ForEach(Mascot.names, id: \.self) { m in
                    Button(m.capitalized) { model.updateProject(project.id, ["icon": ["kind": "mascot", "value": m]]) }
                }
            }
            Menu("Symbol") {
                ForEach(["star.fill", "bolt.fill", "leaf.fill", "flame.fill", "cube.fill", "globe", "server.rack", "iphone", "cart.fill", "book.fill", "hammer.fill", "brain.head.profile"], id: \.self) { s in
                    Button { model.updateProject(project.id, ["icon": ["kind": "symbol", "value": s]]) } label: { Label(s, systemImage: s) }
                }
            }
            Button("Emoji…") { ProjectEditor.emoji(project) }
            Button("Image…") { ProjectEditor.image(project) }
            if let found = ProjectEditor.detectLogo(project.path) {
                Button("Use \(URL(fileURLWithPath: found).lastPathComponent)") {
                    model.updateProject(project.id, ["icon": ["kind": "image", "value": found]])
                }
            }
        }
        Divider()
        if !model.host(for: project.id).isRemote {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            OpenInMenu(path: project.path)
        }
        Button("Copy Path") { copy(project.path) }
        Divider()
        if model.state.workspaces.count > 1 {
            Menu("Move to Workspace") {
                ForEach(model.state.workspaces.filter { $0.id != project.workspaceId }) { w in
                    Button(w.name) { model.moveProject(project.id, toWorkspace: w.id) }
                }
            }
        }
        let muted = model.settingValue("notifications.enabled", scope: "project:\(project.id)")?.bool == false
        Button(muted ? "Unmute Notifications" : "Mute Notifications") {
            model.setSetting("notifications.enabled", muted ? nil : false, scope: "project:\(project.id)")
        }
        Button("Archive") { model.updateProject(project.id, ["archived": true]) }
        Button("Remove Project…", role: .destructive) { model.removeProject(project.id) }
    }

    static func colorName(_ hex: String) -> String {
        ["#459CF7": "Blue", "#F4BF25": "Yellow", "#39C363": "Green", "#E45A9F": "Pink", "#B168D4": "Purple",
         "#37BEB4": "Teal", "#EF8C39": "Orange", "#EA603E": "Red", "#8B949C": "Gray"][hex] ?? hex
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Consecutive sessions that share a tab (split panes) form one group; others stand alone.
func tabGroups(_ sessions: [Session]) -> [[Session]] {
    let model = AppModel.shared
    var out: [[Session]] = []
    var lastTab: String?
    for s in sessions {
        let t = model.tab(containing: s.id)?.id
        if let t, t == lastTab, !out.isEmpty { out[out.count - 1].append(s) } else { out.append([s]) }
        lastTab = t
    }
    return out
}

/// Sidebar rows of one tab: a single session as is; split panes inside one frame with a guide line.
struct SessionGroup: View {
    /// Split tabs as one stacked row (default) or as a framed group of rows.
    static var stacked: Bool { UserDefaults.standard.object(forKey: "octomux.sidebarStackedTabs") as? Bool ?? true }
    @AppStorage("octomux.sidebarStackedTabs") private var stackedPref = true
    @EnvironmentObject var model: AppModel
    let sessions: [Session]
    let indent: CGFloat

    var body: some View {
        if sessions.count == 1 {
            SessionRow(session: sessions[0], indent: indent)
        } else if stackedPref {
            // One row per tab: its focused pane, on a stacked icon.
            let tab = model.tab(containing: sessions[0].id)
            let lead = sessions.first { $0.id == tab?.activeSessionId } ?? sessions[0]
            SessionRow(session: lead, indent: indent, stack: sessions)
        } else {
            let active = model.activeDoc == nil && model.activeTab.map { t in sessions.contains { t.layout.sessions.contains($0.id) } } == true
            VStack(spacing: 0) {
                // Rows keep the icon column of standalone rows: frame starts 8pt left of it (+2 padding).
                ForEach(sessions) { s in SessionRow(session: s, indent: 6, inGroup: true) }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: T.m.rowR + 2, style: .continuous).fill(T.hover.opacity(active ? 0.9 : 0.45)))
            .overlay(RoundedRectangle(cornerRadius: T.m.rowR + 2, style: .continuous).stroke(T.border.opacity(active ? 1 : 0.7)))
            .padding(.leading, indent - 8)
            .padding(.vertical, 2)
            .help("\(sessions.count) panes in one tab")
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    var indent: CGFloat = 18
    var inGroup = false
    /// All panes of the tab when this row stands for a split tab.
    var stack: [Session] = []
    @State private var hover = false
    @State private var editTitle = ""

    var selected: Bool {
        if stack.count > 1 { return model.activeDoc == nil && model.activeTab?.layout.sessions.contains(session.id) == true }
        return model.focusedSessionId == session.id && model.activeTab?.layout.sessions.contains(session.id) == true
    }
    /// The pane whose activity the row shows: one waiting for input beats one working, then unread.
    private var indicated: Session {
        stack.first { $0.activity == .needsInput } ?? stack.first { $0.activity == .working } ?? stack.first { $0.unread } ?? session
    }

    var body: some View {
        let m = T.m
        HStack(spacing: 8) {
            Group {
                if stack.count > 1 {
                    PaneStackFan(sessions: stack, front: session.id, size: 12)
                } else {
                    PaneStackIcon(items: paneStackItems(stack.map(\.id), front: session.id, model: model), size: 12, style: .fan)
                }
            }
            .frame(minWidth: 14, alignment: .leading)
            .zIndex(1)
            if model.renamingSessionId == session.id {
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(T.body)
                    .onSubmit {
                        model.rename(session.id, to: editTitle)
                        model.renamingSessionId = nil
                    }
                    .onExitCommand { model.renamingSessionId = nil }
                    .onAppear { editTitle = session.displayTitle }
            } else {
                Text(session.displayTitle)
                    .font(.system(size: T.k * 13, weight: selected || session.unread ? .semibold : .regular))
                    .foregroundStyle(selected ? T.text : T.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if !hover, model.isPinned(session: session.id) {
                Image(systemName: "pin.fill").font(.system(size: T.k * 8.5, weight: .semibold)).foregroundStyle(T.text3)
                    .rotationEffect(.degrees(40)).help("Pinned")
            }
            if hover {
                Group {
                    if session.isDormant {
                        Button { model.restart(session.id) } label: { Image(systemName: "arrow.clockwise") }
                            .help(session.isAgent ? "Resume" : "Restart")
                        Button { model.remove(session.id) } label: { Image(systemName: "xmark") }
                            .help("Remove")
                    } else {
                        Button { model.stop(session.id) } label: { Image(systemName: "stop.fill").font(.system(size: T.k * 8)) }
                            .help("Stop")
                    }
                }
                .disabled(!model.canManage)
                .buttonStyle(IconButtonStyle(size: 18))
                .font(.system(size: T.k * 10, weight: .semibold))
            } else {
                ActivityIndicator(session: indicated)
            }
        }
        .opacity(session.isDormant ? 0.45 : 1)
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .frame(height: m.rowH)
        .background(RoundedRectangle(cornerRadius: m.rowR, style: .continuous).fill(selected ? WorkspaceTint.selection(model) : hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectSession(session.id) }
        .contextMenu { SessionMenu(session: session) }
        .help(stack.count > 1 ? "\(stack.count) panes: " + stack.map(\.displayTitle).joined(separator: ", ")
              : session.kind == .agent ? "\(model.profile(session.profileId)?.name ?? "agent") · \(session.cwd)"
              : session.agentApp.map { "\(agentAppLabel($0)) in a terminal · \(session.cwd)" } ?? session.cwd)
    }
}

struct SessionMenu: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    /// Inside a tab's menu (TabMenu): it has Rename, Pin and Close Tab itself; Remove stays only for a pane of a split.
    var inTab = false

    var body: some View {
        if !inTab { Button("Rename") { model.renamingSessionId = session.id } }
        if !inTab, session.placement == .tab, let tab = model.tab(containing: session.id) {
            Button(model.isPinned(tab) ? "Unpin" : "Pin") { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.togglePin(tab) } }
        }
        if model.canChat(session) {
            Button(model.isChat(session.id) ? "Show Terminal" : "Show as Chat") { model.toggleChat(session.id) }
        }
        if let aid = session.agentSessionId {
            Button("Copy Session ID") { copy(aid) }
        }
        Button("Copy Transcript Path") { copy(TranscriptLocator.path(for: session, model: model) ?? "") }
            .disabled(TranscriptLocator.path(for: session, model: model) == nil)
        Button("Copy Screen Text") {
            model.client(for: session.id).call("session.screen_text", ["id": session.id]) { r in
                if case .success(let v) = r, let t = (v as? [String: Any])?["text"] as? String { copy(t) }
            }
        }.disabled(session.isDormant)
        Divider()
        if session.isDormant {
            Button(session.isAgent ? "Resume" : "Restart") { model.restart(session.id) }
        } else {
            Button("Stop") { model.stop(session.id) }
            Button("Restart") { model.restart(session.id) }
        }
        if session.isAgent || session.reportsStatus == true {
            Button("Show Agent Events") {
                SettingsWindow.show(section: .advanced)
                SettingsWindow.selection.eventsSession = session.id
                SettingsWindow.selection.open(.advanced, row: "Agent events")
            }
        }
        if session.placement == .tab {
            Button("Move to Dock") { model.client(for: session.id).call("session.move", ["id": session.id, "placement": "dock"]) }
        }
        if !inTab {
            Divider()
            Button("Remove Session", role: .destructive) { model.remove(session.id) }
        } else if (model.tab(containing: session.id)?.layout.sessions.count ?? 1) > 1 {
            Button("Close “\(TabChip.clip(session.displayTitle, 24))” Pane", role: .destructive) { model.closePane(session.id) }
        }
    }
}

enum TranscriptLocator {
    /// The session's transcript: the one the daemon follows (Claude hooks, a running Codex's rollout), else
    /// a Claude conversation's file in the profile's config dir.
    static func path(for s: Session, model: AppModel) -> String? {
        if let p = s.transcriptPath, FileManager.default.fileExists(atPath: p) { return p }
        guard let id = s.agentSessionId, let p = model.profile(s.profileId), p.kind == .claude else { return nil }
        let cfg = p.env["CLAUDE_CONFIG_DIR"].map { NSString(string: $0).expandingTildeInPath } ?? (NSHomeDirectory() + "/.claude")
        let projects = URL(fileURLWithPath: cfg).appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for d in dirs {
            let f = projects.appendingPathComponent(d).appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f.path }
        }
        return nil
    }
}

enum ProjectEditor {
    static func rename(_ p: Project) {
        let a = NSAlert()
        a.messageText = "Rename project"
        let tf = NSTextField(string: p.name)
        tf.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        if a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty {
            AppModel.shared.updateProject(p.id, ["name": tf.stringValue])
        }
    }

    static func emoji(_ p: Project) {
        let a = NSAlert()
        a.messageText = "Project emoji"
        let tf = NSTextField(string: p.icon.kind == "emoji" ? (p.icon.value ?? "") : "")
        tf.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Set")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, let ch = tf.stringValue.first {
            AppModel.shared.updateProject(p.id, ["icon": ["kind": "emoji", "value": String(ch)]])
        }
    }

    static func image(_ p: Project) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .icns, .svg, .image]
        panel.directoryURL = URL(fileURLWithPath: p.path)
        if panel.runModal() == .OK, let u = panel.url {
            AppModel.shared.updateProject(p.id, ["icon": ["kind": "image", "value": u.path]])
        }
    }

    /// Looks for a logo/favicon inside the project to suggest as its icon.
    static func detectLogo(_ root: String) -> String? {
        let candidates = ["logo.png", "icon.png", "favicon.png", "public/favicon.png", "public/logo.png", "public/icon.png",
                          "assets/logo.png", "assets/icon.png", "static/favicon.png", "app/icon.png", "src/app/icon.png",
                          "public/apple-touch-icon.png", "docs/logo.png", ".github/logo.png"]
        for c in candidates {
            let p = (root as NSString).appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: p), NSImage(contentsOfFile: p) != nil { return p }
        }
        return nil
    }
}

/// "N in dock" under a project: click to show or hide that project's dock.
struct DockCountRow: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    let count: Int
    @State private var hover = false

    var body: some View {
        let open = model.isDockOpen(project.id) && model.currentProject?.id == project.id
        HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "rectangle.bottomthird.inset.filled").font(.system(size: T.k * 9, weight: .semibold))
            Text("\(count) in dock")
        }
        .font(T.caption).foregroundStyle(hover ? T.text2 : T.text3)
        .padding(.horizontal, 6).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture {
            if model.currentProject?.id != project.id {
                model.selectProject(project.id)
                if !model.isDockOpen(project.id) { model.toggleDock() }
            } else {
                model.toggleDock()
            }
        }
        .help(open ? "Hide the dock" : "Show the dock")
        .padding(.leading, 14)
    }
}

/// Empty workspace in the sidebar: fading skeletons of project rows (what will appear here), a quiet line,
/// and a dashed drop zone that adds a project on click or when a folder is dropped on it.
struct SidebarEmptyState: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false
    @State private var dropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ghostRow(width: 92, opacity: 0.9)
                ghostRow(width: 120, opacity: 0.55)
                ghostRow(width: 74, opacity: 0.28)
            }
            .padding(.bottom, 16)
            Text("Projects you add will show up here. You can also drop a folder below.")
                .font(.system(size: T.k * 12.5)).foregroundStyle(T.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            let active = hover || dropTarget
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: T.k * 12.5))
                Text(dropTarget ? "Drop to add" : "Add a project")
                    .font(.system(size: T.k * 12.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(active ? T.text : T.text2)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: T.m.rowR + 1, style: .continuous).fill(active ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: T.m.rowR + 1, style: .continuous)
                .strokeBorder(dropTarget ? T.accent : T.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
            .onTapGesture { model.addProject() }
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                guard let ws = model.selectedWorkspaceId else { return false }
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                        DispatchQueue.main.async { model.addProject(path: url.path, workspaceId: ws) }
                    }
                }
                return true
            }
        }
        .padding(.top, 4)
    }

    private func ghostRow(width: CGFloat, opacity: Double) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: min(T.m.tileR, 9), style: .continuous).fill(T.text3.opacity(0.22)).frame(width: 18, height: 18)
            Capsule().fill(T.text3.opacity(0.18)).frame(width: width, height: 8)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: T.m.rowH - 4)
        .opacity(opacity)
    }
}

/// "1 waiting for input · 2 with something new", or "" when nothing wants you.
func attentionText(_ a: (waiting: Int, unread: Int)) -> String {
    var parts: [String] = []
    if a.waiting > 0 { parts.append("\(a.waiting) waiting for input") }
    if a.unread > 0 { parts.append("\(a.unread) with something new") }
    return parts.joined(separator: " · ")
}

/// Amber when something waits for input, else green (something new to look at).
struct AttentionDot: View {
    let attention: (waiting: Int, unread: Int)
    var body: some View {
        Circle().fill(attention.waiting > 0 ? T.amber : T.green).frame(width: 6, height: 6)
    }
}
