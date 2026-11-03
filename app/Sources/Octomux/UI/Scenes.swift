import AppKit
import SwiftUI

// Ambient scenes: a palette for the whole app (chrome and terminals) plus a live backdrop drawn in
// characters behind the chrome, the sidebar and empty panes. Picked per workspace
// (`appearance.scene` at `workspace:<id>`), falling back to the global choice; "none" turns it off.

struct AmbientScene: Identifiable, Equatable {
    enum Kind { case nightSky, reef, fireflies, embers, rain, sky, sakura, snow, aurora, circuit, kites, octopus, tentacles, custom }
    let id: String
    let name: String
    let kind: Kind
    let dark: Bool
    let top: Color
    let bottom: Color
    let colors: ThemeColors
    /// User scenes (see UserScenes): their elements, and the built-in scene they start from, if any.
    var spec: SceneSpec? = nil
    var base: Kind? = nil
    /// First versions kept for comparison (listed apart in the pickers); they use the original glyph texture.
    var legacy = false
    /// Colors for the scene's drawing (keys per kind, see SceneBuilder), so one animation has several looks.
    var art: [String: String] = [:]
    /// The file a user scene was loaded from.
    var file: URL? = nil
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

private func nc(_ hex: String) -> NSColor { NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .gray }
private func col(_ hex: String) -> Color { Color(nsColor: nc(hex)) }

enum Scenes {
    /// Chrome and terminal colors from a few seeds; text and ANSI colors come from Ink's dark or light set.
    static func palette(dark: Bool, surface: String, frame: String, raised: String, accent: String) -> ThemeColors {
        var c = dark ? Themes.ink.dark : Themes.ink.light
        let a = nc(accent), s = nc(surface)
        c.surface = s
        c.frame = nc(frame)
        c.raised = nc(raised)
        c.accent = a
        c.selection = a.withAlphaComponent(dark ? 0.18 : 0.14)
        c.border = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.09 : 0.09)
        c.termCursor = a
        c.termSelection = s.blended(withFraction: dark ? 0.3 : 0.22, of: a) ?? s
        return c
    }

    private static func make(_ id: String, _ name: String, _ kind: AmbientScene.Kind, dark: Bool, top: String, bottom: String,
                             surface: String, frame: String, raised: String, accent: String, art: [String: String] = [:]) -> AmbientScene {
        AmbientScene(id: id, name: name, kind: kind, dark: dark, top: col(top), bottom: col(bottom),
                     colors: palette(dark: dark, surface: surface, frame: frame, raised: raised, accent: accent), art: art)
    }

    /// Built-in scenes, then the user's.
    static var all: [AmbientScene] { builtIn + UserScenes.loaded }

    static let builtIn: [AmbientScene] = [
        // Octomux's own: the logo's octopus.
        make("octo-deep", "Octo Deep", .octopus, dark: true, top: "#2A1A5E", bottom: "#0A0618",
             surface: "#150F2C", frame: "#100A22", raised: "#241A44", accent: "#A78BFA"),
        make("midnight-coral", "Midnight Coral", .octopus, dark: true, top: "#1C2440", bottom: "#0A0E1C",
             surface: "#121830", frame: "#0D1224", raised: "#1E2744", accent: "#FF8A75",
             art: ["body": "#FF7A66", "hi": "#FFC4B8", "shade": "#D9503F", "eye": "#1A1030", "cheek": "#FFD6A0", "octoInk": "#B23A2C",
                   "ink": "#05070F", "rock": "#222B4A", "rockInk": "#3A466E", "weed1": "#2E8F7A", "weed2": "#246E63", "weedInk": "#0E3A33"]),
        make("kraken", "Kraken", .tentacles, dark: true, top: "#1A0F2E", bottom: "#05030B",
             surface: "#130C20", frame: "#0E0918", raised: "#21173A", accent: "#C084FC"),
        make("lavender", "Lavender", .octopus, dark: false, top: "#F3EFFF", bottom: "#D9CFFD",
             surface: "#FBFAFF", frame: "#ECE6FD", raised: "#FFFFFF", accent: "#7C3AED",
             art: ["octoInk": "#5B21B6", "ink": "#6E5BC0", "bubble": "#7F6BD6", "ray": "#FFFFFF", "rock": "#C6B8F4", "rockInk": "#9F8BE6",
                   "weed1": "#A78BFA", "weed2": "#8B6CF0", "weedInk": "#5B3FC4"]),
        make("tide-pool", "Tide Pool", .tentacles, dark: false, top: "#BDE7EE", bottom: "#F6E7CF",
             surface: "#FBF8F2", frame: "#EEF2EC", raised: "#FFFFFF", accent: "#D9503F",
             art: ["arm": "#F07B62", "armInk": "#A8402E", "sucker": "#FFD3C4", "lid": "#D9604A", "eye": "#FFFFFF", "pupil": "#1E1B4B",
                   "speck": "#5E9AA8", "bubble": "#4F8C9A", "glow": "#FFFFFF"]),
        // Dark
        make("aurora", "Aurora", .aurora, dark: true, top: "#04121A", bottom: "#0C1A33",
             surface: "#0D1622", frame: "#09111A", raised: "#18263A", accent: "#5BF0A6"),
        make("night-sky", "Nightfall", .nightSky, dark: true, top: "#070B1F", bottom: "#1C1F4A",
             surface: "#11142C", frame: "#0C0F24", raised: "#1F2346", accent: "#A99BFF",
             art: ["moon": "#F1E7C8", "moonEdge": "#8D8770", "moonInk": "#9A8F66", "cloud": "#2E356E", "cloudInk": "#4F5AA8"]),
        make("dusk-kites", "Dusk Kites", .kites, dark: true, top: "#1A1238", bottom: "#5A2E4A",
             surface: "#191329", frame: "#130E20", raised: "#271E3C", accent: "#C49BFF",
             art: ["sun": "#FF9E7A", "cloud": "#3B2E5A", "cloudInk": "#5A4A80", "string": "#C9B8E8"]),
        make("reef-v2", "Reef", .reef, dark: true, top: "#0E4A52", bottom: "#05181F",
             surface: "#0B242A", frame: "#071C21", raised: "#143840", accent: "#5FD8C9"),
        make("circuit", "Circuit", .circuit, dark: true, top: "#060B0A", bottom: "#0C1A16",
             surface: "#0C1412", frame: "#080F0D", raised: "#16241F", accent: "#4BE3B0"),
        make("fireflies", "Glade", .fireflies, dark: true, top: "#050B07", bottom: "#112418",
             surface: "#0F1912", frame: "#0A130D", raised: "#1A2A1F", accent: "#C6E26A"),
        make("meadow", "Golden Meadow", .fireflies, dark: true, top: "#0E0B05", bottom: "#3A2C10",
             surface: "#17130B", frame: "#110E08", raised: "#262014", accent: "#FFC857",
             art: ["grass": "#D2B45A", "glow": "#FFC857", "core": "#FFE9A8", "reed": "#8A6E36", "reedHead": "#5E3F22"]),
        make("embers", "Embers", .embers, dark: true, top: "#0D0807", bottom: "#2E150D",
             surface: "#1A1210", frame: "#140D0B", raised: "#2A1C18", accent: "#FF8F52"),
        make("sakura-night", "Sakura Night", .sakura, dark: true, top: "#120A12", bottom: "#2E1529",
             surface: "#1A1019", frame: "#140C13", raised: "#2A1A28", accent: "#F08DB4",
             art: ["branch": "#7A5048", "blossom": "#F08DB4", "branchInk": "#3A1A28"]),
        make("rain", "Rain", .rain, dark: true, top: "#1A2430", bottom: "#0C1116",
             surface: "#131A21", frame: "#0F151B", raised: "#1F2933", accent: "#7DB4E0"),
        make("snow-night", "Snow Night", .snow, dark: true, top: "#0A1222", bottom: "#1E2A40",
             surface: "#121A2A", frame: "#0D1422", raised: "#1E283C", accent: "#A9C4F0",
             art: ["drift": "#6F82A3", "driftInk": "#4C5D7E"]),
        // Light
        make("sky", "Daydream", .sky, dark: false, top: "#7FC0F2", bottom: "#D8EEFD",
             surface: "#F5FAFE", frame: "#D6EAFA", raised: "#FFFFFF", accent: "#2C7BD6"),
        make("blueprint", "Blueprint", .circuit, dark: false, top: "#D6E4F6", bottom: "#F2F7FD",
             surface: "#F7FAFE", frame: "#E2ECF8", raised: "#FFFFFF", accent: "#2C6FD6",
             art: ["trace": "#A9C1E0", "padInk": "#2C6FD6", "sig": "#2C6FD6", "core": "#9CC0FF", "bits": "#8EA9CF"]),
        make("shallows", "Shallows", .reef, dark: false, top: "#7FE0D6", bottom: "#DDF7F2",
             surface: "#F4FCFA", frame: "#D2F0EA", raised: "#FFFFFF", accent: "#13897E",
             art: ["weed1": "#5CC28E", "weed2": "#3FA877", "weedInk": "#1F6B4B", "fishInk": "#7A3A2A"]),
        make("kites", "Kites", .kites, dark: false, top: "#9FD6F2", bottom: "#FFE0C4",
             surface: "#FFFAF4", frame: "#F5E6D8", raised: "#FFFFFF", accent: "#D9622B"),
        make("sakura", "Sakura", .sakura, dark: false, top: "#F5C3D2", bottom: "#FFF1F4",
             surface: "#FFF9FA", frame: "#F8E1E7", raised: "#FFFFFF", accent: "#C94F76"),
        make("drizzle", "Drizzle", .rain, dark: false, top: "#B9C6D3", bottom: "#E9EEF3",
             surface: "#F6F8FA", frame: "#E1E7ED", raised: "#FFFFFF", accent: "#4E6E8E",
             art: ["cloud": "#D5DDE6", "cloudInk": "#B0BCCA", "drop": "#6F86A0"]),
        make("snow", "Snowfall", .snow, dark: false, top: "#9DB4CC", bottom: "#E3EBF3",
             surface: "#F6F9FC", frame: "#E1E9F1", raised: "#FFFFFF", accent: "#3F6E9E"),
    ]

    /// Ids that moved: the first Reef became `reef-v2`.
    static let aliases = ["reef": "reef-v2"]

    static func scene(_ id: String?) -> AmbientScene? {
        let id = id.map { aliases[$0] ?? $0 }
        return all.first { $0.id == id }
    }

    /// Scenes whose accent sits near a workspace color's hue (gray workspaces get the gray-blue ones).
    static func matching(_ hex: String?, limit: Int = 4) -> [AmbientScene] {
        guard let hex, let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) else { return [] }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        if sat < 0.15 { return ["rain", "drizzle", "snow", "snow-night"].compactMap { scene($0) } }
        func dist(_ s: AmbientScene) -> CGFloat {
            var sh: CGFloat = 0, ss: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
            (s.colors.accent.usingColorSpace(.sRGB) ?? s.colors.accent).getHue(&sh, saturation: &ss, brightness: &sb, alpha: &sa)
            let d = abs(sh - h)
            return min(d, 1 - d)
        }
        return builtIn.filter { dist($0) < 0.09 }.sorted { dist($0) < dist($1) }.prefix(limit).map { $0 }
    }

    /// The scene id a workspace shows: its own `appearance.scene` (where "none" means no scene), else the
    /// global one. nil = no scene.
    static func resolve(workspace: String?, settings: [Setting]) -> String? {
        func value(_ scope: String) -> String? { settings.first { $0.scope == scope && $0.key == "appearance.scene" }?.value.string }
        let v = workspace.flatMap { value("workspace:\($0)") } ?? value("global")
        return v == "none" ? nil : v
    }
}

