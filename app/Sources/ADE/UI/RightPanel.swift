import AppKit
import SwiftUI

enum RightTab: String, CaseIterable { case changes = "Changes", history = "History", files = "Files" }

/// Right-hand panel: Changes / History / Files of the current work path (project or worktree).
struct RightPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("ade.rightTab") private var tab = RightTab.changes.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RightTab.allCases, id: \.self) { t in
                    Chip(selected: tab == t.rawValue, action: { tab = t.rawValue }) { Text(t.rawValue) }
                }
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 38)
            Hairline()
            switch RightTab(rawValue: tab) ?? .changes {
            case .changes: ChangesPanel()
            case .history: HistoryPanel()
            case .files: FilesPanel()
            }
        }
    }
}

// MARK: - History

struct Commit: Identifiable, Equatable {
    let id: String      // full hash
    let short: String
    let author: String
    let when: String    // short date ("Oct 22")
    let relative: String
    let subject: String
    let refs: String
    var parents: [String] = []
    var graph = GraphRow()
    var remotes: [String] = []   // remote names, to tell "origin/x" from a local "feature/x"

    /// Decorations as labels: local branches, tags, remotes ("HEAD -> " dropped).
    var labels: [(text: String, kind: Int)] {   // kind 0 branch (HEAD), 1 branch, 2 tag, 3 remote
        refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { r in
            if r == "HEAD" { return nil }
            if r.hasPrefix("HEAD -> ") { return (String(r.dropFirst(8)), 0) }
            if r.hasPrefix("tag: ") { return (String(r.dropFirst(5)), 2) }
            if remotes.contains(where: { r.hasPrefix($0 + "/") }) { return (r, 3) }
            return (r, 1)
        }
    }
}

/// One row of the commit graph: lanes entering from above, the node's lane, lanes leaving below.
struct GraphRow: Equatable {
    var node = 0
    var through: [Int] = []          // lanes passing straight down
    var incoming: [Int] = []         // lanes (other than node) that end in this commit (merges into it)
    var outgoing: [Int] = []         // lanes the node's extra parents continue in (merge parents)
    var nodeFromAbove = false        // a line enters the node from above
    var nodeToBelow = false          // the first parent continues below in the node lane
    var width = 1

    /// Assigns lanes to commits in log order (newest first).
    static func layout(_ commits: [Commit]) -> [Commit] {
        var lanes: [String?] = []
        var out = commits
        for (k, c) in commits.enumerated() {
            var row = GraphRow()
            let matches = lanes.indices.filter { lanes[$0] == c.id }
            let idx: Int
            if let first = matches.first { idx = first; row.nodeFromAbove = true }
            else if let free = lanes.firstIndex(where: { $0 == nil }) { idx = free; lanes[free] = c.id }
            else { lanes.append(c.id); idx = lanes.count - 1 }
            row.node = idx
            row.incoming = matches.filter { $0 != idx }
            for i in row.incoming { lanes[i] = nil }
            row.through = lanes.indices.filter { $0 != idx && lanes[$0] != nil && !row.incoming.contains($0) }
            if let p0 = c.parents.first {
                // The first parent continues in this lane even if another lane waits for it too;
                // the lanes meet at the parent's row (the leftmost one keeps going).
                lanes[idx] = p0; row.nodeToBelow = true
                for p in c.parents.dropFirst() {
                    if let j = lanes.firstIndex(where: { $0 == p }) { row.outgoing.append(j) }
                    else if let free = lanes.firstIndex(where: { $0 == nil }) { lanes[free] = p; row.outgoing.append(free) }
                    else { lanes.append(p); row.outgoing.append(lanes.count - 1) }
                }
            } else { lanes[idx] = nil }
            while lanes.last == .some(nil) { lanes.removeLast() }
            row.width = max(lanes.count, idx + 1, (row.through + row.incoming + row.outgoing).max().map { $0 + 1 } ?? 1)
            out[k].graph = row
        }
        // One width for every row so the text column stays aligned.
        let w = min(8, out.map(\.graph.width).max() ?? 1)
        for k in out.indices { out[k].graph.width = w }
        return out
    }
}

