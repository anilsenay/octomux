import AppKit
import SwiftUI

/// The `/` (commands, skills) and `@` (files) menus of the chat composers. `ComposerField` reports the text
/// and caret; this finds the token being typed, lists matches, and replaces the token when one is picked.
final class ComposerCompletion: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { insert }
        let title: String
        var detail = ""
        let insert: String
        var icon = "command"
        var badge = ""
    }

    @Published private(set) var items: [Item] = []
    @Published var selected = 0
    @Published private(set) var trigger: Character?
    /// Lists matches for a trigger (`/` or `@`) and the text after it.
    var provider: (Character, String) -> [Item] = { _, _ in [] }
    weak var textView: NSTextView?
    private var range: NSRange?
    private var dismissed: NSRange?
    private var lastText = ""
    private var lastCaret = 0

    var isActive: Bool { !items.isEmpty }

    /// The token at the caret: `/name` at the very start of the message, or `@path` after a space or at the start.
    static func token(in text: String, caret: Int) -> (Character, String, NSRange)? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        var start = caret
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 32 || c == 10 || c == 9 { break }
            start -= 1
        }
        guard start < caret else { return nil }
        let word = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let first = word.first else { return nil }
        if first == "/", ns.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("/", String(word.dropFirst()), NSRange(location: start, length: caret - start))
        }
        if first == "@" { return ("@", String(word.dropFirst()), NSRange(location: start, length: caret - start)) }
        return nil
    }

    func update(text: String, caret: Int) {
        lastText = text; lastCaret = caret
        guard let (t, q, r) = Self.token(in: text, caret: caret) else { close(); return }
        if let d = dismissed, d.location == r.location { close(keepDismissed: true); return }
        dismissed = nil
        let found = Array(provider(t, q).prefix(60))
        range = r
        trigger = t
        if found != items { items = found; selected = 0 }
        if found.isEmpty { trigger = nil }
    }

    /// Lists again with the same text (a file index finished loading).
    func refresh() { if trigger != nil || range != nil { update(text: lastText, caret: lastCaret) } }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
    }

    func accept(_ index: Int? = nil) {
        guard let tv = textView, let r = range, items.indices.contains(index ?? selected) else { return }
        let item = items[index ?? selected]
        close()
        let text = item.insert + " "
        if tv.shouldChangeText(in: r, replacementString: text) {
            tv.replaceCharacters(in: r, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
        }
        tv.window?.makeFirstResponder(tv)
    }

    func dismiss() {
        dismissed = range
        close(keepDismissed: true)
    }

    private func close(keepDismissed: Bool = false) {
        if !keepDismissed { dismissed = nil }
        range = nil
        trigger = nil
        if !items.isEmpty { items = [] }
    }
}

// MARK: - Sources

/// Slash commands an agent understands: built-ins, the user's and the project's commands and skills, and
/// enabled plugins' (Claude); built-ins and saved prompts (Codex). Read from files only (names, descriptions).
enum SlashCommands {
    struct Entry: Equatable { let name: String; let detail: String; let kind: String }

    static let claudeBuiltins: [Entry] = [
        ("compact", "Summarize the conversation to free context"), ("clear", "Start over with an empty conversation"),
        ("context", "Show what fills the context"), ("model", "Switch the model"), ("init", "Write a CLAUDE.md for this project"),
        ("review", "Review a pull request"), ("memory", "Edit memory files"), ("permissions", "Allow or deny tools"),
        ("mcp", "MCP servers"), ("agents", "Subagents"), ("hooks", "Hooks"), ("config", "Settings"), ("cost", "Token usage and cost"),
        ("usage", "Plan usage limits"), ("todos", "Current todo list"), ("export", "Export the conversation"),
        ("rewind", "Go back to an earlier point"), ("add-dir", "Add a working directory"), ("doctor", "Check the installation"),
        ("help", "All commands"),
    ].map { Entry(name: $0.0, detail: $0.1, kind: "built-in") }

    static let codexBuiltins: [Entry] = [
        ("model", "Choose the model and reasoning effort"), ("approvals", "Choose what Codex may do without asking"),
        ("review", "Review the current changes"), ("new", "Start a new chat"), ("init", "Write an AGENTS.md"),
        ("compact", "Summarize the conversation to free context"), ("diff", "Show the git diff"), ("mention", "Mention a file"),
        ("status", "Session settings and token usage"), ("mcp", "MCP tools"),
    ].map { Entry(name: $0.0, detail: $0.1, kind: "built-in") }

    private static var cache: [String: (Date, [Entry])] = [:]