// MARK: Clock

/// One clock for every live backdrop. Backdrops are Core Animation layer trees frozen at `speed = 0`;
/// each tick moves their `timeOffset` forward, so the frame rate is exactly the tick rate and the app
/// itself does almost nothing per frame (the render server draws). Full rate while Octomux is in front,
/// slow while it is visible behind another app, stopped (last frame stays) when the window cannot be
/// seen, in Low Power Mode or with Reduce Motion.
final class AmbientClock: ObservableObject {
    static let shared = AmbientClock()
    static let activeFPS = 24.0
    static let backgroundFPS = 6.0

    @Published private(set) var fps = AmbientClock.activeFPS
    /// Scene time in seconds; only advances while running (faster while agents work).
    private(set) var time: Double = 1000
    /// What the current workspace's agents are doing; backdrops react to it (see AmbientMood).
    private(set) var mood: AmbientMood = .calm
    private var views = NSHashTable<SceneLayerView>.weakObjects()
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var screensAsleep = false
    private var sessionActive = true
    private var tokens: [(NotificationCenter, Any)] = []

    private init() {
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        func on(_ c: NotificationCenter, _ n: Notification.Name, _ f: @escaping () -> Void = {}) {
            tokens.append((c, c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in f(); self?.update() }))
        }
        on(nc, NSApplication.didBecomeActiveNotification)
        on(nc, NSApplication.didResignActiveNotification)
        on(nc, NSWindow.didChangeOcclusionStateNotification)
        on(nc, NSWindow.didMiniaturizeNotification)
        on(nc, NSWindow.didDeminiaturizeNotification)
        on(nc, .NSProcessInfoPowerStateDidChange)
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screensAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionActive = false }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionActive = true }
        on(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
    }

    var reason: String {
        guard let w = (NSApp.delegate as? AppDelegate)?.mainWindow else { return "no window" }
        if screensAsleep || !sessionActive { return "screen off" }
        if w.isMiniaturized || !w.occlusionState.contains(.visible) { return "hidden" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "low power" }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "reduce motion" }
        return NSApp.isActive ? "active" : "background"
    }

    func register(_ v: SceneLayerView) { views.add(v); update() }

    func setMood(_ m: AmbientMood) {
        guard m != mood else { return }
        mood = m
        for v in views.allObjects { v.rebuild() }   // same clock time, so nothing jumps; only colors and the glow change
    }
    func unregister(_ v: SceneLayerView) { views.remove(v); update() }

    /// Frames per second for a `reason`: full in front, slow behind another app, 0 otherwise.
    static func fps(for reason: String) -> Double {
        switch reason {
        case "active": return activeFPS
        case "background": return backgroundFPS
        default: return 0
        }
    }

    func update() {
        let f = Self.fps(for: reason)
        if f != fps { fps = f }
        let want = views.count > 0 ? f : 0
        if want == 0 { timer?.invalidate(); timer = nil; return }
        if let t = timer, abs(t.timeInterval - 1 / want) < 0.001 { return }
        timer?.invalidate()
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / want, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        time += min(now - last, 0.5) * (mood == .busy ? 1.6 : 1)
        last = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in views.allObjects { v.root.timeOffset = time }
        CATransaction.commit()
    }
}

// MARK: Views

/// The scene's live backdrop. `still` shows one fixed moment (thumbnails).
struct SceneBackdrop: NSViewRepresentable {
    let scene: AmbientScene
    var still = false
    /// Width at the left edge that holds text (the sidebar): static art is laid out to its right.
    var textColumn: CGFloat = 0
    func makeNSView(context: Context) -> SceneLayerView {
        let v = SceneLayerView(scene: scene, still: still); v.textColumn = textColumn; return v
    }
    func updateNSView(_ v: SceneLayerView, context: Context) { v.set(scene); v.setTextColumn(textColumn) }
}

final class SceneLayerView: NSView {
    private(set) var scene: AmbientScene
    let still: Bool
    /// A full-size frame that does not move (behind terminals in the "still" mode).
    let frozen: Bool
    let root = CALayer()
    private var builtSize: CGSize = .zero
    private var pending: DispatchWorkItem?
    private var faded = false
    /// See SceneBackdrop.textColumn.
    var textColumn: CGFloat = 0

    init(scene: AmbientScene, still: Bool, frozen: Bool = false) {
        self.scene = scene
        self.still = still
        self.frozen = frozen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        root.anchorPoint = .zero
        root.speed = 0
        layer?.addSublayer(root)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !still && !frozen else { return }
        if window != nil { AmbientClock.shared.register(self) } else { AmbientClock.shared.unregister(self) }
    }

    func set(_ s: AmbientScene) {
        guard s.id != scene.id else { return }
        scene = s
        rebuild()
    }

    /// The sidebar was shown, hidden or resized: rebuild once it settles.
    func setTextColumn(_ w: CGFloat) {
        guard abs(w - textColumn) > 1 else { return }
        textColumn = w
        if builtSize != .zero { rebuildSoon() }
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - builtSize.width) > 1 || abs(bounds.height - builtSize.height) > 1 else { return }
        // Live window resizing: rebuild once it settles (keep the old layers scaled meanwhile).
        if builtSize == .zero { rebuild(); return }
        rebuildSoon()
    }

    private func rebuildSoon() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rebuild() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func rebuild() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        builtSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = nil
        // Thumbnails lay a larger virtual canvas out and scale it down, so sprites keep their proportions.
        let v = still ? CGSize(width: 520, height: 520 * bounds.height / bounds.width) : bounds.size
        root.bounds = CGRect(origin: .zero, size: v)
        root.position = .zero
        root.setAffineTransform(still ? CGAffineTransform(scaleX: bounds.width / v.width, y: bounds.height / v.height) : .identity)
        root.timeOffset = still ? 37 : AmbientClock.shared.time
        SceneBuilder(root: root, W: v.width, H: v.height, now: root.timeOffset, mood: still ? .calm : AmbientClock.shared.mood, art: scene.art, dark: scene.dark,
                     textColumn: still ? 0 : min(textColumn, v.width * 0.5)).build(scene)
        CATransaction.commit()
        // A new scene eases in over the window's frame color (the view's own layer runs on real time).
        if !still && !frozen && !faded {
            faded = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(a, forKey: "fadeIn")
        }
    }
}

// MARK: Art

private func hash(_ a: Int, _ b: Int = 0) -> Int {
    var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663 &+ 0x9E37_79B9)
    x ^= x >> 16; x &*= 0x45D9_F3B; x ^= x >> 16; x &*= 0x45D9_F3B; x ^= x >> 16
    return Int(x % 1_000_003)
}
/// Stable pseudo-random 0..<1 for item `i`, property `k`.
private func rnd(_ i: Int, _ k: Int) -> Double { Double(hash(i, k) % 10_000) / 10_000 }
private func cg(_ hex: String, _ a: CGFloat = 1) -> CGColor { nc(hex).withAlphaComponent(a).cgColor }

/// Bitmaps for the backdrops (glyphs, character-cell sprites, glows), cached for the process.
private enum Art {
    static let scale: CGFloat = 2
    static let cell: CGFloat = 12
    private static var cache: [String: CGImage] = [:]
    /// The glyphs inside character cells: code characters; the first versions used letters.
    static let codeGlyphs: [Character] = ["{", "}", ";", "=", "<", ">", "/", "*", "0", "1", "(", ")"]
    static let classicGlyphs: [Character] = ["t", "%", "S", "x", ":", "s", "#", "X"]
    /// Set by SceneBuilder for the scene being built (main thread only).
    static var glyphs: [Character] = codeGlyphs

    static func bitmap(_ key: String, _ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        if let c = cache[key] { return c }
        guard let ctx = CGContext(data: nil, width: max(1, Int(ceil(size.width * scale))), height: max(1, Int(ceil(size.height * scale))),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity
        draw(ctx)
        let img = ctx.makeImage()
        cache[key] = img
        return img
    }

    /// `s` centered in `r` (the context is y-up).
    static func text(_ s: String, in r: CGRect, _ color: CGColor, size: CGFloat, _ ctx: CGContext) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor(cgColor: color) ?? .white])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: r.midX - b.width / 2 - b.minX, y: r.midY - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }

    static func glyph(_ s: String, _ hex: String, size: CGFloat) -> (CGImage?, CGSize) {
        let d = CGSize(width: ceil(size * 1.2), height: ceil(size * 1.4))
        return (bitmap("g\(s)\(hex)\(size)", d) { text(s, in: CGRect(origin: .zero, size: d), cg(hex), size: size, $0) }, d)
    }

    /// Rows of characters; each non-space character is a cell filled with `colors[ch]`, with a darker glyph inside.
    static func sprite(_ rows: [String], _ colors: [Character: String], ink: String?, seed: Int, flip: Bool = false) -> (CGImage?, CGSize) {
        let cols = rows.map(\.count).max() ?? 0
        let size = CGSize(width: CGFloat(cols) * cell, height: CGFloat(rows.count) * cell)
        let key = "s\(rows.joined(separator: "|"))\(colors.sorted { $0.key < $1.key })\(ink ?? "")\(seed)\(flip)\(String(glyphs))"
        return (bitmap(key, size) { ctx in
            for (r, row) in rows.enumerated() {
                let chars = Array(row)
                for (i, ch) in chars.enumerated() where ch != " " {
                    guard let fill = colors[ch] else { continue }
                    let cx = flip ? cols - 1 - i : i
                    let rect = CGRect(x: CGFloat(cx) * cell + 0.75, y: size.height - CGFloat(r + 1) * cell + 0.75, width: cell - 1.5, height: cell - 1.5)
                    ctx.setFillColor(cg(fill))
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.fillPath()
                    if let ink {
                        let g = glyphs[hash(seed &* 131 &+ r, i) % glyphs.count]
                        text(String(g), in: rect, cg(ink, 0.55), size: cell * 0.72, ctx)
                    }
                }
            }
        }, size)
    }

    /// A soft round glow with a small square core (fireflies).
    static func glow(_ hex: String, core: String, radius: CGFloat) -> (CGImage?, CGSize) {
        let size = CGSize(width: radius * 2, height: radius * 2)
        return (bitmap("glow\(hex)\(core)\(radius)", size) { ctx in
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cg(hex, 0.45), cg(hex, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: radius, y: radius), startRadius: 0, endCenter: CGPoint(x: radius, y: radius), endRadius: radius, options: [])
            ctx.setFillColor(cg(core))
            ctx.addPath(CGPath(roundedRect: CGRect(x: radius - 4, y: radius - 4, width: 8, height: 8), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.fillPath()
        }, size)
    }

    /// A vertical strip of cells, bright at the bottom and fading upward (aurora curtains).
    static func curtain(_ h: Int, _ hex: String) -> (CGImage?, CGSize) {
        let size = CGSize(width: cell, height: CGFloat(h) * cell)
        return (bitmap("curtain\(h)\(hex)\(String(glyphs))", size) { ctx in
            for k in 0..<h {
                let r = CGRect(x: 0.75, y: CGFloat(k) * cell + 0.75, width: cell - 1.5, height: cell - 1.5)
                ctx.setFillColor(cg(hex, 0.12 + 0.78 * (1 - CGFloat(k) / CGFloat(h))))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.fillPath()
                text(String(glyphs[hash(h * 31 + k, hex.count) % glyphs.count]), in: r, cg("#000000", 0.3), size: cell * 0.72, ctx)
            }
        }, size)
    }

    /// A column of `|` glyphs, brighter toward the top (grass blades).
    static func blade(_ h: Int, _ hex: String) -> (CGImage?, CGSize) {
        let size = CGSize(width: cell, height: CGFloat(h) * cell)
        return (bitmap("blade\(h)\(hex)", size) { ctx in
            for k in 0..<h { text("|", in: CGRect(x: 0, y: CGFloat(k) * cell, width: cell, height: cell), cg(hex, 0.3 + 0.12 * CGFloat(k)), size: cell * 0.9, ctx) }
        }, size)
    }
}

