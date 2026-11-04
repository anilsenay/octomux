import SwiftUI

// TEMPORARY: a lab for how a workspace that wants you shows in the switcher (Settings → Appearance →
// "Workspace attention lab"). Every look, with its knobs, so they can be compared; one stays, the rest go.

final class AttentionLab: ObservableObject {
    static let shared = AttentionLab()

    enum Style: String, CaseIterable, Identifiable {
        case cornerDot, ring, tint, bar, badge, ripple, rectGradient, glow, breathe, border, sweep, fill, underGlow, orbit, halo
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cornerDot: return "Corner dot (the old one)"
            case .ring: return "Ring around the icon"
            case .tint: return "Icon itself in color"
            case .bar: return "Bar under the icon"
            case .badge: return "Count badge"
            case .ripple: return "Ripple rings"
            case .rectGradient: return "Gradient filling the button (clipped)"
            case .glow: return "Blurred glow (current)"
            case .breathe: return "Icon breathes (brightens and grows)"
            case .border: return "Button border fades in and out"
            case .sweep: return "Light sweeps across the button"
            case .fill: return "Button background tinted"
            case .underGlow: return "Glow under the icon (soft bar)"
            case .orbit: return "Small dot orbiting the icon"
            case .halo: return "Soft halo, no animation"
            }
        }
        /// Moves by default.
        var animatedByDefault: Bool { ![.cornerDot, .tint, .badge, .fill, .halo].contains(self) }
    }

    enum ColorSource: String, CaseIterable, Identifiable {
        case workspace, attention, accent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .workspace: return "Workspace color"
            case .attention: return "Amber waiting / green finished"
            case .accent: return "Theme accent"
            }
        }
    }

    private static let prefix = "octomux.lab.attention."
    private func load<T>(_ k: String, _ d: T) -> T { UserDefaults.standard.object(forKey: Self.prefix + k) as? T ?? d }
    private func save(_ k: String, _ v: Any) { UserDefaults.standard.set(v, forKey: Self.prefix + k) }

    @Published var style: Style { didSet { save("style", style.rawValue) } }
    @Published var colorSource: ColorSource { didSet { save("color", colorSource.rawValue) } }
    @Published var opacity: Double { didSet { save("opacity", opacity) } }
    @Published var size: Double { didSet { save("size", size) } }
    @Published var duration: Double { didSet { save("duration", duration) } }
    @Published var pause: Double { didSet { save("pause", pause) } }
    @Published var blur: Double { didSet { save("blur", blur) } }
    @Published var line: Double { didSet { save("line", line) } }
    @Published var animated: Bool { didSet { save("animated", animated) } }
    /// Show it on every other workspace, wanted or not (to look at it without waiting for an agent).
    @Published var force: Bool { didSet { save("force", force) } }

    init() {
        style = Style(rawValue: UserDefaults.standard.string(forKey: Self.prefix + "style") ?? "") ?? .glow
        colorSource = ColorSource(rawValue: UserDefaults.standard.string(forKey: Self.prefix + "color") ?? "") ?? .workspace
        opacity = 0; size = 0; duration = 0; pause = 0; blur = 0; line = 0; animated = true; force = false
        opacity = load("opacity", 0.42); size = load("size", 1.0); duration = load("duration", 1.4); pause = load("pause", 1.0)
        blur = load("blur", 4.0); line = load("line", 1.5); animated = load("animated", true); force = load("force", false)
    }

    func reset() {
        opacity = 0.42; size = 1.0; duration = 1.4; pause = 1.0; blur = 4.0; line = 1.5
        animated = style.animatedByDefault; colorSource = .workspace
    }

    func color(workspace: Workspace, attention: (waiting: Int, unread: Int)) -> Color {
        switch colorSource {
        case .workspace: return Color(hex: workspace.color)
        case .attention: return attention.waiting > 0 || attention.unread == 0 ? T.amber : T.green
        case .accent: return T.accent
        }
    }
}

