import AppKit
import SwiftUI

// MARK: Mood

/// What the current workspace's agents are doing, as the backdrop shows it: busy agents speed the scene
/// up, one waiting for input adds a breathing amber glow (fireflies turn amber), an error a red one.
enum AmbientMood: Equatable {
    case calm, busy, attention, error

    /// The most urgent state among the running agents of these projects: error, then input, then working.
    static func of(_ sessions: [Session], projectIds: Set<String>) -> AmbientMood {
        let agents = sessions.filter { $0.kind == .agent && !$0.isDormant && projectIds.contains($0.projectId) }
        if agents.contains(where: { $0.activity == .error }) { return .error }
        if agents.contains(where: { $0.activity == .needsInput }) { return .attention }
        if agents.contains(where: { $0.activity == .working }) { return .busy }
        return .calm
    }

    var glow: String? {
        switch self {
        case .attention: return "#F5B841"
        case .error: return "#FF6B5B"
        default: return nil
        }
    }
}

extension AppModel {
    /// `appearance.scene_reactive` (default on).
    var scenesReactToAgents: Bool { settingValue("appearance.scene_reactive", scope: "global")?.bool ?? true }

    func updateAmbientMood() {
        guard scenesReactToAgents else { AmbientClock.shared.setMood(.calm); return }
        AmbientClock.shared.setMood(AmbientMood.of(state.sessions, projectIds: Set(projects.map(\.id))))
    }
}

// MARK: User scenes

/// A scene file in `<Octomux home>/scenes/*.json`. Every field is optional except `name`; see the README
/// written next to the template.
struct SceneSpec: Codable {
    /// "octomux-scene/1" (or the pre-rename "ade-scene/1"); files without it are read as version 1.
    var format: String?
    var id: String?
    var name: String
    var dark: Bool?
    /// A built-in scene id to start from: its animation, and its colors unless `colors` / `gradient` override them.
    var base: String?
    /// [top, bottom]
    var gradient: [String]?
    var colors: Colors?
    var twinkle: Twinkle?
    var sprites: [Sprite]?
    var particles: [Particles]?
    /// A terminal color scheme for the 16 ANSI colors, text, cursor and selection: a Ghostty theme name
    /// ("Catppuccin Mocha") or a path to a Ghostty theme file, relative to the scenes folder.
    var terminal: String?

    struct Colors: Codable { var surface, frame, raised, accent: String? }
    struct Twinkle: Codable { var glyphs: [String]?; var color: String?; var count: Int?; var size: Double? }
    struct Sprite: Codable {
        var rows: [String]
        var colors: [String: String]
        var ink: String?
        var x: Double?, y: Double?
        var count: Int?
        var drift: Double?, rise: Double?, bob: Double?
        var opacity: Double?
        var flip: Bool?
    }
    struct Particles: Codable {
        var glyphs: [String]
        var color: String?
        var colors: [String]?
        var size: Double?
        var count: Int?
        var direction: String?
        var speed: [Double]?
        var sway: Double?
        var spin: Bool?
        var fade: Bool?
        var opacity: Double?
    }
}

enum UserScenes {
    static var dir: URL { Paths.home.appendingPathComponent("scenes") }
    private(set) static var loaded: [AmbientScene] = load()
    private(set) static var errors: [String] = []
    private static var source: DispatchSourceFileSystemObject?
    private static var pending: DispatchWorkItem?

