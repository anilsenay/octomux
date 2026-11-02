import AppKit
import SwiftUI

// Ambient scenes: a palette for the whole app (chrome and terminals) plus a live backdrop drawn in
// characters behind the chrome, the sidebar and empty panes. Picked per workspace
// (`appearance.scene` at `workspace:<id>`), falling back to the global choice; "none" turns it off.

struct AmbientScene: Identifiable, Equatable {
    enum Kind { case nightSky, reef, fireflies, embers, rain, sky, sakura, snow, aurora, circuit, kites, custom }
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
                             surface: String, frame: String, raised: String, accent: String, legacy: Bool = false) -> AmbientScene {
        AmbientScene(id: id, name: name, kind: kind, dark: dark, top: col(top), bottom: col(bottom),
                     colors: palette(dark: dark, surface: surface, frame: frame, raised: raised, accent: accent), legacy: legacy)
    }

    /// Built-in scenes, then the user's.
    static var all: [AmbientScene] { builtIn + UserScenes.loaded }

    static let builtIn: [AmbientScene] = [
        make("aurora", "Aurora", .aurora, dark: true, top: "#04121A", bottom: "#0C1A33",
             surface: "#0D1622", frame: "#09111A", raised: "#18263A", accent: "#5BF0A6"),
        make("reef-v2", "Reef", .reef, dark: true, top: "#0E4A52", bottom: "#05181F",
             surface: "#0B242A", frame: "#071C21", raised: "#143840", accent: "#5FD8C9"),
        make("circuit", "Circuit", .circuit, dark: true, top: "#060B0A", bottom: "#0C1A16",
             surface: "#0C1412", frame: "#080F0D", raised: "#16241F", accent: "#4BE3B0"),
        make("embers", "Embers", .embers, dark: true, top: "#0D0807", bottom: "#2E150D",
             surface: "#1A1210", frame: "#140D0B", raised: "#2A1C18", accent: "#FF8F52"),
        make("rain", "Rain", .rain, dark: true, top: "#1A2430", bottom: "#0C1116",
             surface: "#131A21", frame: "#0F151B", raised: "#1F2933", accent: "#7DB4E0"),
        make("kites", "Kites", .kites, dark: false, top: "#9FD6F2", bottom: "#FFE0C4",
             surface: "#FFFAF4", frame: "#F5E6D8", raised: "#FFFFFF", accent: "#D9622B"),
        make("sakura", "Sakura", .sakura, dark: false, top: "#F5C3D2", bottom: "#FFF1F4",
             surface: "#FFF9FA", frame: "#F8E1E7", raised: "#FFFFFF", accent: "#C94F76"),
        make("snow", "Snowfall", .snow, dark: false, top: "#9DB4CC", bottom: "#E3EBF3",
             surface: "#F6F9FC", frame: "#E1E9F1", raised: "#FFFFFF", accent: "#3F6E9E"),
        // First versions, too close to a published concept; kept only to compare, then removed.
        make("night-sky", "Night Sky (old)", .nightSky, dark: true, top: "#060A1C", bottom: "#1A2550",
             surface: "#10152B", frame: "#0B1024", raised: "#1E2546", accent: "#9DB0FF", legacy: true),
        make("reef", "Reef (old)", .reef, dark: true, top: "#0E4A52", bottom: "#05181F",
             surface: "#0B242A", frame: "#071C21", raised: "#143840", accent: "#5FD8C9", legacy: true),
        make("fireflies", "Fireflies (old)", .fireflies, dark: true, top: "#050B07", bottom: "#112418",
             surface: "#0F1912", frame: "#0A130D", raised: "#1A2A1F", accent: "#C6E26A", legacy: true),
        make("sky", "Sky (old)", .sky, dark: false, top: "#7FC0F2", bottom: "#D8EEFD",
             surface: "#F5FAFE", frame: "#D6EAFA", raised: "#FFFFFF", accent: "#2C7BD6", legacy: true),
    ]

    static func scene(_ id: String?) -> AmbientScene? { all.first { $0.id == id } }
}

// MARK: Clock