private enum Sprites {
    /// The logo's octopus (design/brand/octomux-logo.html): `#` body, `h` highlight, `s` shade, `e` eyes, `w` glints,
    /// `c` cheeks. Frames, all 14 rows (padded on top, the legs stay put): idle, squish (a head row dropped, legs
    /// out), stretch (a row doubled, legs trailing: the push), blink. Like the menu bar's bounce.
    static let octoBody = [
        "     ######     ",
        "   #hhh######   ",
        "  #hhh########  ",
        " ##hh#########s ",
        " #############s ",
        " ###we####we##s ",
        " ###ee####ee##s ",
        " ###ee####ee##s ",
        " #c##########cs ",
        "  ###########s  ",
    ]
    static let octoFrames: [[String]] = {
        let legs = [" ## ## ## ## ## ", "##  #  ##  #  ##", "#   #  ##  #   #"]
        let spread = ["##  ##    ##  ##", "#   #      #   #"]
        let tuck = ["   ## #### ##   ", "   #  #  #  #   ", "  #   #  #   #  "]
        func pad(_ r: [String]) -> [String] { Array(repeating: String(repeating: " ", count: 16), count: 14 - r.count) + r }
        let b = octoBody
        let idle = pad(b + legs)
        let squish = pad(Array(b[0..<4]) + Array(b[5...]) + spread)
        let stretch = pad(Array(b[0..<5]) + [b[4]] + Array(b[5...]) + tuck)
        let blink = idle.map { $0.replacingOccurrences(of: "e", with: "#").replacingOccurrences(of: "w", with: "#") }
        return [idle, squish, stretch, blink]
    }()
    /// Little ones, legs in and out.
    static let babyFrames = [
        ["  ####  ", " ###### ", " #e##e# ", " ###### ", " # ## # ", "#  ##  #"],
        ["  ####  ", " ###### ", " #e##e# ", " ###### ", "  ####  ", "  #  #  "],
    ]
    static let inkPuff = [
        "  ####  ",
        " ###### ",
        "########",
        " ###### ",
        "  ## #  ",
    ]
    static let rock = [
        "   ####   ",
        " ######## ",
        "##########",
    ]
    /// A big eye peeking out of the sand: `#` lid, `y` eye, `p` pupil.
    static let bigEye = [
        "  ####  ",
        " #yyyy# ",
        "#yyppyy#",
        "#yyppyy#",
        " #yyyy# ",
    ]
    static let cloud = [
        "      ######",
        "   ############",
        " ################",
        "####################",
        " ##################",
    ]
    static let smallCloud = [
        "   #####",
        " #########",
        "############",
    ]
    static let flatCloud = [
        "     ##########",
        " ####################",
        "##########################",
    ]
    /// A crescent from two circles (lit side lower left); `+` cells are the partly covered edge, drawn dimmer.
    static let moon = [
        "     +",
        "   +#+",
        "  ###",
        " +##+",
        " ###+",
        "+###+",
        "+####",
        "+####",
        "+#####",
        " ######",
        " +##########+",
        "  ##########",
        "   +######+",
        "     ++++",
    ]
    static let fish = [
        "#   ####",
        "## ######",
        "#########o#",
        "## ######",
        "#   ####",
    ]
    static let smallFish = [
        "#  ###",
        "######o",
        "#  ###",
    ]
    static let sun = [
        "  ####",
        " ######",
        "########",
        "########",
        " ######",
        "  ####",
    ]
    static let kite = [
        "   a",
        "  aab",
        " aaabb",
        "aaaabbb",
        " bbbaa",
        "  bba",
        "   b",
    ]
    static let balloon = [
        "  ####",
        " ##oo##",
        "########",
        "##oo####",
        " ######",
        "  ####",
        "   ||",
        "   []",
    ]
    static let branch = [
        "##########   o",
        "     ###oo#######o",
        "   oo ###   oo   #####",
        "  ooo  oo         ###oo",
        "   o               ooo",
    ]
}

// MARK: Layers

/// Builds one scene as layers and animations in `root`. Positions are given y-down (top-left origin)
/// and converted; `now` is the root's frozen time, so animation phases line up with the shared clock.
private struct SceneBuilder {
    let root: CALayer
    let W: CGFloat
    let H: CGFloat
    let now: CFTimeInterval
    var mood: AmbientMood = .calm
    var art: [String: String] = [:]
    var dark = false
    /// The sidebar's width: art that stays put (branches, weeds, reeds, traces, the moon, kites) goes to its right
    /// so it never sits behind text; things passing through (particles, fish, clouds) and low ground stay.
    var textColumn: CGFloat = 0

    /// x for a fraction across the area right of the text column.
    func px(_ f: CGFloat) -> CGFloat { textColumn + f * (W - textColumn) }
    /// Under the text column, ground art keeps to this many cells (it sits behind the sidebar footer).
    func groundCap(_ x: CGFloat, _ h: Int) -> Int { x < textColumn ? min(h, 2) : h }

    /// The scene's color for `key`, or the default drawing color.
    func a(_ key: String, _ fallback: String) -> String { art[key] ?? fallback }

    func build(_ s: AmbientScene) {
        Art.glyphs = s.legacy ? Art.classicGlyphs : Art.codeGlyphs
        let g = CAGradientLayer()
        g.frame = root.bounds
        g.colors = [NSColor(s.bottom).cgColor, NSColor(s.top).cgColor]   // layer space is y-up
        root.addSublayer(g)
        switch s.kind {
        case .nightSky: nightSky()
        case .reef: reef()
        case .fireflies: fireflies()
        case .embers: embers()
        case .rain: rain()
        case .sky: sky()
        case .sakura: sakura()
        case .snow: snow()
        case .aurora: aurora()
        case .circuit: circuit()
        case .kites: kites()
        case .octopus: octopus()
        case .tentacles: tentacles()
        case .custom:
            if let b = s.base { build(kind: b) }
            if let spec = s.spec { custom(spec, dark: s.dark) }
        }
        moodGlow(dark: s.dark)
    }

    private func build(kind: AmbientScene.Kind) {
        switch kind {
        case .nightSky: nightSky()
        case .reef: reef()
        case .fireflies: fireflies()
        case .embers: embers()
        case .rain: rain()
        case .sky: sky()
        case .sakura: sakura()
        case .snow: snow()
        case .aurora: aurora()
        case .circuit: circuit()
        case .kites: kites()
        case .octopus: octopus()
        case .tentacles: tentacles()
        case .custom: break
        }
    }

    /// Agents waiting for input (amber) or failing (red): a glow rises from the bottom and breathes.
    private func moodGlow(dark: Bool) {
        guard let hex = mood.glow else { return }
        let g = CAGradientLayer()
        g.frame = CGRect(x: 0, y: 0, width: W, height: H * 0.55)
        g.colors = [cg(hex, dark ? 0.3 : 0.24), cg(hex, 0)]
        root.addSublayer(g)
        pulse(g, 0.35, 1, period: 2.8, phase: 0)
    }

    // Helpers

    @discardableResult
    func add(_ art: (CGImage?, CGSize), x: CGFloat, y: CGFloat, opacity: Float = 1, anchorBottom: Bool = false) -> CALayer {
        let l = CALayer()
        l.contents = art.0
        l.contentsScale = Art.scale
        if anchorBottom { l.anchorPoint = CGPoint(x: 0.5, y: 0) }
        l.frame = CGRect(x: x, y: H - y - art.1.height, width: art.1.width, height: art.1.height)
        l.opacity = opacity
        root.addSublayer(l)
        return l
    }

    private func forever(_ a: CAAnimation, phase: Double) {
        a.repeatCount = .infinity
        a.beginTime = now - phase - 0.001
    }

    /// Across the whole width at `speed` pt/s, re-entering on the other side.
    func drift(_ l: CALayer, speed: CGFloat, phase: Double, leftward: Bool = false) {
        let w = l.bounds.width
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = leftward ? W + w / 2 : -w / 2
        a.toValue = leftward ? -w / 2 : W + w / 2
        a.duration = Double((W + w) / speed)
        forever(a, phase: phase * a.duration)
        l.add(a, forKey: "drift")
    }

