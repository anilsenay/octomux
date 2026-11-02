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
}

/// `git worktree list` per project, refreshed in the background; create / remove.
final class Worktrees: ObservableObject {
    static let shared = Worktrees()
    @Published private var lists: [String: [Worktree]] = [:]
    private var fetched: [String: Date] = [:]
    private let queue = DispatchQueue(label: "ade.worktrees", qos: .utility)

    /// Linked worktrees (not the main checkout) of a project.
    func linked(_ projectPath: String) -> [Worktree] {
        refreshIfStale(projectPath)
        return (lists[projectPath] ?? []).filter { !$0.isMain }
    }

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
            var path = "", branch = "(detached)"
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            }
            if !path.isEmpty { res.append(Worktree(path: path, branch: branch, isMain: res.isEmpty)) }
        }
        return res
    }

    /// `<parent>/<repo>.worktrees/<branch-slug>`
    static func defaultPath(project: String, branch: String) -> String {
        let url = URL(fileURLWithPath: project)
        let slug = branch.replacingOccurrences(of: "/", with: "-").filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".worktrees").appendingPathComponent(slug).path
    }

    /// Creates a new branch in a new worktree (or checks out an existing branch).
    static func create(project: String, branch: String) -> Result<String, GitError> {
        let path = defaultPath(project: project, branch: branch)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let exists = GitInfo.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: project) != nil
        let args = exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path]
        let (ok, err) = gitWithError(args, in: project)
        shared.refresh(project)
        return ok ? .success(path) : .failure(GitError(message: err))
    }

    static func remove(project: String, path: String, force: Bool) -> Result<Void, GitError> {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        let (ok, err) = gitWithError(args, in: project)
        shared.refresh(project)
        return ok ? .success(()) : .failure(GitError(message: err))
    }

    static func gitWithError(_ args: [String], in dir: String) -> (Bool, String) {
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
    func newWorktree(project: Project, branch: String, open profileId: String?) {
        let b = branch.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Worktrees.create(project: project.path, branch: b)
            DispatchQueue.main.async {
                switch r {
                case .success(let path): self.newSession(profileId: profileId, projectId: project.id, worktree: path)
                case .failure(let e): self.lastError = "git worktree add failed: \(e)"
                }
            }
        }
    }

    /// Closes the worktree's sessions and removes it (asks before discarding changes).
    func removeWorktree(project: Project, path: String) {
        let a = NSAlert()
        a.messageText = "Remove worktree “\((path as NSString).lastPathComponent)”?"
        a.informativeText = "Its sessions are closed and the folder is deleted. The branch is kept."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for s in state.sessions where s.worktree == path { remove(s.id, confirm: false) }
        DispatchQueue.global(qos: .userInitiated).async {
            var r = Worktrees.remove(project: project.path, path: path, force: false)
            if case .failure(let e) = r, e.contains("modified or untracked") || e.contains("--force") {
                var force = false
                DispatchQueue.main.sync {
                    let b = NSAlert()
                    b.messageText = "The worktree has uncommitted changes"
                    b.informativeText = "Remove anyway and discard them?"
                    b.addButton(withTitle: "Discard and Remove")
                    b.addButton(withTitle: "Cancel")
                    force = b.runModal() == .alertFirstButtonReturn
                }
                if force { r = Worktrees.remove(project: project.path, path: path, force: true) } else { return }
            }
            DispatchQueue.main.async {
                if case .failure(let e) = r { self.lastError = "git worktree remove failed: \(e)" }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New worktree").font(T.title)
            Text("Creates a branch in its own folder next to the project, so an agent can work there without touching your checkout.")
                .font(T.body).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            TextField("Branch name (e.g. feat/usage-limits)", text: $branch).textFieldStyle(.roundedBorder).onSubmit(create)
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
        .onAppear { openWith = (model.pinnedProfiles.first ?? model.enabledProfiles.first)?.id ?? "__terminal" }
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
        default: model.newWorktree(project: project, branch: branch, open: openWith)
        }
        done()
    }
}
