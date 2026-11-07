import Foundation
import ImageIO

// A layout as a file people share (.octomux-layout.json), format v1. Data only — no code, no paths, no commands:
//
//   {"schema": 1,
//    "name": "Review desk", "author": "Ada",
//    "base": "agents",                       // a built-in layout: what the file doesn't say comes from it
//    "tree": {"row": [...]},                 // the window (blocks of this version; optional: the base's window)
//    "settings": {"regions": {...}, "statusBar": true, "chat": true, "sideChat": false},   // optional
//    "theme": {"id": "ink", "mode": "dark"}, // optional; applied only when you choose to
//    "keys": {"cmd.new-terminal-tab": "cmd+t"},   // optional; applied only when you choose to
//    "preview": "data:image/png;base64,…"}   // optional: a picture of the window
//
// Fields this version doesn't know are ignored; a file that can't be read, is for another schema, has no name or
// base, or whose tree breaks the blocks' rules is refused with the reason. Parts that only this Mac can't use (a
// theme it doesn't have, a shortcut for a command it doesn't know) are left out with a note.

struct LayoutFile: Equatable {
    static let schema = 1
    static let fileExtension = "octomux-layout.json"
    /// Bigger files are refused (a layout is a few KB; a preview at most a few hundred).
    static let maxBytes = 2_000_000
    static let maxPreviewBytes = 1_000_000

    struct Theme: Equatable { var id: String; var mode: String? }

    var name: String
    var author = ""
    var base: LayoutPreset
    /// The window; nil = the base's.
    var tree: ShellTree?
    /// The layout's switches and region items, as a layout's changes are stored (`regions`, `statusBar`, …).
    var settings: [String: JSONValue] = [:]
    var theme: Theme?
    var keys: [String: String] = [:]
    /// PNG or JPEG bytes.
    var preview: Data?

    enum Problem: Error, Equatable {
        case tooBig, unreadable, schema(Int), noName, base(String), tree(ShellTree.Problem)

        var message: String {
            switch self {
            case .tooBig: return "The file is too big for a layout."
            case .unreadable: return "It isn't an Octomux layout file (JSON with a name, a base layout and a window)."
            case .schema(let n): return n == 0 ? "It has no schema number." : "It is for layout schema \(n); this version reads schema \(LayoutFile.schema)."
            case .noName: return "It has no name."
            case .base(let b): return b.isEmpty ? "It names no base layout." : "Its base layout “\(b)” isn't one this version has."
            case .tree(let p): return "Its window can't be used: " + p.message
            }
        }
    }

    // MARK: Reading