/// A workspace button's icon with the lab's attention look around it. `wants`: draw it.
struct AttentionDecorated: View {
    @ObservedObject var lab = AttentionLab.shared
    let workspace: Workspace
    let attention: (waiting: Int, unread: Int)
    let wants: Bool
    let dimmed: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if wants && lab.animated && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                decorated(phase(ctx.date))
            }
        } else {
            decorated(wants ? 0.5 : nil)
        }
    }

    /// 0…1 through the wave, nil in the pause.
    private func phase(_ d: Date) -> Double? {
        let cycle = max(0.1, lab.duration + lab.pause)
        let t = d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        return t < lab.duration ? t / max(0.05, lab.duration) : nil
    }

    @ViewBuilder private func decorated(_ p: Double?) -> some View {
        let c = lab.color(workspace: workspace, attention: attention)
        let on = wants
        let still = !lab.animated || reduceMotion
        // Envelope: quick in, slow out; 1 when still.
        let env: Double = still ? 1 : p.map { min(1, $0 * 4) * (1 - $0) * 1.6 } ?? 0
        let grow: Double = still ? 1 : p.map { 1 - pow(1 - $0, 3) } ?? 0
        let a = min(1, lab.opacity * env)
        let s = lab.size
        let n = attention.waiting > 0 ? attention.waiting : max(attention.unread, 1)

        WorkspaceIcon(workspace: workspace, size: 13, dimmed: dimmed && !(on && lab.style == .tint),
                      tint: on && lab.style == .tint ? c.opacity(still ? 1 : 0.55 + 0.45 * env) : nil)
            .scaleEffect(on && lab.style == .breathe ? 1 + 0.18 * s * env : 1)
            .brightness(on && lab.style == .breathe ? 0.35 * lab.opacity * env : 0)
            .overlay {
                if on && lab.style == .ring {
                    Circle().stroke(c.opacity(still ? lab.opacity : a), lineWidth: lab.line).frame(width: 15 * s, height: 15 * s)
                }
                if on && lab.style == .orbit, let p {
                    let ang = p * 2 * .pi
                    Circle().fill(c.opacity(lab.opacity)).frame(width: 3.5 * s, height: 3.5 * s)
                        .offset(x: cos(ang) * 9 * s, y: sin(ang) * 9 * s)
                }
            }
            .overlay(alignment: .trailing) {
                if on && lab.style == .badge {
                    Text("\(n)").font(.system(size: T.k * 8.5 * s, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 3).frame(minWidth: 12 * s, minHeight: 12 * s)
                        .background(Capsule().fill(c.opacity(lab.opacity)))
                        .offset(x: 8 * s, y: -6 * s)
                }
            }
            .frame(width: width, height: 24)
            .background {
                if on { background(c, p: p, a: a, grow: grow, still: still) }
            }
            .overlay(alignment: .bottom) {
                if on && lab.style == .bar {
                    Capsule().fill(c.opacity(still ? lab.opacity : max(0.25, env) * lab.opacity)).frame(width: 10 * s, height: lab.line + 1).offset(y: -1)
                }
                if on && lab.style == .underGlow {
                    Capsule().fill(c.opacity(still ? lab.opacity : a)).frame(width: 14 * s, height: 3 + lab.line).blur(radius: lab.blur * 0.6).offset(y: -1)
                }
            }
            .overlay {
                if on && lab.style == .border {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.opacity(still ? lab.opacity : a), lineWidth: lab.line)
                }
            }
            .overlay(alignment: .topTrailing) {
                if on && lab.style == .cornerDot {
                    Circle().fill(c.opacity(lab.opacity)).frame(width: 6 * s, height: 6 * s)
                        .overlay(Circle().stroke(T.frame, lineWidth: 1.5)).offset(x: -2, y: 2)
                }
            }
    }

    @ViewBuilder private func background(_ c: Color, p: Double?, a: Double, grow: Double, still: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let s = lab.size
        switch lab.style {
        case .ripple:
            if let p, !still {
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let q = (p + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(c.opacity(lab.opacity * (1 - q)), lineWidth: lab.line)
                            .frame(width: (8 + 18 * q) * s, height: (8 + 18 * q) * s)
                    }
                }
            } else if still {
                Circle().stroke(c.opacity(lab.opacity * 0.5), lineWidth: lab.line).frame(width: 18 * s, height: 18 * s)
            }
        case .rectGradient:
            GeometryReader { g in
                let reach = max(1, hypot(g.size.width, g.size.height) / 2 * (0.35 + 0.75 * grow) * s)
                shape.fill(RadialGradient(colors: [c.opacity(a), c.opacity(a * 0.55), c.opacity(0)], center: .center, startRadius: 0, endRadius: reach))
            }
        case .glow:
            shape.fill(c.opacity(a)).padding(3).scaleEffect((0.35 + 0.65 * grow) * s).blur(radius: lab.blur)
        case .halo:
            Circle().fill(c.opacity(lab.opacity * 0.6)).frame(width: 16 * s, height: 16 * s).blur(radius: lab.blur)
        case .fill:
            shape.fill(c.opacity(still ? lab.opacity * 0.5 : a * 0.6))
        case .sweep:
            if let p, !still {
                GeometryReader { g in
                    LinearGradient(colors: [c.opacity(0), c.opacity(lab.opacity), c.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6 * s)
                        .offset(x: -g.size.width * 0.6 + (g.size.width * 1.6) * p)
                        .blur(radius: lab.blur * 0.5)
                }
                .clipShape(shape)
            }
        default:
            EmptyView()
        }
    }
}