    /// Pre-rename scene files: `*.adescene.json` → `*.octomuxscene.json`, and `"format": "ade-scene/1"` →
    /// `octomux-scene/1`. The scene id comes from the base name, so picked scenes stay picked.
    static func migrateLegacyFiles(in dir: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension.lowercased() == "json" {
            var target = f
            if f.lastPathComponent.hasSuffix(".adescene.json") {
                let renamed = dir.appendingPathComponent(baseName(f) + ".octomuxscene.json")
                guard !fm.fileExists(atPath: renamed.path), (try? fm.moveItem(at: f, to: renamed)) != nil else { continue }
                target = renamed
            }
            guard let text = try? String(contentsOf: target, encoding: .utf8), text.contains(legacyFormat) else { continue }
            try? text.replacingOccurrences(of: "\"\(legacyFormat)\"", with: "\"\(format)\"").write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private static func load() -> [AmbientScene] {
        migrateLegacyFiles(in: dir)
        var out: [AmbientScene] = [], errs: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasSuffix(".schema.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            do {
                let sc = try parse(Data(contentsOf: f), file: f)
                if out.contains(where: { $0.id == sc.id }) {
                    errs.append("\(f.lastPathComponent): another file already uses the id “\(sc.id.dropFirst("user.".count))”; set a different \"id\"")
                } else {
                    out.append(sc)
                }
            } catch let e as DecodingError {
                errs.append("\(f.lastPathComponent): \(describe(e))")
            } catch {
                errs.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        errors = errs
        return out
    }

    /// One scene file's contents as a scene (throws DecodingError for bad JSON or fields).
    static let format = "octomux-scene/1"
    /// Read as the same version (files written before the rename).
    static let legacyFormat = "ade-scene/1"

    struct SceneError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ data: Data, file: URL) throws -> AmbientScene {
        let spec = try JSONDecoder().decode(SceneSpec.self, from: data)
        if let f = spec.format, f != format, f != legacyFormat {
            throw SceneError(message: "format “\(f)” is not supported (this Octomux reads \(format))")
        }
        var theme: TerminalThemes.Theme?
        if let name = spec.terminal {
            guard let t = TerminalThemes.load(name, relativeTo: file.deletingLastPathComponent()) else {
                throw SceneError(message: "terminal theme “\(name)” not found")
            }
            theme = t
        }
        return scene(from: spec, file: file, terminal: theme)
    }

    /// `my-lake.octomuxscene.json`, the pre-rename `my-lake.octomuxscene.json` and `my-lake.json` all give `my-lake`.
    static func baseName(_ file: URL) -> String {
        var n = file.deletingPathExtension().lastPathComponent
        for suffix in [".octomuxscene", ".adescene"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        return n
    }

    static func describe(_ e: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c): return "missing “\(k.stringValue)”" + (c.codingPath.isEmpty ? "" : " in \(path(c))")
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "wrong type at \(path(c))"
        case .dataCorrupted(let c): return c.debugDescription.contains("JSON") ? "not valid JSON" : "invalid value at \(path(c))"
        @unknown default: return "invalid"
        }
    }

    private static func scene(from spec: SceneSpec, file: URL, terminal: TerminalThemes.Theme? = nil) -> AmbientScene {
        let base = Scenes.builtIn.first { $0.id == spec.base }
        let dark = spec.dark ?? base?.dark ?? true
        let id = "user." + (spec.id ?? baseName(file))
        var colors = base?.colors ?? Scenes.palette(dark: dark, surface: dark ? "#14151A" : "#FAFAFA", frame: dark ? "#0F1014" : "#ECECEE",
                                                    raised: dark ? "#24252C" : "#FFFFFF", accent: dark ? "#9DB0FF" : "#2C7BD6")
        if let c = spec.colors {
            let fallback = colors
            func hex(_ n: NSColor) -> String {
                let x = n.usingColorSpace(.sRGB) ?? n
                return String(format: "#%02X%02X%02X", Int(round(x.redComponent * 255)), Int(round(x.greenComponent * 255)), Int(round(x.blueComponent * 255)))
            }
            colors = Scenes.palette(dark: dark, surface: c.surface ?? hex(fallback.surface), frame: c.frame ?? hex(fallback.frame),
                                    raised: c.raised ?? hex(fallback.raised), accent: c.accent ?? hex(fallback.accent))
        }
        if let t = terminal {
            colors.ansi = (0..<16).map { t.palette[$0] ?? colors.ansi[$0] }
            if let fg = t.foreground { colors.termFg = NSColor(Color(hex: fg)) }
            if let c = t.cursor { colors.termCursor = NSColor(Color(hex: c)) }
            if let sel = t.selection { colors.termSelection = NSColor(Color(hex: sel)) }
            // The scheme's background becomes the terminal surface unless the scene sets one.
            if spec.colors?.surface == nil, let bg = t.background { colors.surface = NSColor(Color(hex: bg)) }
        }
        let top = spec.gradient?.first.map { Color(hex: $0) } ?? base?.top ?? Color(nsColor: colors.frame)
        let bottom = spec.gradient?.last.map { Color(hex: $0) } ?? base?.bottom ?? Color(nsColor: colors.surface)
        return AmbientScene(id: id, name: spec.name, kind: .custom, dark: dark, top: top, bottom: bottom, colors: colors,
                            spec: spec, base: base?.kind, art: base?.art ?? [:], file: file)
    }

    /// Re-reads the folder and restyles if the shown scene changed.
    static func reload() {
        loaded = load()
        ThemeStore.shared.scenesReloaded()
    }

    /// Watches the folder so saving a scene file shows the change right away.
    static func startWatching() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler {
            pending?.cancel()
            let w = DispatchWorkItem { reload() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        writeDocs()
        // Editors save files in place too (no directory event): poll the folder's newest date as a backstop.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let stamp = latestChange()
            if stamp != lastStamp { lastStamp = stamp; reload() }
        }
        lastStamp = latestChange()
    }

    private static var lastStamp: Date?
    private static func latestChange() -> Date? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Writes an example scene (and the field reference) and returns its URL.
    @discardableResult
    static func writeTemplate() -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("lanterns.octomuxscene.json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("lanterns-\(n).octomuxscene.json"); n += 1 }
        let name = n == 2 ? "Lanterns" : "Lanterns \(n - 1)"
        try? template(name: name, id: baseName(url)).write(to: url, atomically: true, encoding: .utf8)
        writeDocs()
        reload()
        return url
    }

    static func template(name: String, id: String) -> String { """
    {
      "$schema": "./scene.schema.json",
      "format": "octomux-scene/1",
      "id": "\(id)",
      "name": "\(name)",
      "dark": true,
      "gradient": ["#0B0A1F", "#2A1838"],
      "colors": { "surface": "#15122A", "frame": "#0F0C22", "raised": "#241E3D", "accent": "#FFB35C" },
      "terminal": "Catppuccin Mocha",
      "twinkle": { "glyphs": ["·", "+"], "color": "#FFFFFF", "count": 60 },
      "sprites": [
        {
          "rows": [" ### ", "#####", "#ooo#", "#####", " ### ", "  |  "],
          "colors": { "#": "#E0703A", "o": "#FFD08A", "|": "#5A3A2A" },
          "ink": "#7A3A12",
          "count": 6,
          "rise": 9,
          "bob": 4,
          "opacity": 0.9
        }
      ],
      "particles": [
        { "glyphs": ["·", "*"], "colors": ["#FFC37A", "#FF9E4A"], "size": 12, "count": 40,
          "direction": "up", "speed": [10, 24], "sway": 14, "fade": true, "opacity": 0.9 }
      ]
    }

    """ }

    /// README and JSON Schema next to the scene files (rewritten on launch, so they match this version).
    static func writeDocs() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? schema.write(to: dir.appendingPathComponent("scene.schema.json"), atomically: true, encoding: .utf8)
    }