    /// Reads a file; what it couldn't use is in `notes`. `themes` and `commands` are what this Mac has (nil: any,
    /// for what was checked when it came in).
    static func read(_ data: Data, themes: Set<String>?, commands: Set<String>?) -> Result<(file: LayoutFile, notes: [String]), Problem> {
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .failure(.unreadable) }
        return read(v, themes: themes, commands: commands)
    }

    static func read(_ v: JSONValue, themes: Set<String>?, commands: Set<String>?) -> Result<(file: LayoutFile, notes: [String]), Problem> {
        guard case .object(let o) = v else { return .failure(.unreadable) }
        let schema = ShellTree.schemaNumber(o["schema"])
        guard schema == Self.schema else { return .failure(.schema(schema)) }
        let name = (o["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.noName) }
        let baseName = o["base"]?.string ?? ""
        guard let base = LayoutPreset(rawValue: baseName) else { return .failure(.base(baseName)) }
        var f = LayoutFile(name: String(name.prefix(60)), base: base)
        var notes: [String] = []
        f.author = String((o["author"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if let t = o["tree"] {
            // The tree alone ({"row": …}) or as the engine stores it ({"schema": 1, "root": …}).
            var wrapped = t
            if case .object(let to) = t, to["root"] == nil { wrapped = .object(["schema": .number(Double(ShellTree.schema)), "root": t]) }
            switch ShellTree.parse(wrapped) {
            case .success(let tree): f.tree = tree
            case .failure(let p): return .failure(.tree(p))
            }
        }
        if case .object(let s)? = o["settings"] {
            // Only the parts a layout keeps; each read again (and checked) when the layout is resolved.
            for k in ["regions", "statusBar", "chat", "sideChat"] { if let x = s[k] { f.settings[k] = x } }
        }
        if case .object(let t)? = o["theme"], let id = t["id"]?.string {
            let mode = t["mode"]?.string.flatMap { ["dark", "light", "system"].contains($0) ? $0 : nil }
            if themes?.contains(id) ?? true { f.theme = Theme(id: id, mode: mode) } else { notes.append("Its theme “\(id)” isn't on this Mac; left out.") }
        }
        if case .object(let k)? = o["keys"] {
            var dropped = 0, kept = 0
            for (id, v) in k {
                guard let s = v.string, commands?.contains(id) ?? true, s.isEmpty || Self.isShortcut(s) else { dropped += 1; continue }
                // A file may give a command a key, never take one away or take a key the Mac and every app keep.
                guard !s.isEmpty, !Self.isReserved(s) else { kept += 1; continue }
                f.keys[id] = s
            }
            if dropped > 0 { notes.append(dropped == 1 ? "1 shortcut is for a command this version doesn't have; left out." : "\(dropped) shortcuts are for commands this version doesn't have; left out.") }
            if kept > 0 { notes.append(kept == 1 ? "1 shortcut would turn a command off or take ⌘Q, ⌘W, ⌘H, ⌘M or ⌘,; left out." : "\(kept) shortcuts would turn commands off or take ⌘Q, ⌘W, ⌘H, ⌘M or ⌘,; left out.") }
        }
        if let p = o["preview"]?.string {
            if let d = Self.image(fromDataURL: p) { f.preview = d } else { notes.append("Its preview picture couldn't be read; left out.") }
        }
        return .success((f, notes))
    }

    /// Keys a layout file can't take: quit, close, hide, hide others, minimize, settings, next window.
    static let reserved: [Shortcut] = ["cmd+q", "cmd+w", "cmd+h", "opt+cmd+h", "cmd+m", "cmd+,", "cmd+`"].compactMap(Shortcut.init(string:))
    static func isReserved(_ s: String) -> Bool { Shortcut(string: s).map { reserved.contains($0) } ?? false }

    /// The file's shortcuts this Mac can take as they are: none on a key another command has (built in or yours, and
    /// not moved by the file) or that two of its commands share. `current`: every command's shortcut now.
    static func usableKeys(_ keys: [String: String], current: [String: Shortcut]) -> (use: [String: String], clash: [String: String]) {
        var after = current
        for (id, s) in keys { after[id] = Shortcut(string: s) }
        var use: [String: String] = [:], clash: [String: String] = [:]
        for (id, s) in keys {
            guard let sc = Shortcut(string: s) else { continue }
            if let other = after.filter({ $0.key != id && $0.value == sc }).keys.sorted().first { clash[id] = other } else { use[id] = s }
        }
        return (use, clash)
    }

    /// "cmd+shift+t", "ctrl+cmd+left": modifiers then one key ("" turns a shortcut off).
    static func isShortcut(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let key = parts.last else { return false }
        let mods: Set<String> = ["cmd", "shift", "opt", "alt", "ctrl"]
        guard parts.dropLast().allSatisfy({ mods.contains($0) }) else { return false }
        let named: Set<String> = ["left", "right", "up", "down", "plus"]
        return named.contains(key) || (key.count == 1 && key != " ")
    }

    /// A PNG or JPEG data URL's bytes (nothing else: no remote pictures, no other formats).
    static func image(fromDataURL s: String) -> Data? {
        for prefix in ["data:image/png;base64,", "data:image/jpeg;base64,"] where s.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(s.dropFirst(prefix.count))), d.count <= maxPreviewBytes else { return nil }
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47], jpg: [UInt8] = [0xFF, 0xD8, 0xFF]
            let head = [UInt8](d.prefix(4))
            guard head.starts(with: png) || head.starts(with: jpg), isSmallPicture(d) else { return nil }
            return d
        }
        return nil
    }

    /// Biggest picture a preview may be once drawn (a small file can still unpack to gigabytes).
    static let maxPreviewSide = 4096, maxPreviewPixels = 16_000_000
    /// One picture that reads, no bigger than that, judged from its header before anything is drawn.
    static func isSmallPicture(_ d: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) == 1,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return false }
        return w > 0 && h > 0 && w <= maxPreviewSide && h <= maxPreviewSide && w * h <= maxPreviewPixels
    }

    // MARK: Writing

    /// The file people share (with the preview when there is one).
    func json(withPreview: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = ["schema": .number(Double(Self.schema)), "name": .string(name), "base": .string(base.rawValue)]
        if !author.isEmpty { o["author"] = .string(author) }
        if let tree, case .object(let t) = tree.json, let root = t["root"] { o["tree"] = root }
        if !settings.isEmpty { o["settings"] = .object(settings) }
        if let theme {
            var t: [String: JSONValue] = ["id": .string(theme.id)]
            if let m = theme.mode { t["mode"] = .string(m) }
            o["theme"] = .object(t)
        }
        if !keys.isEmpty { o["keys"] = .object(keys.mapValues { .string($0) }) }
        if withPreview, let p = preview {
            let png = p.prefix(4).starts(with: [0x89, 0x50, 0x4E, 0x47])
            o["preview"] = .string((png ? "data:image/png;base64," : "data:image/jpeg;base64,") + p.base64EncodedString())
        }
        return .object(o)
    }

    func data(withPreview: Bool = true) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(json(withPreview: withPreview))) ?? Data()
    }

    /// A file name for the layout ("Review desk.octomux-layout.json").
    var fileName: String {
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(safe) + "." + Self.fileExtension
    }
}

