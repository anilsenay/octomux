import AppKit
import SwiftUI

// Design tokens. See docs/DESIGN.md. Every color is dynamic (dark/light) and
// resolved against the current preset at draw time; the root view is
// re-identified when the preset changes so everything re-renders.

struct ThemeColors {
    var frame, surface, raised, hover, selection, border: NSColor
    var text, text2, text3: NSColor
    var accent, claude, amber, green, red, blue: NSColor
    // Terminal
    var termFg, termCursor, termSelection: NSColor
    var ansi: [String]
}

enum TabStyle: String { case pill, underline, segment }

struct ThemeMetrics {
    var rowH: CGFloat = 30
    var rowR: CGFloat = 7
    var tileR: CGFloat = 5
    var tabStyle: TabStyle = .pill
    var tabH: CGFloat = 28
    var topH: CGFloat = 46
    var statusH: CGFloat = 30
    var cardR: CGFloat = 10
    var inset: CGFloat = 8
    var monoLabels = false
    var sidebarMaterial = false
    /// Whole window translucent (behind-window blur); terminals use background-opacity.
    var glass = false
}

struct ThemePreset: Identifiable {
    let id: String
    let name: String
    let summary: String
    let dark: ThemeColors
    let light: ThemeColors
    let metrics: ThemeMetrics
}