/// One clock for every live backdrop. Backdrops are Core Animation layer trees frozen at `speed = 0`;
/// each tick moves their `timeOffset` forward, so the frame rate is exactly the tick rate and the app
/// itself does almost nothing per frame (the render server draws). Full rate while ADE is in front,
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

    func update() {
        let f: Double
        switch reason {
        case "active": f = Self.activeFPS
        case "background": f = Self.backgroundFPS
        default: f = 0
        }
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
    func makeNSView(context: Context) -> SceneLayerView { SceneLayerView(scene: scene, still: still) }
    func updateNSView(_ v: SceneLayerView, context: Context) { v.set(scene) }
}

final class SceneLayerView: NSView {
    private(set) var scene: AmbientScene
    let still: Bool
    let root = CALayer()
    private var builtSize: CGSize = .zero
    private var pending: DispatchWorkItem?
    private var faded = false

    init(scene: AmbientScene, still: Bool) {
        self.scene = scene
        self.still = still
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
        guard !still else { return }
        if window != nil { AmbientClock.shared.register(self) } else { AmbientClock.shared.unregister(self) }
    }

    func set(_ s: AmbientScene) {
        guard s.id != scene.id else { return }
        scene = s
        rebuild()
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - builtSize.width) > 1 || abs(bounds.height - builtSize.height) > 1 else { return }
        // Live window resizing: rebuild once it settles (keep the old layers scaled meanwhile).
        if builtSize == .zero { rebuild(); return }
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
        SceneBuilder(root: root, W: v.width, H: v.height, now: root.timeOffset, mood: still ? .calm : AmbientClock.shared.mood).build(scene)
        CATransaction.commit()
        // A new scene eases in over the window's frame color (the view's own layer runs on real time).
        if !still && !faded {
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
    static let moon = [
        "   ##",
        "  ###",
        " ###",
        " ###",
        " ####",
        "  #####   #",
        "   ########",
        "     ####",
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
        let moon = add(Art.sprite(Sprites.moon, ["#": "#E9E1C4"], ink: "#8F855F", seed: 3), x: W * 0.62, y: H * 0.1)
        swing(moon, "transform.translation.y", 3, period: 18, phase: 0)
        for i in 0..<3 {
            let l = add(Art.sprite(Sprites.flatCloud, ["#": "#33417F"], ink: "#5B6BB5", seed: 10 + i), x: 0, y: H * (0.16 + CGFloat(i) * 0.24), opacity: 0.8)
            drift(l, speed: 5 + CGFloat(i) * 3, phase: rnd(i, 7))
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
            pulse(shape(p, fill: .white, opacity: 0.035), 0.015, 0.06, period: 9 + Double(i) * 3, phase: Double(i) * 2)
        }
        for i in 0..<9 {
            let x0 = rnd(i, 20) * W, h = 5 + hash(i, 21) % 8
            for k in 0..<h {
                let l = add(Art.sprite(["#"], ["#": i % 3 == 0 ? "#3E9E6A" : "#2E7D5B"], ink: "#123A2A", seed: hash(i, k)), x: x0, y: H - CGFloat(k + 1) * 12, opacity: 0.9)
                swing(l, "transform.translation.x", 0.5 + CGFloat(k) * 0.9, period: 7, phase: Double(k) * 0.39 + Double(i))
            }
        }
        let colors = ["#FF8A5C", "#FFC857", "#FF6F91", "#7FD6FF", "#FFB36B", "#C9A2FF"]
        for i in 0..<6 {
            let right = i % 2 == 0
            let l = add(Art.sprite(i % 3 == 0 ? Sprites.fish : Sprites.smallFish, ["#": colors[i], "o": "#10232A"], ink: "#4A2A20", seed: 30 + i, flip: !right),
                        x: 0, y: H * (0.12 + 0.13 * CGFloat(i)), opacity: 0.92)
            drift(l, speed: 14 + CGFloat(rnd(i, 8)) * 16, phase: rnd(i, 7), leftward: !right)
            swing(l, "transform.translation.y", 8, period: 7.8, phase: Double(i) * 1.3)
        }
        particles(30, art: { Art.glyph($0 % 3 == 0 ? "o" : $0 % 3 == 1 ? "°" : ".", "#FFFFFF", size: 10) },
                  from: { CGPoint(x: rnd($0, 11) * W, y: H + 15) }, to: { CGPoint(x: rnd($0, 11) * W, y: -15) },
                  duration: { Double(H + 30) / (16 + rnd($0, 9) * 30) }, opacity: { _ in 0.45 }, sway: 6)
    }

    func fireflies() {
        let cols = Int(W / 12) + 1
        for c in 0..<cols {
            let h = 1 + hash(c, 40) % 4
            let l = add(Art.blade(h, "#5FA35A"), x: CGFloat(c) * 12, y: H - 2 - CGFloat(h) * 12, anchorBottom: true)
            swing(l, "transform.rotation.z", 0.16, period: 5.7, phase: Double(c) * 0.16)
        }
        for i in 0..<28 {
            let bx = rnd(i, 1) * W, by = H * (0.08 + rnd(i, 4) * 0.78)
            // Fireflies take the mood's color: amber when an agent waits for you, red on an error.
            let (glowHex, coreHex) = mood == .attention ? ("#F5B841", "#FFE3A0") : mood == .error ? ("#FF6B5B", "#FFC2B8") : ("#D8F27A", "#EEF8A8")
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
            let l = add(Art.sprite(i % 2 == 0 ? Sprites.cloud : Sprites.smallCloud, ["#": "#2A3542"], ink: "#4A5868", seed: 50 + i), x: 0, y: H * 0.02 + CGFloat(i % 2) * 30, opacity: 0.9)
            drift(l, speed: 3 + CGFloat(i), phase: rnd(i, 7))
        }
        particles(Int(min(150, W * H / 7000)), art: { _ in Art.glyph("/", "#8FA8C2", size: 11) },
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
        for i in 0..<6 {
            let l = add(Art.sprite(i % 2 == 0 ? Sprites.cloud : Sprites.smallCloud, ["#": "#FFFFFF"], ink: "#A9CFF0", seed: 60 + i), x: 0, y: H * (0.05 + 0.15 * CGFloat(i)), opacity: 0.95)
            drift(l, speed: 5 + CGFloat(rnd(i, 1)) * 8, phase: rnd(i, 7))
            swing(l, "transform.translation.y", 4, period: 31, phase: Double(i) * 5)
        }
        let up = Art.bitmap("flock-v", CGSize(width: 44, height: 24)) { ctx in
            for k in 0..<3 { Art.text("v", in: CGRect(x: CGFloat(k) * 15, y: CGFloat(k % 2) * 9, width: 14, height: 14), cg("#4F6C88", 0.75), size: 12, ctx) }
        }
        let down = Art.bitmap("flock--", CGSize(width: 44, height: 24)) { ctx in
            for k in 0..<3 { Art.text("-", in: CGRect(x: CGFloat(k) * 15, y: CGFloat(k % 2) * 9, width: 14, height: 14), cg("#4F6C88", 0.75), size: 12, ctx) }
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
        let colors: [Character: String] = ["#": "#7A4E3A", "o": "#F49AB4"]
        // Branches reach in from the right edge and the lower left, clear of the sidebar's header.
        let a = Art.sprite(Sprites.branch, colors, ink: "#B85A78", seed: 70, flip: true)
        swing(add(a, x: W - a.1.width + 12, y: 54), "transform.translation.y", 1.5, period: 15, phase: 0)
        swing(add(Art.sprite(Sprites.branch, colors, ink: "#B85A78", seed: 71), x: -12, y: H * 0.7, opacity: 0.85), "transform.translation.y", 1.5, period: 17, phase: 3)
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
        let (sig, core) = mood == .attention ? ("#F5B841", "#FFE3A0") : mood == .error ? ("#FF6B5B", "#FFC2B8") : ("#4BE3B0", "#C8FFE9")
        for i in 0..<Int(min(18, W * H / 50000) + 4) {
            var x = Int(rnd(i, 1) * Double(gx)), y = Int(rnd(i, 2) * Double(gy))
            func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) * step + 6, y: CGFloat(y) * step + 6) }
            var pts = [pt(x, y)]
            var horizontal = i % 2 == 0
            for seg in 0..<(3 + hash(i, 3) % 4) {
                let len = 2 + hash(i * 7 + seg, 4) % 7
                let sign = hash(i * 7 + seg, 5) % 2 == 0 ? 1 : -1
                if horizontal { x = max(0, min(gx, x + sign * len)) } else { y = max(0, min(gy, y + sign * len)) }
                pts.append(pt(x, y))
                horizontal.toggle()
            }
            _ = line(pts, stroke: cg("#1E4A3C", 0.9), width: 2)
            for (j, p) in [pts.first!, pts.last!].enumerated() {
                let pad = add(Art.sprite(["#"], ["#": "#1E4A3C"], ink: "#4BE3B0", seed: i * 2 + j), x: p.x - 6, y: p.y - 6)
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
            let a = Art.glyph(i % 2 == 0 ? "0" : "1", "#2E7A60", size: 10)
            let l = add(a, x: CGFloat(Int(rnd(i, 20) * Double(gx))) * step, y: CGFloat(Int(rnd(i, 21) * Double(gy))) * step, opacity: 0.3)
            pulse(l, 0, 0.6, period: 2 + rnd(i, 22) * 4, phase: rnd(i, 23) * 6)
        }
    }

    func kites() {
        let sun = CAGradientLayer()
        sun.type = .radial
        sun.frame = CGRect(x: W * 0.8 - 320, y: H - H * 0.12 - 320, width: 640, height: 640)
        sun.colors = [cg("#FFF4E0", 0.75), cg("#FFF4E0", 0)]
        sun.startPoint = CGPoint(x: 0.5, y: 0.5); sun.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(sun)
        for i in 0..<3 {
            let l = add(Art.sprite(Sprites.smallCloud, ["#": "#FFFFFF"], ink: "#E8D2C0", seed: 90 + i), x: 0, y: H * (0.08 + 0.2 * CGFloat(i)), opacity: 0.75)
            drift(l, speed: 4 + CGFloat(i) * 2, phase: rnd(i, 7))
        }
        let balloonColors = [("#E86A5A", "#FFD27A"), ("#6AA8E8", "#FFFFFF")]
        for (i, c) in balloonColors.enumerated() {
            let a = Art.sprite(Sprites.balloon, ["#": c.0, "o": c.1, "|": "#7A5A40", "[": "#8A5A3A", "]": "#8A5A3A"], ink: "#5A2A20", seed: 100 + i)
            let l = add(a, x: W * (0.55 + 0.3 * CGFloat(i)), y: H * 0.5, opacity: 0.95)
            rise(l, speed: 5 + CGFloat(i) * 2, phase: rnd(i, 30), up: true)
            swing(l, "transform.translation.x", 14, period: 17, phase: Double(i) * 4)
        }
        let kiteColors = [("#E0703A", "#FFC15A"), ("#4E8FD9", "#9FD0FF"), ("#C94F76", "#F4A3BE")]
        for (k, c) in kiteColors.enumerated() {
            let kite = Art.sprite(Sprites.kite, ["a": c.0, "b": c.1], ink: "#3A2A20", seed: 110 + k)
            let tail: CGFloat = 96
            // A container moves the kite, its tail and its string together (its own coordinates are y-up).
            let box = CALayer()
            box.frame = CGRect(x: W * (0.12 + 0.3 * CGFloat(k)), y: H - H * (0.14 + 0.1 * CGFloat(k % 2)) - kite.1.height - tail,
                               width: kite.1.width, height: kite.1.height + tail)
            root.addSublayer(box)
            let string = CAShapeLayer()
            let sp = CGMutablePath()
            sp.move(to: CGPoint(x: kite.1.width / 2, y: tail + 6))
            sp.addQuadCurve(to: CGPoint(x: kite.1.width / 2 - 140, y: -H), control: CGPoint(x: kite.1.width / 2 + 30, y: -H * 0.4))
            string.path = sp
            string.fillColor = nil
            string.strokeColor = cg("#6A5A4A", 0.3)
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
                let x = CGFloat(sp.x ?? rnd(i, 1)) * W, y = CGFloat(sp.y ?? rnd(i, 2)) * H
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
        let heights = (0..<cols).map { c in 1 + Int((sin(Double(c) * 0.11) + 1) * 1.4 + (sin(Double(c) * 0.037 + 2) + 1)) }
        let top = heights.max() ?? 1
        let rows = (0..<top).map { r in String((0..<cols).map { heights[$0] >= top - r ? "#" : " " }) }
        add(Art.sprite(rows, ["#": "#FFFFFF"], ink: "#C3D3E3", seed: 80), x: 0, y: H - CGFloat(top) * 12, opacity: 0.95)
        let speeds: [CGFloat] = [14, 24, 40]
        particles(90, art: { Art.glyph($0 % 3 == 2 ? "*" : "·", "#FFFFFF", size: [9, 12, 14][$0 % 3]) },
                  from: { CGPoint(x: rnd($0, 2) * W, y: -15) },
                  to: { CGPoint(x: rnd($0, 2) * W + (H + 30) / speeds[$0 % 3] * 4, y: H + 15) },
                  duration: { Double((H + 30) / speeds[$0 % 3]) }, opacity: { 0.65 + 0.1 * Float($0 % 3) }, sway: 20, spin: false)
    }
}

// MARK: Picking

extension AppModel {
    /// The scene a workspace shows: its own pick, else the global one. nil = none.
    func sceneId(workspace: String?) -> String? {
        if let ws = workspace, let v = settingValue("appearance.scene", scope: "workspace:\(ws)")?.string { return v == "none" ? nil : v }
        let g = settingValue("appearance.scene", scope: "global")?.string
        return g == "none" ? nil : g
    }

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
    var id: String { title ?? "" }
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
    @Binding var highlighted: SceneChoice?

    /// Picker sections: the scenes, the user's own, and the first versions (kept to compare).
    var sections: [SceneSection] {
        let all = Scenes.all
        return [
            SceneSection(title: nil, items: (scope.hasPrefix("workspace:") ? [.global] : []) + [.none] + all.filter { $0.kind != .custom && !$0.legacy }.map { .scene($0.id) }),
            SceneSection(title: "Your scenes", items: all.filter { $0.kind == .custom }.map { .scene($0.id) }),
            SceneSection(title: "Earlier versions · for comparison", items: all.filter(\.legacy).map { .scene($0.id) }),
        ].filter { !$0.items.isEmpty }
    }

    var choices: [SceneChoice] { sections.flatMap(\.items) }

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
                .onHover { inside in
                    if inside { highlighted = c; store.preview(scene(for: c)) }
                }
                .onTapGesture { pick(c) }
                .pointerCursor()
        }
    }