    /// Back and forth around the model value (translation, rotation): ±amount over `period` seconds.
    func swing(_ l: CALayer, _ key: String, _ amount: CGFloat, period: Double, phase: Double) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = -amount
        a.toValue = amount
        a.isAdditive = true
        a.autoreverses = true
        a.duration = period / 2
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        forever(a, phase: phase)
        l.add(a, forKey: key)
    }

    func pulse(_ l: CALayer, _ lo: Float, _ hi: Float, period: Double, phase: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = lo
        a.toValue = hi
        a.autoreverses = true
        a.duration = period / 2
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        forever(a, phase: phase)
        l.add(a, forKey: "pulse")
    }

    /// `count` particles, each travelling from `from(i)` to `to(i)` (y-down) in `duration(i)` seconds and
    /// starting over, with a random phase so the screen is full from the first frame. Plain layer
    /// animations (not CAEmitterLayer) so they follow the shared clock and show in still thumbnails.
    func particles(_ count: Int, art: (Int) -> (CGImage?, CGSize), from: (Int) -> CGPoint, to: (Int) -> CGPoint,
                   duration: (Int) -> Double, opacity: (Int) -> Float, fade: Bool = false, sway: CGFloat = 0, spin: Bool = false, seed: Int = 0) {
        for i in 0..<count {
            let a = art(i), f = from(i), t = to(i), d = duration(i)
            let l = add(a, x: f.x - a.1.width / 2, y: f.y - a.1.height / 2, opacity: opacity(i))
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = CGPoint(x: f.x, y: H - f.y)
            move.toValue = CGPoint(x: t.x, y: H - t.y)
            move.duration = d
            let phase = rnd(i + seed, 90) * d
            forever(move, phase: phase)
            l.add(move, forKey: "move")
            if fade {
                let o = CAKeyframeAnimation(keyPath: "opacity")
                o.values = [0, opacity(i), opacity(i) * 0.7, 0]
                o.keyTimes = [0, 0.06, 0.55, 1]
                o.duration = d
                forever(o, phase: phase)
                l.add(o, forKey: "fade")
            }
            if sway > 0 { swing(l, "transform.translation.x", sway * CGFloat(0.5 + rnd(i + seed, 91)), period: 6 + rnd(i + seed, 92) * 8, phase: rnd(i + seed, 93) * 10) }
            if spin {
                let r = CABasicAnimation(keyPath: "transform.rotation.z")
                r.fromValue = 0
                r.toValue = (i % 2 == 0 ? 1 : -1) * 2 * Double.pi
                r.duration = 5 + rnd(i, 94) * 8
                forever(r, phase: rnd(i, 95) * r.duration)
                l.add(r, forKey: "spin")
            }
        }
    }

    func shape(_ path: CGPath, fill: CGColor, opacity: Float = 1) -> CAShapeLayer {
        let l = CAShapeLayer()
        var flip = CGAffineTransform(translationX: 0, y: H).scaledBy(x: 1, y: -1)
        l.path = path.copy(using: &flip)
        l.fillColor = fill
        l.opacity = opacity
        root.addSublayer(l)
        return l
    }

    // Scenes

    func nightSky() {
        let count = Int(min(140, W * H / 9000))
        for i in 0..<count {
            let big = i % 11 == 0
            let l = add(Art.glyph(big ? "+" : "·", "#FFFFFF", size: big ? 11 : 10), x: rnd(i, 1) * W, y: rnd(i, 2) * H * 0.92, opacity: 0.4)
            pulse(l, 0.08, big ? 0.9 : 0.6, period: 2.5 + rnd(i, 3) * 5, phase: rnd(i, 4) * 8)
        }
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.frame = CGRect(x: W * 0.16 + 70 - 150, y: H - H * 0.09 - 90 - 150, width: 300, height: 300)
        halo.colors = [cg(a("moon", "#E9E1C4"), 0.16), cg(a("moon", "#E9E1C4"), 0)]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(halo)
        pulse(halo, 0.6, 1, period: 12, phase: 0)
        let moon = add(Art.sprite(Sprites.moon, ["#": a("moon", "#E9E1C4"), "+": a("moonEdge", "#8C8670")], ink: a("moonInk", "#8F855F"), seed: 3),
                       x: px(0.16), y: H * 0.09)
        swing(moon, "transform.translation.y", 3, period: 18, phase: 0)
        for i in 0..<2 {
            let l = add(Art.sprite(i == 0 ? Sprites.flatCloud : Sprites.smallCloud, ["#": a("cloud", "#33417F")], ink: a("cloudInk", "#5B6BB5"), seed: 10 + i),
                        x: 0, y: H * (0.32 + CGFloat(i) * 0.3), opacity: 0.7)
            drift(l, speed: 4 + CGFloat(i) * 3, phase: rnd(i, 7))
        }
        // A shooting star every 13 s.
        let streak = Art.bitmap("streak", CGSize(width: 90, height: 14)) { ctx in
            for k in 0..<7 { Art.text(k == 6 ? "*" : "-", in: CGRect(x: CGFloat(k) * 12, y: 0, width: 12, height: 14), cg("#FFFFFF", 0.15 + 0.14 * CGFloat(k)), size: 11, ctx) }
        }
        let s = add((streak, CGSize(width: 90, height: 14)), x: W * 0.3, y: H * 0.12, opacity: 0)
        s.setAffineTransform(CGAffineTransform(rotationAngle: -0.33))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0, 0]; fade.keyTimes = [0, 0.01, 0.05, 0.085, 1]
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [CGPoint(x: W * 0.3, y: H * 0.88), CGPoint(x: W * 0.3 + 260, y: H * 0.88 - 90), CGPoint(x: W * 0.3 + 260, y: H * 0.88 - 90)]
        move.keyTimes = [0, 0.085, 1]
        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.duration = 13
        forever(group, phase: 4)
        s.add(group, forKey: "shoot")
    }

    func reef() {
        for i in 0..<3 {
            let x0 = W * (0.15 + 0.3 * CGFloat(i))
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: x0, y: 0), CGPoint(x: x0 + 70, y: 0), CGPoint(x: x0 + 260, y: H), CGPoint(x: x0 + 90, y: H)])
            p.closeSubpath()
            pulse(shape(p, fill: cg(a("ray", "#FFFFFF")), opacity: 0.035), 0.015, 0.06, period: 9 + Double(i) * 3, phase: Double(i) * 2)
        }
        for i in 0..<9 {
            let x0 = px(rnd(i, 20)), h = 5 + hash(i, 21) % 8
            for k in 0..<h {
                let l = add(Art.sprite(["#"], ["#": i % 3 == 0 ? a("weed1", "#3E9E6A") : a("weed2", "#2E7D5B")], ink: a("weedInk", "#123A2A"), seed: hash(i, k)), x: x0, y: H - CGFloat(k + 1) * 12, opacity: 0.9)
                swing(l, "transform.translation.x", 0.5 + CGFloat(k) * 0.9, period: 7, phase: Double(k) * 0.39 + Double(i))
            }
        }
        let colors = ["#FF8A5C", "#FFC857", "#FF6F91", "#7FD6FF", "#FFB36B", "#C9A2FF"]
        for i in 0..<6 {
            let right = i % 2 == 0
            let l = add(Art.sprite(i % 3 == 0 ? Sprites.fish : Sprites.smallFish, ["#": colors[i], "o": "#10232A"], ink: a("fishInk", "#4A2A20"), seed: 30 + i, flip: !right),
                        x: 0, y: H * (0.12 + 0.13 * CGFloat(i)), opacity: 0.92)
            drift(l, speed: 14 + CGFloat(rnd(i, 8)) * 16, phase: rnd(i, 7), leftward: !right)
            swing(l, "transform.translation.y", 8, period: 7.8, phase: Double(i) * 1.3)
        }
        particles(30, art: { Art.glyph($0 % 3 == 0 ? "o" : $0 % 3 == 1 ? "°" : ".", a("bubble", "#FFFFFF"), size: 10) },
                  from: { CGPoint(x: rnd($0, 11) * W, y: H + 15) }, to: { CGPoint(x: rnd($0, 11) * W, y: -15) },
                  duration: { Double(H + 30) / (16 + rnd($0, 9) * 30) }, opacity: { _ in 0.45 }, sway: 6)
    }

    func fireflies() {
        let cols = Int(W / 12) + 1
        for c in 0..<cols {
            let h = groundCap(CGFloat(c) * 12, 1 + hash(c, 40) % 4)
            let l = add(Art.blade(h, a("grass", "#5FA35A")), x: CGFloat(c) * 12, y: H - 2 - CGFloat(h) * 12, anchorBottom: true)
            swing(l, "transform.rotation.z", 0.16, period: 5.7, phase: Double(c) * 0.16)
        }
        // Reeds with seed heads standing above the grass.
        for i in 0..<Int(W / 110) + 1 {
            let h = 4 + hash(i, 41) % 4
            let rows = ["o", "o"] + Array(repeating: "|", count: h)
            let l = add(Art.sprite(rows, ["o": a("reedHead", "#6B4A2A"), "|": a("reed", "#3F6B3A")], ink: nil, seed: 300 + i),
                        x: px(rnd(i, 42)), y: H - 4 - CGFloat(rows.count) * 12, opacity: 0.85, anchorBottom: true)
            swing(l, "transform.rotation.z", 0.05, period: 7 + rnd(i, 43) * 3, phase: rnd(i, 44) * 6)
        }
        for i in 0..<28 {
            let bx = rnd(i, 1) * W, by = H * (0.08 + rnd(i, 4) * 0.78)
            // Fireflies take the mood's color: amber when an agent waits for you, red on an error.
            let (glowHex, coreHex) = mood == .attention ? ("#F5B841", "#FFE3A0") : mood == .error ? ("#FF6B5B", "#FFC2B8") : (a("glow", "#D8F27A"), a("core", "#EEF8A8"))
            let l = add(Art.glow(glowHex, core: coreHex, radius: 18), x: bx - 18, y: by - 18, opacity: 0)
            let wander = CAKeyframeAnimation(keyPath: "position")
            let rx = 30 + rnd(i, 5) * 50, ry = 20 + rnd(i, 6) * 35
            let ellipse = CGPath(ellipseIn: CGRect(x: bx - rx, y: H - by - ry, width: rx * 2, height: ry * 2), transform: nil)
            wander.path = ellipse
            wander.calculationMode = .paced
            wander.duration = 22 + rnd(i, 7) * 26
            forever(wander, phase: rnd(i, 8) * wander.duration)
            l.add(wander, forKey: "wander")
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0, 0, 1, 0.2, 0]
            blink.keyTimes = [0, 0.35, 0.55, 0.8, 1]
            blink.duration = 4 + rnd(i, 9) * 5
            forever(blink, phase: rnd(i, 10) * blink.duration)
            l.add(blink, forKey: "blink")
        }
    }

    func embers() {
        let glow = CAGradientLayer()
        glow.frame = CGRect(x: 0, y: 0, width: W, height: H * 0.45)
        glow.colors = [cg("#FF7A3D", 0.22), cg("#FF7A3D", 0)]
        root.addSublayer(glow)
        let hills = CGMutablePath()
        hills.move(to: CGPoint(x: 0, y: H))
        for x in stride(from: 0, through: W, by: 12) {
            hills.addLine(to: CGPoint(x: x, y: H - 26 - (sin(x * 0.006) + 1) * 22 - (sin(x * 0.017 + 1) + 1) * 8))
        }
        hills.addLine(to: CGPoint(x: W, y: H)); hills.closeSubpath()
        _ = shape(hills, fill: cg("#120A08", 0.85))
        particles(55, art: { $0 % 4 == 0 ? Art.glyph("*", "#FF6B45", size: 10) : Art.glyph("·", $0 % 2 == 0 ? "#FFB06B" : "#FF8A55", size: 13) },
                  from: { CGPoint(x: rnd($0, 3) * W, y: H + 10) }, to: { CGPoint(x: rnd($0, 3) * W + H * 0.06, y: H * (0.1 + rnd($0, 4) * 0.4)) },
                  duration: { Double(H) / (12 + rnd($0, 1) * 28) }, opacity: { _ in 1 }, fade: true, sway: 18, spin: false)
    }

    func rain() {
        for i in 0..<4 {
            let l = add(Art.sprite(i % 2 == 0 ? Sprites.cloud : Sprites.smallCloud, ["#": a("cloud", "#2A3542")], ink: a("cloudInk", "#4A5868"), seed: 50 + i), x: 0, y: H * 0.02 + CGFloat(i % 2) * 30, opacity: 0.9)
            drift(l, speed: 3 + CGFloat(i), phase: rnd(i, 7))
        }
        particles(Int(min(150, W * H / 7000)), art: { _ in Art.glyph("/", a("drop", "#8FA8C2"), size: 11) },
                  from: { CGPoint(x: rnd($0, 3) * W * 1.25, y: -20) }, to: { CGPoint(x: rnd($0, 3) * W * 1.25 - (H + 40) * 0.18, y: H + 20) },
                  duration: { Double(H + 40) / (240 + rnd($0, 1) * 160) }, opacity: { 0.3 + 0.35 * Float(rnd($0, 4)) })
    }

    func sky() {
        let sun = CAGradientLayer()
        sun.type = .radial
        sun.frame = CGRect(x: W * 0.82 - 260, y: H - 60 - 260, width: 520, height: 520)
        sun.colors = [cg("#FFFFFF", 0.55), cg("#FFFFFF", 0)]
        sun.startPoint = CGPoint(x: 0.5, y: 0.5); sun.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(sun)
        let disc = add(Art.sprite(Sprites.sun, ["#": a("sun", "#FFE08A")], ink: a("sunInk", "#E0A93A"), seed: 61), x: W * 0.82 - 48, y: 26, opacity: 0.95)
        pulse(disc, 0.8, 1, period: 6, phase: 0)
        for i in 0..<5 {
            let l = add(Art.sprite(i % 2 == 0 ? Sprites.cloud : Sprites.smallCloud, ["#": a("cloud", "#FFFFFF")], ink: a("cloudInk", "#A9CFF0"), seed: 60 + i), x: 0, y: H * (0.2 + 0.15 * CGFloat(i)), opacity: 0.95)
            drift(l, speed: 5 + CGFloat(rnd(i, 1)) * 8, phase: rnd(i, 7))
            swing(l, "transform.translation.y", 4, period: 31, phase: Double(i) * 5)
        }
        let up = Art.bitmap("flock-v", CGSize(width: 44, height: 24)) { ctx in
            for k in 0..<3 { Art.text("v", in: CGRect(x: CGFloat(k) * 15, y: CGFloat(k % 2) * 9, width: 14, height: 14), cg(a("bird", "#4F6C88"), 0.75), size: 12, ctx) }
        }
        let down = Art.bitmap("flock--", CGSize(width: 44, height: 24)) { ctx in
            for k in 0..<3 { Art.text("-", in: CGRect(x: CGFloat(k) * 15, y: CGFloat(k % 2) * 9, width: 14, height: 14), cg(a("bird", "#4F6C88"), 0.75), size: 12, ctx) }
        }
        for i in 0..<4 {
            let l = add((up, CGSize(width: 44, height: 24)), x: 0, y: H * (0.2 + CGFloat(rnd(i, 3)) * 0.3))
            drift(l, speed: 26 + CGFloat(rnd(i, 2)) * 10, phase: rnd(i + 20, 7))
            swing(l, "transform.translation.y", 6, period: 5.7, phase: Double(i))
            let flap = CAKeyframeAnimation(keyPath: "contents")
            flap.values = [up as Any, down as Any]
            flap.calculationMode = .discrete
            flap.duration = 0.9
            forever(flap, phase: Double(i) * 0.2)
            l.add(flap, forKey: "flap")
        }
    }

    func sakura() {
        let colors: [Character: String] = ["#": a("branch", "#7A4E3A"), "o": a("blossom", "#F49AB4")]
        // Branches reach in from the right edge and the lower left, clear of the sidebar's header.
        let br = Art.sprite(Sprites.branch, colors, ink: a("branchInk", "#B85A78"), seed: 70, flip: true)
        swing(add(br, x: W - br.1.width + 12, y: 54), "transform.translation.y", 1.5, period: 15, phase: 0)
        // The lower-left branch fills an empty corner; with a sidebar there it would sit behind its rows.
        if textColumn == 0 {
            swing(add(Art.sprite(Sprites.branch, colors, ink: a("branchInk", "#B85A78"), seed: 71), x: -12, y: H * 0.7, opacity: 0.85), "transform.translation.y", 1.5, period: 17, phase: 3)
        }
        let pinks = [("*", "#E77C9C"), ("•", "#F2A3BA"), ("+", "#D9668A")]
        particles(48, art: { Art.glyph(pinks[$0 % 3].0, pinks[$0 % 3].1, size: 10 + CGFloat(hash($0, 5) % 4)) },
                  from: { CGPoint(x: rnd($0, 3) * W * 1.1 - W * 0.1, y: -15) },
                  to: { CGPoint(x: rnd($0, 3) * W * 1.1 - W * 0.1 + (H + 30) / (14 + rnd($0, 1) * 22) * 9, y: H + 15) },
                  duration: { Double(H + 30) / (14 + rnd($0, 1) * 22) }, opacity: { 0.5 + 0.35 * Float(rnd($0, 4)) }, sway: 30, spin: true)
    }

    private func line(_ points: [CGPoint], stroke: CGColor, width: CGFloat, dash: [NSNumber]? = nil) -> CAShapeLayer {
        let p = CGMutablePath()
        p.addLines(between: points.map { CGPoint(x: $0.x, y: H - $0.y) })
        let l = CAShapeLayer()
        l.path = p
        l.fillColor = nil
        l.strokeColor = stroke
        l.lineWidth = width
        l.lineJoin = .round
        l.lineCap = .round
        l.lineDashPattern = dash
        root.addSublayer(l)
        return l
    }

    func aurora() {
        for i in 0..<Int(min(90, W * H / 14000)) {
            let l = add(Art.glyph("·", "#FFFFFF", size: 10), x: rnd(i, 1) * W, y: rnd(i, 2) * H * 0.9, opacity: 0.3)
            pulse(l, 0.05, 0.5, period: 3 + rnd(i, 3) * 5, phase: rnd(i, 4) * 8)
        }
        // Curtains: columns of cells along a wavy band, brightening and dimming in a wave that travels sideways.
        let bands: [(String, CGFloat, Float)] = [("#5BF0A6", 0.2, 0.42), ("#4FD6E8", 0.3, 0.3), ("#B58CFF", 0.13, 0.24)]
        let cols = Int(W / 12) + 1
        for (b, band) in bands.enumerated() {
            for c in 0..<cols {
                let h = 3 + Int((sin(Double(c) * 0.09 + Double(b) * 2) + 1) * 2.5 + (sin(Double(c) * 0.031 + Double(b)) + 1) * 1.5)
                let cy = H * band.1 + CGFloat(sin(Double(c) * 0.045 + Double(b) * 1.7)) * 46
                let l = add(Art.curtain(h, band.0), x: CGFloat(c) * 12, y: cy - CGFloat(h) * 6, opacity: band.2)
                pulse(l, band.2 * 0.2, band.2, period: 8 + Double(b) * 2.5, phase: Double(c) * 0.11 + Double(b) * 3)
                swing(l, "transform.translation.y", 9, period: 12 + Double(b) * 3, phase: Double(c) * 0.09)
            }
        }
        // Constellations: a few stars joined by faint dashed lines.
        for k in 0..<5 {
            let cx = W * (0.06 + 0.88 * CGFloat(rnd(k, 60))), cy = H * (0.06 + 0.55 * CGFloat(rnd(k, 61)))
            let n = 4 + hash(k, 62) % 3
            let pts = (0..<n).map { j in CGPoint(x: cx + (CGFloat(rnd(k * 10 + j, 63)) - 0.5) * 170, y: cy + (CGFloat(rnd(k * 10 + j, 64)) - 0.5) * 110) }
                .sorted { $0.x < $1.x }
            pulse(line(pts, stroke: cg("#FFFFFF", 0.2), width: 1, dash: [2, 4]), 0.3, 1, period: 10, phase: Double(k) * 2)
            for (j, pt) in pts.enumerated() {
                let a = Art.glyph(j % 2 == 0 ? "+" : "*", "#FFFFFF", size: 11)
                pulse(add(a, x: pt.x - a.1.width / 2, y: pt.y - a.1.height / 2, opacity: 0.6), 0.25, 0.95,
                      period: 3 + rnd(k * 10 + j, 65) * 3, phase: rnd(k * 10 + j, 66) * 6)
            }
        }
    }

    func circuit() {
        let step: CGFloat = 24
        let gx = Int(W / step), gy = Int(H / step)
        // Signals take the mood's color: amber when an agent waits for you, red on an error.
        let (sig, core) = mood == .attention ? ("#F5B841", "#FFE3A0") : mood == .error ? ("#FF6B5B", "#FFC2B8") : (a("sig", "#4BE3B0"), a("core", "#C8FFE9"))
        for i in 0..<Int(min(18, W * H / 50000) + 4) {
            let x0 = min(gx, Int((textColumn / step).rounded(.up)))   // traces stay right of the sidebar
            var x = x0 + Int(rnd(i, 1) * Double(gx - x0)), y = Int(rnd(i, 2) * Double(gy))
            func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) * step + 6, y: CGFloat(y) * step + 6) }
            var pts = [pt(x, y)]
            var horizontal = i % 2 == 0
            for seg in 0..<(3 + hash(i, 3) % 4) {
                let len = 2 + hash(i * 7 + seg, 4) % 7
                let sign = hash(i * 7 + seg, 5) % 2 == 0 ? 1 : -1
                if horizontal { x = max(x0, min(gx, x + sign * len)) } else { y = max(0, min(gy, y + sign * len)) }
                pts.append(pt(x, y))
                horizontal.toggle()
            }
            _ = line(pts, stroke: cg(a("trace", "#1E4A3C"), 0.9), width: 2)
            for (j, p) in [pts.first!, pts.last!].enumerated() {
                let pad = add(Art.sprite(["#"], ["#": a("trace", "#1E4A3C")], ink: a("padInk", "#4BE3B0"), seed: i * 2 + j), x: p.x - 6, y: p.y - 6)
                if j == 1 { pulse(pad, 0.5, 1, period: 3 + rnd(i, 6) * 3, phase: rnd(i, 7) * 4) }
            }
            // A signal runs the trace, then the trace rests.
            var length: CGFloat = 0
            for k in 1..<pts.count { length += abs(pts[k].x - pts[k - 1].x) + abs(pts[k].y - pts[k - 1].y) }
            let travel = Double(max(length, 24) / 70), rest = 2 + rnd(i, 8) * 5
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: $0.x, y: H - $0.y) })
            let g = add(Art.glow(sig, core: core, radius: 10), x: pts[0].x - 10, y: pts[0].y - 10, opacity: 0)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.duration = travel
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [0, 1, 1, 0]
            show.keyTimes = [0, 0.05, 0.9, 1]
            show.duration = travel
            let group = CAAnimationGroup()
            group.animations = [move, show]
            group.duration = travel + rest
            forever(group, phase: rnd(i, 9) * (travel + rest))
            g.add(group, forKey: "signal")
        }
        // Scattered bits blinking on the grid.
        for i in 0..<Int(min(50, W * H / 20000)) {
            let bit = Art.glyph(i % 2 == 0 ? "0" : "1", a("bits", "#2E7A60"), size: 10)
            let l = add(bit, x: CGFloat(Int(rnd(i, 20) * Double(gx))) * step, y: CGFloat(Int(rnd(i, 21) * Double(gy))) * step, opacity: 0.3)
            pulse(l, 0, 0.6, period: 2 + rnd(i, 22) * 4, phase: rnd(i, 23) * 6)
        }
    }

    func kites() {
        let sun = CAGradientLayer()
        sun.type = .radial
        sun.frame = CGRect(x: W * 0.8 - 320, y: H - H * 0.12 - 320, width: 640, height: 640)
        sun.colors = [cg(a("sun", "#FFF4E0"), 0.75), cg(a("sun", "#FFF4E0"), 0)]
        sun.startPoint = CGPoint(x: 0.5, y: 0.5); sun.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(sun)
        for i in 0..<3 {
            let l = add(Art.sprite(Sprites.smallCloud, ["#": a("cloud", "#FFFFFF")], ink: a("cloudInk", "#E8D2C0"), seed: 90 + i), x: 0, y: H * (0.08 + 0.2 * CGFloat(i)), opacity: 0.75)
            drift(l, speed: 4 + CGFloat(i) * 2, phase: rnd(i, 7))
        }
        let balloonColors = [("#E86A5A", "#FFD27A"), ("#6AA8E8", "#FFFFFF")]
        for (i, c) in balloonColors.enumerated() {
            let a = Art.sprite(Sprites.balloon, ["#": c.0, "o": c.1, "|": "#7A5A40", "[": "#8A5A3A", "]": "#8A5A3A"], ink: "#5A2A20", seed: 100 + i)
            let l = add(a, x: px(0.55 + 0.3 * CGFloat(i)), y: H * 0.5, opacity: 0.95)
            rise(l, speed: 5 + CGFloat(i) * 2, phase: rnd(i, 30), up: true)
            swing(l, "transform.translation.x", 14, period: 17, phase: Double(i) * 4)
        }
        let kiteColors = [("#E0703A", "#FFC15A"), ("#4E8FD9", "#9FD0FF"), ("#C94F76", "#F4A3BE")]
        for (k, c) in kiteColors.enumerated() {
            let kite = Art.sprite(Sprites.kite, ["a": c.0, "b": c.1], ink: "#3A2A20", seed: 110 + k)
            let tail: CGFloat = 96
            // A container moves the kite, its tail and its string together (its own coordinates are y-up).
            let box = CALayer()
            box.frame = CGRect(x: px(0.12 + 0.3 * CGFloat(k)), y: H - H * (0.14 + 0.1 * CGFloat(k % 2)) - kite.1.height - tail,
                               width: kite.1.width, height: kite.1.height + tail)
            root.addSublayer(box)
            let string = CAShapeLayer()
            let sp = CGMutablePath()
            sp.move(to: CGPoint(x: kite.1.width / 2, y: tail + 6))
            sp.addQuadCurve(to: CGPoint(x: kite.1.width / 2 - 140, y: -H), control: CGPoint(x: kite.1.width / 2 + 30, y: -H * 0.4))
            string.path = sp
            string.fillColor = nil
            string.strokeColor = cg(a("string", "#6A5A4A"), 0.3)
            string.lineWidth = 1
            box.addSublayer(string)
            for j in 0..<6 {
                let bow = Art.glyph(j % 2 == 0 ? "<" : ">", c.0, size: 11)
                let l = CALayer()
                l.contents = bow.0
                l.contentsScale = Art.scale
                l.frame = CGRect(x: kite.1.width / 2 - bow.1.width / 2, y: tail - CGFloat(j + 1) * 15, width: bow.1.width, height: bow.1.height)
                box.addSublayer(l)
                swing(l, "transform.translation.x", 2 + CGFloat(j) * 1.8, period: 2.4, phase: Double(j) * 0.25)
            }
            let body = CALayer()
            body.contents = kite.0
            body.contentsScale = Art.scale
            body.frame = CGRect(x: 0, y: tail, width: kite.1.width, height: kite.1.height)
            box.addSublayer(body)
            swing(box, "transform.rotation.z", 0.08, period: 6 + Double(k), phase: Double(k) * 2)
            swing(box, "transform.translation.x", 26, period: 14 + Double(k) * 3, phase: Double(k) * 5)
            swing(box, "transform.translation.y", 10, period: 9 + Double(k) * 2, phase: Double(k) * 3)
        }
    }


    /// The logo's octopus swims in place right of the sidebar (squish, push, drift back down, blink; faster while
    /// agents work, since the clock runs faster), puffs ink now and then, and shows a "!" while an agent waits.
    /// Little ones rise past, bubbles go up, rocks and weeds on the floor.
    func octopus() {
        for i in 0..<3 {
            let x0 = W * (0.12 + 0.32 * CGFloat(i))
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: x0, y: 0), CGPoint(x: x0 + 60, y: 0), CGPoint(x: x0 + 230, y: H), CGPoint(x: x0 + 80, y: H)])
            p.closeSubpath()
            pulse(shape(p, fill: cg(a("ray", "#FFFFFF")), opacity: 0.03), 0.012, dark ? 0.05 : 0.18, period: 10 + Double(i) * 3, phase: Double(i) * 2)
        }
        // Floor: rocks and weeds, right of the sidebar.
        for i in 0..<3 {
            let r = Art.sprite(Sprites.rock, ["#": a("rock", dark ? "#2A2150" : "#C6B8F4")], ink: a("rockInk", dark ? "#43367A" : "#9F8BE6"), seed: 420 + i, flip: i == 1)
            add(r, x: px(0.08 + 0.4 * CGFloat(i)), y: H - r.1.height + 2, opacity: 0.9)
        }
        for i in 0..<7 {
            let x0 = px(0.03 + 0.94 * CGFloat(rnd(i, 430))), h = 3 + hash(i, 431) % 6
            for k in 0..<h {
                let l = add(Art.sprite(["#"], ["#": i % 3 == 0 ? a("weed1", "#4E8F7A") : a("weed2", "#3A7366")], ink: a("weedInk", "#143A30"), seed: hash(i + 40, k)),
                            x: x0, y: H - CGFloat(k + 1) * 12, opacity: 0.85)
                swing(l, "transform.translation.x", 0.5 + CGFloat(k) * 0.9, period: 7.5, phase: Double(k) * 0.39 + Double(i))
            }
        }
        particles(26, art: { Art.glyph($0 % 3 == 0 ? "o" : $0 % 3 == 1 ? "°" : ".", a("bubble", "#FFFFFF"), size: 10) },
                  from: { CGPoint(x: rnd($0, 411) * W, y: H + 15) }, to: { CGPoint(x: rnd($0, 411) * W, y: -15) },
                  duration: { Double(H + 30) / (16 + rnd($0, 412) * 28) }, opacity: { _ in dark ? 0.4 : 0.5 }, sway: 6, seed: 410)
        // Little ones in the logo's other colors, rising slowly.
        let babyColors = [a("baby1", "#A78BFA"), a("baby2", "#60A5FA"), a("baby3", "#FF8A7A"), a("baby4", "#F9A8D4")]
        for i in 0..<5 {
            let colors: [Character: String] = ["#": babyColors[i % babyColors.count], "e": a("eye", "#1E1B4B")]
            let frames = Sprites.babyFrames.map { Art.sprite($0, colors, ink: a("babyInk", "#000000"), seed: 440 + i) }
            let l = add(frames[0], x: rnd(i, 441) * (W - frames[0].1.width), y: H * 0.5, opacity: dark ? 0.8 : 0.9)
            rise(l, speed: 7 + CGFloat(rnd(i, 442)) * 7, phase: rnd(i, 443), up: true)
            swing(l, "transform.translation.x", 16, period: 9 + rnd(i, 444) * 6, phase: rnd(i, 445) * 9)
            let legs = CAKeyframeAnimation(keyPath: "contents")
            legs.values = [frames[0].0 as Any, frames[1].0 as Any]
            legs.keyTimes = [0, 0.7, 1]
            legs.calculationMode = .discrete
            legs.duration = 1.4 + rnd(i, 446)
            forever(legs, phase: rnd(i, 447) * legs.duration)
            l.add(legs, forKey: "legs")
        }
        // The octopus.
        let colors: [Character: String] = ["#": a("body", "#8B5CF6"), "h": a("hi", "#C4B5FD"), "s": a("shade", "#6D28D9"),
                                           "e": a("eye", "#1E1B4B"), "w": "#FFFFFF", "c": a("cheek", "#F9A8D4")]
        let frames = Sprites.octoFrames.map { Art.sprite($0, colors, ink: a("octoInk", "#5B21B6"), seed: 400) }
        let size = frames[0].1
        let cx = px(0.7), top = max(H * 0.1, H - size.height - H * 0.22)
        let period = 4.4
        // Ink first, so it stays behind the body.
        let puff = Art.sprite(Sprites.inkPuff, ["#": a("ink", "#0B061A")], ink: nil, seed: 401)
        let ink = add(puff, x: cx - puff.1.width / 2, y: top + size.height - puff.1.height, opacity: 0)
        let inkShow = CAKeyframeAnimation(keyPath: "opacity")
        inkShow.values = [0, 0, dark ? 0.75 : 0.35, dark ? 0.45 : 0.2, 0, 0]
        inkShow.keyTimes = [0, 0.48, 0.52, 0.62, 0.8, 1]
        let inkGrow = CAKeyframeAnimation(keyPath: "transform.scale")
        inkGrow.values = [0.3, 0.3, 0.9, 1.7, 2.3, 2.3]
        inkGrow.keyTimes = inkShow.keyTimes
        let inkSink = CAKeyframeAnimation(keyPath: "transform.translation.y")
        inkSink.values = [0, 0, -6, -24, -36, -36]
        inkSink.keyTimes = inkShow.keyTimes
        let inkGroup = CAAnimationGroup()
        inkGroup.animations = [inkShow, inkGrow, inkSink]
        inkGroup.duration = period * 3        // every third push
        forever(inkGroup, phase: period * 1.1)
        ink.add(inkGroup, forKey: "ink")
        let body = add(frames[0], x: cx - size.width / 2, y: top)
        // idle … squish, stretch (the push), idle … blink, idle.
        let swim = CAKeyframeAnimation(keyPath: "contents")
        swim.values = [0, 1, 2, 0, 3, 0].map { frames[$0].0 as Any }
        swim.keyTimes = [0, 0.4, 0.48, 0.6, 0.9, 0.94, 1]
        swim.calculationMode = .discrete
        swim.duration = period
        forever(swim, phase: 0)
        body.add(swim, forKey: "swim")
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")   // y-up: a dip, the push up, a slow sink
        lift.values = [0, 0, -4, 16, 6, 0]
        lift.keyTimes = [0, 0.4, 0.48, 0.6, 0.85, 1]
        lift.isAdditive = true
        lift.timingFunctions = [.init(name: .linear), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeInEaseOut)]
        lift.duration = period
        forever(lift, phase: 0)
        body.add(lift, forKey: "lift")
        swing(body, "transform.translation.x", 34, period: 27, phase: 5)
        swing(body, "transform.rotation.z", 0.035, period: 11, phase: 2)
        // The ink cloud follows the octopus sideways.
        swing(ink, "transform.translation.x", 34, period: 27, phase: 5)
        if mood == .attention || mood == .error {
            let mark = Art.glyph(mood == .error ? "×" : "!", mood == .error ? "#FF6B5B" : "#F5B841", size: 22)
            let l = CALayer()
            l.contents = mark.0
            l.contentsScale = Art.scale
            l.frame = CGRect(x: size.width - 26, y: size.height - 8, width: mark.1.width, height: mark.1.height)
            body.addSublayer(l)
            pulse(l, 0.35, 1, period: 1.4, phase: 0)
        }
    }

    /// Something big lives under the sand: tentacles rise from the floor right of the sidebar and wave (a wave runs
    /// up each one), two eyes peek out and blink (amber while an agent waits, red on an error). Specks and bubbles.
    func tentacles() {
        particles(Int(min(60, W * H / 16000)), art: { Art.glyph($0 % 4 == 0 ? "*" : "·", a("speck", "#B9A6FF"), size: 10) },
                  from: { CGPoint(x: rnd($0, 501) * W, y: H + 10) }, to: { CGPoint(x: rnd($0, 501) * W + 40, y: -10) },
                  duration: { Double(H + 20) / (5 + rnd($0, 502) * 9) }, opacity: { 0.25 + 0.3 * Float(rnd($0, 503)) }, fade: true, sway: 14, seed: 500)
        particles(14, art: { Art.glyph($0 % 2 == 0 ? "o" : "°", a("bubble", "#D8CCFF"), size: 10) },
                  from: { CGPoint(x: rnd($0, 511) * W, y: H + 15) }, to: { CGPoint(x: rnd($0, 511) * W, y: -15) },
                  duration: { Double(H + 30) / (18 + rnd($0, 512) * 24) }, opacity: { _ in 0.4 }, sway: 5, seed: 510)
        // The eyes, between the middle tentacles.
        let (eyeHex, pupilHex) = mood == .attention ? ("#F5B841", "#2A1A05") : mood == .error ? ("#FF6B5B", "#2A0805") : (a("eye", "#FDE68A"), a("pupil", "#1A0A2A"))
        let eye = Art.sprite(Sprites.bigEye, ["#": a("lid", "#4C1D95"), "y": eyeHex, "p": pupilHex], ink: nil, seed: 520)
        // Above the status bar, which covers the window's bottom ~30 pt.
        let ex = px(0.51), ey = H - eye.1.height - 40
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(x: ex - 150, y: 0, width: 300, height: 200)
        glow.colors = [cg(mood == .calm || mood == .busy ? a("glow", "#FDE68A") : eyeHex, dark ? 0.16 : 0.35), cg(eyeHex, 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(glow)
        pulse(glow, 0.5, 1, period: 6, phase: 0)
        for (j, dx) in [-eye.1.width - 10, 10].enumerated() {
            let l = add(eye, x: ex + dx, y: ey)
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.12, 1, 1, 0.12, 1, 1]
            blink.keyTimes = [0, 0.6, 0.63, 0.66, 0.7, 0.73, 0.76, 1]
            blink.duration = 9
            forever(blink, phase: Double(j) * 0.02)
            l.add(blink, forKey: "blink")
            // Looking around: the eyes drift a little together.
            swing(l, "transform.translation.x", 5, period: 13, phase: 1)
        }
        // Tentacles: rows of cells, wide at the floor and thin at the tip, which curls; suckers on the inner side.
        let colors: [Character: String] = ["#": a("arm", "#6D3FD0"), "o": a("sucker", "#C4B5FD")]
        let bases: [CGFloat] = W - textColumn > 700 ? [0.07, 0.29, 0.73, 0.94] : [0.12, 0.88]
        for (t, f) in bases.enumerated() {
            let base = px(f)
            let h = max(6, Int(H * (0.34 + 0.2 * CGFloat(rnd(t, 530))) / 12))
            let lean: CGFloat = f < 0.5 ? 1 : -1
            for k in 0..<h {
                let u = CGFloat(k) / CGFloat(h)
                let w = max(1, Int((4.4 * (1 - u) + 0.6).rounded()))
                var row = Array(String(repeating: "#", count: w))
                if w >= 2 && k % 2 == 0 { row[lean > 0 ? w - 1 : 0] = "o" }
                let curl = lean * pow(max(0, u - 0.55) / 0.45, 2) * 42
                let l = add(Art.sprite([String(row)], colors, ink: a("armInk", "#2E1065"), seed: t * 100 + k),
                            x: base - CGFloat(w) * 6 + curl, y: H - CGFloat(k + 1) * 12 + 2)
                swing(l, "transform.translation.x", 0.8 + CGFloat(k) * 1.15, period: 8 + Double(t) * 1.3, phase: Double(t) * 2.2 - Double(k) * 0.2)
                if u > 0.55 { swing(l, "transform.translation.y", (u - 0.55) * 14, period: 8 + Double(t) * 1.3, phase: Double(t) * 2.2 - Double(k) * 0.2 + 2) }
            }
        }
    }

    /// Vertical loop: up (or down) through the whole height at `speed` pt/s.
    func rise(_ l: CALayer, speed: CGFloat, phase: Double, up: Bool) {
        let h = l.bounds.height
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = up ? -h / 2 : H + h / 2
        a.toValue = up ? H + h / 2 : -h / 2
        a.duration = Double((H + h) / speed)
        forever(a, phase: phase * a.duration)
        l.add(a, forKey: "rise")
    }

    /// A user scene's elements (on top of its base scene, if it has one).
    func custom(_ spec: SceneSpec, dark: Bool) {
        let ink = dark ? "#FFFFFF" : "#2B2B30"
        if let t = spec.twinkle {
            let glyphs = (t.glyphs ?? ["·", "+"]).filter { !$0.isEmpty }
            let count = min(t.count ?? Int(min(120, W * H / 10000)), 400)
            for i in 0..<count {
                let g = glyphs.isEmpty ? "·" : glyphs[i % glyphs.count]
                let l = add(Art.glyph(g, t.color ?? ink, size: CGFloat(t.size ?? 10)), x: rnd(i + 5000, 1) * W, y: rnd(i + 5000, 2) * H * 0.92, opacity: 0.4)
                pulse(l, 0.08, 0.8, period: 2.5 + rnd(i + 5000, 3) * 5, phase: rnd(i + 5000, 4) * 8)
            }
        }
        for (si, sp) in (spec.sprites ?? []).enumerated() where !sp.rows.isEmpty {
            var colors: [Character: String] = [:]
            for (k, v) in sp.colors { if let c = k.first { colors[c] = v } }
            for c in 0..<min(sp.count ?? 1, 50) {
                let i = 6000 + si * 100 + c
                let art = Art.sprite(sp.rows, colors, ink: sp.ink, seed: i, flip: sp.flip ?? false)
                let moves = (sp.drift ?? 0) != 0
                let fx = CGFloat(sp.x ?? rnd(i, 1)), y = CGFloat(sp.y ?? rnd(i, 2)) * H
                let x = moves ? fx * W : px(fx)
                let l = add(art, x: x, y: y, opacity: Float(sp.opacity ?? 1))
                if let d = sp.drift, d != 0 { drift(l, speed: CGFloat(abs(d)), phase: rnd(i, 7), leftward: d < 0) }
                if let r = sp.rise, r != 0 { rise(l, speed: CGFloat(abs(r)), phase: rnd(i, 8), up: r > 0) }
                if let b = sp.bob, b > 0 { swing(l, "transform.translation.y", CGFloat(b), period: 7 + rnd(i, 9) * 6, phase: rnd(i, 10) * 10) }
            }
        }
        for (pi, p) in (spec.particles ?? []).enumerated() {
            let glyphs = p.glyphs.filter { !$0.isEmpty }.isEmpty ? ["·"] : p.glyphs.filter { !$0.isEmpty }
            let colors = p.colors ?? [p.color ?? ink]
            let size = CGFloat(p.size ?? 11)
            let lo = CGFloat(p.speed?.first ?? 14), hi = CGFloat(p.speed?.last ?? 40)
            let seed = 7000 + pi * 1000
            let speed: (Int) -> CGFloat = { lo + CGFloat(rnd($0 + seed, 1)) * max(0, hi - lo) }
            let dir = p.direction ?? "down"
            let horizontal = dir == "left" || dir == "right"
            let span = horizontal ? W + 30 : H + 30
            particles(min(p.count ?? 40, 400), art: { Art.glyph(glyphs[$0 % glyphs.count], colors[$0 % colors.count], size: size) },
                      from: { i in
                          let r = CGFloat(rnd(i + seed, 2))
                          switch dir {
                          case "up": return CGPoint(x: r * W, y: H + 15)
                          case "left": return CGPoint(x: W + 15, y: r * H)
                          case "right": return CGPoint(x: -15, y: r * H)
                          default: return CGPoint(x: r * W, y: -15)
                          }
                      },
                      to: { i in
                          let r = CGFloat(rnd(i + seed, 2))
                          switch dir {
                          case "up": return CGPoint(x: r * W, y: -15)
                          case "left": return CGPoint(x: -15, y: r * H)
                          case "right": return CGPoint(x: W + 15, y: r * H)
                          default: return CGPoint(x: r * W, y: H + 15)
                          }
                      },
                      duration: { Double(span / max(speed($0), 1)) }, opacity: { _ in Float(p.opacity ?? 0.7) },
                      fade: p.fade ?? false, sway: CGFloat(p.sway ?? 0), spin: p.spin ?? false, seed: seed)
        }
    }

    func snow() {
        let cols = Int(W / 12) + 1
        let heights = (0..<cols).map { c in groundCap(CGFloat(c) * 12, 1 + Int((sin(Double(c) * 0.11) + 1) * 1.4 + (sin(Double(c) * 0.037 + 2) + 1))) }
        let top = heights.max() ?? 1
        let rows = (0..<top).map { r in String((0..<cols).map { heights[$0] >= top - r ? "#" : " " }) }
        add(Art.sprite(rows, ["#": a("drift", "#FFFFFF")], ink: a("driftInk", "#C3D3E3"), seed: 80), x: 0, y: H - CGFloat(top) * 12, opacity: dark ? 0.55 : 0.95)
        let speeds: [CGFloat] = [14, 24, 40]
        particles(90, art: { Art.glyph($0 % 3 == 2 ? "*" : "·", a("flake", "#FFFFFF"), size: [9, 12, 14][$0 % 3]) },
                  from: { CGPoint(x: rnd($0, 2) * W, y: -15) },
                  to: { CGPoint(x: rnd($0, 2) * W + (H + 30) / speeds[$0 % 3] * 4, y: H + 15) },
                  duration: { Double((H + 30) / speeds[$0 % 3]) }, opacity: { 0.65 + 0.1 * Float($0 % 3) }, sway: 20, spin: false)
    }
}