    static func list(kind: AgentKind?, configDir: URL, project: String?) -> [Entry] {
        let key = "\(kind.map { "\($0)" } ?? "")|\(configDir.path)|\(project ?? "")"
        if let (at, v) = cache[key], Date().timeIntervalSince(at) < 30 { return v }
        var out: [Entry] = []
        if kind == .codex {
            out = codexBuiltins
            for f in mdFiles(configDir.appendingPathComponent("prompts"), recursive: false) {
                out.append(Entry(name: "prompts:" + f.name, detail: f.detail, kind: "prompt"))
            }
        } else {
            out = claudeBuiltins
            let dirs = [configDir] + (project.map { [URL(fileURLWithPath: $0).appendingPathComponent(".claude")] } ?? [])
            for (i, d) in dirs.enumerated() {
                let scope = i == 0 ? "user" : "project"
                for f in mdFiles(d.appendingPathComponent("commands"), recursive: true) { out.append(Entry(name: f.name, detail: f.detail, kind: scope)) }
                for s in skills(d.appendingPathComponent("skills")) { out.append(Entry(name: s.name, detail: s.detail, kind: "skill")) }
            }
            out += pluginEntries(configDir)
        }
        // Later sources win over built-ins of the same name (a custom /review), keeping the first position.
        var seen: [String: Int] = [:]
        var merged: [Entry] = []
        for e in out {
            if let i = seen[e.name] { merged[i] = e } else { seen[e.name] = merged.count; merged.append(e) }
        }
        cache[key] = (Date(), merged)
        return merged
    }