/// Draws one graph row (lane colors cycle).
struct GraphCell: View {
    let row: GraphRow
    let head: Bool
    static let lane: CGFloat = 12
    static let colors: [Color] = [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.94, green: 0.55, blue: 0.22), Color(red: 0.31, green: 0.76, blue: 0.48),
                                  Color(red: 0.75, green: 0.45, blue: 0.95), Color(red: 0.95, green: 0.38, blue: 0.45), Color(red: 0.25, green: 0.75, blue: 0.8)]

    var body: some View {
        Canvas { ctx, size in
            let x = { (i: Int) in CGFloat(i) * Self.lane + Self.lane / 2 + 2 }
            let mid = min(size.height / 2, 14)
            func color(_ i: Int) -> Color { Self.colors[i % Self.colors.count] }
            func line(_ a: CGPoint, _ b: CGPoint, _ c: Color) {
                var p = Path()
                p.move(to: a)
                if a.x == b.x { p.addLine(to: b) } else {
                    p.addCurve(to: b, control1: CGPoint(x: a.x, y: (a.y + b.y) / 2), control2: CGPoint(x: b.x, y: (a.y + b.y) / 2))
                }
                ctx.stroke(p, with: .color(c), lineWidth: 1.6)
            }
            for i in row.through { line(CGPoint(x: x(i), y: 0), CGPoint(x: x(i), y: size.height), color(i)) }
            let n = CGPoint(x: x(row.node), y: mid)
            if row.nodeFromAbove { line(CGPoint(x: n.x, y: 0), n, color(row.node)) }
            if row.nodeToBelow { line(n, CGPoint(x: n.x, y: size.height), color(row.node)) }
            for i in row.incoming { line(CGPoint(x: x(i), y: 0), n, color(i)) }
            for j in row.outgoing { line(n, CGPoint(x: x(j), y: size.height), color(j)) }
            let r: CGFloat = head ? 4.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2))
            if head {
                ctx.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(dot, with: .color(color(row.node)), lineWidth: 2)
            } else {
                ctx.fill(dot, with: .color(color(row.node)))
            }
        }
        .frame(width: CGFloat(max(1, row.width)) * Self.lane + 4)
    }
}

final class HistoryModel: ObservableObject {
    @Published var commits: [Commit] = []
    @Published var selected: String?
    @Published var isRepo = true
    @Published var branch = ""
    @Published var all = UserDefaults.standard.bool(forKey: "ade.historyAll") {
        didSet { UserDefaults.standard.set(all, forKey: "ade.historyAll"); refresh() }
    }
    private var path: String?

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        selected = nil
        refresh()
    }

    func refresh() {
        guard let path else { return }
        let all = self.all
        DispatchQueue.global(qos: .utility).async {
            let out = GitInfo.git(["log", "-n", "400", "--topo-order"] + (all ? ["--all"] : []) +
                                  ["--date=format:%b %d", "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%ar%x1f%s%x1f%D%x1f%P"], in: path)
            var list = (out ?? "").split(separator: "\n").compactMap { line -> Commit? in
                let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 8 else { return nil }
                return Commit(id: f[0], short: f[1], author: f[2], when: f[3], relative: f[4], subject: f[5], refs: f[6],
                              parents: f[7].split(separator: " ").map(String.init))
            }
            let remotes = (GitInfo.git(["remote"], in: path) ?? "").split(separator: "\n").map(String.init)
            for k in list.indices { list[k].remotes = remotes }
            list = GraphRow.layout(list)
            let branch = GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self.isRepo = out != nil
                self.branch = branch
                if self.commits != list { self.commits = list }
            }
        }
    }

    func select(_ c: Commit) {
        selected = c.id
        guard let path else { return }
        AppModel.shared.openDoc(.commit(c.id, c.subject), workPath: path)
    }
}

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var h = HistoryModel()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if !h.isRepo {
                PanelEmpty(icon: "clock.arrow.circlepath", text: "Not a git repository")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5)).foregroundStyle(T.text3)
                    Text(h.branch).font(.system(size: 12, weight: .semibold)).foregroundStyle(T.text2).lineLimit(1)
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(T.text3)
                    TextField("Filter", text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 80)
                    Button { h.all.toggle() } label: { Text(h.all ? "All" : "Current").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(ChromeButtonStyle(active: h.all)).help(h.all ? "Showing all branches" : "Showing the current branch")
                    Button { h.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(ChromeButtonStyle())
                }
                .padding(.leading, 12).padding(.trailing, 8).frame(height: 32)
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let shown = query.isEmpty ? h.commits : h.commits.filter {
                            $0.subject.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) || $0.id.hasPrefix(query.lowercased())
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                            CommitRow(c: c, head: i == 0 && query.isEmpty && !h.all, graph: query.isEmpty,
                                      selected: { if case .commit(let hh, _) = model.activeDoc?.kind { return hh == c.id }; return false }())
                                .onTapGesture { h.select(c) }
                                .contextMenu {
                                    Button("Copy Hash") { copy(c.id) }
                                    Button("Copy Subject") { copy(c.subject) }
                                }
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
        .onAppear { h.attach(model.currentWorkPath) }
        .onChange(of: model.currentWorkPath) { _, p in h.attach(p) }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let i = n.userInfo?["commit"] as? Int, i < h.commits.count { h.select(h.commits[i]) }
        }
    }
}

