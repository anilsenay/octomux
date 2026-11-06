import SwiftUI

/// Settings → Projects: one project's name, folder, color, icon, worktree folder and scripts, plus the
/// worktree defaults for all projects.
struct ProjectSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection
    @State private var name = ""
    @State private var setup = ""
    @State private var teardown = ""
    @State private var styleGlobal = ""
    @State private var styleProject = ""
    @State private var branchPattern = ""
    @State private var prStyle = ""
    /// Models of the commit-message agent when it is Codex (nil: not asked yet).
    @State private var codexList: [(id: String, name: String)]?
    @State private var codexListFor: String?
    @State private var loadedFor: String?

    var body: some View {
        let projects = model.state.projects.filter { !$0.archived }
        if let p = projects.first(where: { $0.id == sel.project }) ?? model.currentProject ?? projects.first {
            picker(p, projects)
            projectGroup(p)
            worktreeGroup(p)
            scriptsGroup(p)
            commitGroup(p)
            defaultsGroup
            Color.clear.frame(height: 0)
                .onDisappear { saveStyle(styleGlobal, scope: "global"); savePattern(); savePR() }
                .onAppear { load(p) }
                .onChange(of: p.id) { _, _ in load(p) }
        } else {
            Text("Add a project first (⌘⇧O).").font(.system(size: T.k * 13)).foregroundStyle(T.text2)
            defaultsGroup
        }
    }

    // MARK: Groups

    private func picker(_ p: Project, _ projects: [Project]) -> some View {
        HStack(spacing: 10) {
            Text("Project").font(.system(size: T.k * 12.5)).foregroundStyle(T.text2)
            Menu {
                ForEach(model.orderedWorkspaces) { w in
                    let ps = projects.filter { $0.workspaceId == w.id }.sorted { $0.sort < $1.sort }
                    if !ps.isEmpty {
                        Section(w.name) {
                            ForEach(ps) { x in Button(x.name) { sel.project = x.id } }
                        }
                    }
                }
            } label: {
                Text(p.name).font(.system(size: T.k * 13, weight: .medium))
            }
            .menuStyle(.button).fixedSize()
            ProjectIconView(project: p, size: 18)
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func projectGroup(_ p: Project) -> some View {
        let remote = model.host(for: p.id).isRemote
        return SettingsGroup("Project") {
            SettingRow("Name") {
                TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { commitName(p) }
            }
            SettingRow("Folder", desc: (p.path as NSString).abbreviatingWithTildeInPath + (remote ? " on \(model.host(for: p.id).name)" : ""), mono: true) {
                if !remote {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button("Copy Path") { copy(p.path) }.buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("Color") {
                ColorDots(selected: p.color) { model.updateProject(p.id, ["color": $0]) }
            }
            SettingRow("Icon", desc: iconDesc(p)) {
                ProjectIconView(project: p, size: 22)
                Menu("Change") {
                    Button("Folder") { model.updateProject(p.id, ["icon": ["kind": "folder"]]) }
                    Menu("Mascot") {
                        ForEach(Mascot.names, id: \.self) { m in
                            Button(m.capitalized) { model.updateProject(p.id, ["icon": ["kind": "mascot", "value": m]]) }
                        }
                    }
                    Button("Emoji…") { ProjectEditor.emoji(p) }
                    if !remote {
                        Button("Image…") { ProjectEditor.image(p) }
                        if let found = ProjectEditor.detectLogo(p.path) {
                            Button("Use \(URL(fileURLWithPath: found).lastPathComponent)") {
                                model.updateProject(p.id, ["icon": ["kind": "image", "value": found]])
                            }
                        }
                    }
                }
                .menuStyle(.button).fixedSize()
            }
        }
        .onDisappear { commitName(p) }
    }

    private func worktreeGroup(_ p: Project) -> some View {
        let remote = model.host(for: p.id).isRemote
        let own = model.settingValue("worktrees.root", scope: "project:\(p.id)")?.string
        let ownDelete = model.settingValue("worktrees.delete_branch", scope: "project:\(p.id)")?.bool
        return SettingsGroup("Worktrees") {
            SettingRow("Worktree folder", desc: remote ? "Worktrees of a project on another host go next to it."
                       : "New worktrees go to " + Self.pattern(p.path) + ".",
                       modified: own != nil, onReset: { model.setSetting("worktrees.root", nil, scope: "project:\(p.id)") }) {
                if !remote {
                    Button("Choose…") { if let f = chooseFolder() { model.setSetting("worktrees.root", f, scope: "project:\(p.id)") } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingRow("Delete the branch with its worktree", desc: "Ticks “Also delete the branch” when you remove a worktree. A branch that isn't merged asks first.",
                       modified: ownDelete != nil, onReset: { model.setSetting("worktrees.delete_branch", nil, scope: "project:\(p.id)") }) {
                SettingSwitch(isOn: Binding(get: { model.setting("worktrees.delete_branch", project: p.id)?.bool ?? false },
                                            set: { model.setSetting("worktrees.delete_branch", $0, scope: "project:\(p.id)") }))
            }
        }
    }

    private func scriptsGroup(_ p: Project) -> some View {
        SettingsGroup("Scripts", desc: "Shell commands for this project's worktrees. They get OCTOMUX_PROJECT_PATH (the main checkout), OCTOMUX_WORKTREE and OCTOMUX_BRANCH. Commands you run often belong in the dock's Actions (▶).") {
            script("Setup", desc: "Runs in a new worktree, in the dock, right after it is created: install dependencies, copy .env files.",
                   text: $setup, key: "setup", p)
            script("Teardown", desc: "Runs in the worktree before it is removed (this Mac only, up to 2 minutes): stop its services, clean up.",
                   text: $teardown, key: "teardown", p)
        }
    }

    private func commitGroup(_ p: Project) -> some View {
        let own = model.settingValue("commit_message.instructions", scope: "project:\(p.id)")?.string
        return SettingsGroup("Commit messages", desc: "✨ next to the commit message box in the Changes panel asks an agent for a message.") {
            SettingRow("Style for this project", desc: own == nil ? "Uses the style for all projects below." : "Used instead of the style for all projects.",
                       modified: own != nil, onReset: { model.setSetting("commit_message.instructions", nil, scope: "project:\(p.id)"); styleProject = "" }) {
                TextField("e.g. Conventional Commits, scope = crate", text: $styleProject, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(width: 280)
                    .onSubmit { saveStyle(styleProject, scope: "project:\(p.id)") }
            }
        }
        .onDisappear { saveStyle(styleProject, scope: "project:\(p.id)") }
    }

    private func loadCodexModels(_ p: Profile?) {
        guard let p, codexListFor != p.id else { return }
        codexListFor = p.id
        DispatchQueue.global(qos: .userInitiated).async {
            let list = CommitMessageGen.codexModels(p)
            DispatchQueue.main.async { codexList = list }
        }
    }

    private func savePR() {
        let t = prStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != (model.settingValue("pr.instructions", scope: "global")?.string ?? "") { model.setSetting("pr.instructions", t.isEmpty ? nil : t) }
    }

    private func savePattern() {
        let t = branchPattern.trimmingCharacters(in: .whitespaces)
        if t != (model.settingValue("worktrees.branch_pattern", scope: "global")?.string ?? "") { model.setSetting("worktrees.branch_pattern", t.isEmpty ? nil : t) }
    }

    private func saveStyle(_ v: String, scope: String) {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let cur = model.settingValue("commit_message.instructions", scope: scope)?.string ?? ""
        if t != cur { model.setSetting("commit_message.instructions", t.isEmpty ? nil : t, scope: scope) }
    }

    private var defaultsGroup: some View {
        let root = model.settingValue("worktrees.root", scope: "global")?.string
        let agents = model.enabledProfiles.filter { $0.kind == .claude || $0.kind == .codex }
        let agent = CommitMessageGen.profile(model: model, project: nil)
        let storedModel = model.settingValue("commit_message.model", scope: "global")?.string
        return SettingsGroup("All projects", desc: "Used by every project that doesn't set its own.") {
            SettingRow("Worktree folder", desc: root.map { "Worktrees go to " + ($0 as NSString).abbreviatingWithTildeInPath + "/<project>/<branch>." }
                       ?? "Next to each project, in <project>.worktrees/<branch>. Projects on other hosts always use this.") {
                if root != nil {
                    Button("Next to Project") { model.setSetting("worktrees.root", nil) }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Choose…") { if let f = chooseFolder() { model.setSetting("worktrees.root", f) } }.buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("Branch name", desc: "Filled in when you make a worktree: {user}, {date}, {project}, {n} (the first number not taken). Empty: you type it, or ✨ names it from the task.") {
                TextField("e.g. {user}/{date}-{n}", text: $branchPattern).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { savePattern() }
            }
            SettingRow("Delete the branch with its worktree", desc: "The default for the checkbox when you remove a worktree.") {
                SettingSwitch(isOn: Binding(get: { model.settingValue("worktrees.delete_branch", scope: "global")?.bool ?? false },
                                            set: { model.setSetting("worktrees.delete_branch", $0 ? true : nil) }))
            }
            SettingRow("Commit message agent", desc: "Runs once in the background with the diff (\(agent?.kind == .codex ? "codex exec" : "claude -p"), no tools, nothing saved). The diff goes to its provider like any agent prompt; each message uses a little of your plan.") {
                Picker("", selection: Binding(get: { agent?.id ?? "" }, set: { model.setSetting("commit_message.profile", $0) })) {
                    ForEach(agents) { a in Text(a.name).tag(a.id) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow("Commit message model", desc: agent?.kind == .codex ? "The models your Codex offers; Codex default is the one in its config." : "Haiku is fast and enough for a commit message.") {
                if agent?.kind == .codex, let codexList, !codexList.isEmpty {
                    Picker("", selection: Binding(get: { storedModel ?? "" }, set: { model.setSetting("commit_message.model", $0.isEmpty ? nil : $0) })) {
                        Text("Codex default").tag("")
                        Divider()
                        ForEach(codexList, id: \.id) { m in Text(m.name).tag(m.id) }
                        if let cur = storedModel, !cur.isEmpty, !codexList.contains(where: { $0.id == cur }) { Text(cur).tag(cur) }
                    }
                    .labelsHidden().fixedSize()
                } else if agent?.kind == .codex {
                    TextField(codexList == nil ? "Loading models…" : "default", text: Binding(get: { storedModel ?? "" }, set: { model.setSetting("commit_message.model", $0.isEmpty ? nil : $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                        .onAppear { loadCodexModels(agent) }
                } else {
                    Picker("", selection: Binding(get: { storedModel ?? "haiku" }, set: { model.setSetting("commit_message.model", $0 == "haiku" ? nil : $0) })) {
                        Text("Haiku").tag("haiku"); Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("CLI default").tag("default")
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingRow("Pull request style", desc: "Extra instructions for ✨ in Create Pull Request, e.g. “link the Jira issue from the branch name”.") {
                TextField("Summary and Testing sections", text: $prStyle, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(width: 280)
                    .onSubmit { savePR() }
            }
            SettingRow("Commit message style", desc: "Extra instructions, e.g. “Conventional Commits”, “one line only”. Without any, it follows the repository's recent commits.") {
                TextField("Follow the repository's style", text: $styleGlobal, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(width: 280)
                    .onSubmit { saveStyle(styleGlobal, scope: "global") }
            }
        }
    }

    private func script(_ title: String, desc: String, text: Binding<String>, key: String, _ p: Project) -> some View {
        let saved = model.settingValue("worktrees.\(key)", scope: "project:\(p.id)")?.string ?? ""
        return SettingBlock {
            HStack {
                Text(title).font(.system(size: T.k * 13, weight: .medium))
                Spacer()
                if text.wrappedValue != saved {
                    Button("Revert") { text.wrappedValue = saved }.buttonStyle(SecondaryButtonStyle())
                    Button("Save") {
                        let v = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.setSetting("worktrees.\(key)", v.isEmpty ? nil : v, scope: "project:\(p.id)")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            Text(desc).font(.system(size: T.k * 11.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text).font(T.mono(12)).frame(height: 64)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
        }
        .settingAnchor(title)
    }

    // MARK: Helpers

    /// Where a new worktree of this project goes, with `<branch>` for the branch's folder.
    static func pattern(_ project: String) -> String {
        let path = (Worktrees.defaultPath(project: project, branch: "b") as NSString).deletingLastPathComponent
        return (path as NSString).abbreviatingWithTildeInPath + "/<branch>"
    }

    private func load(_ p: Project) {
        guard loadedFor != p.id else { return }
        loadedFor = p.id
        name = p.name
        styleProject = model.settingValue("commit_message.instructions", scope: "project:\(p.id)")?.string ?? ""
        styleGlobal = model.settingValue("commit_message.instructions", scope: "global")?.string ?? ""
        branchPattern = model.settingValue("worktrees.branch_pattern", scope: "global")?.string ?? ""
        prStyle = model.settingValue("pr.instructions", scope: "global")?.string ?? ""
        setup = model.settingValue("worktrees.setup", scope: "project:\(p.id)")?.string ?? ""
        teardown = model.settingValue("worktrees.teardown", scope: "project:\(p.id)")?.string ?? ""
    }

    private func commitName(_ p: Project) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != p.name { model.updateProject(p.id, ["name": n]) }
    }

    private func iconDesc(_ p: Project) -> String {
        switch p.icon.kind {
        case "mascot": return "Mascot: \(p.icon.value?.capitalized ?? "")"
        case "symbol": return "Symbol"
        case "emoji": return "Emoji"
        case "image": return ((p.icon.value ?? "") as NSString).lastPathComponent
        default: return "The project's initial on its color"
        }
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let u = panel.url else { return nil }
        return (u.path as NSString).abbreviatingWithTildeInPath
    }
}