/// The layouts you saved or imported: global setting `ui.layouts` = {"<id>": <file without its preview>}; previews
/// are pictures in Octomux's folder (layout-previews/<id>.png), not in the setting every window reads.
enum SavedLayouts {
    static let key = "ui.layouts"

    /// The saved layouts by id; entries that no longer read are left out.
    static func parse(_ v: JSONValue?) -> [String: LayoutFile] {
        guard case .object(let o)? = v else { return [:] }
        var out: [String: LayoutFile] = [:]
        for (id, f) in o where isId(id) {
            // What was stored was checked when it came in; read it again with every theme and command accepted.
            if case .success(let r) = LayoutFile.read(f, themes: nil, commands: nil) { out[id] = r.file }
        }
        return out
    }

    /// In order: by name, then id.
    static func sorted(_ d: [String: LayoutFile]) -> [(id: String, file: LayoutFile)] {
        d.map { ($0.key, $0.value) }.sorted { $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending || ($0.1.name == $1.1.name && $0.0 < $1.0) }
    }

    static func adding(_ f: LayoutFile, id: String, to v: JSONValue?) -> JSONValue {
        var o = LayoutEdit.object(v)
        o[id] = f.json(withPreview: false)
        return .object(o)
    }

    static func removing(_ id: String, from v: JSONValue?) -> JSONValue? {
        var o = LayoutEdit.object(v)
        o[id] = nil
        return o.isEmpty ? nil : .object(o)
    }

