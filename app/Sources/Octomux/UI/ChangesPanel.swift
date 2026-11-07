import AppKit
import SwiftUI

struct GitChange: Identifiable, Equatable {
    var id: String { path }
    let status: String   // two-letter porcelain code
    let path: String
    var stagedStat: (Int, Int)? = nil
    var unstagedStat: (Int, Int)? = nil

    static func == (a: GitChange, b: GitChange) -> Bool {
        a.status == b.status && a.path == b.path && a.stagedStat?.0 == b.stagedStat?.0 && a.stagedStat?.1 == b.stagedStat?.1
            && a.unstagedStat?.0 == b.unstagedStat?.0 && a.unstagedStat?.1 == b.unstagedStat?.1
    }

    var x: Character { status.first ?? " " }
    var y: Character { status.count > 1 ? status[status.index(after: status.startIndex)] : " " }
    var isStaged: Bool { x != " " && x != "?" }
    var isUnstaged: Bool { y != " " || x == "?" }

    static func badge(_ c: Character) -> String { c == "?" ? "U" : String(c) }
    static func color(_ b: String) -> Color {
        switch b {
        case "A", "U": return T.diffAdd
        case "D": return T.diffDel
        case "R": return T.blue
        default: return T.amber
        }
    }

    var badge: String {
        let s = status.trimmingCharacters(in: .whitespaces)
        if s == "??" { return "U" }
        return String(s.first(where: { $0 != " " }) ?? "M")
    }

    var color: Color {
        switch badge {
        case "A", "U": return T.diffAdd
        case "D": return T.diffDel
        case "R": return T.blue
        default: return T.amber
        }
    }
}

/// A file changed since the compare branch (committed on this branch or not); read-only in the panel.
struct BaseFile: Identifiable, Equatable {
    /// Not the bare path: the same file can sit in the uncommitted groups of the same list.
    var id: String { "b:" + path }
    let path: String
    let status: String
    let added: Int, removed: Int
}

/// Right-hand panel: working-tree changes of the current project, diffs, commit.
final class ChangesModel: ObservableObject {
    @Published var changes: [GitChange] = []
    @Published var selected: String?
    @Published var diff: String = ""
    @Published var message = ""
    @Published var status = ""
    @Published var busy = false
    @Published var isRepo = true
    /// The branch the status bar compares against (nil = uncommitted work only), and the files since it.
    @Published var baseName: String?
    @Published var baseFiles: [BaseFile] = []
    /// ✨ writing a commit message right now.
    @Published var generating: CommitMessageGen.Run?
    private var path: String?
    var workPath: String? { path }

    /// ✨: asks the commit-message agent for a message and puts it in the box (Settings → Projects → Commit messages).
    func generateMessage(projectId: String?, model: AppModel) {
        if let g = generating { g.cancel(); generating = nil; status = ""; return }
        guard let path else { return }
        status = "Writing a commit message…"
        generating = CommitMessageGen.generate(path: path, projectId: projectId, model: model) { [weak self] r in
            guard let self else { return }
            self.generating = nil
            switch r {
            case .success(let m): self.message = m; self.status = ""
            case .failure(let e): self.status = e.localizedDescription
            }
        }
        if generating == nil, status == "Writing a commit message…" { status = "" }
    }
    private var timer: Timer?

    func attach(path: String?) {
        guard path != self.path else { return }
        self.path = path
        selected = nil
        diff = ""
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        path = nil
    }

    func refresh() {
        guard let path else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = GitInfo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: path)
            let list: [GitChange] = (out ?? "").split(separator: "\n").compactMap { line in
                guard line.count > 3 else { return nil }
                let code = String(line.prefix(2))
                var p = String(line.dropFirst(3))
                if let arrow = p.range(of: " -> ") { p = String(p[arrow.upperBound...]) }
                return GitChange(status: code, path: p.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
            let staged = GitDiffData.numstat(GitInfo.git(["diff", "--cached", "--numstat"], in: path))
            let unstaged = GitDiffData.numstat(GitInfo.git(["diff", "--numstat"], in: path))
            let untracked = GitDiffData.untrackedStats(path, list.filter { $0.status == "??" }.map(\.path))
            let full = list.map { c -> GitChange in
                var c = c
                if let s = staged[c.path] { c.stagedStat = (s.0, s.1) }
                if let s = unstaged[c.path] { c.unstagedStat = (s.0, s.1) }
                if let n = untracked[c.path] { c.unstagedStat = (n, 0) }
                return c
            }
            let baseName = GitInfo.compareBase(for: path)
            let base = baseName == nil ? nil : GitInfo.diffBase(for: path)
            let since = base.map { b in GitDiffData.baseSummary(path, b).map { BaseFile(path: $0.path, status: $0.status, added: $0.added, removed: $0.removed) } } ?? []
            DispatchQueue.main.async {
                guard self.path == path else { return }
                self.isRepo = out != nil
                if self.changes != full { self.changes = full }
                let name = base == nil ? nil : baseName
                if self.baseName != name { self.baseName = name }
                if self.baseFiles != since { self.baseFiles = since }
            }
        }
    }

