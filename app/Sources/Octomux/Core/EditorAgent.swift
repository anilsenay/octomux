import Foundation

/// Working on code next to an agent: which lines of a file changed (the editor's gutter marks), what the agent
/// touched this turn (the Files panel), and notes on lines sent to the agent.

/// Changed lines of a file against its last commit, from `git diff -U0`.
struct ChangeMarks: Equatable {
    var added: [Int] = []       // new lines (1-based, in the file as it is)
    var modified: [Int] = []
    var deleted: [Int] = []     // lines after which something was removed (0: before the first line)

    var isEmpty: Bool { added.isEmpty && modified.isEmpty && deleted.isEmpty }
    var json: [String: Any] { ["added": added, "modified": modified, "deleted": deleted] }

    /// Reads the hunk headers (`@@ -a,b +c,d @@`).
    static func parse(_ diff: String) -> ChangeMarks {
        var m = ChangeMarks()
        for line in diff.split(separator: "\n") where line.hasPrefix("@@") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { continue }
            let (_, oldCount) = range(parts[1].dropFirst())
            let (newStart, newCount) = range(parts[2].dropFirst())
            if newCount == 0 { m.deleted.append(newStart); continue }
            let lines = Array(newStart..<(newStart + newCount))
            if oldCount == 0 { m.added += lines } else {
                // A replaced block: as many lines as were removed count as modified, the rest as added.
                m.modified += lines.prefix(oldCount)
                m.added += lines.dropFirst(oldCount)
            }
        }
        return m
    }

    private static func range(_ s: Substring) -> (Int, Int) {
        let p = s.split(separator: ",")
        return (Int(p.first ?? "") ?? 0, p.count > 1 ? Int(p[1]) ?? 1 : 1)
    }

    /// The file's marks (a new, untracked file: every line added).
    static func read(_ workPath: String, _ rel: String) -> ChangeMarks {
        if let d = GitInfo.git(["diff", "-U0", "--no-color", "HEAD", "--", rel], in: workPath), !d.isEmpty { return parse(d) }
        let tracked = GitInfo.git(["ls-files", "--error-unmatch", "--", rel], in: workPath) != nil
        guard !tracked, GitInfo.git(["rev-parse", "--git-dir"], in: workPath) != nil,
              let text = try? String(contentsOfFile: (workPath as NSString).appendingPathComponent(rel), encoding: .utf8) else { return ChangeMarks() }
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        return ChangeMarks(added: n > 0 ? Array(1...n) : [])
    }
}

/// A file the agent read or changed in its current turn.
struct TouchedFile: Equatable, Identifiable {
    enum How: String { case modified = "M", read = "R" }
    var path: String           // relative to the work path when inside it
    var how: How
    var id: String { path }

    /// From the turn's tool calls: changed files first (a file both read and changed counts as changed).
    static func from(_ items: [ChatItem], workPath: String) -> [TouchedFile] {
        let start = (items.lastIndex { $0.kind == .user }).map { $0 + 1 } ?? 0
        var out: [TouchedFile] = []
        func add(_ raw: String, _ how: How) {
            guard !raw.isEmpty, !raw.contains(" ") || raw.hasPrefix("/") else { return }
            let p = raw.hasPrefix(workPath + "/") ? String(raw.dropFirst(workPath.count + 1)) : raw
            if let i = out.firstIndex(where: { $0.path == p }) { if how == .modified { out[i].how = .modified } } else { out.append(TouchedFile(path: p, how: how)) }
        }
        for t in items[min(start, items.count)...] where t.kind == .tool {
            switch t.tool {
            case "Edit", "Write", "MultiEdit", "NotebookEdit": add(t.detail, .modified)
            case "Read": add(t.detail, .read)
            default: break
            }
        }
        return out.filter { $0.how == .modified } + out.filter { $0.how == .read }
    }
}

extension AppModel {
    /// The agent the editor works with in a project: the focused session when it is an agent, else the project's
    /// most recently active one.
    func editorAgent(projectId: String?) -> Session? {
        guard let pid = projectId else { return nil }
        if let id = EditorAgentPick.shared.picked[pid], let s = session(id), !s.isDormant { return s }
        if let f = session(focusedSessionId), f.isAgent, f.projectId == pid, !f.isDormant { return f }
        return state.sessions.filter { $0.projectId == pid && $0.isAgent && !$0.isDormant }.max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// The text a note on lines becomes: the note, then where, then the lines themselves.
    static func noteText(_ note: String, path: String, from: Int, to: Int, excerpt: String) -> String {
        let place = from == to ? "\(path):\(from)" : "\(path):\(from)-\(to)"
        let fence = excerpt.contains("```") ? "~~~" : "```"
        return "\(note.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(place)\n\(fence)\n\(excerpt)\n\(fence)"
    }

    /// Puts a note on lines in the agent's composer (or its prompt, in a terminal) without sending it: you read
    /// it there and press Return. The agent beside the editor keeps the editor on screen; otherwise its pane opens.
    @MainActor func sendNote(_ note: String, path: String, from: Int, to: Int, excerpt: String) {
        guard let s = editorAgent(projectId: currentProject?.id) else {
            lastError = "No agent is running in this project. Start one (⌘N) and send the note again."
            return
        }
        let text = Self.noteText(note, path: path, from: from, to: to, excerpt: excerpt)
        let beside = layout.sideChat
        if isChat(s.id) || (beside && canChat(s)) {
            BrowserSend.pendingChat[s.id, default: []].append(text)
            NotificationCenter.default.post(name: .octomuxComposerAppend, object: s.id, userInfo: ["text": text])
            if !beside { selectSession(s.id) }
        } else {
            sendToSession(s.id, text: text, submit: false)
            if !beside { selectSession(s.id) }
        }
    }
}

/// Follows the project agent's transcript for the Files panel's "touched this turn" (one reader, while shown).
final class TouchedFiles: ObservableObject {
    @Published private(set) var files: [TouchedFile] = []
    @Published private(set) var agent: Session?
    private let reader = ChatModel()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        reader.attach(nil)
    }

    private func refresh() {
        let m = AppModel.shared
        let a = m.editorAgent(projectId: m.currentProject?.id)
        if a?.id != agent?.id || a?.transcriptPath != agent?.transcriptPath {
            agent = a
            reader.attach(a.flatMap { $0.transcriptPath ?? TranscriptLocator.path(for: $0, model: m) })
        }
        let list = a.map { TouchedFile.from(reader.items, workPath: m.workPath(of: $0)) } ?? []
        if list != files { files = list }
    }
}

/// The agent picked for a project's editor column (memory only; otherwise the focused or latest agent).
final class EditorAgentPick: ObservableObject {
    static let shared = EditorAgentPick()
    @Published var picked: [String: String] = [:]
}
