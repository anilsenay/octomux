import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ade.collapsed") ?? [])

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.projects) { p in
                        ProjectRow(project: p, collapsed: collapsed.contains(p.id)) {
                            if collapsed.contains(p.id) { collapsed.remove(p.id) } else { collapsed.insert(p.id) }
                            UserDefaults.standard.set(Array(collapsed), forKey: "ade.collapsed")
                        }
                        if !collapsed.contains(p.id) {
                            ForEach(model.sessions(ofProject: p.id)) { s in
                                SessionRow(session: s)
                            }
                            let dock = model.state.sessions.filter { $0.projectId == p.id && $0.placement == .dock }
                            if !dock.isEmpty {
                                Text("\(dock.count) in dock").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 34)
                            }
                        }
                    }
                    if model.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No projects in this workspace").font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Add Project…") { model.addProject() }.controlSize(.small)
                        }.padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            footer
        }
        .background(Palette.sidebarBG)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: model.workspace?.color ?? "#888")).frame(width: 8, height: 8)
            Text(model.workspace?.name ?? "ADE").font(.system(size: 13, weight: .semibold))
            Spacer()
            if !model.connected {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange).help("Reconnecting to the ADE daemon…")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: {
                Image(systemName: "gearshape")
            }.buttonStyle(ChromeButtonStyle()).help("Settings (⌘,)")
            Button { model.addProject() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(ChromeButtonStyle()).help("Add Project (⌘⇧O)")
            Spacer()
            WorkspaceDots()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

struct WorkspaceDots: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                let selected = w.id == model.selectedWorkspaceId
                Circle()
                    .fill(selected ? Color(hex: w.color) : Color.secondary.opacity(0.45))
                    .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                    .padding(2)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectWorkspace(w.id) }
                    .help(w.name)
            }
            Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("New workspace")
                .popover(isPresented: $adding) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New workspace").font(.headline)
                        TextField("Name", text: $newName).frame(width: 180).onSubmit(create)
                        HStack { Spacer(); Button("Create", action: create).keyboardShortcut(.defaultAction) }
                    }.padding(12)
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
    let project: Project
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            ProjectIconView(project: project)
                .frame(width: 18)
            Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if collapsed {
                let n = model.sessions(ofProject: project.id).filter { $0.activity == .needsInput || $0.unread }.count
                if n > 0 { Circle().fill(Color.orange).frame(width: 6, height: 6) }
            }
            Spacer()
            if hover {
                NewSessionMenu(projectId: project.id, compact: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 1) { toggle(); model.selectProject(project.id) }
        .contextMenu { ProjectMenu(project: project) }
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
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
        OpenInMenu(path: project.path)
        Button("Copy Path") { copy(project.path) }
        Divider()
        if model.state.workspaces.count > 1 {
            Menu("Move to Workspace") {
                ForEach(model.state.workspaces.filter { $0.id != project.workspaceId }) { w in
                    Button(w.name) { model.updateProject(project.id, ["workspace_id": w.id]) }
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
    @State private var hover = false
    @State private var editTitle = ""

    var selected: Bool { model.focusedSessionId == session.id && model.activeTab?.layout.sessions.contains(session.id) == true }

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(icon: iconName(for: session, model: model), size: 11).frame(width: 14)
            if model.renamingSessionId == session.id {
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        model.rename(session.id, to: editTitle)
                        model.renamingSessionId = nil
                    }
                    .onExitCommand { model.renamingSessionId = nil }
                    .onAppear { editTitle = session.displayTitle }
            } else {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: session.unread ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hover {
                if session.isDormant {
                    Button { model.restart(session.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help(session.kind == .agent ? "Resume" : "Restart")
                    Button { model.remove(session.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Remove")
                } else {
                    Button { model.stop(session.id) } label: { Image(systemName: "stop.fill").font(.system(size: 8)) }
                        .buttonStyle(.plain).help("Stop")
                }
            } else {
                ActivityIndicator(session: session)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.primary)
        .opacity(session.isDormant ? 0.45 : 1)
        .padding(.leading, 30)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : hover ? Color.primary.opacity(0.05) : .clear).padding(.horizontal, 6))
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
        if let aid = session.agentSessionId {
            Button("Copy Session ID") { copy(aid) }
        }
        Button("Copy Transcript Path") { copy(TranscriptLocator.path(for: session, model: model) ?? "") }
            .disabled(TranscriptLocator.path(for: session, model: model) == nil)
        Button("Copy Screen Text") {
            model.client.call("session.screen_text", ["id": session.id]) { r in
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
            Button("Move to Dock") { model.client.call("session.move", ["id": session.id, "placement": "dock"]) }
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