private func c(_ hex: String, _ a: CGFloat = 1) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
private func w(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
private func b(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }

private let ansiDark = ["#2A2A30", "#F27474", "#5DCB8E", "#E9B949", "#74A9F8", "#C792EA", "#5CC8D0", "#C8C8CE",
                        "#5A5A64", "#FF8E8E", "#7EE0A8", "#F5CE6A", "#96BFFF", "#DDB0F5", "#7ADCE3", "#F2F2F4"]
private let ansiLight = ["#2B2B30", "#C93838", "#1E8A4C", "#9A6200", "#2A6BD1", "#8E44AD", "#13808A", "#C9C9CE",
                         "#6B6B73", "#E04848", "#26A35B", "#B87800", "#3F82E8", "#A35BC4", "#1597A2", "#E8E8EB"]

enum Themes {
    static let ink = ThemePreset(
        id: "ink", name: "Ink", summary: "Unified ink chrome, inset terminal cards, warm accent",
        dark: ThemeColors(frame: c("#141416"), surface: c("#1B1B1F"), raised: c("#27272C"), hover: w(0.05), selection: c("#EB8A5E", 0.14), border: w(0.07),
                          text: c("#EDEDEF"), text2: c("#A6A6AF"), text3: c("#8B8B94"),
                          accent: c("#EB8A5E"), claude: c("#E8875B"), amber: c("#E9B949"), green: c("#5DCB8E"), red: c("#F27474"), blue: c("#74A9F8"),
                          termFg: c("#DCDCE0"), termCursor: c("#EB8A5E"), termSelection: c("#3A3A42"), ansi: ansiDark),
        light: ThemeColors(frame: c("#ECEBE8"), surface: c("#FBFBFA"), raised: c("#FFFFFF"), hover: b(0.045), selection: c("#C9592B", 0.11), border: b(0.08),
                           text: c("#1D1D1F"), text2: c("#55555C"), text3: c("#6B6B73"),
                           accent: c("#C9592B"), claude: c("#C9592B"), amber: c("#9A6200"), green: c("#1E8A4C"), red: c("#C93838"), blue: c("#2A6BD1"),
                           termFg: c("#2B2B30"), termCursor: c("#C9592B"), termSelection: c("#E6E1DC"), ansi: ansiLight),
        metrics: ThemeMetrics())

    static let grid = ThemePreset(
        id: "grid", name: "Grid", summary: "Dense and technical: edge-to-edge panes, hairlines, mono labels",
        dark: ThemeColors(frame: c("#0D0F12"), surface: c("#0A0C0E"), raised: c("#161A1F"), hover: w(0.05), selection: c("#7EA6FF", 0.13), border: w(0.09),
                          text: c("#E3E7EC"), text2: c("#9AA3AE"), text3: c("#7D8793"),
                          accent: c("#7EA6FF"), claude: c("#E8875B"), amber: c("#F0C04A"), green: c("#6BD49A"), red: c("#FF7A7A"), blue: c("#7EA6FF"),
                          termFg: c("#D6DCE3"), termCursor: c("#7EA6FF"), termSelection: c("#26303D"), ansi: ansiDark),
        light: ThemeColors(frame: c("#F6F7F9"), surface: c("#FFFFFF"), raised: c("#EEF0F3"), hover: b(0.05), selection: c("#2D5BDB", 0.10), border: b(0.10),
                           text: c("#111418"), text2: c("#4F5865"), text3: c("#636D79"),
                           accent: c("#2D5BDB"), claude: c("#C9592B"), amber: c("#986300"), green: c("#1B8649"), red: c("#C83030"), blue: c("#2D5BDB"),
                           termFg: c("#1A1E24"), termCursor: c("#2D5BDB"), termSelection: c("#DCE4F5"), ansi: ansiLight),
        metrics: ThemeMetrics(rowH: 24, rowR: 2, tileR: 2, tabStyle: .underline, tabH: 36, topH: 36, statusH: 24, cardR: 0, inset: 0, monoLabels: true))

    static let glass = ThemePreset(
        id: "glass", name: "Glass", summary: "Closest to stock macOS: translucent sidebar, segmented tabs",
        dark: ThemeColors(frame: c("#1E1F24"), surface: c("#16171B"), raised: c("#3A3B42"), hover: w(0.06), selection: c("#3B8CFF", 0.22), border: w(0.08),
                          text: c("#F2F2F5"), text2: c("#ABACB5"), text3: c("#8C8D96"),
                          accent: c("#3B8CFF"), claude: c("#E8875B"), amber: c("#F5B841"), green: c("#44CF7C"), red: c("#FF6B6B"), blue: c("#3B8CFF"),
                          termFg: c("#E2E3E8"), termCursor: c("#3B8CFF"), termSelection: c("#2E3A50"), ansi: ansiDark),
        light: ThemeColors(frame: c("#E6E8ED"), surface: c("#FFFFFF"), raised: c("#FFFFFF"), hover: b(0.05), selection: c("#0A6CF0", 0.13), border: b(0.09),
                           text: c("#15161A"), text2: c("#50525D"), text3: c("#666874"),
                           accent: c("#0A6CF0"), claude: c("#C9592B"), amber: c("#966100"), green: c("#178A47"), red: c("#CC3333"), blue: c("#0A6CF0"),
                           termFg: c("#1F2024"), termCursor: c("#0A6CF0"), termSelection: c("#D5E4FB"), ansi: ansiLight),
        metrics: ThemeMetrics(rowH: 30, rowR: 8, tileR: 9, tabStyle: .segment, tabH: 26, topH: 48, statusH: 32, cardR: 12, inset: 8, sidebarMaterial: true, glass: true))

    static let all = [ink, grid, glass]
    static func preset(_ id: String?) -> ThemePreset { all.first { $0.id == id } ?? ink }
}

/// Current preset + appearance mode, synced from global settings
/// (`appearance.theme`, `appearance.mode`, `appearance.terminal_colors`).
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published private(set) var preset: ThemePreset = Themes.ink
    /// Dark until the user picks Light or System in Settings.
    @Published private(set) var mode = "dark"
    /// The current workspace's scene (see Scenes.swift), and a scene shown while hovering a picker.
    @Published private(set) var scene: AmbientScene?
    @Published private(set) var previewing = false
    private(set) var previewScene: AmbientScene?
    var activeScene: AmbientScene? { previewing ? previewScene : scene }
    private(set) var terminalColors = true
    /// `appearance.scene_terminals`: terminals are translucent so the scene shows behind them.
    /// What terminal panes show of the scene (`appearance.scene_terminals`, per workspace) and how opaque the
    /// terminal background stays (`appearance.scene_terminal_opacity`).
    private(set) var sceneTerminals: TerminalSceneMode = .off
    private(set) var sceneTerminalOpacity = TerminalSceneMode.defaultOpacity
    /// The terminal-pane mode in effect: `.off` without a scene.
    var terminalSceneMode: TerminalSceneMode { activeScene == nil || metrics.glass ? .off : sceneTerminals }
    var transparentPanes: Bool { metrics.glass || terminalSceneMode != .off }
    /// Ghostty's `background-opacity` when terminals are translucent (nil: opaque). Pane headers use it too.
    var terminalBackgroundOpacity: Double? {
        metrics.glass ? (isDark ? 0.55 : 0.6) : transparentPanes ? sceneTerminalOpacity : nil
    }
    private var appearanceObs: NSKeyValueObservation?
    private var lastWritten = ""

    /// Bumped when user scene files are reloaded (same ids, new content).
    @Published private(set) var sceneGeneration = 0
    var revision: String { "\(preset.id)-\(scale)-\(mode)-\(activeScene?.id ?? "")-\(sceneGeneration)-\(workspaceColor ?? "")" }

    func scenesReloaded() {
        if let s = scene { scene = Scenes.scene(s.id) }
        if previewing, let p = previewScene { previewScene = Scenes.scene(p.id) }
        sceneGeneration += 1
        sceneDidChange()
    }

    /// Colors for an appearance: the active scene's (a scene has one appearance) or the preset's.
    func colors(dark: Bool) -> ThemeColors {
        if let s = activeScene { return s.colors }
        var c = dark ? preset.dark : preset.light
        // The workspace color is the app's primary color (buttons, toggles, focus, cursor, selection).
        if let a = WorkspaceTint.tuned(workspaceColor, dark: dark) {
            c.accent = a
            c.selection = a.withAlphaComponent(dark ? 0.16 : 0.12)
            c.termCursor = a
        }
        return c
    }

    /// The current workspace's color (nil: none or gray → the preset's accent).
    @Published private(set) var workspaceColor: String?

    /// Settings → Appearance → Interface size (this Mac): text and row heights of the window, not the terminal.
    static let scaleKey = "octomux.uiScale"
    @Published private(set) var scale: CGFloat = {
        let v = UserDefaults.standard.double(forKey: ThemeStore.scaleKey)
        return v >= 0.8 && v <= 1.3 ? CGFloat(v) : 1
    }()
    func set(scale v: CGFloat) {
        let c = min(1.3, max(0.8, v))
        UserDefaults.standard.set(Double(c), forKey: Self.scaleKey)
        scale = c
    }

    /// The preset's metrics; a scene draws its own backdrop, so no window glass or sidebar material.
    var metrics: ThemeMetrics {
        var m = preset.metrics
        if activeScene != nil { m.glass = false; m.sidebarMaterial = false }
        if scale != 1 {
            m.rowH = (m.rowH * scale).rounded(); m.tabH = (m.tabH * scale).rounded()
            m.topH = (m.topH * scale).rounded(); m.statusH = (m.statusH * scale).rounded()
        }
        return m
    }

    init() {
        appearanceObs = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.writeTerminalTheme() }
        }
        DispatchQueue.main.async { [weak self] in
            UserScenes.startWatching()
            // Dark from the first frame, before the daemon's settings arrive (no light flash on a fresh install).
            self?.applyAppearance()
            AppIconStyle.apply()
        }
    }

    func sync(from model: AppModel) {
        // Appearance is this Mac's preference: a remote host's settings do not change it.
        if model.host.isRemote && !lastWritten.isEmpty { return }
        let id = model.settingValue("appearance.theme", scope: "global")?.string ?? "ink"
        let m = model.settingValue("appearance.mode", scope: "global")?.string ?? "dark"
        let tc = model.settingValue("appearance.terminal_colors", scope: "global")?.bool ?? true
        let sc = Scenes.scene(model.sceneId(workspace: model.selectedWorkspaceId))
        let sceneChanged = sc?.id != scene?.id
        let ws = model.selectedWorkspaceId
        let st = TerminalSceneMode.resolve(workspace: ws, settings: model.state.settings)
        let so = TerminalSceneMode.resolveOpacity(workspace: ws, settings: model.state.settings)
        let wc = model.workspace?.color
        let changed = id != preset.id || m != mode || tc != terminalColors || sceneChanged || st != sceneTerminals || so != sceneTerminalOpacity || wc != workspaceColor
        guard changed || lastWritten.isEmpty else { return }
        let before = activeScene?.id
        if sceneChanged { scene = sc }
        let restyle = id != preset.id || before != activeScene?.id || st != sceneTerminals || so != sceneTerminalOpacity || wc != workspaceColor
        if wc != workspaceColor { workspaceColor = wc }
        sceneTerminals = st
        sceneTerminalOpacity = so
        if id != preset.id { preset = Themes.preset(id) }
        if m != mode { mode = m }
        terminalColors = tc
        if restyle { restyleViews() }
        applyAppearance()
        writeTerminalTheme()
    }

    /// Shows `scene` (nil = no scene) until `endPreview()`; the setting is not changed.
    func preview(_ s: AmbientScene?) {
        if previewing && previewScene?.id == s?.id { return }
        let before = activeScene?.id
        previewScene = s
        previewing = true
        if before != activeScene?.id { sceneDidChange() }
    }

    func endPreview() {
        guard previewing else { return }
        let before = activeScene?.id
        previewing = false
        previewScene = nil
        if before != activeScene?.id { sceneDidChange() }
    }

    private func sceneDidChange() {
        restyleViews()
        applyAppearance()
        writeTerminalTheme()
    }

    private func restyleViews() {
        DispatchQueue.main.async {
            Self.applyWindowGlass()
            TerminalHost.shared.render(force: true)
            TerminalHost.shared.renderDock(force: true)
            TerminalHost.shared.refreshPaneBackgrounds()
        }
    }

    /// A scene has a fixed appearance; otherwise the mode setting decides.
    private func applyAppearance() {
        let want: NSAppearance? = activeScene.map { NSAppearance(named: $0.dark ? .darkAqua : .aqua)! }
            ?? (mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil)
        if NSApp.appearance?.name != want?.name { NSApp.appearance = want }
    }

    /// Glass needs a non-opaque window so the behind-window blur shows through the terminals.
    static func applyWindowGlass() {
        guard let w = (NSApp.delegate as? AppDelegate)?.mainWindow else { return }
        let glass = shared.metrics.glass
        w.isOpaque = !glass
        w.backgroundColor = glass ? .clear : .windowBackgroundColor
    }

    var isDark: Bool {
        if let s = activeScene { return s.dark }
        switch mode {
        case "dark": return true
        case "light": return false
        default: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Ghostty config fragment with the preset's terminal colors, loaded after the user's terminal.conf.
    func terminalConfigText(dark: Bool) -> String {
        let p = colors(dark: dark)
        func hex(_ n: NSColor) -> String {
            let x = n.usingColorSpace(.sRGB) ?? n
            return String(format: "#%02X%02X%02X", Int(round(x.redComponent * 255)), Int(round(x.greenComponent * 255)), Int(round(x.blueComponent * 255)))
        }
        var lines = [
            "# Generated by Octomux from the \(activeScene?.name ?? preset.name) theme (\(dark ? "dark" : "light")). Edit terminal.conf instead.",
            "background = \(hex(WorkspaceTint.canvas(dark: dark)))",
            "foreground = \(hex(p.termFg))",
            "cursor-color = \(hex(p.termCursor))",
            "selection-background = \(hex(p.termSelection))",
            "selection-foreground = \(hex(p.termFg))",
        ]
        for (i, col) in p.ansi.enumerated() { lines.append("palette = \(i)=\(col)") }
        return lines.joined(separator: "\n") + "\n"
    }

    func writeTerminalTheme() {
        DocHost.shared.refreshTheme()
        ChatWebHost.shared.refreshTheme()
        let text = terminalColors ? terminalConfigText(dark: isDark) : "# Terminal colors come from terminal.conf\n"
        let padding = "window-padding-x = 12\nwindow-padding-y = 8\nwindow-padding-balance = true\nwindow-padding-color = background\n"
        let glass = terminalBackgroundOpacity.map { "background-opacity = \($0)\n" } ?? ""
        let full = padding + glass + text
        guard full != lastWritten else { return }
        lastWritten = full
        try? FileManager.default.createDirectory(at: Paths.themeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? full.write(to: Paths.themeConfig, atomically: true, encoding: .utf8)
        GhosttyRuntime.shared.reloadConfig()
    }

    func set(theme: String? = nil, mode: String? = nil) {
        if let theme { AppModel.shared.setSetting("appearance.theme", theme) }
        if let mode { AppModel.shared.setSetting("appearance.mode", mode) }
    }
}

/// Token accessors. `T.frame`, `T.text2`, `T.m.rowH`…
enum T {
    private static func dyn(_ key: KeyPath<ThemeColors, NSColor>) -> Color {
        Color(nsColor: ns(key))
    }
    static func ns(_ key: KeyPath<ThemeColors, NSColor>) -> NSColor {
        NSColor(name: nil) { a in
            ThemeStore.shared.colors(dark: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)[keyPath: key]
        }
    }

    static var frame: Color { dyn(\.frame) }
    static var surface: Color { dyn(\.surface) }
    static var raised: Color { dyn(\.raised) }
    static var hover: Color { dyn(\.hover) }
    static var selection: Color { dyn(\.selection) }
    static var border: Color { dyn(\.border) }
    static var text: Color { dyn(\.text) }
    static var text2: Color { dyn(\.text2) }
    static var text3: Color { dyn(\.text3) }
    static var accent: Color { dyn(\.accent) }
    static var claude: Color { dyn(\.claude) }
    static var amber: Color { dyn(\.amber) }
    static var green: Color { dyn(\.green) }
    static var red: Color { dyn(\.red) }
    static var blue: Color { dyn(\.blue) }

    /// Settings → Appearance → Diff colors: blue and orange (told apart with red–green color blindness) instead
    /// of green and red, for added and removed lines and counts.
    static var colorblindDiff = false
    static var diffAddNS: NSColor { colorblindDiff ? ns(\.blue) : ns(\.green) }
    static var diffDelNS: NSColor {
        colorblindDiff ? NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.94, green: 0.56, blue: 0.16, alpha: 1)
                                                               : NSColor(srgbRed: 0.80, green: 0.40, blue: 0.04, alpha: 1)
        } : ns(\.red)
    }
    static var diffAdd: Color { Color(nsColor: diffAddNS) }
    static var diffDel: Color { Color(nsColor: diffDelNS) }

    static var m: ThemeMetrics { ThemeStore.shared.metrics }

    // Typography
    static let monoName: String? = ["JetBrainsMono-Regular", "JetBrains Mono"].first { NSFont(name: $0, size: 12) != nil }
    /// The interface size (1 = 100%); every font size in the UI is multiplied by it.
    static var k: CGFloat { ThemeStore.shared.scale }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let n = monoName { return .custom(n, fixedSize: size * k).weight(weight) }
        return .system(size: size * k, weight: weight, design: .monospaced)
    }
    static var title: Font { .system(size: 20 * k, weight: .bold) }
    static var headline: Font { .system(size: 13 * k, weight: .semibold) }
    static var body: Font { .system(size: 13 * k) }
    static var small: Font { .system(size: 12 * k, weight: .medium) }
    static var caption: Font { .system(size: 11 * k, weight: .medium) }
    static var label: Font { m.monoLabels ? mono(10.5, .semibold) : .system(size: 11 * k, weight: .semibold) }
}

