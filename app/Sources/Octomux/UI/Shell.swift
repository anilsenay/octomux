import SwiftUI

extension Notification.Name {
    /// The layout engine's Home: put the keys in its composer (⌘T in the Agents layout).
    static let octomuxShellComposer = Notification.Name("octomux.shellComposer")
    /// Give the keys to the agent rail (↑ ↓ ↩ then move and open).
    static let octomuxRailFocus = Notification.Name("octomux.railFocus")
}

extension AppModel {
    /// How the window moves: nil = the classic window (tabs), else the engine window's tabs or its list.
    var shellNav: ShellNav? { shellTree?.nav }
    /// The window steps through a list (agents or tasks) instead of tabs.
    var shellListNav: Bool { shellNav == .agents || shellNav == .tasks }

    /// The engine window shows its Home: the window has one and is on it (a tree may have the rail but no Home).
    var shellHomeShown: Bool { shellHome && shellTree?.has(.home) == true }
    /// The window has a Home (its tree has the block).
    var shellHasHome: Bool { shellTree?.has(.home) == true }

    /// The engine window's "new" (⌘T): Home's composer, or the tasks rail's new task (a window without Home: a
    /// terminal, as in the classic window).
    func shellNew() {
        if shellNav == .agents, shellTree?.has(.home) != true { newSession(profileId: nil); return }
        if shellNav == .agents, !homeLayout.contains(.composer) { newDefaultAgent(); return }   // no composer there
        if shellNav == .agents { shellHome = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NotificationCenter.default.post(name: .octomuxShellComposer, object: nil) }
    }
    /// Home (⌘0): the Agents window's Home; in the Tasks window, the assistant.
    func shellGoHome() {
        if shellNav == .tasks { shellTaskId = nil; openAssistant(); return }   // started when there is none yet
        shellHome = true
    }

    /// The list ⌘1…9 and ⌘[ ⌘] go through, and where the window is on it.
    var shellList: [String] { shellNav == .tasks ? tasksRail.map(\.id) : railSessions.map(\.id) }
    var shellListCurrent: String? { shellNav == .tasks ? shellTaskId : (shellHomeShown ? nil : focusedSessionId) }
    func shellOpen(_ id: String) { if shellNav == .tasks { shellSelectTask(id) } else { selectSession(id) } }
}

