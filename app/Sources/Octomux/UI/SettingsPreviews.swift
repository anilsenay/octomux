import AppKit
import SwiftUI

// Settings pickers that show what each choice looks like, instead of a segmented control and a sentence.

/// A setting picked from tiles: title and description on top, then one tile per choice with its preview.
struct VisualSettingRow<Tiles: View>: View {
    @EnvironmentObject var sel: SettingsSelection
    let title: String
    var desc: String?
    var modified = false
    var onReset: (() -> Void)?
    /// Tiles in a row that scrolls sideways; off for content that wraps by itself (a grid).
    var scrolls = true
    @ViewBuilder var tiles: () -> Tiles

    init(_ title: String, desc: String? = nil, modified: Bool = false, onReset: (() -> Void)? = nil, scrolls: Bool = true,
         @ViewBuilder tiles: @escaping () -> Tiles) {
        self.title = title; self.desc = desc; self.modified = modified; self.onReset = onReset; self.scrolls = scrolls; self.tiles = tiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if modified { Circle().fill(T.accent).frame(width: 6, height: 6).help("Set for this workspace") }
                        Text(title).font(.system(size: 13, weight: .medium))
                    }
                    if let desc { Text(desc).font(.system(size: 11.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if modified, let onReset {
                    Button("Reset", action: onReset).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.accent)
                }
            }
            if scrolls { ScrollView(.horizontal, showsIndicators: false) { tiles().padding(2) } } else { tiles() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.accent.opacity(sel.flash == title ? 0.14 : 0))
        .settingAnchor(title)
    }
}

/// One choice: its preview, with the name under it; the picked one has an accent ring and a check.
struct ChoiceTile<Preview: View>: View {
    let title: String
    let selected: Bool
    var width: CGFloat = 128
    var height: CGFloat = 76
    let action: () -> Void
    @ViewBuilder var preview: () -> Preview
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                preview()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? T.accent : hover ? T.text3 : T.border, lineWidth: selected ? 2 : 1))
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? T.text : T.text2).lineLimit(1)
                    if selected { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.accent) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pointerCursor()
    }
}

// MARK: Window mode

/// The current theme in dark or light; System shows both, split diagonally like macOS does.
struct ModePreview: View {
    @ObservedObject var store = ThemeStore.shared
    let mode: String

    var body: some View {
        switch mode {
        case "dark": MiniWindow(colors: store.preset.dark, metrics: store.preset.metrics)
        case "light": MiniWindow(colors: store.preset.light, metrics: store.preset.metrics)
        default:
            ZStack {
                MiniWindow(colors: store.preset.light, metrics: store.preset.metrics)
                MiniWindow(colors: store.preset.dark, metrics: store.preset.metrics)
                    .mask(GeometryReader { g in
                        Path { p in
                            p.move(to: CGPoint(x: g.size.width * 0.62, y: 0)); p.addLine(to: CGPoint(x: g.size.width, y: 0))
                            p.addLine(to: CGPoint(x: g.size.width, y: g.size.height)); p.addLine(to: CGPoint(x: g.size.width * 0.38, y: g.size.height))
                            p.closeSubpath()
                        }
                    })
            }
        }
    }
}

/// A tiny Octomux window in the given colors: sidebar rows, a terminal card with a few lines.
struct MiniWindow: View {
    let colors: ThemeColors
    var metrics = ThemeMetrics()
    /// Tints the chrome like a workspace color does.
    var tint: Color?

    var body: some View {
        let c = colors
        HStack(spacing: metrics.inset > 0 ? 4 : 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) { ForEach(0..<3) { _ in Circle().fill(Color(nsColor: c.text3).opacity(0.6)).frame(width: 3.5, height: 3.5) } }
                    .padding(.bottom, 3)
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i == 1 ? Color(nsColor: c.accent) : Color(nsColor: c.text3).opacity(0.5))
                        .frame(width: i == 0 ? 24 : 32, height: 3)
                }
                Spacer()
            }
            .padding(6)
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: i == 4 ? c.accent : c.termFg).opacity(i == 4 ? 1 : 0.55))
                        .frame(width: [52, 38, 60, 26, 6][i], height: 3)
                }
                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: metrics.cardR > 0 ? 4 : 0).fill(Color(nsColor: c.surface)))
            .overlay(RoundedRectangle(cornerRadius: metrics.cardR > 0 ? 4 : 0).stroke(Color(nsColor: c.border)))
            .padding(.vertical, metrics.inset > 0 ? 4 : 0)
            .padding(.trailing, metrics.inset > 0 ? 4 : 0)
        }
        .background(ZStack { Color(nsColor: c.frame); if let tint { tint.opacity(0.16) } })
    }
}

