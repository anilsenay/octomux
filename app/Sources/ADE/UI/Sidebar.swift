import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wt = Worktrees.shared
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ade.collapsed") ?? [])

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                SectionLabel("Projects")
                Spacer()
                if model.extraHosts.isEmpty {
                    Button { model.addProject() } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(T.text3).help("Add Project (⌘⇧O)")
                } else {
                    Menu {
                        Button("On \(model.host.name)…") { model.addProject() }
                        ForEach(model.extraHosts) { h in
                            Button("On \(h.name)…") { model.addProject(onHost: h.id) }
                        }
                    } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(T.text3).help("Add Project")
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { i, p in
                        ProjectRow(project: p, collapsed: collapsed.contains(p.id)) {
                            if collapsed.contains(p.id) { collapsed.remove(p.id) } else { collapsed.insert(p.id) }
                            UserDefaults.standard.set(Array(collapsed), forKey: "ade.collapsed")
                        }
                        .padding(.top, i == 0 ? 0 : 6)
                        if !collapsed.contains(p.id) {
                            let all = model.sessions(ofProject: p.id)
                            ForEach(all.filter { $0.worktree == nil }) { s in
                                SessionRow(session: s)
                            }
                            ForEach((model.setting("features.worktrees")?.bool ?? true) ? worktreeGroups(p, all) : [], id: \.path) { g in
                                WorktreeRow(project: p, path: g.path, branch: g.branch, sessions: g.sessions)
                                ForEach(g.sessions) { s in SessionRow(session: s, indent: 46) }
                            }
                            let dock = model.state.sessions.filter { $0.projectId == p.id && $0.placement == .dock }
                            if !dock.isEmpty {
                                Text("\(dock.count) in dock").font(T.caption).foregroundStyle(T.text3).padding(.leading, 38).frame(height: 20)
                            }
                        }
                    }
                    if model.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No projects in this workspace").font(T.body).foregroundStyle(T.text2)
                            Button("Add Project…") { model.addProject() }.buttonStyle(SecondaryButtonStyle())
                        }.padding(.horizontal, 10).padding(.vertical, 8)
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
            Spacer().frame(height: 38)  // traffic lights
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
                    Circle().fill(Color(hex: model.workspace?.color ?? "#888")).frame(width: 8, height: 8)
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
            Button { model.paletteVisible = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Search")
                    Spacer()
                    Text(KeyBindings.shared.current("cmd.command-palette")?.display ?? "").font(T.mono(11))
                }
                .font(T.body).foregroundStyle(T.text3)
                .padding(.horizontal, 10).frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).stroke(T.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: {
                Image(systemName: "gearshape")
            }.buttonStyle(ChromeButtonStyle()).help("Settings (⌘,)")
            Button { model.addProject() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(ChromeButtonStyle()).help("Add Project (⌘⇧O)")
            Spacer()
            WorkspaceDots()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay(alignment: .top) { Hairline() }
    }
}

struct WorkspaceDots: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                let selected = w.id == model.selectedWorkspaceId
                Circle()
                    .fill(selected ? Color(hex: w.color) : T.text3.opacity(0.6))
                    .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                    .padding(3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectWorkspace(w.id) }
                    .help(w.name)
            }
            Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(T.text3).help("New workspace")
                .popover(isPresented: $adding) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New workspace").font(T.headline)
                        TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(create)
                        HStack { Spacer(); Button("Create", action: create).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    }.padding(14)
                }
        }
    }

    private func create() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.createWorkspace(name: n)
        newName = ""
        adding = false
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
            if hover {
                NewSessionMenu(projectId: project.id, compact: true)
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
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
            } else if sessions.isEmpty {
                Text("empty").font(T.caption).foregroundStyle(T.text3)
            }
        }
        .padding(.leading, 30).padding(.trailing, 8)
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
                Button { model.updateProject(project.id, ["color": c]) } label: { Text(colorName(c)) }
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

    func colorName(_ hex: String) -> String {
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
    var indent: CGFloat = 30
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
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(T.text2)
            } else {
                ActivityIndicator(session: session)
            }
        }
        .opacity(session.isDormant ? 0.45 : 1)
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .frame(height: m.rowH)
        .background(RoundedRectangle(cornerRadius: m.rowR, style: .continuous).fill(selected ? T.selection : hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
