import AppKit
import SwiftUI

struct GitChange: Identifiable, Equatable {
    var id: String { path }
    let status: String   // two-letter porcelain code
    let path: String

    var badge: String {
        let s = status.trimmingCharacters(in: .whitespaces)
        if s == "??" { return "U" }
        return String(s.first(where: { $0 != " " }) ?? "M")
    }

    var color: Color {
        switch badge {
        case "A", "U": return .green
        case "D": return .red
        case "R": return .blue
        default: return .orange
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
            DispatchQueue.main.async {
                self.isRepo = out != nil
                if self.changes != list { self.changes = list }
                if let sel = self.selected, !list.contains(where: { $0.path == sel }) { self.selected = nil; self.diff = "" }
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
                let content = (try? String(contentsOfFile: full, encoding: .utf8)) ?? "(binary or unreadable file)"
                d = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(2000).map { "+" + $0 }.joined(separator: "\n")
            } else {
                d = GitInfo.git(["diff", "HEAD", "--", c.path], in: path) ?? GitInfo.git(["diff", "--cached", "--", c.path], in: path) ?? ""
            }
            if d.count > 400_000 { d = String(d.prefix(400_000)) + "\n… (truncated)" }
            DispatchQueue.main.async { if self.selected == c.path { self.diff = d } }
        }
    }

    func commit(push: Bool) {
        guard let path, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        status = "Committing…"
        let msg = message
        DispatchQueue.global(qos: .userInitiated).async {
            _ = GitInfo.git(["add", "-A"], in: path)
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
            HStack {
                Text("Changes").font(.system(size: 12, weight: .semibold))
                if !changes.changes.isEmpty {
                    Text("\(changes.changes.count)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
                Spacer()
                Button { changes.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(ChromeButtonStyle())
            }
            .padding(.horizontal, 10).frame(height: 32)
            Divider()
            if !changes.isRepo {
                Text("Not a git repository").foregroundStyle(.secondary).font(.system(size: 12)).padding(12)
                Spacer()
            } else {
                VStack(spacing: 6) {
                    TextField("Commit message", text: $changes.message, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    HStack {
                        Button("Commit") { changes.commit(push: false) }
                        Button("Commit & Push") { changes.commit(push: true) }
                        Spacer()
                    }
                    .controlSize(.small)
                    .disabled(changes.busy || changes.changes.isEmpty || changes.message.isEmpty)
                    if !changes.status.isEmpty { Text(changes.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes.changes) { c in
                            HStack(spacing: 6) {
                                Text((c.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                Text((c.path as NSString).deletingLastPathComponent).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(c.badge).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(c.color)
                            }
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(changes.selected == c.path ? Palette.selection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { changes.select(c) }
                        }
                        if changes.changes.isEmpty {
                            Text("Working tree clean").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
                .frame(maxHeight: changes.selected == nil ? .infinity : 220)
                if changes.selected != nil {
                    Divider()
                    DiffView(text: changes.diff)
                }
            }
        }
        .onAppear { changes.attach(path: model.currentProject?.path) }
        .onDisappear { changes.detach() }
        .onChange(of: model.currentProject?.path) { _, p in changes.attach(path: p) }
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(s.hasPrefix("@@") ? Color.blue : s.hasPrefix("+") && !s.hasPrefix("+++") ? Color.green : s.hasPrefix("-") && !s.hasPrefix("---") ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(s.hasPrefix("+") && !s.hasPrefix("+++") ? Color.green.opacity(0.08) : s.hasPrefix("-") && !s.hasPrefix("---") ? Color.red.opacity(0.08) : .clear)
                }
            }
            .padding(6)
            .textSelection(.enabled)
        }
    }
}
