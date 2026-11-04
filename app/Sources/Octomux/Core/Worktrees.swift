import AppKit
import SwiftUI

struct GitError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    func contains(_ s: String) -> Bool { message.contains(s) }
}

struct Worktree: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let branch: String     // "feat/x" or "(detached)"
    let isMain: Bool
    var head = ""          // short commit
    var detached = false
    /// `git worktree lock` reason ("" when locked without one); nil when not locked.
    var locked: String? = nil

    /// Sidebar label: the branch, or for a detached HEAD the folder name.
    var label: String { detached ? (path as NSString).lastPathComponent : branch }
}

/// `git worktree list` per project, refreshed in the background; create / remove.
final class Worktrees: ObservableObject {
    static let shared = Worktrees()
    @Published private var lists: [String: [Worktree]] = [:]
    private var fetched: [String: Date] = [:]
    private let queue = DispatchQueue(label: "octomux.worktrees", qos: .utility)

    /// Linked worktrees (not the main checkout) of a project.
    func linked(_ projectPath: String) -> [Worktree] {
        refreshIfStale(projectPath)
        return (lists[projectPath] ?? []).filter { !$0.isMain && !hidden.contains($0.path) }
    }

    /// Worktrees the user hid from the sidebar (e.g. ones another tool made and manages).
    @Published private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey: "octomux.hiddenWorktrees") ?? [])
    func hide(_ path: String) {
        hidden.insert(path)
        UserDefaults.standard.set(Array(hidden), forKey: "octomux.hiddenWorktrees")
    }
    func hiddenPaths(of projectPath: String) -> [String] {
        (lists[projectPath] ?? []).map(\.path).filter { hidden.contains($0) }
    }
    func unhide(_ paths: [String]) {
        hidden.subtract(paths)
        UserDefaults.standard.set(Array(hidden), forKey: "octomux.hiddenWorktrees")
    }
    func info(_ path: String) -> Worktree? { lists.values.lazy.flatMap { $0 }.first { $0.path == path } }

    func refresh(_ projectPath: String) {
        fetched[projectPath] = nil
        refreshIfStale(projectPath)
    }

    private func refreshIfStale(_ path: String) {
        if let t = fetched[path], Date().timeIntervalSince(t) < 6 { return }
        fetched[path] = Date()
        queue.async {
            let list = Self.parse(GitInfo.git(["worktree", "list", "--porcelain"], in: path) ?? "")
            DispatchQueue.main.async { if self.lists[path] != list { self.lists[path] = list } }
        }
    }

    static func parse(_ out: String) -> [Worktree] {
        var res: [Worktree] = []
        for block in out.components(separatedBy: "\n\n") {
            var path = "", branch = "(detached)", head = "", detached = false
            var locked: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5).prefix(7)) }
                if line == "detached" { detached = true }
                if line == "locked" { locked = "" } else if line.hasPrefix("locked ") { locked = String(line.dropFirst(7)) }
            }
            if !path.isEmpty {
                res.append(Worktree(path: path, branch: branch, isMain: res.isEmpty, head: head, detached: detached, locked: locked))
            }
        }
        return res
    }

    /// `<parent>/<repo>.worktrees/<branch-slug>`, or `<root>/<repo>/<branch-slug>` with a worktree folder set
    /// (Settings → Projects, or for all projects; this Mac's projects only).
    static func defaultPath(project: String, branch: String) -> String {
        defaultPath(project: project, branch: branch, root: customRoot(project))
    }

    static func defaultPath(project: String, branch: String, root: String?) -> String {
        let url = URL(fileURLWithPath: project)
        let slug = branch.replacingOccurrences(of: "/", with: "-").filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        if let root { return URL(fileURLWithPath: root).appendingPathComponent(url.lastPathComponent).appendingPathComponent(slug).path }
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".worktrees").appendingPathComponent(slug).path
    }

    /// The worktree folder set for this project (project setting, else the global one); nil: next to the project.
    static func customRoot(_ projectPath: String) -> String? {
        let m = AppModel.shared
        guard !m.host(forPath: projectPath).0.isRemote else { return nil }
        let pid = m.state.projects.first { $0.path == projectPath }?.id
        guard let v = m.setting("worktrees.root", project: pid)?.string?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return (v as NSString).expandingTildeInPath
    }

    /// Made where Octomux puts worktrees (next to the project, or under the worktree folder).
    static func isOurs(project: String, path: String) -> Bool {
        if path.hasPrefix(project + ".worktrees/") { return true }
        guard let root = customRoot(project) else { return false }
        return path.hasPrefix(defaultPath(project: project, branch: "x", root: root).dropLast(1))
    }

    /// Creates a new branch in a new worktree (or checks out an existing branch).
    static func create(project: String, branch: String) -> Result<String, GitError> {
        let path = defaultPath(project: project, branch: branch)
        if !AppModel.shared.host(forPath: project).0.isRemote {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let exists = GitInfo.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: project) != nil
        let args = exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path]
        let (ok, err) = gitWithError(args, in: project)
        shared.refresh(project)
        return ok ? .success(path) : .failure(GitError(message: err))
    }

    static func remove(project: String, path: String, force: Bool, locked: Bool = false) -> Result<Void, GitError> {
        var args = ["worktree", "remove"]
        if force || locked { args.append("--force") }
        if locked { args.append("--force") }   // git wants -f twice for a locked worktree
        args.append(path)
        let (ok, err) = gitWithError(args, in: project)
        shared.refresh(project)
        return ok ? .success(()) : .failure(GitError(message: err))
    }

    static func gitWithError(_ args: [String], in dir: String) -> (Bool, String) {
        let (h, c) = AppModel.shared.host(forPath: dir)
        if h.isRemote {
            do {
                let r = try c.callSync("git.run", ["cwd": dir, "args": args]) as? [String: Any]
                return ((r?["ok"] as? Bool) ?? false, (r?["stderr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { return (false, "\(error)") }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "\(error)") }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension AppModel {
    func newWorktree(project: Project, branch: String, open profileId: String?, prompt: String? = nil) {
        let b = branch.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Worktrees.create(project: project.path, branch: b)
            DispatchQueue.main.async {
                switch r {
                case .success(let path):
                    self.runWorktreeSetup(project: project, path: path, branch: b)
                    let task = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let profileId, let task, !task.isEmpty, let kind = self.profile(profileId)?.kind {
                        self.newSession(profileId: profileId, projectId: project.id, worktree: path, prompt: task, chat: true,
                                        extraArgs: ChatLaunchOptions.load(kind).args(kind)) { ChatFirstMessage.set($0, task) }
                    } else {
                        self.newSession(profileId: profileId, projectId: project.id, worktree: path)
                    }
                case .failure(let e): self.lastError = "git worktree add failed: \(e)"
                }
            }
        }
    }

    // MARK: Worktree scripts (Settings → Projects)

    func worktreeScript(_ which: String, project: Project) -> String? {
        let v = setting("worktrees.\(which)", project: project.id)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return v?.isEmpty == false ? v : nil
    }

    /// What a script sees: the main checkout, the worktree and its branch.
    static func worktreeEnv(project: Project, path: String, branch: String) -> String {
        "export OCTOMUX_PROJECT_PATH=\(project.path.shellQuoted) OCTOMUX_WORKTREE=\(path.shellQuoted) OCTOMUX_BRANCH=\(branch.shellQuoted)"
    }

    /// The setup script runs in the new worktree, in the dock, so its output stays visible.
    func runWorktreeSetup(project: Project, path: String, branch: String) {
        guard let script = worktreeScript("setup", project: project) else { return }
        setDockOpen(project.id, true)
        let cmd = Self.worktreeEnv(project: project, path: path, branch: branch) + "; " + script
        client(for: project.id).call("session.create", ["project_id": project.id, "placement": "dock", "worktree": path,
                                                         "command": cmd, "title": "Setup \(branch)"], completion: report)
    }

    /// The teardown script, before the folder goes (this Mac only, up to 2 minutes). Nil when it passed or
    /// there is none; else what went wrong.
    func runWorktreeTeardown(project: Project, path: String) -> String? {
        guard let script = worktreeScript("teardown", project: project) else { return nil }
        if host(for: project.id).isRemote { return "teardown scripts run on this Mac only; skipped" }
        let branch = Worktrees.shared.info(path)?.branch ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", Self.worktreeEnv(project: project, path: path, branch: branch) + "; " + script]
        p.currentDirectoryURL = URL(fileURLWithPath: path)
        // Output to a file: a pipe nobody reads while we wait would stall a chatty script.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-teardown-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let fh = try? FileHandle(forWritingTo: log) else { return "teardown didn't start: no log file" }
        p.standardOutput = fh
        p.standardError = fh
        do { try p.run() } catch { return "teardown didn't start: \(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        try? fh.close()
        if p.isRunning { p.terminate(); return "teardown script still running after 2 minutes; stopped it" }
        let text = String(decoding: ((try? Data(contentsOf: log)) ?? Data()).suffix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? nil : "teardown script exited with \(p.terminationStatus)\(text.isEmpty ? "" : ": \(text)")"
    }

    /// `git branch -d` (only when merged; -D after the user agreed to lose its commits).
    static func deleteBranch(project: String, branch: String, force: Bool) -> (Bool, String) {
        Worktrees.gitWithError(["branch", force ? "-D" : "-d", branch], in: project)
    }

    /// Closes the worktree's sessions, runs the teardown script, removes it (asks before discarding changes),
    /// and deletes its branch when the box is ticked.
    func removeWorktree(project: Project, path: String) {
        let info = Worktrees.shared.info(path)
        let lock = info?.locked
        let branch = info.flatMap { $0.detached || $0.isMain ? nil : $0.branch }
        let a = NSAlert()
        a.messageText = "Remove worktree “\((path as NSString).lastPathComponent)”?"
        if let lock {
            a.informativeText = "It is locked\(lock.isEmpty ? "" : " (“\(lock)”)"), usually by the tool that created it, which may still be using it. "
                + "Removing it deletes the folder, uncommitted changes included. To only get it out of the sidebar, use Hide instead."
            a.addButton(withTitle: "Unlock and Remove").hasDestructiveAction = true
        } else {
            a.informativeText = "Its sessions are closed and the folder is deleted."
                + (worktreeScript("teardown", project: project) != nil ? " The project's teardown script runs first." : "")
            a.addButton(withTitle: "Remove").hasDestructiveAction = true
        }
        a.addButton(withTitle: "Cancel")
        var box: NSButton?
        if let branch {
            let b = NSButton(checkboxWithTitle: "Also delete the branch “\(branch)”", target: nil, action: nil)
            b.state = (setting("worktrees.delete_branch", project: project.id)?.bool ?? false) ? .on : .off
            a.accessoryView = b
            box = b
        }
        guard a.runModal() == .alertFirstButtonReturn else { return }
        performWorktreeRemoval(project: project, path: path, locked: lock != nil, dropBranch: box?.state == .on ? branch : nil)
    }

    /// After the question: close its sessions, teardown, `git worktree remove`, then the branch.
    func performWorktreeRemoval(project: Project, path: String, locked: Bool, dropBranch: String?) {
        let lock: String? = locked ? "" : nil
        for s in state.sessions where s.worktree == path { remove(s.id, confirm: false) }
        DispatchQueue.global(qos: .userInitiated).async {
            var notes: [String] = []
            if let t = self.runWorktreeTeardown(project: project, path: path) { notes.append(t) }
            var r = Worktrees.remove(project: project.path, path: path, force: lock != nil, locked: lock != nil)
            if lock == nil, case .failure(let e) = r, e.contains("modified or untracked") || e.contains("--force") {
                var force = false
                DispatchQueue.main.sync {
                    let b = NSAlert()
                    b.messageText = "The worktree has uncommitted changes"
                    b.informativeText = "Remove anyway and discard them?"
                    b.addButton(withTitle: "Discard and Remove").hasDestructiveAction = true
                    b.addButton(withTitle: "Cancel")
                    force = b.runModal() == .alertFirstButtonReturn
                }
                if force { r = Worktrees.remove(project: project.path, path: path, force: true) } else { return }
            }
            if case .failure(let e) = r { notes.append("git worktree remove failed: \(e)") }
            if case .success = r, let dropBranch {
                var (ok, err) = Self.deleteBranch(project: project.path, branch: dropBranch, force: false)
                if !ok, err.contains("not fully merged") {
                    var force = false
                    DispatchQueue.main.sync {
                        let b = NSAlert()
                        b.messageText = "“\(dropBranch)” is not merged"
                        b.informativeText = "Its commits are not in another branch. Delete it anyway and lose them?"
                        b.addButton(withTitle: "Delete Branch").hasDestructiveAction = true
                        b.addButton(withTitle: "Keep Branch")
                        force = b.runModal() == .alertFirstButtonReturn
                    }
                    if force { (ok, err) = Self.deleteBranch(project: project.path, branch: dropBranch, force: true) } else { ok = true }
                }
                if !ok { notes.append("git branch -d \(dropBranch) failed: \(err)") }
                Worktrees.shared.refresh(project.path)
            }
            DispatchQueue.main.async { if !notes.isEmpty { self.lastError = notes.joined(separator: " · ") } }
        }
    }
}

/// Sheet: new branch + worktree, then open a terminal or agent in it.
struct NewWorktreeSheet: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    let done: () -> Void
    @State private var branch = ""
    @State private var openWith = "__pinned"
    @State private var task = ""
    @State private var naming: CommitMessageGen.Run?
    @State private var nameError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New worktree").font(T.title)
            Text("Creates a branch in its own folder, so an agent can work there without touching your checkout."
                 + (model.worktreeScript("setup", project: project) != nil ? " The project's setup script then runs in the dock." : ""))
                .font(T.body).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            TextField("Task for the agent (optional)", text: $task, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
            HStack(spacing: 6) {
                TextField("Branch name (e.g. feat/usage-limits)", text: $branch).textFieldStyle(.roundedBorder).onSubmit(create)
                Button { suggestName() } label: {
                    if naming != nil { ProgressView().controlSize(.small).frame(width: 14, height: 14) } else { Image(systemName: "sparkles") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && naming == nil)
                .help(naming != nil ? "Stop" : "Name the branch from the task (asks \(CommitMessageGen.profile(model: model, project: project.id)?.name ?? "an agent"))")
            }
            if !nameError.isEmpty { Text(nameError).font(T.caption).foregroundStyle(T.amber) }
            if !branch.isEmpty {
                Text(Worktrees.defaultPath(project: project.path, branch: branch).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(T.mono(11)).foregroundStyle(T.text3)
            }
            Picker("Open with", selection: $openWith) {
                ForEach(model.enabledProfiles) { p in Text(p.name).tag(p.id) }
                Text("Terminal").tag("__terminal")
                Text("Nothing").tag("__none")
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create") { create() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(branch.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(T.surface)
        .onAppear {
            openWith = (model.pinnedProfiles.first ?? model.enabledProfiles.first)?.id ?? "__terminal"
            if branch.isEmpty, let pattern = model.setting("worktrees.branch_pattern", project: project.id)?.string {
                let taken = Set(GitInfo.branches(in: project.path, remotes: false))
                branch = BranchNames.fromPattern(pattern, project: project) { taken.contains($0) } ?? ""
            }
        }
        .onDisappear { naming?.cancel() }
    }

    private func suggestName() {
        if let n = naming { n.cancel(); naming = nil; return }
        nameError = ""
        naming = BranchNames.suggest(task: task, project: project, model: model) { r in
            naming = nil
            switch r {
            case .success(let b): branch = b
            case .failure(let e): nameError = e.localizedDescription
            }
        }
    }

    private func create() {
        guard !branch.isEmpty else { return }
        switch openWith {
        case "__none":
            DispatchQueue.global().async {
                let r = Worktrees.create(project: project.path, branch: branch)
                if case .failure(let e) = r { DispatchQueue.main.async { model.lastError = "git worktree add failed: \(e)" } }
            }
        case "__terminal": model.newWorktree(project: project, branch: branch, open: nil)
        default: model.newWorktree(project: project, branch: branch, open: openWith, prompt: task)
        }
        done()
    }
}
