import AppKit
import Foundation

/// An app-side tab next to the session tabs: a file, the working-tree changes, or a commit.
/// Lives only in the app (UserDefaults), never in the daemon or the sidebar.
struct DocTab: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case file(String)            // path relative to workPath
        case changes
        case commit(String, String)  // hash, subject
        case newChat                 // start screen of a chat session (no agent running yet)
    }
    var id: String
    var projectId: String
    var workPath: String
    var kind: Kind

    var title: String {
        switch kind {
        case .file(let rel): return (rel as NSString).lastPathComponent
        case .changes: return "Changes"
        case .commit(let h, let subject): return subject.isEmpty ? String(h.prefix(7)) : subject
        case .newChat: return "New session"
        }
    }

    var icon: String {
        switch kind {
        case .file: return "doc.text"
        case .changes: return "plusminus"
        case .commit: return "clock.arrow.circlepath"
        case .newChat: return "bubble.left.and.text.bubble.right"
        }
    }

    static func load() -> [DocTab] {
        guard let d = UserDefaults.standard.data(forKey: "ade.docTabs"),
              let v = try? JSONDecoder().decode([DocTab].self, from: d) else { return [] }
        return v
    }

    static func save(_ v: [DocTab]) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: "ade.docTabs") }
    }
}

extension AppModel {
    /// Doc tabs of the current project, in open order.
    var currentDocs: [DocTab] { docTabs.filter { $0.projectId == currentProject?.id && project($0.projectId) != nil } }

    /// The doc tab showing right now (only when it belongs to the current project).
    var activeDoc: DocTab? { currentDocs.first { $0.id == activeDocId } }

    func openDoc(_ kind: DocTab.Kind, workPath: String? = nil, scrollTo: String? = nil, line: Int? = nil) {
        guard let p = currentProject, let wp = workPath ?? currentWorkPath else { return }
        let doc: DocTab
        if let existing = docTabs.first(where: { $0.projectId == p.id && $0.workPath == wp && $0.kind == kind }) {
            doc = existing
        } else {
            doc = DocTab(id: UUID().uuidString, projectId: p.id, workPath: wp, kind: kind)
            docTabs.append(doc)
        }
        activeDocId = doc.id
        if let scrollTo { DocHost.shared.controller(for: doc).scroll(to: scrollTo) }
        if let line { DocHost.shared.controller(for: doc).goto(line: line) }
    }

    /// A fresh chat start screen (each call opens another one, like a new tab).
    /// `draft`: text the composer starts with (e.g. an instruction the user completes).
    func openNewChat(projectId: String? = nil, draft: String? = nil) {
        guard let p = project(projectId ?? currentProject?.id ?? "") ?? currentProject else {
            lastError = "Add a project first (⌘⇧O)."
            return
        }
        if p.id != currentProject?.id { selectedProjectId = p.id; activeTabId = tabs(ofProject: p.id).first?.id }
        let doc = DocTab(id: UUID().uuidString, projectId: p.id, workPath: p.path, kind: .newChat)
        if let draft { NewChatDraft.pending[doc.id] = draft }
        docTabs.append(doc)
        activeDocId = doc.id
    }

    func openFile(_ rel: String, line: Int? = nil) { openDoc(.file(rel), line: line) }
    func openChanges(scrollTo: String? = nil) { openDoc(.changes, scrollTo: scrollTo) }
    func openCommit(_ hash: String, subject: String) { openDoc(.commit(hash, subject)) }

    func selectDoc(_ id: String) {
        guard let d = docTabs.first(where: { $0.id == id }) else { return }
        if d.projectId != currentProject?.id { selectedProjectId = d.projectId; activeTabId = tabs(ofProject: d.projectId).first?.id }
        activeDocId = id
    }

    func closeDoc(_ id: String) {
        guard let i = docTabs.firstIndex(where: { $0.id == id }) else { return }
        if DocHost.shared.isDirty(id) {
            let a = NSAlert()
            a.messageText = "Discard unsaved changes to \(docTabs[i].title)?"
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        let siblings = currentDocs
        docTabs.remove(at: i)
        DocHost.shared.drop(id)
        if activeDocId == id {
            // Next doc to the right (else left); with none left, the session tab shows again.
            if let j = siblings.firstIndex(where: { $0.id == id }) {
                let rest = siblings.filter { $0.id != id }
                activeDocId = rest.isEmpty ? nil : rest[min(j, rest.count - 1)].id
            } else { activeDocId = nil }
            if activeDocId == nil { TerminalHost.shared.focusCurrent() }
        }
    }

    func moveDoc(_ id: String, before target: String) {
        guard id != target, let from = docTabs.firstIndex(where: { $0.id == id }) else { return }
        let d = docTabs.remove(at: from)
        let to = docTabs.firstIndex(where: { $0.id == target }) ?? docTabs.count
        docTabs.insert(d, at: to)
    }
}

// MARK: - Git content for the diff views

enum GitDiffData {
    struct FileDiff {
        var key: String, path: String, status: String
        var added = 0, removed = 0
        var original = "", modified = ""
        var binary = false, tooLarge = false

