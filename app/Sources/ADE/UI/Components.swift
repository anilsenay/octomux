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

/// Claude's mark: three crossing strokes (drawn, so it scales and tints cleanly).
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX, cy = r.midY, rad = min(r.width, r.height) / 2
        for a in [90.0, 30.0, -30.0] {
            let t = a * .pi / 180
            p.move(to: CGPoint(x: cx - cos(t) * rad, y: cy - sin(t) * rad))
            p.addLine(to: CGPoint(x: cx + cos(t) * rad, y: cy + sin(t) * rad))
        }
        return p
    }
}

struct HexMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX, cy = r.midY, rad = min(r.width, r.height) / 2
        for i in 0..<6 {
            let t = (Double(i) * 60 - 90) * .pi / 180
            let pt = CGPoint(x: cx + cos(t) * rad, y: cy + sin(t) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
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
            ClaudeMark().stroke(T.claude, style: StrokeStyle(lineWidth: max(1.6, size / 6), lineCap: .round))
                .frame(width: size, height: size)
        case "codex":
            HexMark().stroke(T.text, style: StrokeStyle(lineWidth: max(1.2, size / 8), lineJoin: .round))
                .frame(width: size, height: size)
        case "gemini":
            Image(systemName: "sparkle").font(.system(size: size)).foregroundStyle(T.blue)
        case "terminal":
            Image(systemName: "chevron.right").font(.system(size: size * 0.8, weight: .bold)).foregroundStyle(T.text3)
                .frame(width: size, height: size)
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

/// Hover-aware icon button used across the chrome.
struct ChromeButtonStyle: ButtonStyle {
    var active = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? T.accent : T.text2)
            .padding(.horizontal, 6).frame(minWidth: 26, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed ? T.border : hover ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
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
