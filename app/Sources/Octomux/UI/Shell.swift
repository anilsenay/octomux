import SwiftUI

extension Notification.Name {
    /// The layout engine's Home: put the keys in its composer (⌘T in the Agents layout).
    static let octomuxShellComposer = Notification.Name("octomux.shellComposer")
}

extension AppModel {
    /// The engine window's "new": its Home, with the composer ready (⌘T).
    func shellNew() {
        shellHome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NotificationCenter.default.post(name: .octomuxShellComposer, object: nil) }
    }
    func shellGoHome() { shellHome = true }
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

    /// Which neighbours a block has: the classic window's insets depend on them (no gap next to a rail, no inset
    /// before the side panel).
    struct Edges { var railLeft = false; var panelRight = false }

    var body: some View {
        node(tree.root, edges: Edges())
            .environmentObject(digests)
            .onAppear { if tree.root.blocks.contains(.agentRail) || tree.root.blocks.contains(.home) { digests.start() } }
            .onDisappear { digests.stop() }
    }

    private func node(_ n: ShellNode, edges: Edges) -> AnyView {
        let flat = T.m.inset == 0
        switch n {
        case .block(let b):
            return AnyView(block(b, edges: edges))
        case .row(let kids):
            let shown = kids.filter(visible)
            return AnyView(HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, k in
                    let left = i == 0 ? edges.railLeft : Self.isSideRail(shown[i - 1].node)
                    let right = i == shown.count - 1 ? edges.panelRight : shown[i + 1].node == .block(.sidePanel)
                    sized(node(k.node, edges: Edges(railLeft: left, panelRight: right)), k, horizontal: true)
                    if flat, Self.isSideRail(k.node), i < shown.count - 1 { Hairline(vertical: true) }
                }
            })
        case .column(let kids):
            let shown = kids.filter(visible)
            return AnyView(VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, k in
                    if flat, k.node == .block(.statusBar), i > 0 { Hairline() }
                    sized(node(k.node, edges: edges), k, horizontal: false)
                    if flat, Self.isTopBar(k.node), i < shown.count - 1 { Hairline() }
                }
            })
        case .stack(let kids):
            let home = model.shellHome || (model.activeTab == nil && model.activeDoc == nil)
            guard let k = ShellNode.shown(kids, home: home) else { return AnyView(EmptyView()) }
            return node(k.node, edges: edges)
        }
    }

    private static func isSideRail(_ n: ShellNode) -> Bool { n == .block(.agentRail) || n == .block(.projectTree) }
    private static func isTopBar(_ n: ShellNode) -> Bool { n == .block(.breadcrumb) || n == .block(.tabStrip) }

    /// Blocks with their own on/off: the side panel (⌘⌥B) and the status bar (the layout's switch).
    private func visible(_ k: ShellChild) -> Bool {
        switch k.node {
        case .block(.sidePanel): return model.rightPanelVisible
        default: return true
        }
    }

    @ViewBuilder private func sized(_ v: AnyView, _ k: ShellChild, horizontal: Bool) -> some View {
        let natural: ShellSize? = {
            if let s = k.size { return s }
            if case .block(let b) = k.node {
                if b == .sidePanel { return .fixed(model.rightPanelWidth) }
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

    @ViewBuilder private func block(_ b: ShellBlock, edges: Edges) -> some View {
        let m = T.m
        switch b {
        case .agentRail:
            AgentRail().background(sidebarBackground)
        case .projectTree:
            SidebarView(floating: false).background(sidebarBackground)
        case .tabStrip:
            TopBar()
        case .breadcrumb:
            ShellBreadcrumb()
        case .workArea:
            WorkAreaBlock()
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, edges.panelRight ? 0 : m.inset)
        case .home:
            ShellHome()
                .background(CanvasBackground(scene: true))
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(m.inset == 0 ? .clear : T.border))
                .padding(.leading, edges.railLeft ? 0 : m.inset)
                .padding(.trailing, edges.panelRight ? 0 : m.inset)
        case .sidePanel:
            RightPanel()
                .background(CanvasBackground(minOpacity: 0.9))
                .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                .overlay(alignment: .leading) { RightPanelResizeHandle() }
                .padding(.leading, m.inset)
                .padding(.trailing, m.inset)
                .transition(.move(edge: .trailing).combined(with: .opacity))
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