        var json: [String: Any] {
            ["key": key, "path": path, "status": status, "added": added, "removed": removed,
             "original": original, "modified": modified, "binary": binary, "tooLarge": tooLarge]
        }
    }

    static let maxBytes = 1_000_000

    /// `git diff --numstat` → path: (added, removed, binary).
    static func numstat(_ out: String?) -> [String: (Int, Int, Bool)] {
        var r: [String: (Int, Int, Bool)] = [:]
        for line in (out ?? "").split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3 else { continue }
            var path = f[2]
            if let arrow = path.range(of: " => ") {   // renames: "dir/{a => b}" or "a => b"
                path = String(path[arrow.upperBound...]).replacingOccurrences(of: "}", with: "")
                if let brace = f[2].range(of: "{") { path = String(f[2][..<brace.lowerBound]) + path }
            }
            r[path] = (Int(f[0]) ?? 0, Int(f[1]) ?? 0, f[0] == "-")
        }
        return r
    }

    /// Lines as git counts them ("a\nb\n" = 2, "a\nb" = 2, "" = 0).
    static func lineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var n = 0
        for b in s.utf8 where b == 10 { n += 1 }
        return s.utf8.last == 10 ? n : n + 1
    }

    /// Added-line counts of untracked files (whole file is new); binaries and huge files count 0.
    static func untrackedStats(_ dir: String, _ paths: [String]) -> [String: Int] {
        var r: [String: Int] = [:]
        for p in paths.prefix(300) {
            let (t, bin, big) = worktreeFile(dir, p)
            r[p] = bin || big ? 0 : lineCount(t)
        }
        return r
    }

    static func blob(_ spec: String, in dir: String) -> String? {
        GitInfo.git(["show", spec], in: dir)
    }

    static func text(_ s: String?) -> (String, Bool, Bool) {
        guard let s else { return ("", false, false) }
        if s.utf8.count > maxBytes { return ("", false, true) }
        if s.utf8.prefix(8000).contains(0) { return ("", true, false) }
        return (s, false, false)
    }

    static func worktreeFile(_ dir: String, _ rel: String) -> (String, Bool, Bool) {
        let full = (dir as NSString).appendingPathComponent(rel)
        if AppModel.shared.host(forPath: dir).0.isRemote {
            let t = RemoteFS.readText(full, max: maxBytes) ?? ""
            if t.hasPrefix("Binary file") { return ("", true, false) }
            if t.hasSuffix("… (truncated)") { return ("", false, true) }
            return (t, false, false)
        }
        guard let d = FileManager.default.contents(atPath: full) else { return ("", false, false) }
        if d.count > maxBytes { return ("", false, true) }
        if d.prefix(8000).contains(0) { return ("", true, false) }
        return (String(decoding: d, as: UTF8.self), false, false)
    }

    /// Staged and unstaged changes of a work tree.
    static func workingTree(_ dir: String) -> (staged: [FileDiff], unstaged: [FileDiff])? {
        guard let status = GitInfo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: dir) else { return nil }
        let hasHead = GitInfo.git(["rev-parse", "--verify", "-q", "HEAD"], in: dir) != nil
        let stagedStat = numstat(GitInfo.git(["diff", "--cached", "--numstat"] + (hasHead ? [] : ["--root"]), in: dir))
        let unstagedStat = numstat(GitInfo.git(["diff", "--numstat"], in: dir))
        var staged: [FileDiff] = [], unstaged: [FileDiff] = []
        for line in status.split(separator: "\n") {
            guard line.count > 3 else { continue }
            let x = line[line.startIndex], y = line[line.index(after: line.startIndex)]
            var p = String(line.dropFirst(3))
            var orig: String?
            if let arrow = p.range(of: " -> ") { orig = String(p[..<arrow.lowerBound]); p = String(p[arrow.upperBound...]) }
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if x == "?" {
                var f = FileDiff(key: "u:" + p, path: p, status: "U")
                (f.modified, f.binary, f.tooLarge) = worktreeFile(dir, p)
                f.added = lineCount(f.modified)
                unstaged.append(f)
                continue
            }
            if x != " " {
                var f = FileDiff(key: "s:" + p, path: p, status: String(x))
                let st = stagedStat[p]
                f.added = st?.0 ?? 0; f.removed = st?.1 ?? 0
                if st?.2 == true { f.binary = true } else {
                    let a = x == "A" || !hasHead ? ("", false, false) : text(blob("HEAD:" + (orig ?? p), in: dir))
                    let b = x == "D" ? ("", false, false) : text(blob(":" + p, in: dir))
                    f.original = a.0; f.modified = b.0
                    f.binary = a.1 || b.1; f.tooLarge = a.2 || b.2
                }
                staged.append(f)
            }
            if y != " " {
                var f = FileDiff(key: "u:" + p, path: p, status: String(y))
                let st = unstagedStat[p]
                f.added = st?.0 ?? 0; f.removed = st?.1 ?? 0
                if st?.2 == true { f.binary = true } else {
                    let a = text(blob(":" + p, in: dir))
                    let b = y == "D" ? ("", false, false) : worktreeFile(dir, p)
                    f.original = a.0; f.modified = b.0
                    f.binary = a.1 || b.1; f.tooLarge = a.2 || b.2
                }
                unstaged.append(f)
            }
        }
        return (staged, unstaged)
    }

    /// The work tree (committed on this branch + uncommitted + untracked) against a base commit.
    static func againstBase(_ dir: String, _ base: String) -> [FileDiff] {
        let names = GitInfo.git(["diff", "--name-status", "-M", base], in: dir) ?? ""
        let stat = numstat(GitInfo.git(["diff", "--numstat", "-M", base], in: dir))
        var out: [FileDiff] = []
        for line in names.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2 else { continue }
            let code = String(f[0].prefix(1))
            let path = f.count >= 3 ? f[2] : f[1], old = f[1]
            var d = FileDiff(key: "b:" + path, path: path, status: code)
            let st = stat[path]
            d.added = st?.0 ?? 0; d.removed = st?.1 ?? 0
            if st?.2 == true { d.binary = true } else {
                let a = code == "A" ? ("", false, false) : text(blob("\(base):\(old)", in: dir))
                let b = code == "D" ? ("", false, false) : worktreeFile(dir, path)
                d.original = a.0; d.modified = b.0
                d.binary = a.1 || b.1; d.tooLarge = a.2 || b.2
            }
            out.append(d)
        }
        let others = (GitInfo.git(["ls-files", "--others", "--exclude-standard"], in: dir) ?? "").split(separator: "\n").map(String.init)
        for p in others.prefix(300) {
            var f = FileDiff(key: "b:" + p, path: p, status: "U")
            (f.modified, f.binary, f.tooLarge) = worktreeFile(dir, p)
            f.added = lineCount(f.modified)
            out.append(f)
        }
        return out
    }

    /// Files changed by a commit (against its first parent).
    static func commit(_ hash: String, in dir: String) -> [FileDiff] {
        let parent = GitInfo.git(["rev-parse", "--verify", "-q", hash + "^"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = GitInfo.git(["show", "--name-status", "--format=", "-M", hash], in: dir) ?? ""
        let stat = numstat(GitInfo.git(["show", "--numstat", "--format=", "-M", hash], in: dir))
        var out: [FileDiff] = []
        for line in names.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2 else { continue }
            let code = String(f[0].prefix(1))
            let path = f.count >= 3 ? f[2] : f[1]
            let old = f.count >= 3 ? f[1] : f[1]
            var d = FileDiff(key: "c:" + path, path: path, status: code)
            let st = stat[path]
            d.added = st?.0 ?? 0; d.removed = st?.1 ?? 0
            if st?.2 == true { d.binary = true } else {
                let a = code == "A" || parent == nil ? ("", false, false) : text(blob("\(parent!):\(old)", in: dir))
                let b = code == "D" ? ("", false, false) : text(blob("\(hash):\(path)", in: dir))
                d.original = a.0; d.modified = b.0
                d.binary = a.1 || b.1; d.tooLarge = a.2 || b.2
            }
            out.append(d)
        }
        return out
    }
}
