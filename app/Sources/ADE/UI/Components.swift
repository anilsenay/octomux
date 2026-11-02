import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum Palette {
    static let colors = ["#459CF7", "#F4BF25", "#39C363", "#E45A9F", "#B168D4", "#37BEB4", "#EF8C39", "#EA603E", "#8B949C"]
    static var sidebarBG: Color { T.frame }
    static var chromeBG: Color { T.frame }
    static var selection: Color { T.selection }
}

/// Claude's spark: tapered rays of uneven length around a small core.
struct ClaudeSpark: Shape {
    static let rays: [(angle: Double, length: Double)] = [
        (0, 1.0), (31, 0.86), (62, 0.97), (90, 0.8), (118, 0.98), (151, 0.84),
        (180, 1.0), (209, 0.88), (241, 0.96), (270, 0.82), (299, 0.99), (330, 0.86),
    ]
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for ray in Self.rays {
            let t = ray.angle * .pi / 180
            let len = R * ray.length, base = R * 0.15, inner = 0.0
            let dir = CGPoint(x: cos(t), y: sin(t)), n = CGPoint(x: -sin(t), y: cos(t))
            let b0 = CGPoint(x: c.x + dir.x * inner + n.x * base, y: c.y + dir.y * inner + n.y * base)
            let b1 = CGPoint(x: c.x + dir.x * inner - n.x * base, y: c.y + dir.y * inner - n.y * base)
            let tip = CGPoint(x: c.x + dir.x * len, y: c.y + dir.y * len)
            let tipW = R * 0.06
            p.move(to: b0)
            p.addLine(to: CGPoint(x: tip.x + n.x * tipW, y: tip.y + n.y * tipW))
            p.addQuadCurve(to: CGPoint(x: tip.x - n.x * tipW, y: tip.y - n.y * tipW),
                           control: CGPoint(x: tip.x + dir.x * tipW * 1.6, y: tip.y + dir.y * tipW * 1.6))
            p.addLine(to: b1)
            p.closeSubpath()
        }
        return p
    }
}

/// Four-point star with concave sides (Gemini-style sparkle).
struct FourPointStar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        let pts = [CGPoint(x: c.x, y: c.y - R), CGPoint(x: c.x + R, y: c.y), CGPoint(x: c.x, y: c.y + R), CGPoint(x: c.x - R, y: c.y)]
        p.move(to: pts[0])
        for i in 1...4 { p.addQuadCurve(to: pts[i % 4], control: c) }
        p.closeSubpath()
        return p
    }
}

/// Three crossed capsules forming a six-petal knot (OpenAI/Codex-style).
struct Rosette: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for i in 0..<3 {
            let link = Path(roundedRect: CGRect(x: -R * 0.3, y: -R * 0.92, width: R * 0.6, height: R * 1.84), cornerRadius: R * 0.3)
            p.addPath(link, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: Double(i) * .pi / 3))
        }
        return p
    }
}

/// Icon for an agent profile / session kind.
struct AgentIcon: View {
    let icon: String
    var size: CGFloat = 12

    var body: some View {
        switch icon {
        case "claude":
            ClaudeSpark().fill(T.claude).frame(width: size, height: size)
        case "codex":
            Rosette().stroke(T.text, style: StrokeStyle(lineWidth: max(1.1, size / 10)))
                .frame(width: size, height: size)
        case "gemini":
            FourPointStar().fill(LinearGradient(colors: [Color(hex: "#4F8DF7"), Color(hex: "#A06CF0")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
        case "terminal":
            Image(systemName: "apple.terminal").font(.system(size: size * 0.92, weight: .regular)).foregroundStyle(T.text2)
                .frame(width: size + 2, height: size)
        case "action":
            Image(systemName: "play.fill").font(.system(size: size - 2)).foregroundStyle(T.text3)
        default:
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size - 1)).foregroundStyle(T.text3)
        }
    }
}

func iconName(for session: Session, model: AppModel) -> String {
    switch session.kind {
    case .terminal: return "terminal"
    case .action: return "action"
    case .agent: return model.profile(session.profileId)?.icon ?? "agent"
    }
}

/// Rotating accent arc: an agent is working.
struct WorkingRing: View {
    var size: CGFloat = 11
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(T.border, lineWidth: 2)
            Circle().trim(from: 0, to: 0.28).stroke(T.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
        }
        .frame(width: size, height: size)
        .onAppear { spin = true }
    }
}

/// Small rounded label: "input", counts.
struct Badge: View {
    let text: String
    var color: Color = T.amber
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// Activity indicator shown next to sessions and in tabs.
struct ActivityIndicator: View {
    let session: Session

    var body: some View {
        Group {
            if session.state == .interrupted {
                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold)).foregroundStyle(T.amber)
                    .help("Restoring…")
            } else if session.isDormant {
                EmptyView()
            } else {
                switch session.activity {
                case .working:
                    WorkingRing().help("Working")
                case .needsInput:
                    Badge(text: "input").fixedSize().help("Needs your input")
                case .error:
                    Circle().fill(T.red).frame(width: 7, height: 7).help("Error")
                case .done where session.unread:
                    Circle().fill(T.green).frame(width: 7, height: 7).help("Finished")
                default:
                    if session.unread {
                        Circle().fill(T.accent).frame(width: 6, height: 6)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .frame(minWidth: 14, minHeight: 14)
    }
}

/// Project icon: color tile with initial / symbol / mascot, or emoji / image.
struct ProjectIconView: View {
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        let color = Color(hex: project.color)
        let tile = RoundedRectangle(cornerRadius: min(T.m.tileR, size / 2), style: .continuous)
        switch project.icon.kind {
        case "emoji":
            Text(project.icon.value ?? "📁").font(.system(size: size - 3)).frame(width: size, height: size)
        case "image":
            if let p = project.icon.value, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(tile)
            } else {
                initialTile(color, tile)
            }
        case "symbol":
            tile.fill(color).frame(width: size, height: size)
                .overlay(Image(systemName: project.icon.value ?? "folder.fill").font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
        case "mascot":
            tile.fill(color).frame(width: size, height: size)
                .overlay(Mascot(name: project.icon.value ?? "invader", color: .white).frame(width: size * 0.62, height: size * 0.62))
        default:
            initialTile(color, tile)
        }
    }

    private func initialTile(_ color: Color, _ tile: RoundedRectangle) -> some View {
        tile.fill(color).frame(width: size, height: size)
            .overlay(Text(String(project.name.first.map { String($0).uppercased() } ?? "?"))
                .font(.system(size: size * 0.58, weight: .bold)).foregroundStyle(.white))
    }
}

/// Our own 8×8 pixel mascots (original designs), tinted with the project color.
struct Mascot: View {
    let name: String
    let color: Color