    func select(_ c: GitChange) {
        selected = c.path
        guard let path else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var d: String
            if c.badge == "U" {
                let full = (path as NSString).appendingPathComponent(c.path)
                let content = RemoteFS.readText(full) ?? "(binary or unreadable file)"
                d = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(2000).map { "+" + $0 }.joined(separator: "\n")
            } else {
                d = GitInfo.git(["diff", "HEAD", "--", c.path], in: path) ?? GitInfo.git(["diff", "--cached", "--", c.path], in: path) ?? ""
            }
            if d.count > 400_000 { d = String(d.prefix(400_000)) + "\n… (truncated)" }
            DispatchQueue.main.async { if self.selected == c.path { self.diff = d } }
        }
    }

    /// Throws away changes, after asking. From the Changes group: what isn't staged (staged edits stay, a new
    /// file goes to the Trash). From the Staged group: everything since the last commit.
    func discardAsking(_ list: [GitChange], staged: Bool) {
        guard !list.isEmpty, let path else { return }
        let remote = AppModel.shared.host(forPath: path).0.isRemote
        let a = NSAlert()
        let new = list.filter { $0.x == "?" || (staged && $0.x == "A") }
        if list.count == 1, let c = list.first {
            a.messageText = "Discard changes in “\((c.path as NSString).lastPathComponent)”?"
            a.informativeText = new.isEmpty
                ? (staged ? "The file goes back to the last commit, staged changes included." : "The file goes back to its staged version, or the last commit if nothing is staged.") + " This can't be undone."
                : remote ? "The file is new; it is deleted. This can't be undone." : "The file is new; it is moved to the Trash."
        } else {
            a.messageText = "Discard \(list.count) changes?"
            let names = list.prefix(5).map { "• " + $0.path }.joined(separator: "\n") + (list.count > 5 ? "\n• and \(list.count - 5) more" : "")
            let what = staged ? "These files go back to the last commit, staged changes included." : "Unstaged changes in these files are lost; staged ones stay."
            let newNote = new.isEmpty ? "" : remote ? " New files are deleted." : " New files are moved to the Trash."
            a.informativeText = "\(names)\n\n\(what)\(newNote) Edits can't be undone."
        }
        a.addButton(withTitle: list.count == 1 ? "Discard" : "Discard All").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        discard(list.map(\.path), staged: staged, in: path, remote: remote)
    }

    private func discard(_ paths: [String], staged: Bool, in path: String, remote: Bool) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.discardFiles(paths, staged: staged, in: path, remote: remote)
            DispatchQueue.main.async {
                self.busy = false
                self.status = ok ? "" : "Some changes could not be discarded."
                self.refresh()
            }
        }
    }

    /// The work of `discardAsking`, without the question (blocking; false when something failed).
    static func discardFiles(_ paths: [String], staged: Bool, in path: String, remote: Bool) -> Bool {
        var ok = true
        if staged, GitInfo.git(["restore", "--staged", "--"] + paths, in: path) == nil { ok = false }
        // What is left of each file: untracked ones are new files, the rest go back to the index.
        let st = GitInfo.git(["status", "--porcelain=v1", "--untracked-files=all", "--"] + paths, in: path) ?? ""
        var untracked: [String] = [], tracked: [String] = []
        for line in st.split(separator: "\n") where line.count > 3 {
            var p = String(line.dropFirst(3))
            if let arrow = p.range(of: " -> ") { p = String(p[arrow.upperBound...]) }
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if line.hasPrefix("??") { untracked.append(p) } else if line.dropFirst().first != " " { tracked.append(p) }
        }
        if !tracked.isEmpty, GitInfo.git(["restore", "--worktree", "--"] + tracked, in: path) == nil { ok = false }
        if !untracked.isEmpty {
            if remote {
                if GitInfo.git(["clean", "-f", "--"] + untracked, in: path) == nil { ok = false }
            } else {
                for u in untracked {
                    let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent(u))
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { ok = false }
                }
            }
        }
        return ok
    }

    func stage(_ paths: [String]) { run(["add", "--"] + paths) }
    func unstage(_ paths: [String]) { run(["restore", "--staged", "--"] + paths) }

    private func run(_ args: [String]) {
        guard let path else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = GitInfo.git(args, in: path)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func commit(push: Bool, amend: Bool = false) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, amend || !msg.isEmpty else { return }
        busy = true
        status = amend ? "Amending…" : "Committing…"
        DispatchQueue.global(qos: .userInitiated).async {
            // Commit what is staged; with nothing staged, everything.
            let anyStaged = !(GitInfo.git(["diff", "--cached", "--name-only"], in: path) ?? "").isEmpty
            if !anyStaged { _ = GitInfo.git(["add", "-A"], in: path) }
            var args = ["commit"]
            if amend { args.append("--amend") }
            args += msg.isEmpty ? ["--no-edit"] : ["-m", msg]
            let ok = GitInfo.git(args, in: path) != nil
            var pushed = true
            if ok && push { pushed = GitInfo.git(["push"], in: path) != nil }
            DispatchQueue.main.async {
                self.busy = false
                if !ok { self.status = "Commit failed (see a terminal for details)" }
                else if !pushed { self.status = "Committed; push failed" }
                else { self.status = (amend ? "Amended" : "Committed") + (push ? " and pushed" : ""); self.message = "" }
                self.refresh()
                NotificationCenter.default.post(name: .octomuxGitCommitted, object: nil)
            }
        }
    }

    func push() {
        guard let path else { return }
        busy = true
        status = "Pushing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = GitInfo.git(["push"], in: path) != nil
            DispatchQueue.main.async { self.busy = false; self.status = ok ? "Pushed" : "Push failed (see a terminal for details)" }
        }
    }
}