    static let readme = """
    # Octomux scenes

    Each `*.octomuxscene.json` (or `*.json`) file here is a scene, format `octomux-scene/1`. Octomux reloads
    them when you save; pick one in View › Change Scene… or Settings › Appearance.

    Start the file with `"$schema": "./scene.schema.json"` and editors such as VS Code and Zed
    complete the fields and flag mistakes as you type.

    | Field | Meaning |
    |---|---|
    | `name` | Shown in the picker (required) |
    | `id` | Stable id (default: the file name) |
    | `dark` | `true` for a dark scene, `false` for light |
    | `base` | Start from a built-in scene: `night-sky`, `reef`, `fireflies`, `embers`, `rain`, `sky`, `sakura`, `snow` |
    | `gradient` | `[top, bottom]` background colors |
    | `colors` | `surface` (terminals, panels), `frame` (sidebar), `raised` (popovers), `accent` |
    | `terminal` | A terminal color scheme: a Ghostty theme name (`"Catppuccin Mocha"`, `"Nord"`, `"Dracula"`…) or a path to a Ghostty theme file. Sets the 16 ANSI colors, text, cursor, selection and (unless `colors.surface` is set) the terminal background |
    | `twinkle` | Blinking glyphs: `glyphs`, `color`, `count`, `size` |
    | `sprites` | Pictures made of character cells (below) |
    | `particles` | Moving glyphs (below) |

    **Sprite**: `rows` is the picture, one string per row; every non-space character is a cell
    filled with `colors[character]`, with a darker `ink` glyph inside (omit `ink` for plain cells).
    `x`, `y` place it (0–1 of the width / height; random when omitted), `count` repeats it,
    `drift` moves it sideways (pt/s, negative = leftward), `rise` up (negative = down),
    `bob` bobs it up and down (pt), `opacity`, `flip` mirrors it.

    **Particles**: `glyphs` (cycled), `color` or `colors`, `size`, `count`,
    `direction` (`down`, `up`, `left`, `right`), `speed` `[min, max]` pt/s, `sway` (pt),
    `spin`, `fade` (fade out along the way), `opacity`.
    """
}