// MARK: Picking

extension AppModel {
    /// The scene a workspace shows: its own pick, else the global one. nil = none.
    func sceneId(workspace: String?) -> String? { Scenes.resolve(workspace: workspace, settings: state.settings) }

    /// The workspace's own pick: nil when it follows the global scene.
    func workspaceSceneOverride(_ ws: String) -> String? { settingValue("appearance.scene", scope: "workspace:\(ws)")?.string }

    /// `id` nil clears the pick (workspace: follow global; global: none).
    func setScene(_ id: String?, scope: String) { setSetting("appearance.scene", id, scope: scope) }
}

/// A scene choice in a picker: a scene, no scene, or (in a workspace) "follow the global choice".
enum SceneChoice: Hashable {
    case none, global, scene(String)
    var settingValue: String? {
        switch self { case .none: return "none"; case .global: return nil; case .scene(let id): return id }
    }
}

struct SceneSection: Identifiable {
    let title: String?
    let items: [SceneChoice]
    var id: String { title ?? "-" }
}

/// One tile: a still of the scene, its name, a check when it is the current choice.
struct SceneTile: View {
    let choice: SceneChoice
    let title: String
    let scene: AmbientScene?
    let selected: Bool
    let highlighted: Bool
    var width: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if let scene { SceneBackdrop(scene: scene, still: true) }
                else {
                    LinearGradient(colors: [T.surface, T.frame], startPoint: .top, endPoint: .bottom)
                    Image(systemName: choice == .global ? "globe" : "circle.slash").font(.system(size: 15)).foregroundStyle(T.text3)
                }
            }
            .frame(width: width, height: width * 0.56)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(highlighted || selected ? T.accent : T.border, lineWidth: highlighted || selected ? 2 : 1))
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                if selected { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.accent) }
            }
            .foregroundStyle(selected ? T.text : T.text2)
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// The strip of scene tiles (quick picker and Settings). Hovering previews a scene on the whole window;
/// clicking picks it for `scope`; leaving the strip shows the current choice again.
struct SceneStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = ThemeStore.shared
    let scope: String
    var tileWidth: CGFloat = 96
    var wrapRows = false
    /// Hovering tries a scene on the whole window. Off in Settings: the preview restyles the Settings
    /// window itself, which rebuilds the tile under the pointer and makes hover flicker on and off.
    var previewOnHover = true
    @Binding var highlighted: SceneChoice?

    /// Picker sections: the scenes, the user's own, and the first versions (kept to compare).
    var sections: [SceneSection] {
        let all = Scenes.all
        let wsId = scope.hasPrefix("workspace:") ? String(scope.dropFirst("workspace:".count)) : model.selectedWorkspaceId
        let ws = model.state.workspaces.first { $0.id == wsId }
        let builtIn = all.filter { $0.kind != .custom }
        return [
            SceneSection(title: nil, items: (scope.hasPrefix("workspace:") ? [.global] : []) + [.none]),
            SceneSection(title: ws.map { "Goes with \($0.name)'s color" }, items: Scenes.matching(ws?.color).map { .scene($0.id) }),
            SceneSection(title: "Dark", items: builtIn.filter(\.dark).map { .scene($0.id) }),
            SceneSection(title: "Light", items: builtIn.filter { !$0.dark }.map { .scene($0.id) }),
            SceneSection(title: "Your scenes", items: all.filter { $0.kind == .custom }.map { .scene($0.id) }),
        ].filter { !$0.items.isEmpty }
    }

    /// Every choice once, in picker order (arrow keys).
    var choices: [SceneChoice] {
        var seen = Set<SceneChoice>()
        return sections.flatMap(\.items).filter { seen.insert($0).inserted }
    }

    func current() -> SceneChoice {
        let v = model.settingValue("appearance.scene", scope: scope)?.string
        if scope.hasPrefix("workspace:") && v == nil { return .global }
        if v == nil || v == "none" { return .none }
        return .scene(v!)
    }

    func scene(for c: SceneChoice) -> AmbientScene? {
        switch c {
        case .none: return nil
        case .global: return Scenes.scene(model.settingValue("appearance.scene", scope: "global")?.string)
        case .scene(let id): return Scenes.scene(id)
        }
    }

    func title(for c: SceneChoice) -> String {
        switch c {
        case .none: return "None"
        case .global: return "Global" + (scene(for: .global).map { " · \($0.name)" } ?? "")
        case .scene(let id): return Scenes.scene(id)?.name ?? id
        }
    }

    private func tiles(_ list: [SceneChoice], _ cur: SceneChoice) -> some View {
        ForEach(list, id: \.self) { c in
            SceneTile(choice: c, title: title(for: c), scene: scene(for: c), selected: c == cur, highlighted: c == highlighted, width: tileWidth)
                .contextMenu { if case .scene(let id) = c, let s = Scenes.scene(id) { SceneMenu(scene: s) } }
                .onHover { inside in
                    guard inside else { return }
                    highlighted = c
                    if previewOnHover { store.preview(scene(for: c)) }
                }
                .onTapGesture { pick(c) }
                .pointerCursor()
        }
    }

    func pick(_ c: SceneChoice) {
        model.setScene(c.settingValue, scope: scope)
        // Keep showing it until the setting comes back from the daemon (no flash of the old scene).
        if previewOnHover { store.preview(scene(for: c)) }
    }

    var body: some View {
        let cur = current()
        Group {
            if wrapRows {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { sec in
                        if let t = sec.title { Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3).padding(.top, 4) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth), spacing: 12)], alignment: .leading, spacing: 12) {
                            tiles(sec.items, cur)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) { tiles(choices, cur) }
            }
        }
        .onHover { inside in
            if !inside { highlighted = nil; if previewOnHover { store.endPreview() } }
        }
    }
}