/// Section label ("Projects", "Agents"…): uppercase mono in Grid.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(T.m.monoLabels ? text.uppercased() : text)
            .font(T.label)
            .tracking(T.m.monoLabels ? 0.8 : 0)
            .foregroundStyle(T.text3)
    }
}

/// The Dock icon, Settings → Appearance → App icon: colorful (the bundle's) or monochrome (AppIcon-mono.png).
/// A preference of this Mac (UserDefaults), applied at launch. Only the running app's icon changes: Finder and a
/// Dock icon kept for a quit Octomux show the bundle's, since changing those means writing into the signed bundle.
enum AppIconStyle {
    static let key = "octomux.appIcon"
    static var current: String { UserDefaults.standard.string(forKey: key) ?? "color" }

    static func set(_ style: String) {
        UserDefaults.standard.set(style, forKey: key)
        apply()
    }

    static func apply() {
        // Octomux Dev keeps its DEV-banded icon, so the two apps stay apart in the Dock.
        guard !Paths.isDevVariant else { return }
        NSApp.applicationIconImage = current == "mono" ? monoImage : nil
    }

    static var monoImage: NSImage? { Bundle.main.url(forResource: "AppIcon-mono", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }

    /// Both icons for Settings' preview: from the bundle, or from app/Resources in a development run.
    static func previewImage(_ style: String) -> NSImage? {
        let name = style == "mono" ? "AppIcon-mono" : "AppIcon-1024"
        if style == "mono", let i = monoImage { return i }
        if style != "mono", let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let i = NSImage(contentsOf: u) { return i }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: repo.appendingPathComponent("Resources/\(name).png"))
    }
}