struct ChangesPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var changes = ChangesModel()
    @State private var pickingBase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(changes.changes.isEmpty ? (changes.baseName == nil ? "No changes" : "No uncommitted changes") : "\(changes.changes.count) changed").font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(T.text2)
                if let wp = model.currentWorkPath, wp != model.currentProject?.path, let b = GitInfo.shared.branch(for: wp) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10))
                        Text(b).font(T.mono(11)).lineLimit(1)
                    }
                    .foregroundStyle(T.text3).help("Worktree: \(wp)")
                }
                Spacer()
                if let wp = model.currentWorkPath, let pid = model.currentProject?.id {
                    AskAgentMenu(projectId: pid, folder: wp, file: nil) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: T.k * 11))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(T.text2)
                    .help("Ask an agent about these changes")
                }
                Button { changes.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: T.k * 11)) }.buttonStyle(ChromeButtonStyle())
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 32)
            Hairline()
            if !changes.isRepo {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 24, weight: .light)).foregroundStyle(T.text3)
                    Text("Not a git repository").font(T.body).foregroundStyle(T.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    TextField("Message (⌘↩ to commit)", text: $changes.message, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.plain).font(T.body)
                        .padding(.leading, 10).padding(.trailing, 30).padding(.vertical, 7)
                        .overlay(alignment: .topTrailing) {
                            Button { changes.generateMessage(projectId: model.currentProject?.id, model: model) } label: {
                                Group {
                                    if changes.generating != nil { Image(systemName: "stop.circle") } else { Image(systemName: "sparkles") }
                                }
                                .font(.system(size: T.k * 12))
                            }
                            .buttonStyle(IconButtonStyle(size: 22)).padding(3)
                            .disabled(changes.changes.isEmpty && changes.generating == nil)
                            .help(changes.generating != nil ? "Stop writing the message"
                                  : "Write a commit message with \(CommitMessageGen.profile(model: model, project: model.currentProject?.id)?.name ?? "an agent")")
                        }
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.frame.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border))
                        .onKeyPress(.return, phases: .down) { press in
                            // ⌘↩ commits only while the message field has focus (never from a terminal).
                            guard press.modifiers.contains(.command) else { return .ignored }
                            if !changes.busy && !changes.changes.isEmpty { changes.commit(push: false) }
                            return .handled
                        }
                    CommitButton(changes: changes)
                    if !changes.status.isEmpty { Text(changes.status).font(T.caption).foregroundStyle(T.text2).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .padding(12)
                Hairline()
                compareRow
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let staged = changes.changes.filter(\.isStaged)
                        let unstaged = changes.changes.filter(\.isUnstaged)
                        if !staged.isEmpty {
                            group("Staged", staged, staged: true)
                        }
                        if !unstaged.isEmpty {
                            group(staged.isEmpty ? "Changes" : "Uncommitted", unstaged, staged: false)
                        }
                        if changes.changes.isEmpty {
                            Text(changes.baseName == nil ? "Working tree clean" : "No uncommitted changes").font(T.body).foregroundStyle(T.text2).padding(14)
                        }
                        if let name = changes.baseName {
                            baseGroup(name)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { changes.attach(path: model.currentWorkPath) }
        .onDisappear { changes.detach() }
        .onChange(of: model.currentWorkPath) { _, p in changes.attach(path: p) }
    }

    @State private var collapsed: Set<String> = []

    /// The branch these changes are compared against (the same choice as the status bar's "→ branch").
    @ViewBuilder private var compareRow: some View {
        if let path = model.currentWorkPath {
            let base = GitInfo.compareBase(for: path)
            HStack(spacing: 6) {
                Text("Compare with").font(T.caption).foregroundStyle(T.text3)
                Button { pickingBase = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10))
                        Text(base ?? "Uncommitted only").font(base == nil ? T.caption : T.mono(11)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
                    }
                    .foregroundStyle(base == nil ? T.text2 : T.text)
                    .padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight(radius: 6, padding: 0).pointerCursor()
                .help(base.map { "Also listing everything since this branch left \($0). Click to pick another branch or go back to uncommitted changes only." }
                      ?? "Only uncommitted changes. Click to also see everything since this branch left another one (like main).")
                .background(PopoverAnchor(isPresented: $pickingBase) {
                    BranchPicker(path: path, mode: .base, current: base) { pickingBase = false }
                })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 30)
            Hairline()
        }
    }

    /// Everything since the compare branch (what the status bar counts): a list only; a click opens its diff.
    @ViewBuilder private func baseGroup(_ name: String) -> some View {
        let list = changes.baseFiles
        let title = "Since \(name)"
        let open = !collapsed.contains(title)
        if !changes.changes.isEmpty { Hairline().padding(.vertical, 4) }
        GroupHeader(title: "\(title) (\(list.count))", open: open, added: list.reduce(0) { $0 + $1.added }, removed: list.reduce(0) { $0 + $1.removed },
                    action: nil, help: "Committed on this branch and not yet, since it left \(name); change it with Compare with above") {
            if open { collapsed.insert(title) } else { collapsed.remove(title) }
        }
        if open {
            if list.isEmpty {
                Text("No changes against \(name)").font(T.body).foregroundStyle(T.text2).padding(.horizontal, 14).padding(.vertical, 6)
            }
            ForEach(list) { f in BaseRow(file: f, changes: changes) }
        }
    }

    @ViewBuilder private func group(_ title: String, _ list: [GitChange], staged: Bool) -> some View {
        let add = list.reduce(0) { $0 + ((staged ? $1.stagedStat : $1.unstagedStat)?.0 ?? 0) }
        let rem = list.reduce(0) { $0 + ((staged ? $1.stagedStat : $1.unstagedStat)?.1 ?? 0) }
        let open = !collapsed.contains(title)
        GroupHeader(title: "\(title) (\(list.count))", open: open, added: add, removed: rem,
                    action: staged ? ("minus", "Unstage all", { changes.unstage(list.map(\.path)) }) : ("plus", "Stage all", { changes.stage(list.map(\.path)) }),
                    discard: model.canManage ? { changes.discardAsking(list, staged: staged) } : nil,
                    discardHelp: staged ? "Discard all staged and unstaged changes in these files" : "Discard all changes not staged") {
            if open { collapsed.insert(title) } else { collapsed.remove(title) }
        }
        if open {
            ForEach(list) { c in
                ChangeRow(change: c, staged: staged, changes: changes)
            }
        }
    }
}

