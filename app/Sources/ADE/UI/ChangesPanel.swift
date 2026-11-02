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
        case "A", "U": return T.green
        case "D": return T.red
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
        case "A", "U": return T.green
        case "D": return T.red
        case "R": return T.blue
        default: return T.amber
        }
    }
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
    private var path: String?
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
            let full = list.map { c -> GitChange in
                var c = c
                if let s = staged[c.path] { c.stagedStat = (s.0, s.1) }
                if let s = unstaged[c.path] { c.unstagedStat = (s.0, s.1) }
                return c
            }
            DispatchQueue.main.async {
                self.isRepo = out != nil
                if self.changes != full { self.changes = full }
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

    func stage(_ paths: [String]) { run(["add", "--"] + paths) }
    func unstage(_ paths: [String]) { run(["restore", "--staged", "--"] + paths) }

    private func run(_ args: [String]) {
        guard let path else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = GitInfo.git(args, in: path)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func commit(push: Bool) {
        guard let path, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        status = "Committing…"
        let msg = message
        DispatchQueue.global(qos: .userInitiated).async {
            // Commit what is staged; with nothing staged, everything.
            let anyStaged = !(GitInfo.git(["diff", "--cached", "--name-only"], in: path) ?? "").isEmpty
            if !anyStaged { _ = GitInfo.git(["add", "-A"], in: path) }
            let ok = GitInfo.git(["commit", "-m", msg], in: path) != nil
            var pushed = true
            if ok && push { pushed = GitInfo.git(["push"], in: path) != nil }
            DispatchQueue.main.async {
                self.busy = false
                if !ok { self.status = "Commit failed (see a terminal for details)" }
                else if !pushed { self.status = "Committed; push failed" }
                else { self.status = push ? "Committed and pushed" : "Committed"; self.message = "" }
                self.refresh()
            }
        }
    }
}

struct ChangesPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var changes = ChangesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(changes.changes.isEmpty ? "No changes" : "\(changes.changes.count) changed").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.text2)
                if let wp = model.currentWorkPath, wp != model.currentProject?.path, let b = GitInfo.shared.branch(for: wp) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                        Text(b).font(T.mono(11)).lineLimit(1)
                    }
                    .foregroundStyle(T.text3).help("Worktree: \(wp)")
                }
                Spacer()
                Button { changes.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(ChromeButtonStyle())
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 32)
            Hairline()
            if !changes.isRepo {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 24, weight: .light)).foregroundStyle(T.text3)
                    Text("Not a git repository").font(T.body).foregroundStyle(T.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    TextField("Commit message", text: $changes.message, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.plain).font(T.body)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.frame.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
                    HStack(spacing: 6) {
                        Button("Commit") { changes.commit(push: false) }.buttonStyle(PrimaryButtonStyle())
                        Button("Commit & Push") { changes.commit(push: true) }.buttonStyle(SecondaryButtonStyle())
                        Spacer()
                    }
                    .disabled(changes.busy || changes.changes.isEmpty || changes.message.isEmpty)
                    if !changes.status.isEmpty { Text(changes.status).font(T.caption).foregroundStyle(T.text2).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .padding(12)
                Hairline()
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
                            Text("Working tree clean").font(T.body).foregroundStyle(T.text2).padding(14)
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

    @ViewBuilder private func group(_ title: String, _ list: [GitChange], staged: Bool) -> some View {
        let add = list.reduce(0) { $0 + ((staged ? $1.stagedStat : $1.unstagedStat)?.0 ?? 0) }
        let rem = list.reduce(0) { $0 + ((staged ? $1.stagedStat : $1.unstagedStat)?.1 ?? 0) }
        let open = !collapsed.contains(title)
        GroupHeader(title: "\(title) (\(list.count))", open: open, added: add, removed: rem,
                    action: staged ? ("minus", "Unstage all", { changes.unstage(list.map(\.path)) }) : ("plus", "Stage all", { changes.stage(list.map(\.path)) })) {
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
    let action: (String, String, () -> Void)
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(T.text3).frame(width: 10)
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(T.text2)
            Spacer()
            if hover {
                Button(action: action.2) { Image(systemName: action.0).font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(IconButtonStyle(size: 18)).help(action.1)
            }
            DiffCount(added: added, removed: removed)
        }
        .padding(.horizontal, 12).frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
    }
}

struct DiffCount: View {
    let added: Int, removed: Int
    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(T.green) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(T.red) }
        }
        .font(T.mono(10.5, .medium))
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
            Text(badge).font(T.mono(10.5, .bold)).foregroundStyle(GitChange.color(badge)).frame(width: 12)
            Text((c.path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundStyle(T.text).lineLimit(1)
            Text((c.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if hover {
                Button { model.openDoc(.file(c.path)) } label: { Image(systemName: "doc.text").font(.system(size: 10)) }
                    .buttonStyle(IconButtonStyle(size: 18)).help("Open file")
                Button { staged ? changes.unstage([c.path]) : changes.stage([c.path]) } label: {
                    Image(systemName: staged ? "minus" : "plus").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 18)).help(staged ? "Unstage" : "Stage")
            } else if let stat {
                DiffCount(added: stat.0, removed: stat.1)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(selected ? T.selection : hover ? T.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture {
            changes.selected = key
            model.openChanges(scrollTo: key)
        }
        .contextMenu {
            Button("Open File") { model.openDoc(.file(c.path)) }
            Button(staged ? "Unstage" : "Stage") { staged ? changes.unstage([c.path]) : changes.stage([c.path]) }
            Button("Copy Path") { copy(c.path) }
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
                        .font(T.mono(11.5))
                        .foregroundStyle(s.hasPrefix("@@") ? T.blue : s.hasPrefix("+") && !s.hasPrefix("+++") ? T.green : s.hasPrefix("-") && !s.hasPrefix("---") ? T.red : T.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(s.hasPrefix("+") && !s.hasPrefix("+++") ? T.green.opacity(0.10) : s.hasPrefix("-") && !s.hasPrefix("---") ? T.red.opacity(0.10) : .clear)
                }
            }
            .padding(6)
            .textSelection(.enabled)
        }
    }
}