    static let names = ["invader", "ghost", "robot", "cat", "crab", "rocket", "slime", "owl"]

    static let sprites: [String: [String]] = [
        "invader": ["..#..#..", "...##...", "..####..", ".##.##.#", "########", "#.####.#", "#.#..#.#", "...##..."],
        "ghost":   ["..####..", ".######.", "##.##.##", "########", "########", "########", "##.##.##", "#..#..#."],
        "robot":   ["...##...", ".######.", ".#.##.#.", ".######.", "..####..", "########", ".#.##.#.", ".##..##."],
        "cat":     ["#......#", "##....##", "########", "#.####.#", "########", ".######.", ".##..##.", ".#....#."],
        "crab":    ["#......#", "#.#..#.#", ".######.", "##.##.##", "########", ".######.", ".#....#.", "#......#"],
        "rocket":  ["...##...", "..####..", "..#..#..", "..####..", ".######.", "##.##.##", "#..##..#", "..#..#.."],
        "slime":   ["........", "...##...", "..####..", ".#.##.#.", "########", "########", "########", ".######."],
        "owl":     [".#....#.", "########", "#..##..#", "#.#..#.#", "########", ".######.", ".######.", "..#..#.."],
    ]

    var body: some View {
        Canvas { ctx, size in
            let rows = Mascot.sprites[name] ?? Mascot.sprites["invader"]!
            let cell = min(size.width, size.height) / 8
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)), with: .color(color))
                }
            }
        }
    }
}

/// Pointing-hand cursor while the pointer is over the view (clickable chrome).
struct PointerCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content.onHover { h in
            inside = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

/// Hover fill + pointing hand, for things that are not Buttons (menus, tappable rows).
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 6
    var padding: CGFloat = 0
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .modifier(PointerCursor())
    }
}

extension View {
    /// Menu whose label is drawn as-is (no accent tint, no indicator).
    func plainMenu() -> some View { menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden) }
    func pointerCursor() -> some View { modifier(PointerCursor()) }
    func hoverHighlight(radius: CGFloat = 6, padding: CGFloat = 0) -> some View { modifier(HoverHighlight(radius: radius, padding: padding)) }
}

/// Hover-aware icon button used across the chrome.
struct ChromeButtonStyle: ButtonStyle {
    var active = false
    var size: CGFloat = 26
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? T.accent : hover ? T.text : T.text2)
            .padding(.horizontal, size > 22 ? 6 : 3).frame(minWidth: size, minHeight: size)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed ? T.border : hover ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
    }
}

/// Small square icon button (row actions, "+" buttons): hover fill + hand cursor.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 20
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? T.text : T.text2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(configuration.isPressed ? T.border : hover ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
    }
}

/// Workspace icon: SF Symbol or emoji, else the workspace's color dot.
struct WorkspaceIcon: View {
    let workspace: Workspace
    var size: CGFloat = 13
    var dimmed = false

    var body: some View {
        if let icon = workspace.icon, !icon.isEmpty {
            if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                Image(systemName: icon).font(.system(size: size, weight: .medium))
                    .foregroundStyle(dimmed ? T.text3 : Color(hex: workspace.color))
            } else {
                Text(icon).font(.system(size: size)).opacity(dimmed ? 0.55 : 1)
            }
        } else {
            Circle().fill(dimmed ? T.text3.opacity(0.6) : Color(hex: workspace.color)).frame(width: size * 0.55, height: size * 0.55)
        }
    }

    static let symbols = ["house.fill", "briefcase.fill", "building.2.fill", "hammer.fill", "flask.fill", "graduationcap.fill",
                          "heart.fill", "star.fill", "bolt.fill", "leaf.fill", "gamecontroller.fill", "globe", "lock.fill", "cube.fill"]
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.45)
            .pointerCursor()
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(T.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(configuration.isPressed ? T.border : hover ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hover = $0 }
            .pointerCursor()
    }
}

/// Selectable chip (dock tabs, filters, panel tabs).
struct Chip<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) { label() }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? T.text : T.text2)
            .padding(.horizontal, 9).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? T.raised : hover ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerCursor()
            .onTapGesture(perform: action)
    }
}

/// Rounded content card (settings sections, panels).
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: max(T.m.cardR, 4), style: .continuous).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: max(T.m.cardR, 4), style: .continuous).stroke(T.border))
    }
}

/// Thin separator in the border color.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(T.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Catches middle-button clicks over a view (SwiftUI has no gesture for it); other clicks pass through.
struct MiddleClick: NSViewRepresentable {
    let action: () -> Void
    final class V: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .otherMouseDown || e.type == .otherMouseUp, e.buttonNumber == 2 else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseDown(with event: NSEvent) {}
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.action = action; return v }
    func updateNSView(_ v: V, context: Context) { v.action = action }
}