/// The quick picker: a grid over the window (View › Change Scene…, or the command palette).
/// ←/→ preview, Return picks, Esc closes.
final class ScenePickerPanel {
    static let shared = ScenePickerPanel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observer: Any?
    let state = PickerState()

    final class PickerState: ObservableObject {
        @Published var allWorkspaces = false
        @Published var highlighted: SceneChoice?
        /// The grid scrolls inside this height (the list is taller than small windows).
        @Published var gridHeight: CGFloat = 520
    }

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : show() }

    func show() {
        guard panel == nil, let win = (NSApp.delegate as? AppDelegate)?.mainWindow else { return }
        let ws = AppModel.shared.selectedWorkspaceId
        state.allWorkspaces = ws == nil
        state.highlighted = nil
        state.gridHeight = max(220, min(620, win.frame.height - 210))
        let host = NSHostingView(rootView: ScenePickerView(state: state).environmentObject(AppModel.shared))
        host.sizingOptions = [.intrinsicContentSize]
        let p = DropdownAnchor<EmptyView>.Panel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = host
        panel = p
        place()
        win.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if e.window !== self?.panel { self?.close() }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 53: self.close(); return nil                    // Esc
            case 36, 76: self.pickHighlighted(); return nil      // Return
            case 123: self.move(-1); return nil                  // ←
            case 124: self.move(1); return nil                   // →
            default: return e
            }
        } as Any)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: win, queue: .main) { [weak self] _ in self?.place() }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        ThemeStore.shared.endPreview()
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p); p.orderOut(nil)
        panel = nil
    }

    func place() {
        guard let p = panel, let win = p.parent ?? (NSApp.delegate as? AppDelegate)?.mainWindow, let host = p.contentView else { return }
        let size = host.fittingSize
        // Centered over the window, like the command palette.
        let frame = NSRect(x: max(win.frame.minX + 8, win.frame.midX - size.width / 2),
                           y: max(win.frame.minY + 8, win.frame.midY - size.height / 2 + 40), width: size.width, height: size.height)
        p.setFrame(frame, display: true)
    }

    private var strip: SceneStrip {
        let m = AppModel.shared
        let scope = state.allWorkspaces || m.selectedWorkspaceId == nil ? "global" : "workspace:\(m.selectedWorkspaceId!)"
        return SceneStrip(scope: scope, highlighted: .constant(nil))
    }

    private func move(_ d: Int) {
        let s = strip, list = s.choices
        let from = state.highlighted ?? s.current()
        let i = ((list.firstIndex(of: from) ?? 0) + d + list.count) % list.count
        state.highlighted = list[i]
        ThemeStore.shared.preview(s.scene(for: list[i]))
    }

    private func pickHighlighted() {
        if let h = state.highlighted { strip.pick(h) }
        close()
    }
}