    /// A new id ("u" + 8 hex), one no saved layout has.
    static func newId(unusedIn d: [String: LayoutFile] = [:]) -> String {
        while true {
            let id = "u" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            if d[id] == nil { return id }
        }
    }
    /// Ids name files (a saved layout's picture), so only the app's own form is one: "u" + 8 lowercase hex.
    static func isId(_ id: String) -> Bool {
        id.count == 9 && id.first == "u" && id.dropFirst().allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// "Review desk", "Review desk 2", …: a name no saved layout has.
    static func freeName(_ name: String, in d: [String: LayoutFile]) -> String {
        let names = Set(d.values.map(\.name))
        if !names.contains(name) { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    /// Where a saved layout's picture is; nil for anything that isn't an id (never a path out of the folder).
    static func previewURL(_ id: String) -> URL? {
        guard isId(id) else { return nil }
        return Paths.home.appendingPathComponent("layout-previews").appendingPathComponent(id + ".png")
    }
    static func preview(_ id: String) -> Data? { previewURL(id).flatMap { try? Data(contentsOf: $0) } }
    static func setPreview(_ id: String, _ d: Data?) {
        guard let u = previewURL(id) else { return }
        if let d {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: u)
        }
    }
}

// MARK: - In the app

extension AppModel {
    /// Themes and menu commands this Mac has (a layout file's theme and shortcuts must be among them).
    var knownThemes: Set<String> { Set(Themes.all.map(\.id)) }
    var knownCommands: Set<String> { Set(KeyBindings.shared.commands.map(\.id)) }
    /// Every command's shortcut now (built in, or yours).
    var currentShortcuts: [String: Shortcut] {
        var d: [String: Shortcut] = [:]
        for c in KeyBindings.shared.commands { if let s = KeyBindings.shared.current(c.id) { d[c.id] = s } }
        return d
    }

    /// The layout in use as a file: its base, its window (none when it is the classic one), its parts.
    func currentLayoutFile(name: String, author: String = "") -> LayoutFile {
        var f = LayoutFile(name: name, author: author, base: layout.preset)
        f.tree = shellTree
        f.settings = layout.settings
        return f
    }

    /// Saves the layout in use under a new name; it becomes the one in use when `use`. Returns its id.
    @discardableResult func saveLayoutAsNew(name: String, author: String = "", use: Bool = true) -> String {
        let id = SavedLayouts.newId(unusedIn: savedLayouts)
        let f = currentLayoutFile(name: SavedLayouts.freeName(name, in: savedLayouts), author: author)
        storeSavedLayouts(SavedLayouts.adding(f, id: id, to: savedLayoutsStored))
        if let from = layout.userId, let p = SavedLayouts.preview(from) { SavedLayouts.setPreview(id, p) }
        if use { chooseSavedLayout(id) }
        return id
    }

    @discardableResult func duplicateSavedLayout(_ id: String) -> String? {
        guard var f = savedLayouts[id] else { return nil }
        let new = SavedLayouts.newId(unusedIn: savedLayouts)
        f.name = SavedLayouts.freeName(f.name, in: savedLayouts)
        // The copy has the changes you made to the original.
        if layout.userId == id { f.settings = layout.settings; f.tree = shellTree }
        storeSavedLayouts(SavedLayouts.adding(f, id: new, to: savedLayoutsStored))
        SavedLayouts.setPreview(new, SavedLayouts.preview(id))
        return new
    }

    /// Deletes a saved layout; the window goes to its base if it was in use.
    func deleteSavedLayout(_ id: String) {
        guard let f = savedLayouts[id] else { return }
        if layout.userId == id { chooseLayout(f.base) }
        if let v = LayoutEdit.forget(user: id, in: layoutStored) { storeLayout(v) }
        storeSavedLayouts(SavedLayouts.removing(id, from: savedLayoutsStored))
        SavedLayouts.setPreview(id, nil)
    }

    /// Adds a layout read from a file. Its theme and shortcuts are applied only when asked; nothing in it runs.
    @discardableResult func addLayout(_ f: LayoutFile, use: Bool, applyTheme: Bool = false, applyKeys: Bool = false) -> String {
        let id = SavedLayouts.newId(unusedIn: savedLayouts)
        var g = f
        g.name = SavedLayouts.freeName(f.name, in: savedLayouts)
        storeSavedLayouts(SavedLayouts.adding(g, id: id, to: savedLayoutsStored))
        SavedLayouts.setPreview(id, f.preview)
        if applyTheme, let t = f.theme {
            setSetting("appearance.theme", t.id, scope: "global")
            if let m = t.mode { setSetting("appearance.mode", m, scope: "global") }
        }
        let keys = LayoutFile.usableKeys(f.keys, current: currentShortcuts).use
        if applyKeys, !keys.isEmpty {
            var o: [String: Any] = [:]
            if case .object(let d)? = settingValue("keybindings", scope: "global") { for (k, v) in d { if let s = v.string { o[k] = s } } }
            for (k, v) in keys { o[k] = v }
            setSetting("keybindings", o, scope: "global")
        }
        if use { chooseSavedLayout(id) }
        return id
    }

    /// A layout as a file to share: a saved one (id), else the one in use. Your theme and shortcuts go in only
    /// when asked.
    func layoutFileForExport(_ id: String?, includeTheme: Bool, includeKeys: Bool) -> LayoutFile {
        var f: LayoutFile
        if let id, var s = savedLayouts[id] {
            if layout.userId == id { s.settings = layout.settings; s.tree = shellTree ?? s.tree }
            f = s
            f.preview = SavedLayouts.preview(id)
        } else {
            f = currentLayoutFile(name: layout.title)
            if let u = layout.userId { f.author = savedLayouts[u]?.author ?? ""; f.preview = SavedLayouts.preview(u) }
        }
        if includeTheme {
            f.theme = LayoutFile.Theme(id: settingValue("appearance.theme", scope: "global")?.string ?? "ink",
                                       mode: settingValue("appearance.mode", scope: "global")?.string ?? "dark")
        } else { f.theme = nil }
        if includeKeys {
            var k: [String: String] = [:]
            if case .object(let d)? = settingValue("keybindings", scope: "global") { for (id, v) in d { if let s = v.string { k[id] = s } } }
            f.keys = k
        } else { f.keys = [:] }
        return f
    }
}