/// Settings: where user scenes live, a template to start from, and files that failed to load.
struct UserScenesRow: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var message: String?

    var body: some View {
        let _ = store.sceneGeneration
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Your scenes").font(.system(size: 12.5, weight: .semibold))
                Text(UserScenes.loaded.isEmpty ? "none yet" : "\(UserScenes.loaded.count) loaded").font(.caption).foregroundStyle(T.text3)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Create with Agent…") { UserScenes.createWithAgent() }
                    .help("Opens a new chat with your default agent and a ready instruction; describe the scene and send.")
                Button("New from Template") { NSWorkspace.shared.open(UserScenes.writeTemplate()) }
                Menu("Import") {
                    Button("From File…") { message = SceneSharing.importFiles() }
                    Button("From Link…") { SceneSharing.importLink { message = $0 } }
                }
                .fixedSize()
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: UserScenes.dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(UserScenes.dir)
                }
                Spacer()
            }
            if let message { Text(message).font(.caption).foregroundStyle(T.text2) }
            Text("JSON files in \(UserScenes.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). They reload when saved; README.md there lists the fields. Right-click any scene to export it or to copy it as a starting point.")
                .font(.caption).foregroundStyle(T.text3)
            ForEach(UserScenes.errors, id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(T.amber)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: Terminals

/// How much of the scene terminal panes show (`appearance.scene_terminals`, workspace over global).
enum TerminalSceneMode: String, CaseIterable {
    /// Opaque terminals in the scene's surface color.
    case off
    /// Translucent terminals over the scene's gradient only: no shapes, nothing moves behind text.
    case color
    /// Translucent terminals over a still frame of the scene.
    case still
    /// Translucent terminals over the live backdrop.
    case live

    static let defaultOpacity = 0.82
    static let opacityRange = 0.5...0.95

    var title: String {
        switch self {
        case .off: return "Off"
        case .color: return "Color only"
        case .still: return "Still"
        case .live: return "Live"
        }
    }

    var help: String {
        switch self {
        case .off: return "Terminals stay opaque in the scene's color."
        case .color: return "Terminals show the scene's gradient, without any shapes behind the text."
        case .still: return "Terminals show the scene as a still picture; it moves only around them."
        case .live: return "Terminals show the moving scene behind the text."
        }
    }

    /// Accepts the first version's `true` as `live`.
    init(json: JSONValue?) {
        switch json {
        case .bool(true)?: self = .live
        case .string(let s)?: self = TerminalSceneMode(rawValue: s) ?? .off
        default: self = .off
        }
    }

    private static func value(_ key: String, workspace: String?, settings: [Setting]) -> JSONValue? {
        func v(_ scope: String) -> JSONValue? { settings.first { $0.scope == scope && $0.key == key }?.value }
        return workspace.flatMap { v("workspace:\($0)") } ?? v("global")
    }

    static func resolve(workspace: String?, settings: [Setting]) -> TerminalSceneMode {
        TerminalSceneMode(json: value("appearance.scene_terminals", workspace: workspace, settings: settings))
    }

    static func resolveOpacity(workspace: String?, settings: [Setting]) -> Double {
        guard case .number(let n)? = value("appearance.scene_terminal_opacity", workspace: workspace, settings: settings) else { return defaultOpacity }
        return min(max(n, opacityRange.lowerBound), opacityRange.upperBound)
    }
}

/// Settings › Appearance › Scene: what terminals show of the scene, and how much.
struct TerminalSceneControls: View {
    @EnvironmentObject var model: AppModel
    let scope: String
    /// The slider's value while dragging, and after release until the daemon's setting comes back with
    /// it (showing the stored value in between made the knob jump back and forth).
    @State private var dragging: Double?
    @State private var pending = false

    private var isWorkspace: Bool { scope.hasPrefix("workspace:") }
    private var own: JSONValue? { model.settingValue("appearance.scene_terminals", scope: scope) }
    private var ownOpacity: JSONValue? { model.settingValue("appearance.scene_terminal_opacity", scope: scope) }
    private var wsId: String? { isWorkspace ? String(scope.dropFirst("workspace:".count)) : nil }

    var body: some View {
        let effective = TerminalSceneMode.resolve(workspace: wsId, settings: model.state.settings)
        let stored = TerminalSceneMode.resolveOpacity(workspace: wsId, settings: model.state.settings)
        let opacity = dragging ?? stored
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Behind terminals")
                Spacer()
                Picker("", selection: Binding<String>(
                    get: { isWorkspace && own == nil ? "global" : effective.rawValue },
                    set: { v in model.setSetting("appearance.scene_terminals", v == "global" ? nil : (v == "off" && !isWorkspace ? nil : v), scope: scope) })) {
                    if isWorkspace { Text("Global").tag("global") }
                    ForEach(TerminalSceneMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text(effective.help + (isWorkspace && own == nil ? " (from Global)" : "")).font(.caption).foregroundStyle(T.text3)
            if effective != .off {
                HStack(spacing: 10) {
                    Text("Terminal opacity")
                    Slider(value: Binding(get: { opacity }, set: { dragging = $0 }), in: TerminalSceneMode.opacityRange) { editing in
                        guard !editing, let d = dragging else { return }
                        let v = (d * 100).rounded() / 100
                        dragging = v
                        pending = true
                        model.setSetting("appearance.scene_terminal_opacity", v, scope: scope)
                        // Fallback if the value never comes back (daemon unreachable).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if pending { pending = false; dragging = nil } }
                    }
                    .frame(maxWidth: 220)
                    Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().foregroundStyle(T.text2).frame(width: 40, alignment: .trailing)
                    if isWorkspace && ownOpacity != nil {
                        Button("Use Global") { model.setSetting("appearance.scene_terminal_opacity", nil, scope: scope) }
                    }
                }
                Text("Lower shows more of the scene; higher keeps text easier to read.").font(.caption).foregroundStyle(T.text3)
            }
        }
        .padding(.top, 4)
        .onChange(of: stored) { _, v in
            if pending, let d = dragging, abs(d - v) < 0.005 { pending = false; dragging = nil }
        }
    }
}

// MARK: Terminal color schemes

/// Ghostty theme files (`palette = N=#rrggbb`, `background = …`): bundled with Octomux, from Ghostty.app,
/// `~/.config/ghostty/themes`, or a path.
enum TerminalThemes {
    struct Theme: Equatable {
        var palette: [Int: String] = [:]
        var background, foreground, cursor, selection: String?
    }

    static var dirs: [URL] {
        var d: [URL] = []
        if let r = Bundle.main.resourceURL { d.append(r.appendingPathComponent("terminal-themes")) }
        d.append(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"))
        d.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/themes"))
        d.append(UserScenes.dir.appendingPathComponent("terminal-themes"))
        // Development builds run outside the app bundle: the vendored Ghostty build has the same themes.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        d.append(repo.appendingPathComponent("vendor/ghostty/zig-out/share/ghostty/themes"))
        return d
    }

    static func parse(_ text: String) -> Theme {
        var t = Theme()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            func hex(_ v: String) -> String? {
                let h = v.hasPrefix("#") ? String(v.dropFirst()) : v
                return h.count == 6 && h.allSatisfy(\.isHexDigit) ? "#" + h : nil
            }
            switch key {
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i), let c = hex(parts[1]) { t.palette[i] = c }
            case "background": t.background = hex(value)
            case "foreground": t.foreground = hex(value)
            case "cursor-color": t.cursor = hex(value)
            case "selection-background": t.selection = hex(value)
            default: break
            }
        }
        return t
    }

    /// A theme by name (first folder that has it) or by path (absolute, `~/…`, or relative to `base`).
    static func load(_ name: String, relativeTo base: URL) -> Theme? {
        let candidates: [URL]
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            candidates = [expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(name)]
        } else {
            candidates = dirs.map { $0.appendingPathComponent(name) }
        }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let t = parse(text)
                if !t.palette.isEmpty || t.background != nil { return t }
            }
        }
        return nil
    }

    /// Theme names available by name (for the schema's suggestions).
    static func names() -> [String] {
        var out = Set<String>()
        for d in dirs { for n in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !n.hasPrefix(".") { out.insert(n) } }
        return out.sorted()
    }
}