private struct CommitRow: View {
    let c: Commit
    let head: Bool
    let graph: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if graph { GraphCell(row: c.graph, head: head || c.refs.hasPrefix("HEAD")).frame(maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.subject).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(Array(c.labels.prefix(2).enumerated()), id: \.offset) { _, l in RefLabel(text: l.text, kind: l.kind) }
                    if c.labels.count > 2 { Text("+\(c.labels.count - 2)").font(.system(size: 10)).foregroundStyle(T.text3) }
                }
                HStack(spacing: 6) {
                    Text(c.author).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(c.when).help(c.relative)
                    Text(c.short).font(T.mono(10.5))
                }
                .font(.system(size: 11)).foregroundStyle(T.text3)
            }
            .padding(.vertical, 5)
        }
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(selected ? T.selection : hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .help("\(c.short) · \(c.author) · \(c.relative)")
    }
}

private struct RefLabel: View {
    let text: String
    let kind: Int
    var body: some View {
        let color: Color = kind == 2 ? T.amber : kind == 3 ? T.text3 : T.accent
        HStack(spacing: 3) {
            Image(systemName: kind == 2 ? "tag.fill" : kind == 3 ? "cloud" : "arrow.triangle.branch").font(.system(size: 8, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(kind == 0 ? Color.white : color)
        .padding(.horizontal, 5).frame(height: 16)
        .background(Capsule().fill(kind == 0 ? color : color.opacity(0.15)))
        .fixedSize()
    }
}

// MARK: - Files

final class FileNode: Identifiable {
    let id: String     // relative path
    let name: String
    var children: [FileNode]?
    init(id: String, name: String, dir: Bool) {
        self.id = id
        self.name = name
        children = dir ? [] : nil
    }
}

final class FilesModel: ObservableObject {
    @Published var root: [FileNode] = []
    @Published var count = 0
    @Published var selected: String?
    @Published var preview = ""
    @Published var expanded: Set<String> = []
    /// Git status letter per changed file (M, A, D, U…), and folders that contain changes.
    @Published var status: [String: String] = [:]
    @Published var dirtyDirs: Set<String> = []
    private(set) var path: String?
    private var all: [String] = []
    private var timer: Timer?
    deinit { timer?.invalidate() }

    func refreshStatus() {
        guard let path else { return }
        DispatchQueue.global(qos: .utility).async {
            var map: [String: String] = [:]
            var dirs: Set<String> = []
            for line in (GitInfo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: path) ?? "").split(separator: "\n") where line.count > 3 {
                let code = Array(line.prefix(2))
                var p = String(line.dropFirst(3))
                if let arrow = p.range(of: " -> ") { p = String(p[arrow.upperBound...]) }
                p = p.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let letter = code[0] == "?" ? "U" : String(code[1] != " " ? code[1] : code[0])
                map[p] = letter
                var d = (p as NSString).deletingLastPathComponent
                while !d.isEmpty { dirs.insert(d); d = (d as NSString).deletingLastPathComponent }
            }
            DispatchQueue.main.async {
                if self.status != map { self.status = map }
                if self.dirtyDirs != dirs { self.dirtyDirs = dirs }
            }
        }
    }

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        selected = nil
        preview = ""
        expanded = []
        load()
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func load() {
        guard let path else { return }
        DispatchQueue.global(qos: .utility).async {
            var files: [String]
            if let out = GitInfo.git(["ls-files", "--cached", "--others", "--exclude-standard"], in: path) {
                files = out.split(separator: "\n").map(String.init)
            } else if AppModel.shared.host(forPath: path).0.isRemote {
                files = []   // non-git folders on remote hosts: no tree walk over the wire
            } else {
                files = []
                let fm = FileManager.default
                if let e = fm.enumerator(atPath: path) {
                    while let f = e.nextObject() as? String, files.count < 20_000 {
                        if f.hasPrefix(".git/") || f.contains("/node_modules/") || f.hasPrefix("node_modules") { continue }
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: (path as NSString).appendingPathComponent(f), isDirectory: &isDir), !isDir.boolValue { files.append(f) }
                    }
                }
            }
            files = Array(Set(files)).sorted()
            let tree = Self.build(files)
            DispatchQueue.main.async {
                self.all = files
                self.count = files.count
                self.root = tree
            }
        }
    }

    static func build(_ files: [String]) -> [FileNode] {
        let root = FileNode(id: "", name: "", dir: true)
        var dirs: [String: FileNode] = ["": root]
        for f in files {
            let parts = f.split(separator: "/").map(String.init)
            var parent = root
            var acc = ""
            for (i, part) in parts.enumerated() {
                acc = acc.isEmpty ? part : acc + "/" + part
                if i == parts.count - 1 {
                    parent.children?.append(FileNode(id: acc, name: part, dir: false))
                } else if let d = dirs[acc] {
                    parent = d
                } else {
                    let d = FileNode(id: acc, name: part, dir: true)
                    parent.children?.append(d)
                    dirs[acc] = d
                    parent = d
                }
            }
        }
        func sort(_ n: FileNode) {
            n.children?.sort { a, b in (a.children != nil) != (b.children != nil) ? a.children != nil : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            n.children?.forEach(sort)
        }
        sort(root)
        return root.children ?? []
    }

    func matches(_ q: String) -> [String] {
        guard !q.isEmpty else { return [] }
        return Array(all.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(300))
    }

    func open(_ rel: String) {
        selected = rel
        guard let path else { return }
        AppModel.shared.openDoc(.file(rel), workPath: path)
    }
}

struct FilesPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var f = FilesModel()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(T.text3)
                TextField("Filter \(f.count) files", text: $query).textFieldStyle(.plain).font(T.body)
                Button { f.load() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(ChromeButtonStyle())
            }
            .padding(.horizontal, 10).frame(height: 34)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        ForEach(rows(f.root, depth: 0), id: \.0.id) { node, depth in row(node, depth: depth) }
                    } else {
                        ForEach(f.matches(query), id: \.self) { rel in
                            fileRow(rel: rel, label: rel, depth: 0)
                        }
                    }
                }
                .padding(6)
            }
        }
        .onAppear { f.attach(model.currentWorkPath) }
        .onChange(of: model.currentWorkPath) { _, p in f.attach(p) }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let rel = n.userInfo?["file"] as? String {
                var acc = ""
                for part in rel.split(separator: "/").dropLast() { acc = acc.isEmpty ? String(part) : acc + "/" + part; f.expanded.insert(acc) }
                f.open(rel)
            }
        }
    }

    /// Flattened visible rows of the tree.
    private func rows(_ nodes: [FileNode], depth: Int) -> [(FileNode, Int)] {
        var out: [(FileNode, Int)] = []
        for n in nodes {
            out.append((n, depth))
            if n.children != nil, f.expanded.contains(n.id) { out += rows(n.children ?? [], depth: depth + 1) }
        }
        return out
    }

    @ViewBuilder private func row(_ n: FileNode, depth: Int) -> some View {
        if n.children != nil {
            let open = f.expanded.contains(n.id)
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                let dirty = f.dirtyDirs.contains(n.id)
                FolderIcon(open: open, tint: dirty ? T.amber.opacity(0.85) : nil)
                Text(n.name).font(.system(size: 12.5)).foregroundStyle(dirty ? T.amber : T.text).lineLimit(1)
                Spacer()
                if dirty { Circle().fill(T.amber.opacity(0.7)).frame(width: 5, height: 5).padding(.trailing, 6) }
            }
            .padding(.leading, CGFloat(depth) * 14 + 6).frame(height: 24)
            .background(HoverFill())
            .contentShape(Rectangle())
            .pointerCursor()
            .onTapGesture { if open { f.expanded.remove(n.id) } else { f.expanded.insert(n.id) } }
        } else {
            fileRow(rel: n.id, label: n.name, depth: depth)
        }
    }

    private func fileRow(rel: String, label: String, depth: Int) -> some View {
        let st = f.status[rel]
        let open: Bool = { if case .file(let r) = model.activeDoc?.kind, r == rel { return true }; return false }()
        return HStack(spacing: 5) {
            Spacer().frame(width: 10)
            FileIcon(name: (rel as NSString).lastPathComponent)
            Text(label).font(.system(size: 12.5)).foregroundStyle(st.map { GitChange.color($0) } ?? T.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let st { Text(st).font(T.mono(10.5, .bold)).foregroundStyle(GitChange.color(st)).padding(.trailing, 6) }
        }
        .padding(.leading, CGFloat(depth) * 14 + 6).frame(height: 24)
        .background(open ? AnyView(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(T.selection)) : AnyView(HoverFill()))
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture { f.open(rel) }
        .contextMenu {
            if let base = f.path {
                let full = (base as NSString).appendingPathComponent(rel)
                OpenInMenu(path: full)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
                Button("Copy Path") { copy(full) }
                Button("Copy Relative Path") { copy(rel) }
            }
        }
    }
}

struct PanelEmpty: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(T.text3)
            Text(text).font(T.body).foregroundStyle(T.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name { static let adeDebugPanel = Notification.Name("ade.debug.panel") }

/// Row background that lights up under the pointer.
struct HoverFill: View {
    @State private var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(hover ? T.hover : .clear)
            .onHover { hover = $0 }
    }
}
