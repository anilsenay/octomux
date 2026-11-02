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
    let when: String
    let subject: String
    let refs: String
}

final class HistoryModel: ObservableObject {
    @Published var commits: [Commit] = []
    @Published var selected: String?
    @Published var detail = ""
    @Published var isRepo = true
    private var path: String?

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        selected = nil
        detail = ""
        refresh()
    }

    func refresh() {
        guard let path else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = GitInfo.git(["log", "-n", "300", "--date=relative", "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%D"], in: path)
            let list = (out ?? "").split(separator: "\n").compactMap { line -> Commit? in
                let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 6 else { return nil }
                return Commit(id: f[0], short: f[1], author: f[2], when: f[3], subject: f[4], refs: f[5])
            }
            DispatchQueue.main.async {
                self.isRepo = out != nil
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

    var body: some View {
        VStack(spacing: 0) {
            if !h.isRepo {
                PanelEmpty(icon: "clock.arrow.circlepath", text: "Not a git repository")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(h.commits) { c in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.subject).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(c.short).font(T.mono(10.5)).foregroundStyle(T.accent)
                                    Text(c.author).lineLimit(1)
                                    Text("·")
                                    Text(c.when).lineLimit(1)
                                    if !c.refs.isEmpty {
                                        Text(c.refs.replacingOccurrences(of: "HEAD -> ", with: "")).font(T.mono(10)).foregroundStyle(T.green).lineLimit(1)
                                    }
                                }
                                .font(.system(size: 11)).foregroundStyle(T.text3)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(h.selected == c.id ? T.selection : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { h.select(c) }
                            .contextMenu { Button("Copy Hash") { copy(c.id) } }
                        }
                    }
                    .padding(6)
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
    private(set) var path: String?
    private var all: [String] = []

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        selected = nil
        preview = ""
        expanded = []
        load()
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
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3).frame(width: 10)
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(T.text3)
                Text(n.name).font(.system(size: 12.5)).foregroundStyle(T.text).lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14 + 6).frame(height: 24)
            .contentShape(Rectangle())
            .onTapGesture { if open { f.expanded.remove(n.id) } else { f.expanded.insert(n.id) } }
        } else {
            fileRow(rel: n.id, label: n.name, depth: depth)
        }
    }

    private func fileRow(rel: String, label: String, depth: Int) -> some View {
        HStack(spacing: 5) {
            Spacer().frame(width: 10)
            Image(systemName: "doc").font(.system(size: 10.5)).foregroundStyle(T.text3)
            Text(label).font(.system(size: 12.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14 + 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(f.selected == rel ? T.selection : .clear))
        .contentShape(Rectangle())
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