extension UserScenes {
    /// JSON Schema (draft-07) for scene files; editors use it for completion and validation.
    static var schema: String {
        let bases = Scenes.builtIn.filter { $0.kind != .custom }.map(\.id)
        let themes = TerminalThemes.names()
        func list(_ a: [String]) -> String { a.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") }
        return """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "$id": "https://octomux.dev/schemas/octomux-scene-1.json",
          "title": "Octomux scene",
          "description": "A live backdrop and palette for Octomux (format octomux-scene/1).",
          "type": "object",
          "required": ["name"],
          "additionalProperties": false,
          "definitions": {
            "color": { "type": "string", "pattern": "^#[0-9A-Fa-f]{6}$", "description": "#RRGGBB" },
            "glyphs": { "type": "array", "items": { "type": "string", "minLength": 1, "maxLength": 2 }, "minItems": 1 }
          },
          "properties": {
            "$schema": { "type": "string" },
            "format": { "enum": ["octomux-scene/1", "ade-scene/1"], "description": "Format version (ade-scene/1: written before the rename, read the same)." },
            "id": { "type": "string", "pattern": "^[A-Za-z0-9._-]+$", "description": "Stable id (default: the file name)." },
            "name": { "type": "string", "minLength": 1, "description": "Shown in the picker." },
            "dark": { "type": "boolean", "description": "Dark scene (true) or light (false)." },
            "base": { "enum": [\(list(bases))], "description": "Start from a built-in scene: its animation, and its colors unless overridden." },
            "gradient": { "type": "array", "items": { "$ref": "#/definitions/color" }, "minItems": 2, "maxItems": 2, "description": "[top, bottom] background colors." },
            "colors": {
              "type": "object", "additionalProperties": false,
              "properties": {
                "surface": { "$ref": "#/definitions/color", "description": "Terminals and panels." },
                "frame": { "$ref": "#/definitions/color", "description": "Sidebar and bars." },
                "raised": { "$ref": "#/definitions/color", "description": "Popovers and cards." },
                "accent": { "$ref": "#/definitions/color", "description": "Selection, focus, buttons." }
              }
            },
            "terminal": {
              "type": "string",
              "description": "Terminal color scheme: a Ghostty theme name, or a path to a Ghostty theme file (relative to this folder).",
              "examples": [\(list(themes.isEmpty ? ["Catppuccin Mocha", "Nord", "Dracula"] : themes))]
            },
            "twinkle": {
              "type": "object", "additionalProperties": false, "description": "Blinking glyphs scattered over the sky.",
              "properties": {
                "glyphs": { "$ref": "#/definitions/glyphs" },
                "color": { "$ref": "#/definitions/color" },
                "count": { "type": "integer", "minimum": 0, "maximum": 400 },
                "size": { "type": "number", "minimum": 6, "maximum": 30 }
              }
            },
            "sprites": {
              "type": "array", "description": "Pictures made of character cells.",
              "items": {
                "type": "object", "required": ["rows", "colors"], "additionalProperties": false,
                "properties": {
                  "rows": { "type": "array", "items": { "type": "string" }, "minItems": 1, "description": "One string per row; each non-space character is a cell." },
                  "colors": { "type": "object", "additionalProperties": { "$ref": "#/definitions/color" }, "description": "Fill color per character used in rows." },
                  "ink": { "$ref": "#/definitions/color", "description": "Glyph drawn inside each cell (omit for plain cells)." },
                  "x": { "type": "number", "minimum": 0, "maximum": 1, "description": "0–1 of the width; random when omitted." },
                  "y": { "type": "number", "minimum": 0, "maximum": 1, "description": "0–1 of the height; random when omitted." },
                  "count": { "type": "integer", "minimum": 1, "maximum": 50 },
                  "drift": { "type": "number", "description": "Sideways speed in pt/s (negative: leftward)." },
                  "rise": { "type": "number", "description": "Upward speed in pt/s (negative: down)." },
                  "bob": { "type": "number", "minimum": 0, "description": "Up-and-down bobbing in pt." },
                  "opacity": { "type": "number", "minimum": 0, "maximum": 1 },
                  "flip": { "type": "boolean", "description": "Mirror horizontally." }
                }
              }
            },
            "particles": {
              "type": "array", "description": "Moving glyphs.",
              "items": {
                "type": "object", "required": ["glyphs"], "additionalProperties": false,
                "properties": {
                  "glyphs": { "$ref": "#/definitions/glyphs" },
                  "color": { "$ref": "#/definitions/color" },
                  "colors": { "type": "array", "items": { "$ref": "#/definitions/color" }, "minItems": 1 },
                  "size": { "type": "number", "minimum": 6, "maximum": 30 },
                  "count": { "type": "integer", "minimum": 1, "maximum": 400 },
                  "direction": { "enum": ["down", "up", "left", "right"] },
                  "speed": { "type": "array", "items": { "type": "number", "minimum": 1 }, "minItems": 1, "maxItems": 2, "description": "[min, max] pt/s." },
                  "sway": { "type": "number", "minimum": 0 },
                  "spin": { "type": "boolean" },
                  "fade": { "type": "boolean", "description": "Fade out along the way." },
                  "opacity": { "type": "number", "minimum": 0, "maximum": 1 }
                }
              }
            }
          }
        }

        """
    }
}

// MARK: Sharing

/// Export a scene as a file, copy one to edit, import files or links.
enum SceneSharing {
    static let maxBytes = 1_000_000