// MARK: Terminal

/// A few lines of a shell session, in the theme's terminal colors or in the colors of terminal.conf.
struct TerminalColorsPreview: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store = ThemeStore.shared
    let themeColors: Bool

    var body: some View {
        let c = scheme == .dark ? store.preset.dark : store.preset.light
        let own = OwnTerminalColors.load()
        let bg = themeColors ? Color(nsColor: c.surface) : own.background
        let fg = themeColors ? Color(nsColor: c.termFg) : own.foreground
        let ansi: (Int) -> Color = { i in themeColors ? Color(hex: c.ansi[i]) : own.ansi(i) }
        VStack(alignment: .leading, spacing: 3) {
            (Text("~/octomux ").foregroundColor(ansi(4)) + Text("main ").foregroundColor(ansi(5)) + Text("❯ ").foregroundColor(ansi(2)) + Text("git status").foregroundColor(fg))
            (Text("modified: ").foregroundColor(ansi(1)) + Text("app.swift").foregroundColor(fg))
            (Text("new file: ").foregroundColor(ansi(2)) + Text("hooks.rs").foregroundColor(fg))
            (Text("❯ ").foregroundColor(ansi(2)) + Text("▍").foregroundColor(fg))
        }
        .font(.system(size: 8.5, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bg)
    }
}

/// background, foreground and palette from terminal.conf (Ghostty syntax), with Ghostty's defaults for the rest.
enum OwnTerminalColors {
    struct Colors {
        var background = Color(hex: "#282C34")
        var foreground = Color(hex: "#FFFFFF")
        var palette: [Int: String] = [:]
        func ansi(_ i: Int) -> Color {
            if let h = palette[i] { return Color(hex: h) }
            return Color(hex: ["#1D1F21", "#CC6666", "#B5BD68", "#F0C674", "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6"][i % 8])
        }
    }

    static func load() -> Colors {
        var c = Colors()
        guard let text = try? String(contentsOf: Paths.terminalConfig, encoding: .utf8) else { return c }
        let t = TerminalThemes.parse(text)
        if let b = t.background { c.background = Color(hex: b.hasPrefix("#") ? b : "#" + b) }
        if let f = t.foreground { c.foreground = Color(hex: f.hasPrefix("#") ? f : "#" + f) }
        c.palette = t.palette
        return c
    }
}

// MARK: Sidebar

/// The sidebar with a split tab: one row with its panes' icons stacked, or a framed group with a row per pane.
struct SplitTabsPreview: View {
    let stacked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(icon: "terminal", w: 46, selected: false)
            if stacked {
                HStack(spacing: 5) {
                    ZStack {
                        icon("sparkle").offset(x: -2, y: -2)
                        icon("terminal").offset(x: 2, y: 2)
                    }
                    .frame(width: 14)
                    bar(54, T.text)
                    Spacer(minLength: 0)
                    Text("2").font(.system(size: 7, weight: .bold)).foregroundStyle(T.text3)
                }
                .padding(.horizontal, 5).frame(height: 15)
                .background(RoundedRectangle(cornerRadius: 3).fill(T.selection))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    row(icon: "sparkle", w: 50, selected: true)
                    row(icon: "terminal", w: 38, selected: false)
                }
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.border))
            }
            row(icon: "sparkle", w: 40, selected: false)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.frame)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 6.5, weight: .semibold)).foregroundStyle(T.text2)
            .frame(width: 9, height: 9).background(RoundedRectangle(cornerRadius: 2).fill(T.raised))
    }
    private func bar(_ w: CGFloat, _ c: Color) -> some View { RoundedRectangle(cornerRadius: 1.5).fill(c.opacity(0.55)).frame(width: w, height: 3) }
    private func row(icon name: String, w: CGFloat, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: name).font(.system(size: 6.5, weight: .semibold)).foregroundStyle(T.text3).frame(width: 14)
            bar(w, selected ? T.text : T.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).frame(height: 13)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? T.selection : .clear))
    }
}

// MARK: Scene behind terminals

