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
/// A tab's icon: the lead session's icon, drawn on stacked cards when the tab holds several panes.
/// A tab's (or stacked sidebar row's) icon. One pane: its icon. Several: a stack of tiles in each pane's
/// own color (Claude orange, Codex dark, terminal gray…), the focused pane in front and the others peeking
/// out behind it, so "Claude + terminal" no longer looks like two terminals. When the front pane changes,
/// its tile hops forward.
struct PaneStackIcon: View {
    struct Item: Equatable { let id: String; let icon: String }
    /// How the tiles behind the front one show: stacked upward and smaller (sidebar rows), or fanned out
    /// to the right at a slight angle (tab bar).
    enum Style { case stack, fan }
    /// Front first.
    let items: [Item]
    var size: CGFloat = 12
    var style: Style = .fan
    @State private var hop: String?

    var body: some View {
        if items.count <= 1 {
            AgentIcon(icon: items.first?.icon ?? "terminal", size: size)
        } else {
            let tile = size + 5
            let shown = Array(items.prefix(3))
            let n = CGFloat(shown.count - 1)
            ZStack(alignment: style == .fan ? .leading : .bottom) {
                ForEach(Array(shown.enumerated()).reversed(), id: \.element.id) { k, item in
                    let d = CGFloat(k)
                    PaneTile(icon: item.icon, size: tile)
                        .scaleEffect(style == .stack ? 1 - 0.13 * d : 1 - 0.08 * d, anchor: style == .stack ? .bottom : .bottomLeading)
                        .rotationEffect(.degrees(style == .fan ? 6 * Double(k) : 0), anchor: .bottomLeading)
                        .offset(x: style == .fan ? d * 5.5 : 0,
                                y: (style == .stack ? -d * 4.5 : 0) + (hop == item.id ? -4 : 0))
                        .opacity(k == 0 ? 1 : 1 - 0.12 * Double(k))
                        .zIndex(Double(10 - k))
                }
            }
            .frame(width: style == .fan ? tile + 5.5 * n + 2 : tile,
                   height: style == .stack ? tile + 4.5 * n : tile, alignment: style == .fan ? .leading : .bottom)
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: shown.map(\.id))
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hop)
            .onChange(of: items.first?.id) { _, front in
                hop = front
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { if hop == front { hop = nil } }
            }
            .help("\(items.count) panes in this tab")
        }
    }
}

