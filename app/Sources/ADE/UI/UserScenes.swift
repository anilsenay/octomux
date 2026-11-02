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

/// A scene file in `<ADE home>/scenes/*.json`. Every field is optional except `name`; see the README
/// written next to the template.
struct SceneSpec: Codable {
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

    private static func load() -> [AmbientScene] {
        var out: [AmbientScene] = [], errs: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            do {
                out.append(try parse(Data(contentsOf: f), file: f))
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
    static func parse(_ data: Data, file: URL) throws -> AmbientScene {
        scene(from: try JSONDecoder().decode(SceneSpec.self, from: data), file: file)
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

    private static func scene(from spec: SceneSpec, file: URL) -> AmbientScene {
        let base = Scenes.builtIn.first { $0.id == spec.base }
        let dark = spec.dark ?? base?.dark ?? true
        let id = "user." + (spec.id ?? file.deletingPathExtension().lastPathComponent)
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
        let top = spec.gradient?.first.map { Color(hex: $0) } ?? base?.top ?? Color(nsColor: colors.frame)
        let bottom = spec.gradient?.last.map { Color(hex: $0) } ?? base?.bottom ?? Color(nsColor: colors.surface)
        return AmbientScene(id: id, name: spec.name, kind: .custom, dark: dark, top: top, bottom: bottom, colors: colors,
                            spec: spec, base: base?.kind)
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
        var url = dir.appendingPathComponent("lanterns.json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("lanterns-\(n).json"); n += 1 }
        let name = n == 2 ? "Lanterns" : "Lanterns \(n - 1)"
        try? template(name: name, id: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        reload()
        return url
    }

    static func template(name: String, id: String) -> String { """
    {
      "id": "\(id)",
      "name": "\(name)",
      "dark": true,
      "gradient": ["#0B0A1F", "#2A1838"],
      "colors": { "surface": "#15122A", "frame": "#0F0C22", "raised": "#241E3D", "accent": "#FFB35C" },
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

    static let readme = """
    # ADE scenes

    Each `*.json` file here is a scene. ADE reloads them when you save; pick one in
    View › Change Scene… or Settings › Appearance.

    | Field | Meaning |
    |---|---|
    | `name` | Shown in the picker (required) |
    | `id` | Stable id (default: the file name) |
    | `dark` | `true` for a dark scene, `false` for light |
    | `base` | Start from a built-in scene: `night-sky`, `reef`, `fireflies`, `embers`, `rain`, `sky`, `sakura`, `snow` |
    | `gradient` | `[top, bottom]` background colors |
    | `colors` | `surface` (terminals, panels), `frame` (sidebar), `raised` (popovers), `accent` |
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

    var body: some View {
        let _ = store.sceneGeneration
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Your scenes").font(.system(size: 12.5, weight: .semibold))
                Text(UserScenes.loaded.isEmpty ? "none yet" : "\(UserScenes.loaded.count) loaded").font(.caption).foregroundStyle(T.text3)
                Spacer()
                Button("New from Template") { NSWorkspace.shared.open(UserScenes.writeTemplate()) }
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: UserScenes.dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(UserScenes.dir)
                }
            }
            Text("JSON files in \(UserScenes.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). They reload when saved; README.md there lists the fields.")
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