private struct GroupHeader: View {
    let title: String
    let open: Bool
    let added: Int, removed: Int
    let action: (String, String, () -> Void)?
    var discard: (() -> Void)?
    var discardHelp = ""
    var help = ""
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: T.k * 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(T.text3).frame(width: 10)
            Text(title).font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(T.text2)
            Spacer()
            if hover {
                if let discard {
                    Button(action: discard) { Image(systemName: "arrow.uturn.backward").font(.system(size: T.k * 10, weight: .semibold)) }
                        .buttonStyle(IconButtonStyle(size: 18)).help(discardHelp)
                }
                if let action {
                    Button(action: action.2) { Image(systemName: action.0).font(.system(size: T.k * 10, weight: .semibold)) }
                        .buttonStyle(IconButtonStyle(size: 18)).help(action.1)
                }
            }
            DiffCount(added: added, removed: removed)
        }
        .padding(.horizontal, 12).frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
        .help(help)
    }
}

/// A file in "Since <branch>": opens the Changes view (against that branch) at the file.
private struct BaseRow: View {
    @EnvironmentObject var model: AppModel
    let file: BaseFile
    @ObservedObject var changes: ChangesModel
    @State private var hover = false

    var body: some View {
        let f = file
        let key = "b:" + f.path
        let selected = model.activeDoc?.kind == .changes && changes.selected == key
        HStack(spacing: 6) {
            FileIcon(name: (f.path as NSString).lastPathComponent)
            Text((f.path as NSString).lastPathComponent).font(.system(size: T.k * 13)).foregroundStyle(T.text).lineLimit(1)
            Text((f.path as NSString).deletingLastPathComponent).font(.system(size: T.k * 11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if hover, f.status != "D" {
                Button { model.openDoc(.file(f.path)) } label: { Image(systemName: "doc.text").font(.system(size: T.k * 10)) }
                    .buttonStyle(IconButtonStyle(size: 18)).help("Open file")
            } else {
                DiffCount(added: f.added, removed: f.removed)
                Text(f.status).font(T.mono(11, .bold)).foregroundStyle(GitChange.color(f.status)).frame(width: 12)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(selected ? T.selection : hover ? T.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .help(f.path)
        .onTapGesture {
            changes.selected = key
            model.openChanges(scrollTo: key)
        }
        .contextMenu {
            if f.status != "D" { Button("Open File") { model.openDoc(.file(f.path)) } }
            if let wp = changes.workPath, let pid = model.currentProject?.id {
                AskAgentMenu(projectId: pid, folder: wp, file: f.path) { Text("Ask Agent") }
            }
            Button("Copy Path") { copy(f.path) }
        }
    }
}

struct DiffCount: View {
    let added: Int, removed: Int
    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(T.diffAdd) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(T.diffDel) }
        }
        .font(T.mono(11, .medium))
    }
}

private struct ChangeRow: View {
    @EnvironmentObject var model: AppModel
    let change: GitChange
    let staged: Bool
    @ObservedObject var changes: ChangesModel
    @State private var hover = false

    var body: some View {
        let c = change
        let badge = GitChange.badge(staged ? c.x : (c.x == "?" ? "?" : c.y))
        let stat = staged ? c.stagedStat : c.unstagedStat
        let key = (staged ? "s:" : "u:") + c.path
        let selected = model.activeDoc?.kind == .changes && changes.selected == key
        HStack(spacing: 6) {
            FileIcon(name: (c.path as NSString).lastPathComponent)
            Text((c.path as NSString).lastPathComponent).font(.system(size: T.k * 13)).foregroundStyle(T.text).lineLimit(1)
            Text((c.path as NSString).deletingLastPathComponent).font(.system(size: T.k * 11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if hover {
                Button { model.openDoc(.file(c.path)) } label: { Image(systemName: "doc.text").font(.system(size: T.k * 10)) }
                    .buttonStyle(IconButtonStyle(size: 18)).help("Open file")
                if model.canManage {
                    Button { changes.discardAsking([c], staged: staged) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: T.k * 10, weight: .semibold))
                    }
                    .buttonStyle(IconButtonStyle(size: 18)).help("Discard changes")
                }
                Button { staged ? changes.unstage([c.path]) : changes.stage([c.path]) } label: {
                    Image(systemName: staged ? "minus" : "plus").font(.system(size: T.k * 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 18)).help(staged ? "Unstage" : "Stage")
            } else {
                if let stat { DiffCount(added: stat.0, removed: stat.1) }
                Text(badge).font(T.mono(11, .bold)).foregroundStyle(GitChange.color(badge)).frame(width: 12)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(selected ? T.selection : hover ? T.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .help(c.path)
        .onTapGesture {
            changes.selected = key
            model.openChanges(scrollTo: changes.baseName == nil ? key : "b:" + c.path)
        }
        .contextMenu {
            Button("Open File") { model.openDoc(.file(c.path)) }
            if let wp = changes.workPath, !model.host(forPath: wp).0.isRemote {
                Button("Open in \(OpenIn.defaultFileAppName)") { OpenIn.openFile((wp as NSString).appendingPathComponent(c.path)) }
            }
            if let wp = changes.workPath, let pid = model.currentProject?.id {
                AskAgentMenu(projectId: pid, folder: wp, file: c.path) { Text("Ask Agent") }
            }
            Button(staged ? "Unstage" : "Stage") { staged ? changes.unstage([c.path]) : changes.stage([c.path]) }
            Button("Copy Path") { copy(c.path) }
            Divider()
            Button("Discard Changes…", role: .destructive) { changes.discardAsking([c], staged: staged) }.disabled(!model.canManage)
        }
    }
}

struct DiffView: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    let s = String(line)
                    Text(s.isEmpty ? " " : s)
                        .fixedSize(horizontal: true, vertical: false)
                        .font(T.mono(12))
                        .foregroundStyle(s.hasPrefix("@@") ? (T.colorblindDiff ? T.text3 : T.blue) : s.hasPrefix("+") && !s.hasPrefix("+++") ? T.diffAdd : s.hasPrefix("-") && !s.hasPrefix("---") ? T.diffDel : T.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(s.hasPrefix("+") && !s.hasPrefix("+++") ? T.diffAdd.opacity(0.10) : s.hasPrefix("-") && !s.hasPrefix("---") ? T.diffDel.opacity(0.10) : .clear)
                }
            }
            .padding(6)
            .textSelection(.enabled)
        }
    }
}

/// Full-width Commit with a menu of the other actions (push, amend).
private struct CommitButton: View {
    @ObservedObject var changes: ChangesModel
    @State private var hover = false

    var body: some View {
        let staged = changes.changes.filter(\.isStaged).count
        let canCommit = !changes.busy && !changes.changes.isEmpty && !changes.message.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 0) {
            Button { changes.commit(push: false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: T.k * 11, weight: .bold))
                    Text(staged > 0 ? "Commit \(staged) staged" : "Commit all")
                }
                .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            Rectangle().fill(canCommit ? Color.white.opacity(0.25) : T.border).frame(width: 1, height: 16)
            PopupMenuButton(menu: menu) {
                Image(systemName: "chevron.down").font(.system(size: T.k * 10, weight: .bold)).frame(width: 28, height: 28)
            }
            .help("More commit actions")
        }
        .font(.system(size: T.k * 13, weight: .semibold))
        // Disabled: neutral, not a faded accent (white on a pale accent can't be read in light themes).
        .foregroundStyle(canCommit ? Color.white : T.text3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(canCommit ? T.accent.opacity(hover ? 0.9 : 1) : T.text.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(canCommit ? .clear : T.border))
        .onHover { hover = $0 }
        .pointerCursor()
    }

    private func menu() -> NSMenu {
        let m = NSMenu()
        let hasMsg = !changes.message.trimmingCharacters(in: .whitespaces).isEmpty
        let hasChanges = !changes.changes.isEmpty
        func add(_ title: String, _ enabled: Bool, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title, action)
            i.isEnabled = enabled
            m.addItem(i)
        }
        m.autoenablesItems = false
        add("Commit & Push", hasMsg && hasChanges) { changes.commit(push: true) }
        add("Amend Last Commit" + (hasMsg ? "" : " (keep message)"), true) { changes.commit(push: false, amend: true) }
        m.addItem(.separator())
        add("Push", true) { changes.push() }
        m.addItem(.separator())
        add("Create Pull Request…", true) { PullRequestWindow.show(model: AppModel.shared) }
        return m
    }
}

/// Prompts marked for the Changes panel (Settings → Prompts), sent to the focused agent or a new one.
struct AskAgentMenu<Label: View>: View {
    @EnvironmentObject var model: AppModel
    let projectId: String
    let folder: String
    /// A changed file (its menu): fills {file}.
    let file: String?
    @ViewBuilder var label: () -> Label

    var body: some View {
        let list = model.templates(project: projectId).filter(\.changes)
        Menu {
            if list.isEmpty { Text("No prompts for the Changes panel yet") }
            ForEach(list) { t in
                Button(t.name) {
                    model.askAgent(model.expandTemplate(t, project: model.project(projectId), folder: folder, file: file), projectId: projectId, folder: folder)
                }
            }
            Divider()
            Button("Edit Prompts…") { SettingsWindow.show(section: .prompts) }
        } label: { label() }
    }
}