    func pick(_ c: SceneChoice) {
        model.setScene(c.settingValue, scope: scope)
        store.preview(scene(for: c))
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
            if !inside { highlighted = nil; store.endPreview() }
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
    }

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : show() }

    func show() {
        guard panel == nil, let win = (NSApp.delegate as? AppDelegate)?.mainWindow else { return }
        let ws = AppModel.shared.selectedWorkspaceId
        state.allWorkspaces = ws == nil
        state.highlighted = nil
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
            SceneStrip(scope: scope, tileWidth: 104, wrapRows: true, highlighted: $state.highlighted)
                .frame(width: 104 * 5 + 12 * 4, alignment: .leading)
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
        .id(store.revision)
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
            SceneStrip(scope: scope, tileWidth: 110, wrapRows: true, highlighted: $highlighted)
            if scope == "global" {
                Toggle("Show the scene behind terminals (translucent terminals)", isOn: Binding(
                    get: { model.settingValue("appearance.scene_terminals", scope: "global")?.bool ?? false },
                    set: { model.setSetting("appearance.scene_terminals", $0 ? true : nil) }))
                Toggle("React to agents: faster while they work, a glow while one waits for you (amber) or fails (red)", isOn: Binding(
                    get: { model.scenesReactToAgents },
                    set: { model.setSetting("appearance.scene_reactive", $0 ? nil : false) }))
                UserScenesRow()
            }
            Text("Animates at \(Int(AmbientClock.activeFPS)) fps while ADE is in front, \(Int(AmbientClock.backgroundFPS)) fps when it is visible behind another app, and stops when the window is hidden, in Low Power Mode, or with Reduce Motion.")
                .font(.caption).foregroundStyle(T.text3)
        }
    }
}