/// One pane's tile: a rounded square in the agent's color with its mark in white.
struct PaneTile: View {
    let icon: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var fill: AnyShapeStyle {
        switch icon {
        case "claude": return AnyShapeStyle(Color(hex: "#D97757"))
        case "codex": return AnyShapeStyle(Color(hex: scheme == .dark ? "#3A3A40" : "#1F1F23"))
        case "gemini": return AnyShapeStyle(LinearGradient(colors: [Color(hex: "#4796E3"), Color(hex: "#9177C7"), Color(hex: "#CA6673")],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing))
        case "terminal": return AnyShapeStyle(Color(hex: scheme == .dark ? "#5A5A63" : "#8A8A93"))
        case "action": return AnyShapeStyle(T.green)
        default: return AnyShapeStyle(T.accent)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(fill)
            .overlay {
                switch icon {
                case "claude", "codex", "gemini":
                    if let img = BrandIcons.image(icon, size: size * 0.62) {
                        Image(nsImage: img).resizable().renderingMode(.template).interpolation(.high).aspectRatio(contentMode: .fit)
                            .foregroundStyle(.white).frame(width: size * 0.62, height: size * 0.62)
                    }
                case "terminal":
                    Text(">_").font(.system(size: size * 0.42, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                case "action":
                    Image(systemName: "play.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
                default:
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(Color.black.opacity(scheme == .dark ? 0.35 : 0.12), lineWidth: 0.75))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 0.8, x: 0.5, y: 0.5)
    }
}

/// Stack items for a tab: the focused (or active) pane first, then the rest in layout order.
func paneStackItems(_ ids: [String], front: String?, model: AppModel) -> [PaneStackIcon.Item] {
    let ordered = (front.map { [$0] } ?? []) + ids.filter { $0 != front }
    return ordered.compactMap { id in model.session(id).map { PaneStackIcon.Item(id: id, icon: iconName(for: $0, model: model)) } }
}

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
    var cursor: NSCursor = .pointingHand
    @State private var inside = false
    func body(content: Content) -> some View {
        content.onHover { h in
            guard h != inside else { return }
            inside = h
            if h { cursor.push() } else { NSCursor.pop() }
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
    /// A menu label that is clickable over its whole box (not just the glyph).
    func menuHitBox(_ w: CGFloat, _ h: CGFloat) -> some View { frame(width: w, height: h).contentShape(Rectangle()) }
    func pointerCursor() -> some View { modifier(PointerCursor()) }
    /// Open-hand cursor: marks a surface that can be grabbed and dragged.
    func grabCursor() -> some View { modifier(PointerCursor(cursor: .openHand)) }
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
    static var current: (kind: String, id: String)? {
        didSet {
            if current == nil { DragState.shared.end() } else { DragState.shared.begin(current!.id) }
        }
    }
}

/// Observable side of `DragItem`: which item is in flight, so its source slot can render as a gap
/// instead of a second copy. SwiftUI's `onDrag` has no "drag ended" callback, so a short poll on the
/// mouse button clears it when a drag is dropped outside any target or cancelled.
final class DragState: ObservableObject {
    static let shared = DragState()
    @Published private(set) var draggingId: String?
    private var timer: Timer?

    func begin(_ id: String) {
        timer?.invalidate()
        // Let the drag preview snapshot the untouched view first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard DragItem.current?.id == id else { return }
            withAnimation(.easeOut(duration: 0.12)) { self?.draggingId = id }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            // performDrop runs around mouse-up and still needs DragItem.current.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if DragItem.current?.id == id { DragItem.current = nil } else { self?.end() }
            }
        }
    }

    func end() {
        timer?.invalidate(); timer = nil
        if draggingId != nil { withAnimation(.easeOut(duration: 0.12)) { draggingId = nil } }
    }
}

/// The source of an in-flight drag: drawn as an empty slot so the live-reordered position reads clearly.
struct DragSourceGap: ViewModifier {
    let id: String
    @ObservedObject private var drag = DragState.shared
    func body(content: Content) -> some View {
        let gap = drag.draggingId == id
        content
            .opacity(gap ? 0 : 1)
            .overlay {
                if gap {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(T.accent.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(T.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
    }
}

/// Live reordering: as the dragged item enters a target of the same kind, `move` runs.
struct ReorderDrop: DropDelegate {
    let kind: String
    let targetId: String
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { DragItem.current?.kind == kind }
    func dropEntered(info: DropInfo) {
        guard let d = DragItem.current, d.kind == kind, d.id != targetId else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { move(d.id, targetId) }
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
            .modifier(DragSourceGap(id: id))
    }
}

/// The selected workspace's color as a light "wash" on the window chrome. Like Unpeel's App color: the
/// base keeps its brightness and only takes the workspace hue, with saturation scaled by brightness (dark
/// grays need more to be seen at all, near-white almost none). `strength` keeps it subtler than Unpeel.
struct WorkspaceTintedFrame: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base = ThemeStore.shared.colors(dark: scheme == .dark).frame
        Rectangle()
            .fill(Color(nsColor: WorkspaceTint.washed(base, toward: model.workspace?.color, strength: WorkspaceTint.strength(dark: scheme == .dark))))
            .animation(.easeOut(duration: 0.4), value: model.selectedWorkspaceId)
    }
}

enum WorkspaceTint {
    static let strength = 0.45
    /// Chrome wash strength per appearance.
    static func strength(dark: Bool) -> Double { dark ? 0.45 : 0.28 }
    /// The terminal canvas takes about a third of the chrome's wash (as in Unpeel): gray with a hint of color.
    static let canvasScale = 0.35

    /// Terminal / pane background for the current workspace.
    static func canvas(dark: Bool) -> NSColor {
        let c = ThemeStore.shared.colors(dark: dark)
        if ThemeStore.shared.activeScene != nil { return c.surface }
        return washed(c.surface, toward: AppModel.shared.workspace?.color,
                      strength: strength(dark: dark) * canvasScale)
    }

    /// The workspace color tuned to read as an accent on this appearance (focused-pane border):
    /// saturation capped so neon picks don't glare, brightness lifted on dark and lowered on light so
    /// every hue keeps similar contrast. Gray or no workspace color → the theme accent.
    static func accent(dark: Bool, hex: String? = AppModel.shared.workspace?.color) -> NSColor {
        if let s = ThemeStore.shared.activeScene { return s.colors.accent }
        guard let hex, let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) else { return T.ns(\.accent) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.12 else { return T.ns(\.accent) }
        let sat = min(max(s, 0.45), dark ? 0.7 : 0.8)
        let bri = dark ? max(b, 0.88) : min(max(b, 0.55), 0.72)
        return NSColor(srgbHue: h, saturation: sat, brightness: bri, alpha: 1)
    }

    /// `base` with its hue pushed toward `hex`'s hue; brightness and alpha unchanged.
    static func washed(_ base: NSColor, toward hex: String?, strength: Double = strength) -> NSColor {
        guard ThemeStore.shared.activeScene == nil, let hex, let b0 = base.usingColorSpace(.sRGB),
              let tint = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) else { return base }
        var th: CGFloat = 0, ts: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        tint.getHue(&th, saturation: &ts, brightness: &tb, alpha: &ta)
        guard ts > 0.08 else { return base }      // gray workspace colors: no wash
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        b0.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let wash = max(s, min(0.5, 0.615 - 0.59 * b) * strength)
        return NSColor(srgbHue: th, saturation: wash, brightness: b, alpha: a)
    }

    /// Selected-row fill: the workspace color when there is one, else the theme's selection.
    static func selection(_ model: AppModel) -> Color {
        guard ThemeStore.shared.activeScene == nil, let hex = model.workspace?.color else { return T.selection }
        return Color(hex: hex).opacity(0.13)
    }
}

extension NSColor {
    /// HSB in sRGB (NSColor's own hue initializer is in generic RGB).
    convenience init(srgbHue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat, alpha a: CGFloat) {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(i) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Pane background (empty / stopped panes): the workspace-washed terminal canvas.
/// Remembers and restores the vertical scroll position of the enclosing scroll view (macOS 14 has no
/// SwiftUI API to read it). Put it in the scroll view's content as a background.
struct ScrollOffsetKeeper: NSViewRepresentable {
    let initial: CGFloat
    let onChange: (CGFloat) -> Void

    final class KeeperView: NSView {
        var initial: CGFloat = 0
        var onChange: ((CGFloat) -> Void)?
        private var restored = false
        private var observer: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            guard window != nil, let sv = enclosingScrollView else { return }
            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard let self, self.restored else { return }
                self.onChange?(clip.bounds.origin.y)
            }
            // Content lays out over the next runloop turns; restore after it has its height.
            for delay in [0.0, 0.05, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak sv] in
                    guard let self, let sv, !self.restored || delay > 0 else { return }
                    let maxY = max(0, (sv.documentView?.frame.height ?? 0) - clip.bounds.height)
                    let y = min(self.initial, maxY)
                    if abs(clip.bounds.origin.y - y) > 0.5 {
                        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                        sv.reflectScrolledClipView(clip)
                    }
                    if delay >= 0.15 { self.restored = true }
                }
            }
        }

        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }

    func makeNSView(context: Context) -> KeeperView {
        let v = KeeperView()
        v.initial = initial
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: KeeperView, context: Context) { v.onChange = onChange }
}

struct CanvasBackground: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    /// Empty panes and the new-chat screen show the active scene's backdrop instead.
    var scene = false
    var body: some View {
        if scene, let s = ThemeStore.shared.activeScene { SceneBackdrop(scene: s) }
        else {
            // Translucent like the terminals when the scene shows behind them.
            let store = ThemeStore.shared
            let see = store.terminalSceneMode != .off
            Rectangle().fill(Color(nsColor: WorkspaceTint.canvas(dark: scheme == .dark)).opacity(see ? store.sceneTerminalOpacity : 1))
        }
    }
}

/// An NSPopover shown from a SwiftUI view, on a fixed side (SwiftUI's popover may cover its anchor near the
/// window edge). Use `.background(PopoverAnchor(isPresented:edge:content:))`.
struct PopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var edge: NSRectEdge = .maxY
    let content: () -> Content

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}
        func popoverDidClose(_ notification: Notification) { popover = nil; onClose() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        c.onClose = { DispatchQueue.main.async { isPresented = false } }
        if isPresented, c.popover == nil, v.window != nil {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = false
            p.delegate = c
            let host = NSHostingController(rootView: content().environmentObject(AppModel.shared))
            host.sizingOptions = .preferredContentSize
            p.contentViewController = host
            c.popover = p
            p.show(relativeTo: v.bounds, of: v, preferredEdge: edge)
        } else if !isPresented, let p = c.popover {
            c.popover = nil
            p.close()
        }
    }
}