    /// A scene as file contents: a user scene's own file; for a built-in, a small file that starts from it
    /// (`base`), ready to be changed.
    static func exportData(_ s: AmbientScene) -> Data? {
        if let f = s.file { return try? Data(contentsOf: f) }
        let json: [String: Any] = ["$schema": "./scene.schema.json", "format": UserScenes.format, "name": s.name + " (copy)", "base": s.id]
        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func slug(_ s: String) -> String {
        let out = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(out).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "scene" : String(joined.prefix(60))
    }

    /// Validates scene JSON and saves it into the scenes folder (never over an existing file).
    /// Returns the installed scene's name.
    @discardableResult
    static func install(_ data: Data, suggestedName: String) throws -> (name: String, url: URL) {
        guard data.count <= maxBytes else { throw UserScenes.SceneError(message: "the file is larger than 1 MB") }
        let probe = try UserScenes.parse(data, file: UserScenes.dir.appendingPathComponent("import.octomuxscene.json"))
        guard let spec = probe.spec else { throw UserScenes.SceneError(message: "not a scene") }
        if let id = spec.id, UserScenes.loaded.contains(where: { $0.id == "user." + id }) {
            throw UserScenes.SceneError(message: "you already have a scene with the id “\(id)”")
        }
        try FileManager.default.createDirectory(at: UserScenes.dir, withIntermediateDirectories: true)
        let base = slug(spec.id ?? (suggestedName.isEmpty ? spec.name : suggestedName))
        var url = UserScenes.dir.appendingPathComponent("\(base).octomuxscene.json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = UserScenes.dir.appendingPathComponent("\(base)-\(n).octomuxscene.json"); n += 1 }
        try data.write(to: url, options: .atomic)
        UserScenes.reload()
        return (spec.name, url)
    }

    static func export(_ s: AmbientScene) {
        guard let data = exportData(s) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (s.file.map(UserScenes.baseName) ?? slug(s.name)) + ".octomuxscene.json"
        panel.canCreateDirectories = true
        panel.message = "Export “\(s.name)” as a scene file others can import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A user scene to edit: a copy of `s` in the scenes folder, opened in the default JSON editor.
    static func duplicate(_ s: AmbientScene) {
        guard var data = exportData(s) else { return }
        if s.file != nil, var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj["name"] = s.name + " (copy)"
            obj.removeValue(forKey: "id")
            data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? data
        }
        if let r = try? install(data, suggestedName: slug(s.name) + "-copy") { NSWorkspace.shared.open(r.url) }
    }

    static func delete(_ s: AmbientScene) {
        guard let f = s.file else { return }
        let a = NSAlert()
        a.messageText = "Move “\(s.name)” to the Trash?"
        a.informativeText = f.lastPathComponent
        a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
        UserScenes.reload()
    }

    /// Returns a status line for Settings.
    static func importFiles() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose scene files (.octomuxscene.json) to add."
        guard panel.runModal() == .OK else { return nil }
        var done: [String] = [], failed: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                done.append(try install(data, suggestedName: UserScenes.baseName(url)).name)
            } catch {
                failed.append("\(url.lastPathComponent): \(describe(error))")
            }
        }
        return summary(done, failed)
    }

