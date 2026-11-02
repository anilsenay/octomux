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

/// Icon for an agent profile / session kind.
struct AgentIcon: View {
    let icon: String
    var size: CGFloat = 12

    var body: some View {
        switch icon {
        case "claude":
            brand("claude", AnyShapeStyle(Color(hex: "#D97757")))
        case "codex":
            brand("codex", AnyShapeStyle(T.text))
        case "gemini":
            brand("gemini", AnyShapeStyle(LinearGradient(colors: [Color(hex: "#4796E3"), Color(hex: "#9177C7"), Color(hex: "#CA6673")],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
        case "terminal":
            Image(systemName: "apple.terminal").font(.system(size: size * 0.92, weight: .regular)).foregroundStyle(T.text2)
                .frame(width: size + 2, height: size)
        case "action":
            Image(systemName: "play.fill").font(.system(size: size - 2)).foregroundStyle(T.text3)
        default:
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size - 1)).foregroundStyle(T.text3)
        }
    }

    @ViewBuilder private func brand(_ key: String, _ style: AnyShapeStyle) -> some View {
        if let img = BrandIcons.image(key, size: size) {
            Rectangle().fill(style)
                .mask(Image(nsImage: img).resizable().renderingMode(.template).interpolation(.high).aspectRatio(contentMode: .fit))
                .frame(width: size, height: size)
        } else {
            Circle().fill(style).frame(width: size * 0.7, height: size * 0.7)
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

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, image: NSImage? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.image = image
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// A button that opens an AppKit menu right below itself on the first click (SwiftUI `Menu` in the title-bar
/// area can miss clicks).
struct PopupMenuButton<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = AnchorBox()

    final class AnchorBox { weak var view: NSView? }

    var body: some View {
        label()
            .contentShape(Rectangle())
            .background(AnchorView(box: anchor))
            .onTapGesture {
                guard let v = anchor.view else { return }
                menu().popUp(positioning: nil, at: NSPoint(x: 0, y: v.isFlipped ? v.bounds.height + 4 : -4), in: v)
            }
    }

    struct AnchorView: NSViewRepresentable {
        let box: AnchorBox
        func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
        func updateNSView(_ v: NSView, context: Context) { box.view = v }
    }
}

/// What is being dragged inside the app (tab / project / session reordering).
enum DragItem {
    static var current: (kind: String, id: String)?
}

/// Live reordering: as the dragged item enters a target of the same kind, `move` runs.
struct ReorderDrop: DropDelegate {
    let kind: String
    let targetId: String
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { DragItem.current?.kind == kind }
    func dropEntered(info: DropInfo) {
        guard let d = DragItem.current, d.kind == kind, d.id != targetId else { return }
        move(d.id, targetId)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { DragItem.current = nil; return true }
}

extension View {
    /// Makes the view draggable and a drop target for items of the same `kind`.
    func reorderable(_ kind: String, id: String, move: @escaping (String, String) -> Void) -> some View {
        self
            .onDrag {
                DragItem.current = (kind, id)
                return NSItemProvider(object: "ade-\(kind):\(id)" as NSString)
            }
            .onDrop(of: [.text], delegate: ReorderDrop(kind: kind, targetId: id, move: move))
    }
}

/// The selected workspace's color, mixed lightly into the window chrome so each workspace has its own feel.
struct WorkspaceTintedFrame: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            T.frame
            if let hex = model.workspace?.color {
                Color(hex: hex).opacity(scheme == .dark ? 0.03 : 0.025)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.selectedWorkspaceId)
    }
}

enum WorkspaceTint {
    /// Selected-row fill: the workspace color when there is one, else the theme's selection.
    static func selection(_ model: AppModel) -> Color {
        guard let hex = model.workspace?.color else { return T.selection }
        return Color(hex: hex).opacity(0.16)
    }
}
