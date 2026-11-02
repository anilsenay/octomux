import AppKit
import SwiftUI

// Design tokens. See DESIGN.md. Every color is dynamic (dark/light) and
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
    @Published private(set) var mode = "system"
    private(set) var terminalColors = true
    private var appearanceObs: NSKeyValueObservation?
    private var lastWritten = ""

    var revision: String { "\(preset.id)-\(mode)" }

    init() {
        appearanceObs = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.writeTerminalTheme() }
        }
    }

    func sync(from model: AppModel) {
        // Appearance is this Mac's preference: a remote host's settings do not change it.
        if model.host.isRemote && !lastWritten.isEmpty { return }
        let id = model.settingValue("appearance.theme", scope: "global")?.string ?? "ink"
        let m = model.settingValue("appearance.mode", scope: "global")?.string ?? "system"
        let tc = model.settingValue("appearance.terminal_colors", scope: "global")?.bool ?? true
        let changed = id != preset.id || m != mode || tc != terminalColors
        guard changed || lastWritten.isEmpty else { return }
        if id != preset.id {
            preset = Themes.preset(id)
            DispatchQueue.main.async {
                Self.applyWindowGlass()
                TerminalHost.shared.render(force: true)
                TerminalHost.shared.renderDock(force: true)
            }
        }
        if m != mode { mode = m }
        terminalColors = tc
        NSApp.appearance = m == "dark" ? NSAppearance(named: .darkAqua) : m == "light" ? NSAppearance(named: .aqua) : nil
        writeTerminalTheme()
    }

    /// Glass needs a non-opaque window so the behind-window blur shows through the terminals.
    static func applyWindowGlass() {
        guard let w = (NSApp.delegate as? AppDelegate)?.mainWindow else { return }
        let glass = shared.preset.metrics.glass
        w.isOpaque = !glass
        w.backgroundColor = glass ? .clear : .windowBackgroundColor
    }

    var isDark: Bool {
        switch mode {
        case "dark": return true
        case "light": return false
        default: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Ghostty config fragment with the preset's terminal colors, loaded after the user's terminal.conf.
    func terminalConfigText(dark: Bool) -> String {
        let p = dark ? preset.dark : preset.light
        func hex(_ n: NSColor) -> String {
            let x = n.usingColorSpace(.sRGB) ?? n
            return String(format: "#%02X%02X%02X", Int(round(x.redComponent * 255)), Int(round(x.greenComponent * 255)), Int(round(x.blueComponent * 255)))
        }
        var lines = [
            "# Generated by ADE from the \(preset.name) theme (\(dark ? "dark" : "light")). Edit terminal.conf instead.",
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
        let text = terminalColors ? terminalConfigText(dark: isDark) : "# Terminal colors come from terminal.conf\n"
        let padding = "window-padding-x = 12\nwindow-padding-y = 8\nwindow-padding-balance = true\nwindow-padding-color = background\n"
        let glass = preset.metrics.glass ? "background-opacity = \(isDark ? 0.55 : 0.6)\n" : ""
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
        Color(nsColor: NSColor(name: nil) { a in
            let p = ThemeStore.shared.preset
            return a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark[keyPath: key] : p.light[keyPath: key]
        })
    }
    static func ns(_ key: KeyPath<ThemeColors, NSColor>) -> NSColor {
        NSColor(name: nil) { a in
            let p = ThemeStore.shared.preset
            return a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark[keyPath: key] : p.light[keyPath: key]
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

    static var m: ThemeMetrics { ThemeStore.shared.preset.metrics }

    // Typography
    static let monoName: String? = ["JetBrainsMono-Regular", "JetBrains Mono"].first { NSFont(name: $0, size: 12) != nil }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let n = monoName { return .custom(n, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
    static let title = Font.system(size: 20, weight: .bold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static var label: Font { m.monoLabels ? mono(10.5, .semibold) : .system(size: 11, weight: .semibold) }
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