    static func importLink(_ report: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "Import a scene from a link"
        a.informativeText = "A link to a .octomuxscene.json file (GitHub file pages work too)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…/my-scene.octomuxscene.json"
        a.accessoryView = field
        a.addButton(withTitle: "Import"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn,
              let url = downloadURL(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        report("Downloading…")
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err { report("Could not download: \(err.localizedDescription)"); return }
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { report("Could not download: HTTP \(h.statusCode)"); return }
                guard let data else { report("Could not download"); return }
                do {
                    let r = try install(data, suggestedName: UserScenes.baseName(url))
                    report("Added “\(r.name)” to your scenes.")
                } catch { report("Not imported: \(describe(error))") }
            }
        }.resume()
    }

    /// https only; GitHub `blob` pages and gist pages point at their raw file.
    static func downloadURL(_ s: String) -> URL? {
        guard var c = URLComponents(string: s), c.scheme == "https", c.host != nil else { return nil }
        if c.host == "github.com" {
            let parts = c.path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count > 4, parts[2] == "blob" {
                c.host = "raw.githubusercontent.com"
                c.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
            }
        } else if c.host == "gist.github.com", !c.path.hasSuffix("/raw") {
            c.path += "/raw"
        }
        return c.url
    }

    private static func describe(_ e: Error) -> String {
        if let d = e as? DecodingError { return UserScenes.describe(d) }
        return e.localizedDescription
    }

