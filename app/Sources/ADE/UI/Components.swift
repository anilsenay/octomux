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
    static let sidebarBG = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.94, alpha: 1)
    })
    static let chromeBG = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    })
    static let selection = Color.accentColor.opacity(0.22)
}

/// Icon for an agent profile / session kind.
struct AgentIcon: View {
    let icon: String
    var size: CGFloat = 12

    var body: some View {
        switch icon {
        case "claude":
            Image(systemName: "asterisk").font(.system(size: size, weight: .bold)).foregroundStyle(Color(hex: "#D97757"))
        case "codex":
            Image(systemName: "hexagon").font(.system(size: size, weight: .semibold)).foregroundStyle(.primary)
        case "gemini":
            Image(systemName: "sparkle").font(.system(size: size)).foregroundStyle(Color(hex: "#4F8DF7"))
        case "terminal":
            Image(systemName: "terminal").font(.system(size: size)).foregroundStyle(.secondary)
        case "action":
            Image(systemName: "play.fill").font(.system(size: size - 2)).foregroundStyle(.secondary)
        default:
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size - 1)).foregroundStyle(.secondary)
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

/// Small activity indicator shown next to sessions.
struct ActivityIndicator: View {
    let session: Session

    var body: some View {
        Group {
            if session.state == .interrupted {
                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                    .help("Restoring…")
            } else if session.isDormant {
                EmptyView()
            } else {
                switch session.activity {
                case .working:
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12).help("Working")
                case .needsInput:
                    Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 10)).foregroundStyle(.orange).help("Needs your input")
                case .error:
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 10)).foregroundStyle(.red).help("Error")
                case .done where session.unread:
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Finished")
                default:
                    if session.unread {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Project icon: colored folder / SF Symbol / emoji / mascot / image.
struct ProjectIconView: View {
    let project: Project
    var size: CGFloat = 14

    var body: some View {
        let color = Color(hex: project.color)
        switch project.icon.kind {
        case "symbol":
            Image(systemName: project.icon.value ?? "folder.fill").font(.system(size: size - 1)).foregroundStyle(color)
        case "emoji":
            Text(project.icon.value ?? "📁").font(.system(size: size - 1))
        case "mascot":
            Mascot(name: project.icon.value ?? "invader", color: color).frame(width: size + 2, height: size + 2)
        case "image":
            if let p = project.icon.value, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFit().frame(width: size + 2, height: size + 2).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "folder.fill").font(.system(size: size - 1)).foregroundStyle(color)
            }
        default:
            Image(systemName: "folder.fill").font(.system(size: size - 1)).foregroundStyle(color)
        }
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

/// Hover-aware button style used across the chrome.
struct ChromeButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Color.primary.opacity(0.15) : hover ? Color.primary.opacity(0.08) : .clear))
            .onHover { hover = $0 }
    }
}