struct ScenePickerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: ScenePickerPanel.PickerState
    @ObservedObject var store = ThemeStore.shared

    var body: some View {
        let ws = model.workspace
        let scope = state.allWorkspaces || ws == nil ? "global" : "workspace:\(ws!.id)"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Scenes").font(.system(size: 13, weight: .semibold))
                if let ws {
                    Picker("", selection: $state.allWorkspaces) {
                        Text(ws.name).tag(false)
                        Text("All workspaces").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                }
                Spacer(minLength: 12)
                Button { ScenePickerPanel.shared.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 22)).help("Close (Esc)")
            }
            ScrollView {
                SceneStrip(scope: scope, tileWidth: 104, wrapRows: true, highlighted: $state.highlighted)
                    .frame(width: 104 * 5 + 12 * 4, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .frame(width: 104 * 5 + 12 * 4 + 14, height: state.gridHeight)
            Text("Point at a scene to try it on the whole window. Click to keep it; Esc puts the old one back.")
                .font(.system(size: 11)).foregroundStyle(T.text3)
            if scope == "global", let ws, model.workspaceSceneOverride(ws.id) != nil {
                Text("\(ws.name) has its own scene, so this changes the other workspaces.")
                    .font(.system(size: 11)).foregroundStyle(T.text3)
            }
        }
        .padding(16)
        .background(T.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.border))
        .foregroundStyle(T.text)
        // No `.id(store.revision)`: previews restyle the window behind; rebuilding this panel under the
        // pointer would end the hover and the preview with it.
        .onChange(of: state.allWorkspaces) { DispatchQueue.main.async { ScenePickerPanel.shared.place() } }
    }
}