    /// `name` (subfolders joined with `:`) and the frontmatter description, else the first line of text.
    static func mdFiles(_ dir: URL, recursive: Bool) -> [(name: String, detail: String)] {
        // Relative paths from the folder itself (a symlinked folder such as /var → /private/var keeps them right).
        guard let en = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var out: [(String, String)] = []
        while let rel = en.nextObject() as? String {
            if !recursive, rel.contains("/") { continue }
            guard rel.hasSuffix(".md"), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            out.append((String(rel.dropLast(3)).replacingOccurrences(of: "/", with: ":"), describe(dir.appendingPathComponent(rel)).detail))
            if out.count > 400 { break }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    static func skills(_ dir: URL) -> [(name: String, detail: String)] {
        guard let subs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return subs.compactMap { d in
            let f = d.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            let m = describe(f)
            return (m.name ?? d.lastPathComponent, m.detail)
        }.sorted { $0.0 < $1.0 }
    }

    /// Enabled plugins' commands and skills, named `plugin:command`.
    static func pluginEntries(_ configDir: URL) -> [Entry] {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: configDir.appendingPathComponent("plugins/installed_plugins.json").path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = o["plugins"] as? [String: Any] else { return [] }
        var enabled: [String: Bool] = [:]
        if let s = fm.contents(atPath: configDir.appendingPathComponent("settings.json").path),
           let so = try? JSONSerialization.jsonObject(with: s) as? [String: Any] {
            enabled = so["enabledPlugins"] as? [String: Bool] ?? [:]
        }
        var out: [Entry] = []
        for (key, v) in plugins.sorted(by: { $0.key < $1.key }) {
            guard enabled[key] == true, let install = ((v as? [[String: Any]])?.first)?["installPath"] as? String else { continue }
            let plugin = String(key.split(separator: "@").first ?? Substring(key))
            let root = URL(fileURLWithPath: install)
            for f in mdFiles(root.appendingPathComponent("commands"), recursive: true) { out.append(Entry(name: plugin + ":" + f.name, detail: f.detail, kind: plugin)) }
            for s in skills(root.appendingPathComponent("skills")) { out.append(Entry(name: plugin + ":" + s.name, detail: s.detail, kind: plugin)) }
        }
        return out
    }

    /// Frontmatter `name` / `description` of a markdown file (only its first 4 KB is read).
    static func describe(_ u: URL) -> (name: String?, detail: String) {
        guard let h = try? FileHandle(forReadingFrom: u) else { return (nil, "") }
        defer { try? h.close() }
        let text = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        var name: String?, detail = ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            while let l = lines.first, l.trimmingCharacters(in: .whitespaces) != "---" {
                lines.removeFirst()
                func value(_ k: String) -> String? {
                    guard l.hasPrefix(k + ":") else { return nil }
                    return l.dropFirst(k.count + 1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                if let v = value("name") { name = v }
                if let v = value("description") { detail = v }
            }
            if !lines.isEmpty { lines.removeFirst() }
        }
        if detail.isEmpty { detail = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") } ?? "" }
        return (name, String(detail.trimmingCharacters(in: .whitespaces).prefix(160)))
    }
}

/// Files of a folder for `@` (git's tracked and untracked-but-not-ignored files; a bounded walk elsewhere),
/// cached per folder and refreshed in the background.
final class FileIndex {
    static let shared = FileIndex()
    private var cache: [String: (at: Date, files: [String])] = [:]
    private var loading: Set<String> = []
    private let q = DispatchQueue(label: "octomux.fileindex", qos: .userInitiated)

    /// Cached files of `dir`; starts a refresh when missing or older than 30 s (`done` runs on main when it lands).
    func files(_ dir: String, done: @escaping () -> Void) -> [String]? {
        let c = cache[dir]
        if (c == nil || Date().timeIntervalSince(c!.at) > 30), !loading.contains(dir) {
            loading.insert(dir)
            q.async {
                let list = Self.load(dir)
                DispatchQueue.main.async {
                    self.cache[dir] = (Date(), list)
                    self.loading.remove(dir)
                    done()
                }
            }
        }
        return c?.files
    }

    static func load(_ dir: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "ls-files", "-co", "--exclude-standard", "-z"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                return data.split(separator: 0).prefix(100_000).map { String(decoding: $0, as: UTF8.self) }
            }
        }
        // Not a repository: a bounded walk that skips hidden folders.
        var files: [String] = []
        let root = URL(fileURLWithPath: dir)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let u as URL in en {
            if ["node_modules", "build", "target", "dist", ".build"].contains(u.lastPathComponent) { en.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(String(u.path.dropFirst(root.path.count + 1)))
                if files.count >= 20_000 { break }
            }
        }
        return files
    }
}

/// Ranks names for a typed query: exact, then name prefix, then the file name's prefix, then substring,
/// then letters in order. Lower is better; nil = no match.
enum FuzzyRank {
    static func score(_ candidate: String, _ query: String) -> Int? {
        guard !query.isEmpty else { return 1000 + candidate.count }
        let c = candidate.lowercased(), q = query.lowercased()
        let leaf = (c as NSString).lastPathComponent
        if c == q || leaf == q { return 0 }
        if c.hasPrefix(q) { return 100 }
        if leaf.hasPrefix(q) { return 200 }
        if let r = c.range(of: q) { return 300 + c.distance(from: c.startIndex, to: r.lowerBound) + c.count }
        var it = c.makeIterator(), gaps = 0
        for ch in q {
            var found = false
            while let x = it.next() { if x == ch { found = true; break }; gaps += 1 }
            if !found { return nil }
        }
        return 1000 + gaps + c.count
    }

    static func rank<T>(_ xs: [T], _ query: String, key: (T) -> String, limit: Int = 60) -> [T] {
        // Ties keep the list's own order (built-in commands come in a useful order, files sorted by git).
        var scored: [(item: T, score: Int, index: Int)] = []
        for (i, x) in xs.enumerated() {
            if let sc = score(key(x), query) { scored.append((x, sc, i)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score < b.score : a.index < b.index }
        return scored.prefix(limit).map { $0.item }
    }
}

extension ComposerCompletion {
    /// Commands for the agent kind and files of the folder, as the chat composers use them.
    func configure(kind: @escaping () -> AgentKind?, configDir: @escaping () -> URL, folder: @escaping () -> String?) {
        provider = { [weak self] trigger, query in
            switch trigger {
            case "/":
                let all = SlashCommands.list(kind: kind(), configDir: configDir(), project: folder())
                return FuzzyRank.rank(all, query, key: \.name).map {
                    Item(title: "/" + $0.name, detail: $0.detail, insert: "/" + $0.name,
                         icon: $0.kind == "skill" ? "sparkles" : $0.kind == "built-in" ? "command" : "text.bubble", badge: $0.kind == "built-in" ? "" : $0.kind)
                }
            case "@":
                guard let dir = folder(), let files = FileIndex.shared.files(dir, done: { self?.refresh() }) else { return [] }
                let ref = kind() == .codex ? "" : "@"
                return FuzzyRank.rank(files, query, key: { $0 }).map { f in
                    let quoted = f.contains(" ") ? "\"\(f)\"" : f
                    return Item(title: (f as NSString).lastPathComponent, detail: (f as NSString).deletingLastPathComponent, insert: ref + quoted, icon: "doc")
                }
            default: return []
            }
        }
    }
}

/// The menu above a composer: up to eight rows, keyboard hints at the bottom.
struct CompletionMenu: View {
    @ObservedObject var completion: ComposerCompletion
    var body: some View {
        if completion.isActive {
            VStack(alignment: .leading, spacing: 0) {
                Text(completion.trigger == "@" ? "FILES" : "COMMANDS & SKILLS")
                    .font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text3).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(completion.items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == completion.selected)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { completion.accept(i) }
                                    .onHover { if $0 { completion.selected = i } }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(height: CGFloat(min(completion.items.count, 8)) * (36 * T.k + 1))
                    .onChange(of: completion.selected) { _, i in proxy.scrollTo(i) }
                }
                Hairline()
                Text("↑↓ navigate · ↩ or ⇥ select · esc dismiss").font(.system(size: T.k * 10.5)).foregroundStyle(T.text3)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.border))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
    }

    private func row(_ item: ComposerCompletion.Item, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon).font(.system(size: T.k * 11)).foregroundStyle(T.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: T.k * 12.5, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
                    if !item.badge.isEmpty {
                        Text(item.badge).font(.system(size: T.k * 10)).foregroundStyle(T.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(T.hover))
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: T.k * 11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 36 * T.k)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? T.hover : Color.clear))
    }
}

/// Where an agent profile keeps its commands, skills and plugins.
enum ChatAgentDirs {
    static func config(_ p: Profile?) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func expand(_ s: String) -> URL { URL(fileURLWithPath: s.hasPrefix("~/") ? home.path + String(s.dropFirst(1)) : s) }
        if p?.kind == .codex || p?.icon == "codex" {
            return p?.env["CODEX_HOME"].map(expand) ?? home.appendingPathComponent(".codex")
        }
        return p?.env["CLAUDE_CONFIG_DIR"].map(expand) ?? home.appendingPathComponent(".claude")
    }
}