/// The scene around a terminal pane, and what shows through the pane: nothing (opaque), the scene's gradient,
/// a still of the scene, or the moving scene (marked with a badge: the tile itself stays still).
struct BehindTerminalPreview: View {
    let mode: TerminalSceneMode
    let scene: AmbientScene?
    let opacity: Double

    var body: some View {
        let surface = scene.map { Color(nsColor: $0.colors.surface) } ?? T.surface
        let fg = scene.map { Color(nsColor: $0.colors.termFg) } ?? T.text
        ZStack(alignment: .topLeading) {
            backdrop
            ZStack(alignment: .topLeading) {
                if let scene, mode == .color { LinearGradient(colors: [scene.top, scene.bottom], startPoint: .top, endPoint: .bottom) }
                Rectangle().fill(surface.opacity(mode == .off ? 1 : opacity))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 1).fill(fg.opacity(0.9)).frame(width: [44, 30, 52, 22][i], height: 3)
                    }
                }
                .padding(7)
            }
            .frame(width: 78, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(fg.opacity(0.18)))
            .offset(x: 30, y: 14)
            if mode == .live {
                Image(systemName: "play.fill").font(.system(size: 7)).foregroundStyle(.white)
                    .padding(4).background(Circle().fill(.black.opacity(0.45))).padding(5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder private var backdrop: some View {
        if let scene { SceneBackdrop(scene: scene, still: true) }
        else { LinearGradient(colors: [T.surface, T.frame], startPoint: .top, endPoint: .bottom) }
    }
}

// MARK: Dock and menu bar

/// The Dock icon itself.
struct AppIconPreview: View {
    let style: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [T.surface, T.frame], startPoint: .top, endPoint: .bottom)
            if let img = AppIconStyle.previewImage(style) {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            }
        }
    }
}

/// A slice of the menu bar with the octopus (or without it) next to the system's own items.
struct MenuBarPreview: View {
    @Environment(\.colorScheme) private var scheme
    let style: StatusItemController.Style

    var body: some View {
        let ink: Color = scheme == .dark ? .white : .black
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Spacer(minLength: 0)
                if let img = StatusItemController.preview(style) {
                    if style == .mono {
                        Image(nsImage: img).renderingMode(.template).interpolation(.none).foregroundStyle(ink)
                    } else {
                        Image(nsImage: img).interpolation(.none)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 16, height: 15)
                }
                Image(systemName: "wifi").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.85))
                Image(systemName: "battery.75percent").font(.system(size: 12)).foregroundStyle(ink.opacity(0.85))
                Text("9:41").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.85))
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(ink.opacity(0.07))
            LinearGradient(colors: [T.surface.opacity(0.6), T.frame.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: Diff colors

struct DiffColorSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let cb = model.settingValue("appearance.diff_colors", scope: "global")?.string == "blue_orange"
        SettingsGroup("Diffs") {
            VisualSettingRow("Diff colors", desc: "Added and removed lines and counts. Blue and orange stay apart with red–green color blindness.") {
                HStack(spacing: 12) {
                    ChoiceTile(title: "Green and red", selected: !cb, width: 150, height: 76, action: { model.setSetting("appearance.diff_colors", nil) }) {
                        DiffPreview(add: T.ns(\.green), del: T.ns(\.red))
                    }
                    ChoiceTile(title: "Blue and orange", selected: cb, width: 150, height: 76, action: { model.setSetting("appearance.diff_colors", "blue_orange") }) {
                        DiffPreview(add: T.ns(\.blue), del: NSColor(srgbRed: 0.94, green: 0.56, blue: 0.16, alpha: 1))
                    }
                }
            }
        }
    }
}

/// Three diff lines and a +/− count in the given colors.
struct DiffPreview: View {
    let add: NSColor
    let del: NSColor

    var body: some View {
        let a = Color(nsColor: add), d = Color(nsColor: del)
        VStack(alignment: .leading, spacing: 3) {
            line("−", "old line", d)
            line("+", "new line", a)
            line("+", "added", a)
            HStack(spacing: 4) {
                Text("+12").foregroundStyle(a)
                Text("−3").foregroundStyle(d)
            }
            .font(T.mono(8, .medium)).padding(.top, 1)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.surface)
    }

    private func line(_ sign: String, _ text: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Text(sign).foregroundStyle(c)
            Text(text).foregroundStyle(T.text2)
            Spacer(minLength: 0)
        }
        .font(T.mono(9))
        .padding(.horizontal, 3).frame(height: 11)
        .background(c.opacity(0.14))
    }
}