/// Settings › Appearance: the scene for the selected scope (global or a workspace).
struct SceneSettingsCard: View {
    @EnvironmentObject var model: AppModel
    let scope: String
    @State private var highlighted: SceneChoice?

    var body: some View {
        SettingsCard {
            Text("Scene").font(.headline)
            Text(scope == "global"
                 ? "A palette and a live backdrop drawn in characters, behind the sidebar, bars and empty panes. Workspaces can pick their own."
                 : "This workspace's scene. “Global” follows the choice in the global settings.")
                .font(.caption).foregroundStyle(T.text2)
            SceneStrip(scope: scope, tileWidth: 110, wrapRows: true, previewOnHover: false, highlighted: $highlighted)
            TerminalSceneControls(scope: scope)
            if scope == "global" {
                Toggle("React to agents: faster while they work, a glow while one waits for you (amber) or fails (red)", isOn: Binding(
                    get: { model.scenesReactToAgents },
                    set: { model.setSetting("appearance.scene_reactive", $0 ? nil : false) }))
                UserScenesRow()
            }
            Text("Animates at \(Int(AmbientClock.activeFPS)) fps while Octomux is in front, \(Int(AmbientClock.backgroundFPS)) fps when it is visible behind another app, and stops when the window is hidden, in Low Power Mode, or with Reduce Motion.")
                .font(.caption).foregroundStyle(T.text3)
        }
    }
}