/// Settings → Appearance: the lab's controls and a preview of three workspaces (a dot, an SF Symbol, an emoji).
struct AttentionLabSettings: View {
    @ObservedObject var lab = AttentionLab.shared

    var body: some View {
        SettingsGroup("Workspace attention lab (temporary)", desc: "How another workspace that wants you shows in the switcher at the bottom of the sidebar. Try them here; the one you like stays, the rest go.") {
            VStack(alignment: .leading, spacing: 0) {
                preview
                Hairline()
                row("Look") {
                    Picker("", selection: Binding(get: { lab.style }, set: { lab.style = $0; lab.animated = $0.animatedByDefault })) {
                        ForEach(AttentionLab.Style.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                row("Color") {
                    Picker("", selection: $lab.colorSource) {
                        ForEach(AttentionLab.ColorSource.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                row("Animated") { Toggle("", isOn: $lab.animated).labelsHidden().toggleStyle(.switch) }
                slider("Opacity", $lab.opacity, 0.05...1, "%.2f")
                slider("Size", $lab.size, 0.5...2, "×%.2f")
                if lab.animated {
                    slider("Wave", $lab.duration, 0.3...4, "%.1f s")
                    slider("Pause", $lab.pause, 0...4, "%.1f s")
                }
                if [.glow, .halo, .sweep, .underGlow].contains(lab.style) { slider("Blur", $lab.blur, 0...10, "%.1f") }
                if [.ring, .ripple, .border, .bar, .underGlow].contains(lab.style) { slider("Line", $lab.line, 0.5...4, "%.1f") }
                row("Show on every other workspace") { Toggle("", isOn: $lab.force).labelsHidden().toggleStyle(.switch) }
                HStack {
                    Text("Real switcher: also follows these settings.").font(.system(size: T.k * 11.5)).foregroundStyle(T.text3)
                    Spacer()
                    Button("Reset Knobs") { lab.reset() }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private var preview: some View {
        let ws = [Workspace.preview("Personal", "#E8704A", nil), Workspace.preview("Work", "#4A90E8", nil),
                  Workspace.preview("School", "#3FB27F", "graduationcap.fill"), Workspace.preview("Side", "#9B6BE8", "🚀")]
        let strip = HStack(spacing: 2) {
            ForEach(Array(ws.enumerated()), id: \.offset) { i, w in
                AttentionDecorated(workspace: w, attention: (i == 3 ? 0 : 1, i == 3 ? 2 : 0), wants: i > 0, dimmed: i > 0, width: i == 0 ? 40 : 28)
                    .background(i == 0 ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.raised) : nil)
                    .overlay(i == 0 ? RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.border) : nil)
            }
        }
        return HStack(spacing: 40) {
            VStack(spacing: 8) { strip; Text("actual size").font(.system(size: T.k * 10.5)).foregroundStyle(T.text3) }
            VStack(spacing: 8) { strip.scaleEffect(2).frame(width: 260, height: 56); Text("2× zoom").font(.system(size: T.k * 10.5)).foregroundStyle(T.text3) }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(T.frame)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: T.k * 12.5))
            Spacer()
            c()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        row(title) {
            Slider(value: v, in: r).frame(width: 220)
            Text(String(format: fmt, v.wrappedValue)).font(T.mono(11)).foregroundStyle(T.text2).frame(width: 52, alignment: .trailing)
        }
    }
}

extension Workspace {
    static func preview(_ name: String, _ color: String, _ icon: String?) -> Workspace {
        Workspace(id: "preview-" + name, name: name, color: color, sort: 0, icon: icon)
    }
}