/// Draws a layout engine tree: rows, columns and stacks of blocks. The blocks are the window's own parts (the work
/// area's terminals are the same views as in the classic window, moved, never made again), so a layout only decides
/// where they go. Agent digests are read once for every block that shows them, and only while the window shows a
/// block that needs them.
struct ShellView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var theme = ThemeStore.shared
    let tree: ShellTree
    @StateObject private var digests = AgentDigests()
    /// On screen (a start queued on appearing does nothing once the view is gone).
    @State private var appeared = false

    /// Which neighbours a block has: the classic window's insets depend on them (no gap next to a rail, no inset
    /// before the side panel).
    struct Edges { var railLeft = false; var panelRight = false }

    /// Whether a block that shows the agents' digests is on screen: the rail (unless hidden with ⌘B) or Home.
    static func wantsDigests(_ tree: ShellTree, railShown: Bool, homeShown: Bool, detailShown: Bool = false, home: HomeLayout = HomePreset.agents.layout) -> Bool {
        let b = tree.root.blocks
        // Only Home's sections that show the agents' words read them (the aquarium shows moods, from the sessions).
        let fromHome = (tree.variant(of: .home).map { HomePreset.named($0).layout } ?? home).all.contains { $0.readsDigests }
        return (b.contains(.agentRail) && railShown) || (b.contains(.home) && homeShown && fromHome)
            || (b.contains(.taskDetail) && detailShown)
    }

    private var homeShown: Bool { model.shellHome || (model.activeTab == nil && model.activeDoc == nil) }
    private var wants: Bool {
        // The task detail shows agents' words only for a picked task (its overview has none).
        Self.wantsDigests(tree, railShown: model.sidebarVisible, homeShown: homeShown, detailShown: model.rightPanelVisible && model.shellTaskId != nil,
                          home: model.homeLayout)
    }

    /// The blocks the last draw put on screen, in order (debug state; E2E checks).
    nonisolated(unsafe) static var drawn: [String] = []

    var body: some View {
        Self.drawn = []
        return node(ShellChild(node: tree.root), edges: Edges())
            .environmentObject(digests)
            // Readers only while a block that shows them is on screen, and after the first frame (the window shows the
            // layout first, then reads the agents' transcripts).
            .onAppear { appeared = true; if wants { DispatchQueue.main.async { if appeared, wants { digests.start() } } } }
            .onChange(of: wants) { _, w in if w, appeared { digests.start() } else { digests.stop() } }
            .onDisappear { appeared = false; digests.stop() }
    }

    private func node(_ k: ShellChild, edges: Edges) -> AnyView {
        let flat = T.m.inset == 0
        switch k.node {
        case .block(let b):
            Self.drawn.append(b.rawValue)
            return AnyView(block(b, variant: k.variant, edges: edges, width: cardWidth(k)))
        case .row(let kids):
            // Every child stays in the list (identity by block); one that is off (the side panel, a hidden rail) is
            // left out by its own `if`, as in the classic window. A list that changed with each toggle left the
            // shared terminal view a step behind after the window was rebuilt (a theme change).
            let shown = kids.filter(visible)
            return AnyView(HStack(spacing: 0) {
                ForEach(kids, id: \.key) { k in
                    if let i = shown.firstIndex(of: k) {
                        let left = i == 0 ? edges.railLeft : Self.flushRight(shown[i - 1].node)
                        let right = i == shown.count - 1 ? edges.panelRight : Self.isPanel(shown[i + 1].node)
                        Group {
                            if flat, Self.isPanel(k.node), i > 0 { Hairline(vertical: true) }
                            sized(node(k, edges: Edges(railLeft: left, panelRight: right)), k, horizontal: true)
                                .overlay(alignment: .trailing) { if k.node == .block(.projectTree), k.size == nil { SidebarResizeHandle() } }
                            if flat, Self.isSideRail(k.node), i < shown.count - 1 { Hairline(vertical: true) }
                        }
                        .transition(Self.isPanel(k.node) ? .move(edge: .trailing).combined(with: .opacity) : .identity)
                    }
                }
            })
        case .column(let kids):
            let shown = kids.filter(visible)
            return AnyView(VStack(spacing: 0) {
                ForEach(kids, id: \.key) { k in
                    if let i = shown.firstIndex(of: k) {
                        if flat, k.node == .block(.statusBar), i > 0, model.layout.statusBar { Hairline() }
                        sized(node(k, edges: edges), k, horizontal: false)
                        if flat, Self.isTopBar(k.node), i < shown.count - 1 { Hairline() }
                    }
                }
            })
        case .stack(let kids):
            guard let k = ShellNode.shown(kids, home: homeShown) else { return AnyView(EmptyView()) }
            return node(k, edges: edges)
        }
    }

    /// Rails drawn edge to edge (a hairline after them in the flat style), and what the block after them sits on
    /// without a gap.
    private static func isSideRail(_ n: ShellNode) -> Bool { n == .block(.agentRail) || n == .block(.projectTree) || n == .block(.tasksRail) }
    private static func flushRight(_ n: ShellNode) -> Bool { isSideRail(n) || n == .block(.sideAgent) }
    /// Cards on the right with their own inset (the block before them has none on that side).
    private static func isPanel(_ n: ShellNode) -> Bool { n == .block(.sidePanel) || n == .block(.taskDetail) }
    private static func isTopBar(_ n: ShellNode) -> Bool { n == .block(.breadcrumb) || n == .block(.tabStrip) }

    /// Blocks with their own on/off: the side panels (⌘⌥B), the rails (⌘B), the agent column and the aquarium
    /// (the layout's switches; the aquarium also not while its tab is open).
    private func visible(_ k: ShellChild) -> Bool {
        switch k.node {
        case .block(.sidePanel), .block(.taskDetail): return model.rightPanelVisible
        case .block(.agentRail), .block(.projectTree), .block(.tasksRail): return model.sidebarVisible   // ⌘B hides the rail too
        case .block(.sideAgent): return model.layout.sideChat
        case .block(.aquariumStrip):
            if case .aquarium? = model.activeDoc?.kind { return false }
            return model.layout.has("aquarium", in: .views)
        default: return true
        }
    }

    /// Cards beside the work area (side panel, task detail, agent column) take their width inside their margins, as
    /// in the classic window: a fixed width is the card's, the margins come on top.
    private static func isCard(_ b: ShellBlock) -> Bool { b == .sidePanel || b == .taskDetail || b == .sideAgent }
    private func cardWidth(_ k: ShellChild) -> CGFloat? {
        guard case .block(let b) = k.node, Self.isCard(b) else { return nil }
        switch k.size {
        case .fixed(let w)?: return w
        case nil: return b == .sidePanel ? model.rightPanelWidth : b == .sideAgent ? model.sideAgentWidth : b.defaultWidth
        default: return nil
        }
    }

    @ViewBuilder private func sized(_ v: AnyView, _ k: ShellChild, horizontal: Bool) -> some View {
        let natural: ShellSize? = {
            if cardWidth(k) != nil, horizontal { return nil }   // the card sizes itself
            if let s = k.size { return s }
            if case .block(let b) = k.node {
                if b == .sidePanel { return .fixed(model.rightPanelWidth) }
                if b == .projectTree { return .fixed(model.sidebarWidth) }
                if b == .aquariumStrip { return .fixed(b.defaultWidth + T.m.inset) }   // its card and the gap below
                if b.kind == .rail { return .fixed(b.defaultWidth) }
                if b.kind == .bar { return nil }
            }
            return .flex(1)
        }()
        switch (natural, horizontal) {
        case (.fixed(let w)?, true): v.frame(width: w)
        case (.fixed(let h)?, false): v.frame(height: h)
        case (.min(let w)?, true): v.frame(minWidth: w, maxWidth: .infinity)
        case (.min(let h)?, false): v.frame(minHeight: h, maxHeight: .infinity)
        case (.flex(let f)?, true): v.frame(minWidth: 0, maxWidth: .infinity).layoutPriority(f)
        case (.flex(let f)?, false): v.frame(minHeight: 0, maxHeight: .infinity).layoutPriority(f)
        case (nil, _): v
        }
    }

    // MARK: Blocks

    @ViewBuilder private func block(_ b: ShellBlock, variant: String?, edges: Edges, width: CGFloat?) -> some View {
        let m = T.m
        switch b {
        case .agentRail:
            AgentRail().background(sidebarBackground)
        case .projectTree:
            SidebarView(floating: false).background(sidebarBackground)
        case .tasksRail:
            TasksRail().background(sidebarBackground)
        case .tabStrip:
            TopBar()
        case .breadcrumb:
            ShellBreadcrumb()
        case .workArea:
            // The aquarium goes above the panes here only when the layout doesn't place it as a block.
            WorkAreaBlock(strip: !tree.has(.aquariumStrip))
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, edges.panelRight ? 0 : m.inset)
        case .home:
            Group {
                if let v = variant { HomePage(layout: HomePreset.named(v).layout) } else { YourHome() }
            }
                .background(CanvasBackground(scene: true))
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(m.inset == 0 ? .clear : T.border))
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, edges.panelRight ? 0 : m.inset)
        case .sidePanel, .taskDetail:
            Group { if b == .sidePanel { RightPanel() } else { TaskDetailPanel() } }
                .frame(width: width)
                .background(CanvasBackground(minOpacity: 0.9))
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                .overlay(alignment: .leading) { if b == .sidePanel { RightPanelResizeHandle() } }
                .padding(.leading, m.inset)
                .padding(.trailing, m.inset)
        case .sideAgent:
            SideAgentColumn()
                .frame(width: width)
                .overlay(alignment: .trailing) { if width == model.sideAgentWidth { SideAgentResizeHandle() } }
                .background(CanvasBackground(minOpacity: 0.9))
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, m.inset)
        case .aquariumStrip:
            AquariumView(style: .strip)
                .overlay(alignment: .top) { AquariumHeader().padding(.horizontal, 14).padding(.top, 10) }
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, edges.panelRight ? 0 : m.inset)
                .padding(.bottom, m.inset)
        case .statusBar:
            if model.layout.statusBar { StatusBar() } else { Color.clear.frame(height: m.inset) }
        }
    }

    /// The same backdrop as the classic sidebar (scene, glass or the workspace-tinted frame).
    private var sidebarBackground: AnyView {
        theme.activeScene.map { _ in AnyView(Color.clear) }
            ?? (T.m.glass ? AnyView(Color.clear) : T.m.sidebarMaterial ? AnyView(VisualEffect(material: .sidebar)) : AnyView(WorkspaceTintedFrame()))
    }
}