    private static func summary(_ done: [String], _ failed: [String]) -> String {
        var parts: [String] = []
        if !done.isEmpty { parts.append("Added " + done.map { "“\($0)”" }.joined(separator: ", ") + ".") }
        if !failed.isEmpty { parts.append("Not imported: " + failed.joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}

/// Right-click menu on a scene tile.
struct SceneMenu: View {
    let scene: AmbientScene
    var body: some View {
        Button("Export…") { SceneSharing.export(scene) }
        Button(scene.file == nil ? "Copy as My Scene to Edit" : "Duplicate to Edit") { SceneSharing.duplicate(scene) }
        if let f = scene.file {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            Button("Move to Trash…") { SceneSharing.delete(scene) }
        }
    }
}

// MARK: Create with an agent

extension UserScenes {
    /// The start of a prompt for the workspace's default agent; the user finishes the last line.
    static var agentInstruction: String {
        let d = dir.path
        let bases = Scenes.builtIn.map(\.id).joined(separator: ", ")
        return """
        Create a scene for Octomux (my terminal app): a live backdrop drawn in character cells plus a color palette, as one JSON file.

        - First read \(d)/README.md and the JSON Schema \(d)/scene.schema.json; follow them exactly.
        - Save it as \(d)/<short-kebab-name>.octomuxscene.json. Start the file with "$schema": "./scene.schema.json" and "format": "octomux-scene/1". Do not overwrite or edit other files there.
        - To reuse an animation, set "base" to one of: \(bases). For the terminal's 16 colors you can set "terminal" to a Ghostty theme name (for example "Catppuccin Mocha", "Nord", "Tokyo Night").
        - Keep text readable: a dark scene needs dark surface/frame colors, a light one light colors. Keep particle and twinkle counts moderate (under 150).
        - Make sure the file is valid JSON. Octomux reloads the folder on its own; when done, tell me the scene's name (I pick it in View › Change Scene…).

        The scene I want:\u{20}
        """
    }

    static func createWithAgent() {
        writeDocs()
        let m = AppModel.shared
        guard m.currentProject != nil || m.projects.first != nil else {
            m.lastError = "Add a project first: the agent runs in one."
            return
        }
        (NSApp.delegate as? AppDelegate)?.mainWindow?.makeKeyAndOrderFront(nil)
        m.openNewChat(projectId: m.currentProject?.id ?? m.projects.first?.id, draft: agentInstruction)
    }
}
