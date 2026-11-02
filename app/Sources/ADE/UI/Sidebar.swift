import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    /// Floating (revealed from the left edge while hidden): no room needed for the traffic lights.
    var floating = false
    @ObservedObject var wt = Worktrees.shared
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ade.collapsed") ?? [])

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                SectionLabel("Projects")
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { i, p in
                        ProjectRow(project: p, collapsed: collapsed.contains(p.id)) {
                            if collapsed.contains(p.id) { collapsed.remove(p.id) } else { collapsed.insert(p.id) }
                            UserDefaults.standard.set(Array(collapsed), forKey: "ade.collapsed")
                        }
                        .reorderable("project", id: p.id) { model.moveProject($0, before: $1) }
                        .padding(.top, i == 0 ? 0 : 6)
                        if !collapsed.contains(p.id) {
                            let all = model.sessions(ofProject: p.id)
                            ForEach(all.filter { $0.worktree == nil }) { s in
                                SessionRow(session: s)
                                    .reorderable("session:\(p.id)", id: s.id) { a, b in
                                        if let ta = model.tab(containing: a), let tb = model.tab(containing: b) { model.moveTab(ta.id, to: tb.id) }
                                    }
                            }
                            ForEach((model.setting("features.worktrees")?.bool ?? true) ? worktreeGroups(p, all) : [], id: \.path) { g in
                                WorktreeRow(project: p, path: g.path, branch: g.branch, sessions: g.sessions)
                                ForEach(g.sessions) { s in SessionRow(session: s, indent: 32) }
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
                .padding(.bottom, 8)
            }
            footer
        }
    }

    struct WorktreeGroup { let path: String; let branch: String; let sessions: [Session] }

    /// Linked git worktrees of the project, plus worktrees sessions still point at.
    private func worktreeGroups(_ p: Project, _ sessions: [Session]) -> [WorktreeGroup] {
        var out: [WorktreeGroup] = []
        var seen = Set<String>()
        for w in wt.linked(p.path) {
            seen.insert(w.path)
            out.append(WorktreeGroup(path: w.path, branch: w.branch, sessions: sessions.filter { $0.worktree == w.path }))
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
                    Button((w.id == model.selectedWorkspaceId ? "✓ " : "") + w.name) { model.selectWorkspace(w.id) }
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
                    Text(model.workspace?.name ?? "ADE").font(T.headline).foregroundStyle(T.text)
                    Spacer()
                    if !model.connected {
                        Image(systemName: "bolt.horizontal.circle").foregroundStyle(T.amber).help("Reconnecting to the ADE daemon…")
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
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
                    Image(systemName: "server.rack").font(.system(size: 10))
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
                Image(systemName: "gearshape").font(.system(size: 13))
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
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(T.text2)
        }
        .plainMenu()
        .frame(width: 26, height: 26)
        .hoverHighlight(radius: 5)
        .help("New project or workspace")
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

    var onStep: (Int) -> Void = { d in withAnimation(.easeOut(duration: 0.15)) { AppModel.shared.cycleWorkspace(d) } }

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
        WorkspaceIcon(workspace: workspace, size: 13, dimmed: !selected && !hover)
            .frame(width: selected ? 40 : 28, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? T.raised : hover ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? T.border : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
            .onTapGesture { model.selectWorkspace(workspace.id) }
            .help(index >= 1 && index <= 9 ? "\(workspace.name)  ⌃\(index)   (⌃⌘← → or scroll to switch)" : workspace.name)
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
                    Image(systemName: "server.rack").font(.system(size: 8.5))
                    Text(model.host(for: project.id).name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(T.text3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(T.hover))
                .help("On \(model.host(for: project.id).name)")
            }
            if collapsed && !sessions.isEmpty {
                Text("\(sessions.count)").font(T.caption).foregroundStyle(T.text3)
            }
            Spacer(minLength: 4)
            if hover || model.debugHoverProject == project.id {
                ProjectQuickActions(project: project)
            } else {
                if waiting > 0 { Badge(text: "\(waiting)") }
                else if collapsed && unread > 0 { Circle().fill(T.green).frame(width: 6, height: 6) }
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
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5, weight: .medium)).foregroundStyle(T.text3).frame(width: 14)
            Text(branch).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hover {
                Menu {
                    Button("Terminal") { model.newSession(profileId: nil, projectId: project.id, worktree: path) }
                    ForEach(model.enabledProfiles) { p in
                        Button(p.name) { model.newSession(profileId: p.id, projectId: project.id, worktree: path) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text2) }
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
        .help(path)
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
            Button("Remove Worktree…", role: .destructive) { model.removeWorktree(project: project, path: path) }
        }
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
        }
        Divider()
        Button("Rename…") { ProjectEditor.rename(project) }
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

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    var indent: CGFloat = 18
    @State private var hover = false
    @State private var editTitle = ""

    var selected: Bool { model.focusedSessionId == session.id && model.activeTab?.layout.sessions.contains(session.id) == true }

    var body: some View {
        let m = T.m
        HStack(spacing: 8) {
            AgentIcon(icon: iconName(for: session, model: model), size: 12).frame(width: 14)
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
                    .font(.system(size: 13, weight: selected || session.unread ? .semibold : .regular))
                    .foregroundStyle(selected ? T.text : T.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hover {
                Group {
                    if session.isDormant {
                        Button { model.restart(session.id) } label: { Image(systemName: "arrow.clockwise") }
                            .help(session.kind == .agent ? "Resume" : "Restart")
                        Button { model.remove(session.id) } label: { Image(systemName: "xmark") }
                            .help("Remove")
                    } else {
                        Button { model.stop(session.id) } label: { Image(systemName: "stop.fill").font(.system(size: 8)) }
                            .help("Stop")
                    }
                }
                .buttonStyle(IconButtonStyle(size: 18))
                .font(.system(size: 10, weight: .semibold))
            } else {
                ActivityIndicator(session: session)
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
        .help(session.kind == .agent ? "\(model.profile(session.profileId)?.name ?? "agent") · \(session.cwd)" : session.cwd)
    }
}

struct SessionMenu: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        Button("Rename") { model.renamingSessionId = session.id }
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
            Button(session.kind == .agent ? "Resume" : "Restart") { model.restart(session.id) }
        } else {
            Button("Stop") { model.stop(session.id) }
            Button("Restart") { model.restart(session.id) }
        }
        if session.placement == .tab {
            Button("Move to Dock") { model.client(for: session.id).call("session.move", ["id": session.id, "placement": "dock"]) }
        }
        Divider()
        Button("Remove Session", role: .destructive) { model.remove(session.id) }
    }
}

enum TranscriptLocator {
    /// Claude transcript path for an agent session (searches the profile's config dir).
    static func path(for s: Session, model: AppModel) -> String? {
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
            Image(systemName: open ? "chevron.down" : "rectangle.bottomthird.inset.filled").font(.system(size: 9, weight: .semibold))
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

/// Empty workspace in the sidebar: a quiet line of text over a pixel illustration (no loud buttons; the
/// footer "+" and this link add a project).
struct SidebarEmptyState: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Projects you add will show up here")
                .font(.system(size: 12.5)).foregroundStyle(T.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PixelArt(rows: PixelArt.folderPlus, cell: 5, gap: 1)
            Text("Add Project…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? T.text : T.text3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? T.hover : .clear))
                .onHover { hover = $0 }
                .pointerCursor()
                .onTapGesture { model.addProject() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }
}

/// Small pixel drawing: "#" = line, "o" = dim fill, "." = empty.
struct PixelArt: View {
    let rows: [String]
    var cell: CGFloat = 5
    var gap: CGFloat = 1

    static let folderPlus = [
        ".#####..........",
        "#ooooo##########",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooo##oooooo#",
        "#oooooo##oooooo#",
        "#oooo######oooo#",
        "#oooo######oooo#",
        "#oooooo##oooooo#",
        "#oooooo##oooooo#",
        "#oooooooooooooo#",
        "################",
    ]

    var body: some View {
        let w = CGFloat(rows.map(\.count).max() ?? 0) * (cell + gap)
        let h = CGFloat(rows.count) * (cell + gap)
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let r = CGRect(x: CGFloat(x) * (cell + gap), y: CGFloat(y) * (cell + gap), width: cell, height: cell)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(ch == "#" ? T.text3.opacity(0.75) : T.text3.opacity(0.14)))
                }
            }
        }
        .frame(width: w, height: h)
    }
}