/// The engine window's keys: the rail's agents (or tasks) take the tab keys' place.
enum ShellKeys {
    /// ⌘1…8: the rail's nth; ⌘9: its last (as for tabs).
    static func goTo(_ n: Int, rail: [String]) -> String? {
        guard !rail.isEmpty, n >= 1 else { return nil }
        if n == 9 { return rail.last }
        return n <= rail.count ? rail[n - 1] : nil
    }

    /// Previous / next on the rail, wrapping; from Home the first (next) or the last (previous).
    static func step(_ d: Int, current: String?, rail: [String]) -> String? {
        guard !rail.isEmpty else { return nil }
        guard let c = current, let i = rail.firstIndex(of: c) else { return d > 0 ? rail.first : rail.last }
        return rail[(i + d + rail.count) % rail.count]
    }

    /// Commands of the engine window only (hidden and off in the classic window).
    static func shellOnly(_ action: Selector?) -> Bool {
        action == #selector(AppDelegate.prevAgent(_:)) || action == #selector(AppDelegate.nextAgent(_:))
    }

    /// A menu item's title in a window that moves by `nav` (nil: the item keeps its title).
    static func menuName(_ action: Selector?, tag: Int, nav: ShellNav) -> String? {
        let tasks = nav == .tasks
        switch (action, nav) {
        case (#selector(AppDelegate.newTerminal(_:)), .tabs): return "New Terminal Tab"
        case (#selector(AppDelegate.newTerminal(_:)), _): return tasks ? "New Task" : "New Session"
        case (#selector(AppDelegate.prevTab(_:)), .tabs): return "Previous Tab"
        case (#selector(AppDelegate.prevTab(_:)), _): return tasks ? "Previous Task" : "Previous Agent"
        case (#selector(AppDelegate.nextTab(_:)), .tabs): return "Next Tab"
        case (#selector(AppDelegate.nextTab(_:)), _): return tasks ? "Next Task" : "Next Agent"
        case (#selector(AppDelegate.prevAgent(_:)), _): return tasks ? "Previous Task" : "Previous Agent"
        case (#selector(AppDelegate.nextAgent(_:)), _): return tasks ? "Next Task" : "Next Agent"
        case (#selector(AppDelegate.goToTab(_:)), .tabs): return "Tab \(tag)"
        case (#selector(AppDelegate.goToTab(_:)), _): return tasks ? "Task \(tag)" : "Agent \(tag)"
        case (#selector(AppDelegate.showMain(_:)), .tabs): return "Main Window"
        case (#selector(AppDelegate.showMain(_:)), _): return tasks ? "Assistant" : "Home"
        default: return nil
        }
    }
}

/// The engine's blocks drawn once off screen a few seconds after launch, while idle: the first switch to a layout
/// then doesn't pay for loading their code and SwiftUI's type data (the first Tasks switch after launch took
/// 250–300 ms, later ones ~200). Nothing is started: no digests read, no key monitors (the rail's keys are off).
enum ShellPrewarm {
    nonisolated(unsafe) static var done = false

    static func run(model: AppModel = .shared) {
        guard !done else { return }
        done = true
        let digests = AgentDigests()
        let root = HStack(spacing: 0) {
            AgentRail()
            TasksRail()
            VStack(spacing: 0) { ShellBreadcrumb(); HomePage(layout: HomePreset.agents.layout); HomePage(layout: HomePreset.workday.layout) }
            TaskDetailPanel()
            // Not the side agent: its chat is live (it attaches to a session and takes pending text when it appears).
        }
        .environmentObject(model)
        .environmentObject(digests)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(x: 0, y: 0, width: 1600, height: 820)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
    }
}

/// A chevron after "Home": Octomux's panel with the presets (the one in use checked, "changed" when you customized
/// it), Customize and Reset.
struct HomeMenuButton: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    @State private var hover = false
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "chevron.down").font(T.icon(8, .semibold)).foregroundStyle(T.text3)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous).fill(open || hover ? T.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { hover = $0 }
        .help("Home: presets and Customize")
        .floatingPanel(isPresented: $open) { HomeMenuPanel() }
        .debugOpens("home_menu", $open)
    }
}

struct HomeMenuPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav = PanelNav()

    /// The panel's rows, in order: the presets, Customize, then Reset when the preset was changed.
    enum Row: Hashable { case preset(HomePreset), customize, reset }
    static func rows(_ h: HomeSetting) -> [Row] { HomePreset.allCases.map(Row.preset) + [.customize] + (h.changed ? [.reset] : []) }

    var body: some View {
        let h = model.homeSetting
        let rows = Self.rows(h)
        PanelCard(width: 350) {
            PanelSectionTitle("Home")
            ForEach(Array(rows.enumerated()), id: \.element) { i, r in
                if r == .customize { PanelDivider() }
                row(r, h, highlighted: nav.index == i)
                    .onHover { on in if on { nav.index = i } else if nav.index == i { nav.index = nil } }
                    .onTapGesture { nav.run(i) }
                    .panelPointer()
            }
        }
        .onAppear {
            nav.set(rows.map { r in { run(r) } })
            nav.attach()
        }
    }

    @ViewBuilder private func row(_ r: Row, _ h: HomeSetting, highlighted: Bool) -> some View {
        switch r {
        case .preset(let p):
            let mine = h.preset == p
            PanelRow(title: p.title + (mine && h.changed ? " (changed)" : ""), detail: p.summary, checked: mine, highlighted: highlighted) {
                Image(systemName: p.icon).font(T.icon(11)).foregroundStyle(T.text3)
            }
        case .customize:
            PanelRow(title: "Customize this Home…", highlighted: highlighted) {
                Image(systemName: "slider.horizontal.3").font(T.icon(11)).foregroundStyle(T.text3)
            }
        case .reset:
            PanelRow(title: "Reset to \(h.preset.title)", highlighted: highlighted) {
                Image(systemName: "arrow.uturn.backward").font(T.icon(11)).foregroundStyle(T.text3)
            }
        }
    }

    private func run(_ r: Row) {
        switch r {
        case .preset(let p): model.chooseHome(p)
        case .customize: model.customizeHome()
        case .reset: model.chooseHome(model.homeSetting.preset)
        }
    }
}

extension AppModel {
    /// Home becomes a preset as it ships, and the window goes to Home.
    func chooseHome(_ p: HomePreset) {
        HomeCustomizeState.shared.hidden = []
        chooseHomePreset(p)
        showHome()
    }
    /// Customize your Home (on Home).
    func customizeHome() {
        showHome()
        HomeCustomizeState.shared.start()
    }
    /// The window shows Home: the Agents layout's, else (step 5) the Home tab.
    func showHome() {
        if shellNav == .agents, shellHasHome { shellHome = true }
    }
}
