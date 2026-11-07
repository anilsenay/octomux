import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        // The layout engine draws the Agents layout; every other layout is the classic window below.
        Group {
            if let tree = model.shellTree { ShellView(tree: tree) } else { classicWindow }
        }
        // Stopped (Settings → Stop Octomux): the window stays, blurred and out of reach, behind a Start card.
        .blur(radius: model.power == .running || model.stopFalling ? 0 : 18)
        .allowsHitTesting(model.power == .running)
        .overlay { if model.power != .running && !model.stopFalling { StoppedOverlay() } }
        .overlay(alignment: .top) { if model.power == .running { DisconnectBanner().padding(.top, T.m.topH + 6) } }
        // Until the daemon's first catalog arrives: the app icon, not an empty window.
        .overlay { if !model.loaded && model.lastError == nil { LaunchCover().transition(.opacity) } }
        // App update offer / download progress / "Relaunch Now", above the status bar.
        .overlay(alignment: .bottomTrailing) { UpdateToast().padding(.trailing, 14).padding(.bottom, 34) }
        .overlay(alignment: .bottom) { HintToast().padding(.bottom, 34) }
        .onChange(of: model.power) { _, p in if p == .running { TerminalHost.shared.render(force: true); TerminalHost.shared.renderDock(force: true) } }
        .background(rootBackground)
        .overlay(alignment: .topLeading) { peekStrip }
        .onChange(of: model.sidebarPeek) { SidebarPeek.shared.update() }
        .onChange(of: model.sidebarVisible) { SidebarPeek.shared.update() }
        .overlay(alignment: .topLeading) {
            TopLeftControls().opacity(model.power == .running ? 1 : 0.35).allowsHitTesting(model.power == .running)
        }
        .foregroundStyle(T.text)
        .tint(T.accent)
        .overlay {
            if model.paletteVisible { CommandPalette() }
        }
        .overlay { TabSwitcherOverlay() }
        .sheet(item: $model.newWorktreeFor) { p in
            NewWorktreeSheet(project: p) { model.newWorktreeFor = nil }.environmentObject(model)
        }
        .overlay(alignment: .top) {
            if let err = model.lastError {
                ErrorBanner(text: err) { model.lastError = nil }.padding(.top, 40)
            }
        }
        .ignoresSafeArea()
        .id(theme.revision)
    }

    /// The classic window: sidebar, top bar with tabs, work area, right panel, status bar (Terminal and every layout
    /// the engine doesn't draw).
    @ViewBuilder private var classicWindow: some View {
        let m = T.m
        let flat = m.inset == 0
        HStack(spacing: 0) {
            if model.sidebarVisible {
                sidebar()
                    .frame(width: model.sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizeHandle() }
                if flat { Hairline(vertical: true) }
            }
            // Top bar and status bar span the window (the right panel opens below the top bar, so the
            // bar's tools stay at the right edge).
            VStack(spacing: 0) {
                TopBar()
                if flat { Hairline() }
                HStack(spacing: 0) {
                    if model.layout.sideChat {
                        SideAgentColumn()
                            .frame(width: 380)
                            .background(CanvasBackground(minOpacity: 0.9))
                            .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                            .padding(.leading, model.sidebarVisible ? 0 : m.inset)
                            .padding(.trailing, m.inset)
                    }
                    WorkAreaBlock()
                        .padding(.trailing, model.rightPanelVisible ? 0 : m.inset)
                        .padding(.leading, model.sidebarVisible || model.layout.sideChat ? 0 : m.inset)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    if model.rightPanelVisible {
                        if flat { Hairline(vertical: true) }
                        RightPanel()
                            .frame(width: model.rightPanelWidth)
                            .background(CanvasBackground(minOpacity: 0.9))
                            .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                            .overlay(alignment: .leading) { RightPanelResizeHandle() }
                            .padding(.leading, m.inset)
                            .padding(.trailing, m.inset)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if model.layout.statusBar {
                    if flat { Hairline() }
                    StatusBar()
                } else {
                    Color.clear.frame(height: m.inset)   // the cards keep their margin at the window's bottom
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    private func sidebar(floating: Bool = false) -> some View {
        SidebarView(floating: floating)
            // With a scene the root background already carries the chrome veil (one layer for sidebar and bars).
            .background(theme.activeScene.map { _ in AnyView(Color.clear) }
                        ?? (T.m.glass ? AnyView(Color.clear) : T.m.sidebarMaterial ? AnyView(VisualEffect(material: .sidebar)) : AnyView(WorkspaceTintedFrame())))
    }

    /// Behind everything: the scene's live backdrop, the window glass, or the workspace-tinted frame.
    private var rootBackground: AnyView {
        // The veil spans the whole window: on the sidebar only, it ended in a hard edge in the top bar.
        if let s = theme.activeScene {
            let backdrop = SceneBackdrop(scene: s, textColumn: model.sidebarVisible ? model.sidebarWidth : 0)
                .overlay(alignment: .bottomLeading) {
                    // The Aquarium scene: the agents' octopuses behind the sidebar.
                    if s.kind == .aquarium { AquariumView(style: .backdrop).frame(width: max(model.sidebarVisible ? model.sidebarWidth : 260, 200)).frame(maxHeight: 360) }
                }
            return AnyView(backdrop.overlay(Color(nsColor: s.colors.frame).opacity(s.dark ? 0.4 : 0.35)))
        }
        return T.m.glass ? AnyView(VisualEffect(material: .underWindowBackground)) : AnyView(WorkspaceTintedFrame())
    }

    /// Hidden sidebar: a strip at the left edge reveals it floating over the content.
    @ViewBuilder private var peekStrip: some View {
        if !model.sidebarVisible && !model.sidebarPeek {
            Color.clear.frame(width: 8).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { model.sidebarPeek = true } }
                .padding(.top, T.m.topH)
        }
    }

}

/// The hidden sidebar revealed from the left edge. It lives in a borderless child window: a SwiftUI layer
/// over the terminals' Metal surfaces makes them stop drawing, a separate window does not.
final class SidebarPeek {
    static let shared = SidebarPeek()
    private var panel: NSPanel?

    func update() {
        let m = AppModel.shared
        guard let win = (NSApp.delegate as? AppDelegate)?.mainWindow, !m.sidebarVisible, m.sidebarPeek else {
            hide(); return
        }
        let top = T.m.topH - 6
        let frame = NSRect(x: win.frame.minX + 6, y: win.frame.minY + 8,
                           width: m.sidebarWidth, height: win.frame.height - top - 8)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.becomesKeyOnlyIfNeeded = true
            let host = NSHostingView(rootView: PeekSidebarView().environmentObject(m))
            host.sizingOptions = []   // the panel keeps the frame we give it
            p.contentView = host
            panel = p
        }
        guard let p = panel else { return }
        p.setFrame(frame, display: true)
        if p.parent == nil { win.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }
}

struct PeekSidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        SidebarView(floating: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(T.m.glass || T.m.sidebarMaterial ? AnyView(VisualEffect(material: .popover)) : AnyView(WorkspaceTintedFrame()))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.border))
            .foregroundStyle(T.text)
            .tint(T.accent)
            .onHover { if !$0 { model.sidebarPeek = false } }
            .id(theme.revision)
    }
}

/// Sidebar toggle + search, next to the traffic lights; stays put whether the sidebar is shown or not.
struct TopLeftControls: View {
    @EnvironmentObject var model: AppModel
    static let width: CGFloat = 78 + 88

    var body: some View {
        HStack(spacing: 2) {
            Button { withAnimation(.easeOut(duration: 0.18)) { model.toggleSidebar() } } label: {
                Image(systemName: "sidebar.left").font(.system(size: T.k * 13))
            }
            .buttonStyle(IconButtonStyle(size: 26)).help("Toggle Sidebar (⌘B)")
            // With the sidebar shown, Search is its first row.
            if !model.sidebarVisible {
                Button { model.paletteVisible = true } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: T.k * 13))
                }
                .buttonStyle(IconButtonStyle(size: 26)).help("Search (\(KeyBindings.shared.current("cmd.command-palette")?.display ?? "⌘K"))")
            }
            NotificationBell()
        }
        .padding(.leading, 78)
        .frame(height: 30)
        .padding(.top, 1)
    }
}

/// Drag the sidebar's right edge to resize it.
struct SidebarResizeHandle: View {
    @EnvironmentObject var model: AppModel
    @State private var start: CGFloat?
    @State private var hover = false

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 6)
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = model.sidebarWidth }
                    model.sidebarWidth = min(440, max(190, (start ?? 252) + v.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: 3)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Octomux stopped from Settings: Start brings the daemon and the tabs back.
struct StoppedOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(ThemeStore.shared.isDark ? 0.25 : 0.08).ignoresSafeArea()
            VStack(spacing: 12) {
                switch model.power {
                case .stopping, .starting:
                    ProgressView().controlSize(.small)
                    Text(model.power == .stopping ? "Stopping Octomux…" : "Starting Octomux…").font(.system(size: T.k * 14, weight: .semibold))
                    Text(model.power == .stopping ? "Ending the programs in your tabs." : "Bringing your tabs back.")
                        .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                default:
                    Image(systemName: "stop.circle").font(.system(size: T.k * 30, weight: .light)).foregroundStyle(T.text2)
                    Text("Octomux is stopped").font(.system(size: T.k * 15, weight: .semibold))
                    Text("Start it to bring your tabs back. Agents pick up their conversations.")
                        .font(.system(size: T.k * 12)).foregroundStyle(T.text2).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button("Start Octomux") { model.startOctomux() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        Button("Open Logs") { NSWorkspace.shared.open(Paths.home.appendingPathComponent("logs")) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 380)
        }
        .transition(.opacity)
    }
}

/// The daemon has been unreachable for a few seconds (it can't start, or a remote host is cut off). Open
/// terminals keep working (they talk to their sessions directly); lists, new tabs and states don't.
/// Covers the window while Octomux connects to its daemon at launch. Appears after a moment (a fast start
/// shows nothing), and explains itself if it takes long.
struct LaunchCover: View {
    @State private var shown = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let t = ctx.date.timeIntervalSince(shown)
            ZStack {
                Rectangle().fill(T.frame)
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(t > 8 ? "Still starting Octomux's background service…" : "Starting Octomux…")
                            .font(T.body).foregroundStyle(T.text2)
                    }
                    if t > 15 {
                        Button("Open Logs") { NSWorkspace.shared.open(Paths.home.appendingPathComponent("logs")) }
                            .controlSize(.small)
                    }
                }
                .opacity(t > 0.3 ? 1 : 0)
            }
        }
        .ignoresSafeArea()
    }
}

struct DisconnectBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let since = model.disconnectedSince, ctx.date.timeIntervalSince(since) >= 5 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(model.host.isRemote ? "Connection to \(model.host.name) lost. Reconnecting…"
                         : "Can't reach the Octomux daemon. Open terminals still work; new tabs and agent states don't.")
                        .font(.system(size: T.k * 12)).lineLimit(2)
                    if !model.host.isRemote {
                        Button("Retry") { DispatchQueue.global().async { _ = DaemonClient.ensureDaemon() } }.controlSize(.small)
                        Button("Open Logs") { NSWorkspace.shared.open(Paths.home.appendingPathComponent("logs")) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 6)
            }
        }
    }
}

/// A one-time tip above the status bar (`AppModel.hint`).
struct HintToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if case .closedTabKeepsSessions(let title) = model.hint {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sidebar.left").font(.system(size: T.k * 13)).foregroundStyle(T.accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(TabChip.clip(title, 32))” is still running").font(T.headline).foregroundStyle(T.text)
                    Text("Closing a tab keeps its sessions in the sidebar. Click one to open it again; Stop and Remove there end it.")
                        .font(T.caption).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Got It") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                        Button("Change in Settings…") {
                            dismiss()
                            SettingsWindow.show(section: .sessions)
                            SettingsWindow.selection.open(.sessions, row: "Closing a terminal tab")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func dismiss() { withAnimation(.easeOut(duration: 0.2)) { model.hint = nil } }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber)
            Text(text).font(.system(size: T.k * 12)).lineLimit(3)
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { dismiss() } }
    }
}

/// Tabs of the current project + new-session controls.
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        GeometryReader { geo in content(width: geo.size.width) }
            .frame(height: T.m.topH)
    }

    /// Fits the bar into `width`: tools on the right are fixed, tabs share the rest (overflow → "+N").
    private func layout(width: CGFloat) -> (chars: Int, compact: Bool, visible: Int, tabW: CGFloat) {
        let leading: CGFloat = model.sidebarVisible ? 8 : TopLeftControls.width + 8
        let compact = width < 820
        let tools: CGFloat = compact ? 130 : 250          // diff, open in, commit, panel
        let newBtn: CGFloat = 52
        let avail = max(120, width - leading - tools - newBtn - 30)
        let tabMin: CGFloat = 140, tabMax: CGFloat = 220
        let pinned = model.currentTabs.filter(model.isPinned).count
        let avail2 = pinned > 0 ? avail - CGFloat(pinned) * (PinnedTabChip.width + 2) - 20 : avail
        let count = model.currentTabs.count - pinned + model.currentDocs.count
        let visible = max(1, min(max(count, 1), Int(max(avail2, tabMin) / tabMin)))
        let tabW = max(tabMin, min(tabMax, (max(avail2, tabMin) - (visible < count ? 44 : 0)) / CGFloat(max(1, visible))))
        return (max(4, Int((tabW - 60) / 7)), compact, visible, tabW)
    }

    private func content(width: CGFloat) -> some View {
        let m = T.m
        let fit = layout(width: width)
        return HStack(spacing: 6) {
            if !model.sidebarVisible {
                WindowDragArea().frame(width: TopLeftControls.width)
            }
            let docs = model.currentDocs
            let pinnedTabs = Array(model.currentTabs.enumerated()).filter { model.isPinned($0.element) }
            if !pinnedTabs.isEmpty {
                // Pinned tabs: icons only, in their own little group, before the others.
                HStack(spacing: 2) {
                    ForEach(pinnedTabs, id: \.element.id) { i, t in
                        PinnedTabChip(tab: t, index: i)
                            .reorderable("tab", id: t.id) { model.moveTab($0, to: $1) }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.hover.opacity(0.7)))
                .fixedSize()
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                Rectangle().fill(T.border).frame(width: 1, height: 16).padding(.horizontal, 2)
            }
            let unpinnedCount = model.currentTabs.count - pinnedTabs.count
            let docSlots = docs.isEmpty ? 0 : max(1, min(docs.count, fit.visible - min(unpinnedCount, 1)))
            let shown = visibleTabs(max(1, fit.visible - docSlots))
            let shownDocs = visibleDocs(docSlots)
            HStack(spacing: m.tabStyle == .underline ? 0 : 4) {
                ForEach(shown, id: \.1.id) { i, t in
                    TabChip(tab: t, index: i, maxChars: fit.chars, width: m.tabStyle == .underline ? nil : fit.tabW)
                        .reorderable("tab", id: t.id) { model.moveTab($0, to: $1) }
                }
                ForEach(shownDocs) { d in
                    DocChip(doc: d, maxChars: fit.chars, width: m.tabStyle == .underline ? nil : fit.tabW)
                        .reorderable("doc", id: d.id) { model.moveDoc($0, before: $1) }
                }
                let hidden = Array(model.currentTabs.enumerated()).filter { e in !model.isPinned(e.element) && !shown.contains { $0.1.id == e.element.id } }
                let hiddenDocs = docs.filter { d in !shownDocs.contains { $0.id == d.id } }
                if !hidden.isEmpty || !hiddenDocs.isEmpty {
                    Menu {
                        ForEach(hidden, id: \.element.id) { i, t in
                            let lead = model.session(t.activeSessionId ?? t.layout.sessions.first)
                            Button((i < 9 ? "⌘\(i + 1)  " : "") + (lead?.displayTitle ?? "Tab")) { model.selectTab(t.id) }
                        }
                        if !hidden.isEmpty && !hiddenDocs.isEmpty { Divider() }
                        ForEach(hiddenDocs) { d in Button(d.title) { model.selectDoc(d.id) } }
                    } label: {
                        Text("+\(hidden.count + hiddenDocs.count)").font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(T.text2)
                            .padding(.horizontal, 6).frame(height: m.tabH).contentShape(Rectangle())
                    }
                    .plainMenu().fixedSize()
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.hover))
                    .pointerCursor()
                    .help("\(hidden.count + hiddenDocs.count) more tabs")
                }
            }
            .onDrop(of: [.text], delegate: PaneToTabDrop(model: model))
            .padding(m.tabStyle == .segment ? 3 : 0)
            .background(m.tabStyle == .segment && !(model.currentTabs.isEmpty && docs.isEmpty) ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.hover) : nil)
            .fixedSize()
            if model.currentProject != nil { NewSessionButton() }
            // Only empty top-bar space moves the window; a window-wide drag view under the tabs would
            // swallow their mouse-down and drag the window instead of the tab.
            WindowDragArea().frame(minWidth: 8, maxWidth: .infinity)
            HStack(spacing: 4) {
                // The layout's buttons (Terminal: diff, Open in, git, right panel); diff and Open in only when wide.
                ForEach(model.layout.shown(.topBar), id: \.self) { id in toolItem(id, compact: fit.compact) }
            }
            .fixedSize()
        }
        .font(.system(size: T.k * 13))
        .foregroundStyle(T.text2)
        .padding(.leading, model.sidebarVisible ? 8 : 0)
        .padding(.trailing, 10)
        .frame(width: width, height: m.topH, alignment: .leading)
        .clipped()
    }

    private func toolItem(_ id: String, compact: Bool) -> some View { TopBarTool(id: id, compact: compact) }
}

/// One of the top bar's project-wide buttons (diff, Open in, git, right panel); the layout engine's breadcrumb uses
/// them too.
struct TopBarTool: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared
    let id: String
    let compact: Bool

    var body: some View {
        switch id {
        case "diff":
                if !compact {
                    if let wp = model.currentWorkPath, let stat = git.diffStat(for: wp), stat.files > 0 {
                        Button { model.toggleChangesPanel() } label: {
                            HStack(spacing: 4) {
                                Text("+\(stat.added)").foregroundStyle(T.diffAdd)
                                Text("−\(stat.removed)").foregroundStyle(T.diffDel)
                            }
                            .font(T.mono(12, .medium))
                        }
                        .buttonStyle(ChromeButtonStyle()).help("\(stat.files) changed files")
                    }
                }
        case "openIn":
                if !compact, let p = model.currentProject, !model.host(for: p.id).isRemote {
                    OpenInButton(path: p.path)
                }
        // Split, chat and browser live in each pane's header now; the bar keeps project-wide actions.
        case "git": if model.currentWorkPath != nil { TopBarCommitButton() }
        case "rightPanel":
                Button { model.toggleRightPanel() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(ChromeButtonStyle(active: model.rightPanelVisible)).help("Files / Changes / Sessions (⌘⌥B)")
        default: EmptyView()
        }
    }
}

extension TopBar {
    /// The first `n` tabs, swapping in the active tab if it would be hidden.
    /// The first `n` unpinned tabs (pinned ones have their own group), keeping their ⌘ numbers.
    func visibleTabs(_ n: Int) -> [(Int, Tab)] {
        let all = Array(model.currentTabs.enumerated()).map { ($0.offset, $0.element) }.filter { !model.isPinned($0.1) }
        guard all.count > n else { return all }
        var shown = Array(all.prefix(n))
        if let active = all.first(where: { $0.1.id == model.activeTabId }), !shown.contains(where: { $0.1.id == active.1.id }) {
            shown[shown.count - 1] = active
        }
        return shown
    }

    /// The first `n` doc tabs, swapping in the active one if it would be hidden.
    func visibleDocs(_ n: Int) -> [DocTab] {
        let all = model.currentDocs
        guard all.count > n else { return all }
        var shown = Array(all.prefix(n))
        if n > 0, let a = model.activeDoc, !shown.contains(where: { $0.id == a.id }) { shown[n - 1] = a }
        return shown
    }
}

/// A file / changes / commit tab (app-side; not in the sidebar).
struct DocChip: View {
    @EnvironmentObject var model: AppModel
    let doc: DocTab
    var maxChars = 24
    var width: CGFloat? = nil
    @State private var hover = false

    var body: some View {
        let m = T.m
        let selected = model.activeDocId == doc.id && model.activeDoc != nil
        HStack(spacing: 7) {
            Group {
                if case .file(let rel) = doc.kind {
                    FileIcon(name: (rel as NSString).lastPathComponent, size: 10.5)
                } else {
                    Image(systemName: doc.icon).font(.system(size: T.k * 11, weight: .medium)).foregroundStyle(selected ? T.text2 : T.text3)
                }
            }
            .opacity(selected ? 1 : 0.6)
            if width != nil {
                Text(doc.title).italic(isPreviewLike).lineLimit(1).truncationMode(.middle)
            } else {
                Text(TabChip.clip(doc.title, maxChars)).italic(doc.isPreview).lineLimit(1).fixedSize()
            }
            if width != nil { Spacer(minLength: 0) }
            Button { model.closeDoc(doc.id) } label: {
                Image(systemName: "xmark").font(.system(size: T.k * 8, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 16)).opacity(hover ? 1 : 0)
        }
        .font(.system(size: T.k * 13, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? T.text : hover ? T.text2 : T.text3.opacity(0.85))
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(width: width, height: m.tabStyle == .underline ? m.topH : m.tabH)
        .background(TabChip.chipBackground(selected: selected, hover: hover))
        .overlay(alignment: .bottom) {
            if m.tabStyle == .underline { Rectangle().fill(selected ? T.accent : .clear).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectDoc(doc.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.keepDoc(doc.id) })
        .overlay(MiddleClick { model.closeDoc(doc.id) })
        .contextMenu {
            Button("Close Tab") { model.closeDoc(doc.id) }
            if doc.isPreview { Button("Keep Open") { model.keepDoc(doc.id) } }
            Divider()
            Button("Close Other Tabs") { model.closeDocs(model.docs(.others, of: doc.id)) }.disabled(model.docs(.others, of: doc.id).isEmpty)
            Button("Close Tabs to the Right") { model.closeDocs(model.docs(.right, of: doc.id)) }.disabled(model.docs(.right, of: doc.id).isEmpty)
            Button("Close Tabs to the Left") { model.closeDocs(model.docs(.left, of: doc.id)) }.disabled(model.docs(.left, of: doc.id).isEmpty)
            Button("Close All File Tabs") { model.closeDocs(model.currentDocs) }
            if case .file(let rel) = doc.kind {
                Divider()
                Button("Copy Path") { copy((doc.workPath as NSString).appendingPathComponent(rel)) }
                Button("Copy Relative Path") { copy(rel) }
                if !model.host(forPath: doc.workPath).0.isRemote {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (doc.workPath as NSString).appendingPathComponent(rel))]) }
                }
            }
        }
        .help(helpText)
    }

    private var isPreviewLike: Bool { if doc.isPreview { return true }; if case .commit = doc.kind { return true }; return false }

    private var helpText: String {
        switch doc.kind {
        case .file(let rel): return doc.isPreview ? rel + " (preview: the next file you open replaces it; double-click to keep it)" : rel
        case .changes: return "Uncommitted changes"
        case .commit(let h, let s): return "\(h.prefix(8)) \(s)"
        case .newChat: return "New chat session"
        case .inbox: return "Pull requests, reviews and issues"
        case .agents: return "Every agent: what it did, what it waits for"
        case .workday: return "Your day: who needs you, what happened, your pull requests and issues"
        case .aquarium: return "Every agent as an octopus: swimming while it works, ! when it waits"
        }
    }
}

struct TabChip: View {
    @EnvironmentObject var model: AppModel
    let tab: Tab
    let index: Int
    var maxChars = 24
    var width: CGFloat? = nil
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = T.m
        let selected = tab.id == model.activeTabId && model.activeDoc == nil
        let ids = tab.layout.sessions
        let lead = model.session(tab.activeSessionId ?? ids.first)
        HStack(spacing: 7) {
            if let lead {
                let panes = ids.compactMap { model.session($0) }
                if panes.count > 1 {
                    PaneStackFan(sessions: panes, front: lead.id, size: 11, dim: !selected)
                } else {
                    PaneStackIcon(items: paneStackItems(ids, front: lead.id, model: model), size: 11)
                        .opacity(selected ? 1 : 0.55).saturation(selected ? 1 : 0.5)
                }
            }
            // The title follows the front pane and slides in when it changes (split tabs).
            Group {
                if width != nil {
                    Text(lead?.displayTitle ?? "Tab").lineLimit(1).truncationMode(.tail)
                } else {
                    Text(Self.clip(lead?.displayTitle ?? "Tab", maxChars)).lineLimit(1).fixedSize()
                }
            }
            .id(lead?.id)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            .animation(.easeOut(duration: 0.2), value: lead?.id)
            if width != nil { Spacer(minLength: 0) }
            if let s = ids.compactMap({ model.session($0) }).first(where: { $0.activity == .needsInput || $0.activity == .working || $0.unread }), !hover {
                Group {
                    if s.activity == .needsInput { Circle().fill(T.amber).frame(width: 6, height: 6) }
                    else if s.activity == .working { Circle().fill(T.accent).frame(width: 6, height: 6) }
                    else { Circle().fill(T.green).frame(width: 6, height: 6) }
                }
                .help("\(s.displayTitle): \(activityHelp(s))")
            }
            Button { model.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: T.k * 8, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 16)).opacity(hover ? 1 : 0)
        }
        .font(.system(size: T.k * 13, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? T.text : hover ? T.text2 : T.text3.opacity(0.85))
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(width: width, height: m.tabStyle == .underline ? m.topH : m.tabH)
        .background(background(selected: selected))
        .overlay(alignment: .bottom) {
            if m.tabStyle == .underline {
                Rectangle().fill(selected ? T.accent : .clear).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectTab(tab.id) }
        .overlay(MiddleClick { model.closeTab(tab.id) })
        .contextMenu { TabMenu(tab: tab) }
        .help(index < 9 ? "⌘\(index + 1)" : "")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(1, n - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func background(selected: Bool) -> some View { Self.chipBackground(selected: selected, hover: hover) }

    @ViewBuilder static func chipBackground(selected: Bool, hover: Bool) -> some View {
        let m = T.m
        switch m.tabStyle {
        case .underline:
            Rectangle().fill(hover && !selected ? T.hover : .clear)
        case .pill, .segment:
            let dark = ThemeStore.shared.isDark
            RoundedRectangle(cornerRadius: R.md, style: .continuous)
                .fill(selected ? (dark ? Color.white.opacity(0.13) : T.raised)
                      : hover ? (dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
                      : (dark ? Color.white.opacity(0.03) : Color.black.opacity(0.03)))
                .shadow(color: .black.opacity(selected && !dark ? 0.14 : 0), radius: 1.5, y: 1)
        }
    }
}

/// Menu items for starting a session: Terminal, then agents (profiles of one kind in a submenu).
struct NewSessionItems: View {
    @EnvironmentObject var model: AppModel
    let projectId: String?
    var remember = false

    var body: some View {
        Button { model.openNewChat(projectId: projectId) } label: { Label("New Chat…", systemImage: "bubble.left.and.text.bubble.right") }
        Divider()
        Button { start(nil) } label: { Label("Terminal", systemImage: "terminal") }
        Divider()
        ForEach(model.profileGroups(forProject: projectId), id: \.first!.id) { group in
            if group.count == 1, let p = group.first {
                Button { start(p.id) } label: { Text(p.name) }
            } else {
                Menu(group.first!.name) {
                    ForEach(group) { p in Button(p.name) { start(p.id) } }
                }
            }
        }
        Divider()
        Button("Manage Agents…") { SettingsWindow.show(section: .agents) }
    }

    private func start(_ profileId: String?) {
        if remember { model.lastNewSessionProfile = profileId }
        model.newSession(profileId: profileId, projectId: projectId)
    }
}

/// AppKit version of `NewSessionItems` (for `PopupMenuButton`).
func newSessionMenu(model: AppModel, projectId: String?, remember: Bool) -> NSMenu {
    let menu = NSMenu()
    func start(_ id: String?) {
        if remember { model.lastNewSessionProfile = id }
        model.newSession(profileId: id, projectId: projectId)
    }
    let chat = ClosureMenuItem("New Chat…", image: NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)) {
        model.openNewChat(projectId: projectId)
    }
    chat.keyEquivalent = "n"; chat.keyEquivalentModifierMask = [.command]
    menu.addItem(chat)
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem("Terminal", image: NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)) { start(nil) })
    menu.addItem(.separator())
    for group in model.profileGroups(forProject: projectId) {
        let icon = BrandIcons.image(group[0].icon).map { img -> NSImage in
            let i = img.copy() as! NSImage; i.size = NSSize(width: 14, height: 14); return i
        }
        if group.count == 1 {
            menu.addItem(ClosureMenuItem(group[0].name, image: icon) { start(group[0].id) })
        } else {
            let parent = NSMenuItem(title: group[0].name, action: nil, keyEquivalent: "")
            parent.image = icon
            let sub = NSMenu()
            for p in group { sub.addItem(ClosureMenuItem(p.name) { start(p.id) }) }
            parent.submenu = sub
            menu.addItem(parent)
        }
    }
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem("Manage Agents…") { SettingsWindow.show(section: .agents) })
    return menu
}

/// Tab bar: one button that starts the last used kind of session, with a menu for the others.
/// The two halves highlight and explain themselves separately.
struct NewSessionButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hoverMain = false
    @State private var hoverMenu = false

    var body: some View {
        let last = model.profile(model.lastNewSessionProfile)
        HStack(spacing: 1) {
            ZStack(alignment: .topTrailing) {
                AgentIcon(icon: last?.icon ?? "terminal", size: 13).frame(width: 15, height: 15)
                Image(systemName: "plus").font(.system(size: T.k * 7, weight: .black)).foregroundStyle(hoverMain ? T.text : T.text2)
                    .offset(x: 5, y: -4)
            }
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hoverMain ? T.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hoverMain = $0 }
            .pointerCursor()
            .onTapGesture { model.newSession(profileId: last?.id) }
            .help("New \(last?.name ?? "Terminal") tab  \(last == nil ? "⌘T" : "⌘⇧T")")
            PopupMenuButton(menu: { newSessionMenu(model: model, projectId: model.currentProject?.id, remember: true) }) {
                Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(hoverMenu ? T.text : T.text3)
                    .frame(width: 16, height: 26)
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hoverMenu ? T.hover : .clear))
            .onHover { hoverMenu = $0 }
            .pointerCursor()
            .help("New tab with… (Terminal, agents)")
        }
        .disabled(!model.canManage).opacity(model.canManage ? 1 : 0.4)
    }
}

/// Shown on a sidebar project row under the pointer: terminal, pinned agents, and a menu with everything.
struct ProjectQuickActions: View {
    @EnvironmentObject var model: AppModel
    let project: Project

    var body: some View {
        HStack(spacing: 1) {
            Button { model.newSession(profileId: nil, projectId: project.id) } label: { AgentIcon(icon: "terminal", size: 10) }
                .buttonStyle(IconButtonStyle()).help("New Terminal")
            ForEach(model.profileGroups(forProject: project.id, pinnedOnly: true), id: \.first!.id) { group in
                if group.count == 1, let p = group.first {
                    Button { model.newSession(profileId: p.id, projectId: project.id) } label: { AgentIcon(icon: p.icon, size: 11) }
                        .buttonStyle(IconButtonStyle()).help("New \(p.name)")
                } else {
                    Menu {
                        ForEach(group) { p in Button(p.name) { model.newSession(profileId: p.id, projectId: project.id) } }
                    } label: { AgentIcon(icon: group[0].icon, size: 11).menuHitBox(20, 20) }
                        .plainMenu()
                        .frame(width: 20, height: 20).hoverHighlight(radius: 5)
                        .help(group.map(\.name).joined(separator: " / "))
                }
            }
            Menu {
                NewSessionItems(projectId: project.id)
            } label: { Image(systemName: "plus").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text2).menuHitBox(20, 20) }
                .plainMenu()
                .frame(width: 20, height: 20).hoverHighlight(radius: 5)
                .help("New session")
        }
        .disabled(!model.canManage)
    }
}

struct TerminalArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneSlotView {
        let v = PaneSlotView(TerminalHost.shared.container)
        // Drawn once, when it takes the container (in the window); not again from here.
        v.onAdopt = { DispatchQueue.main.async { TerminalHost.shared.render(force: true) } }   // after the window's frame (the panes moved with the container)
        return v
    }
    func updateNSView(_ v: PaneSlotView, context: Context) {
        if v.adopt() { TerminalHost.shared.render(force: true) } else { TerminalHost.shared.render() }
    }
}

/// Lets the user drag the window by empty top-bar space (window has a hidden title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let win = window else { return }
            if event.clickCount == 2 { win.zoom(nil); return }
            // The window is not movable by itself (see AppDelegate); allow it for this one drag.
            win.isMovable = true
            win.performDrag(with: event)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak win] t in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate(); win?.isMovable = false
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct DormantPaneView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    @State private var flags = false

    var body: some View {
        let s = model.session(sessionId)
        VStack(spacing: 10) {
            if let s {
                AgentIcon(icon: iconName(for: s, model: model), size: 26).opacity(0.7).padding(.bottom, 4)
                Text(s.displayTitle).font(.system(size: T.k * 15, weight: .semibold)).foregroundStyle(T.text)
                Text(s.state == .stopped ? "Stopped" : "Exited\(s.exitCode.map { " with code \($0)" } ?? "")")
                    .font(T.body).foregroundStyle(T.text2)
                HStack(spacing: 8) {
                    Button(s.isAgent ? "Resume" : "Restart") { model.restart(s.id) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    if s.kind == .agent {
                        Button("Resume with Flags…") { flags = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Resume with other command-line flags, such as --chrome")
                            .background(DropdownAnchor(isPresented: $flags) {
                                ResumeFlagsView(model: model, session: s) { flags = false }
                            })
                    }
                    Button("Remove") { model.remove(s.id, confirm: false) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 6)
                if s.kind == .agent, s.agentSessionId != nil {
                    Text("Resume continues the same conversation.").font(T.caption).foregroundStyle(T.text3)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["resumeFlags"] as? Bool { flags = v }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground())
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let p = model.currentProject {
                ProjectIconView(project: p, size: 44).padding(.bottom, 6)
                Text(p.name).font(.system(size: T.k * 20, weight: .bold)).foregroundStyle(T.text)
                Text(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(T.mono(12)).foregroundStyle(T.text3)
                HStack(spacing: 8) {
                    ForEach(model.enabledProfiles.prefix(4)) { prof in
                        Button { model.newSession(profileId: prof.id) } label: {
                            HStack(spacing: 7) { AgentIcon(icon: prof.icon, size: 12); Text(prof.name) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button { model.newSession(profileId: nil) } label: {
                        HStack(spacing: 7) { AgentIcon(icon: "terminal", size: 12); Text("Terminal") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 10)
                Text("⌘T terminal · ⌘⇧T first pinned agent").font(T.caption).foregroundStyle(T.text3).padding(.top, 4)
            } else {
                Image(systemName: "folder.badge.plus").font(.system(size: T.k * 36, weight: .light)).foregroundStyle(T.text3)
                Text("Add a project to get started").font(.system(size: T.k * 17, weight: .semibold)).foregroundStyle(T.text)
                Text("A project is any folder. Sessions, tabs and actions live under it.").font(T.body).foregroundStyle(T.text2)
                Button("Add Project…") { model.addProject() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground(scene: true))
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        let m = T.m
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
        }
        .font(m.monoLabels ? T.mono(11) : T.caption)
        .foregroundStyle(T.text2)
        .padding(.leading, model.sidebarVisible ? 6 : 14)
        .padding(.trailing, 8)
        .frame(height: m.statusH)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func bar(full: Bool) -> some View {
        let layout = model.layout
        return HStack(spacing: 12) {
            // The layout's items (Terminal: agents, branch | cup, usage, actions, dock).
            ForEach(layout.shown(.statusLeft), id: \.self) { id in leftItem(id, full: full) }
            Spacer(minLength: 8)
            ForEach(layout.shown(.statusRight), id: \.self) { id in rightItem(id, full: full) }
        }
    }

    @ViewBuilder private func leftItem(_ id: String, full: Bool) -> some View {
        switch id {
        case "agents":
            let working = model.state.sessions.filter { $0.activity == .working && $0.state == .running }.count
            let waiting = model.state.sessions.filter { $0.activity == .needsInput }.count
            if working > 0 {
                HStack(spacing: 6) { Circle().fill(T.accent).frame(width: 6, height: 6); Text(full ? "\(working) working" : "\(working)") }
                    .fixedSize().help("\(working) agents working")
            }
            if waiting > 0 {
                Button { model.nextNeedingInput() } label: {
                    HStack(spacing: 6) { Circle().fill(T.amber).frame(width: 6, height: 6); Text(full ? "\(waiting) waiting" : "\(waiting)") }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(T.amber).fixedSize().hoverHighlight(radius: 5, padding: 3).help("Jump to the next session waiting for input (⌘⇧U)")
            }
            if working == 0 && waiting == 0 {
                Text(full ? "No agents busy" : "Idle").foregroundStyle(T.text3).fixedSize()
                    .help("No agent is working or waiting for input, in any project")
            }
        case "git":
            if let wp = model.currentWorkPath, let branch = git.branch(for: wp) {
                GitStatusControls(path: wp, branch: branch, full: full)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func rightItem(_ id: String, full: Bool) -> some View {
        switch id {
        case "layout": LayoutControl(full: full)
        case "keepAwake": if !model.host.isRemote { KeepAwakeControl() }
        case "usage": UsageStatus(compact: !full)
        case "actions": ActionsControl().fixedSize()
        case "aquarium":
            Button { model.openAquarium() } label: {
                HStack(spacing: 5) { Image(systemName: "fish").font(.system(size: T.k * 11)); if full { Text("Aquarium") } }
            }
            .buttonStyle(ChromeButtonStyle()).fixedSize().help("Every agent as an octopus")
        case "dock":
            Button { model.toggleDock() } label: {
                HStack(spacing: 5) { Image(systemName: "terminal").font(.system(size: T.k * 11)); if full { Text("Terminal") } }
            }
            .buttonStyle(ChromeButtonStyle(active: model.isDockOpen(model.currentProject?.id)))
            .fixedSize()
            .help("Toggle dock (⌘J)").disabled(model.currentProject == nil)
        default: EmptyView()
        }
    }
}

/// Agent rate limits in the status bar: the focused session's profile plus
/// profiles marked "always show". Click for details.
struct UsageStatus: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UsageReading.showsLeftKey) private var showsLeft = false
    @AppStorage(UsageReading.windowsKey) private var windows = "all"
    var compact = false

    var body: some View {
        let open = Binding(get: { model.usagePopoverOpen && !compact }, set: { model.usagePopoverOpen = $0 })
        let shown = model.usageProfilesShown()
        if !shown.isEmpty {
            Button { model.usagePopoverOpen.toggle() } label: {
                HStack(spacing: 12) {
                    ForEach(shown, id: \.0.id) { prof, readings in
                        HStack(spacing: 5) {
                            AgentIcon(icon: prof.icon, size: 10)
                            ForEach(compact ? Array(UsageReading.shown(readings, windows).prefix(1)) : UsageReading.shown(readings, windows)) { r in
                                if !compact { Text(r.shortName).foregroundStyle(T.text3) }
                                UsageRing(used: r.effectivePercent, left: showsLeft, primary: r.window == "five_hour").frame(width: 12, height: 12)
                                // After the window resets the old reading says nothing: "—" until a new one arrives.
                                Text(r.isReset ? "—" : r.label(left: showsLeft)).font(T.mono(11))
                                    .foregroundStyle(r.isReset ? T.text3 : T.text)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .hoverHighlight(radius: 5, padding: 3)
            .help(shown.contains { $0.1.contains(where: \.isReset) }
                  ? "Usage limits — “—” means the window reset and no newer reading came in yet. Click for details"
                  : "Usage limits — click for details")
            .popover(isPresented: open, arrowEdge: .top) { UsagePopover().environmentObject(model) }
        }
    }
}

/// A limit as a small ring (status bar): filled with what is used, or with what is left.
struct UsageRing: View {
    let used: Double
    var left = false
    var primary = true
    var body: some View {
        let fill = left ? max(0, 100 - used) : used
        ZStack {
            Circle().stroke(T.border, lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0.02, fill / 100)))
                .stroke(UsageMeter(used: used, primary: primary).color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// A limit as a bar: filled with what is used, or with what is left. The color always follows the use.
struct UsageMeter: View {
    let used: Double
    var left = false
    var primary = true
    var body: some View {
        let fill = left ? max(0, 100 - used) : used
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(T.border)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, fill / 100)))
            }
        }
        .frame(height: 5)
    }
    var color: Color { used >= 90 ? T.red : used >= 70 ? T.amber : primary ? T.accent : T.text2 }
}

struct UsagePopover: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UsageReading.showsLeftKey) private var showsLeft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage limits").font(T.headline).foregroundStyle(T.text)
                Spacer()
                Picker("", selection: $showsLeft) { Text("Used").tag(false); Text("Left").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Show how much of each limit is used, or how much is left")
                Button {
                    // The profiles the status bar shows, like the automatic refresh.
                    for id in model.usageProfileIds { model.client(for: id).call("usage.refresh", ["profile_ids": [id]]) }
                } label: { Image(systemName: "arrow.clockwise").font(.system(size: T.k * 11, weight: .medium)) }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Refresh the agents shown in the status bar now")
            }
            if let ws = model.workspace {
                Picker("", selection: Binding(get: { model.workspaceOverridesAlwaysShow }, set: { model.setWorkspaceAlwaysShowOverride($0) })) {
                    Text("All workspaces").tag(false)
                    Text("Only \(ws.name)").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Always show: one list for every workspace, or a list of its own for \(ws.name)")
                Text(model.workspaceOverridesAlwaysShow
                     ? "\(ws.name) has its own Always show list; other workspaces keep theirs."
                     : "Always show applies to every workspace without a list of its own.")
                    .font(T.caption).foregroundStyle(T.text3)
            }
            Text("Only the agents shown in the status bar (the focused one and those set to Always show) are refreshed: every minute while Octomux is open, and right after their session finishes a turn. Claude is asked with its own `/usage` command (no tokens used); Codex is read from its session files.")
                .font(T.caption).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
            // Readings so far, plus Claude/Codex profiles without one yet (so they can be set to Always show).
            let profiles = model.enabledProfiles.filter { p in model.state.usage.contains { $0.profileId == p.id } || p.kind == .claude || p.kind == .codex }
            if profiles.isEmpty {
                Text("No readings yet. They arrive while a Claude or Codex session runs.").font(T.body).foregroundStyle(T.text2)
            }
            ForEach(profiles) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        AgentIcon(icon: p.icon, size: 12)
                        Text(p.name).font(.system(size: T.k * 13, weight: .semibold)).foregroundStyle(T.text)
                        Spacer()
                        Toggle("Always show", isOn: Binding(get: { model.usageAlwaysShown(p.id) }, set: { model.setUsageAlwaysShown(p.id, $0) }))
                            .toggleStyle(.checkbox).font(T.caption).foregroundStyle(T.text2)
                    }
                    ForEach(model.usage(of: p.id)) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.longName).font(T.body).foregroundStyle(T.text2)
                                Spacer()
                                Text(r.isReset ? "no reading since reset" : r.label(left: showsLeft) + (showsLeft ? " left" : " used"))
                                    .font(r.isReset ? T.caption : T.mono(12, .semibold)).foregroundStyle(r.isReset ? T.text3 : T.text)
                            }
                            UsageMeter(used: r.effectivePercent, left: showsLeft, primary: r.window == "five_hour")
                            HStack {
                                if let at = r.resetsAt, !r.isReset { Text("resets \(relative(at))").font(T.caption).foregroundStyle(T.text3) }
                                Spacer()
                                Text("updated \(relative(r.observedAt))").font(T.caption).foregroundStyle(T.text3)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border))
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(T.raised)
    }

    func relative(_ t: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}

/// Session tab context menu.
/// A pinned tab in the tab bar: the pane stack icon only, a dot for activity; the title is in the tooltip.
struct PinnedTabChip: View {
    static let width: CGFloat = 32
    @EnvironmentObject var model: AppModel
    let tab: Tab
    let index: Int
    @State private var hover = false

    var body: some View {
        let selected = tab.id == model.activeTabId && model.activeDoc == nil
        let ids = tab.layout.sessions
        let lead = model.session(tab.activeSessionId ?? ids.first)
        let busy = ids.compactMap { model.session($0) }.first { $0.activity == .needsInput || $0.activity == .working || $0.unread }
        ZStack {
            PaneStackIcon(items: paneStackItems(ids, front: lead?.id, model: model), size: 12)
                .opacity(selected ? 1 : hover ? 0.85 : 0.6).saturation(selected ? 1 : 0.6)
        }
        .frame(width: Self.width, height: T.m.tabH - 4)
        .overlay(alignment: .topTrailing) {
            if let busy {
                Circle().fill(busy.activity == .needsInput ? T.amber : busy.activity == .working ? T.accent : T.green)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(T.frame, lineWidth: 1.5))
                    .offset(x: -3, y: 3)
                    .help("\(busy.displayTitle): \(activityHelp(busy))")
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? (ThemeStore.shared.isDark ? Color.white.opacity(0.1) : T.raised) : hover ? T.hover : .clear)
            .shadow(color: .black.opacity(selected && !ThemeStore.shared.isDark ? 0.1 : 0), radius: 1, y: 0.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectTab(tab.id) }
        .contextMenu { TabMenu(tab: tab) }
        .help((lead?.displayTitle ?? "Tab") + (index < 9 ? "  ⌘\(index + 1)" : "") + " · pinned")
    }
}

struct TabMenu: View {
    @EnvironmentObject var model: AppModel
    let tab: Tab

    var body: some View {
        let lead = model.session(tab.activeSessionId ?? tab.layout.sessions.first)
        if let lead {
            Button("Rename Tab…") { model.selectTab(tab.id); model.renamingSessionId = lead.id }
        }
        Button(model.isPinned(tab) ? "Unpin Tab" : "Pin Tab") { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.togglePin(tab) } }
        if model.activeTab?.id != tab.id, model.activeTab != nil {
            Button("Open in Current Tab Split") { model.mergeTabIntoCurrent(tab.id) }
        }
        if tab.layout.sessions.count > 1, let lead {
            Button("Move “\(TabChip.clip(lead.displayTitle, 24))” to New Tab") { model.movePaneToNewTab(lead.id) }
        }
        // The session's own actions (the tab's active pane); Rename / Pin are above, closing is below.
        if let lead {
            Divider()
            SessionMenu(session: lead, inTab: true)
        }
        Divider()
        Button("Close Tab") { model.closeTab(tab.id) }
        Button("Close Other Tabs") { model.closeTabs(model.tabs(.others, of: tab.id)) }.disabled(model.tabs(.others, of: tab.id).isEmpty)
        Button("Close Tabs to the Right") { model.closeTabs(model.tabs(.right, of: tab.id)) }.disabled(model.tabs(.right, of: tab.id).isEmpty)
        Button("Close Tabs to the Left") { model.closeTabs(model.tabs(.left, of: tab.id)) }.disabled(model.tabs(.left, of: tab.id).isEmpty)
        Button(model.pinnedTabIds(project: tab.projectId).isEmpty ? "Close All Tabs" : "Close All Unpinned Tabs") { model.closeTabs(model.tabs(.all, of: tab.id)) }
            .disabled(model.tabs(.all, of: tab.id).isEmpty)
    }
}

/// A pane header dropped on the tab strip leaves its split and becomes a tab.
struct PaneToTabDrop: DropDelegate {
    let model: AppModel
    func validateDrop(info: DropInfo) -> Bool { DragItem.current?.kind == "pane" }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: DragItem.current?.kind == "pane" ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        guard let d = DragItem.current, d.kind == "pane" else { return false }
        DragItem.current = nil
        model.movePaneToNewTab(d.id)
        return true
    }
}

/// Status bar git controls: branch (click to switch), changed-file count (opens Changes), compare base.
struct GitStatusControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared
    let path: String
    let branch: String
    let full: Bool
    @State private var picking = false
    @State private var pickingBase = false
    @State private var hover = false

    var body: some View {
        let base = GitInfo.compareBase(for: path)
        HStack(spacing: 6) {
            Button { picking = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10, weight: .semibold))
                    Text(branch).font(T.mono(11, .medium)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().help("Switch branch")
            .background(DropdownAnchor(isPresented: $picking) {
                BranchPicker(path: path, mode: .checkout, current: branch) { picking = false }
            })
            if let stat = git.diffStat(for: path), stat.files > 0 {
                Button { model.toggleChangesPanel() } label: {
                    HStack(spacing: 5) {
                        Text(full ? "\(stat.files) changed" : "\(stat.files)").foregroundStyle(T.amber)
                        if full {
                            Text("+\(stat.added)").foregroundStyle(T.diffAdd)
                            Text("−\(stat.removed)").foregroundStyle(T.diffDel)
                        }
                    }
                    .font(T.mono(11, .medium))
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.amber.opacity(0.13)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(base.map { "Show changes against \($0)" } ?? "Show uncommitted changes")
            }
            if full {
                Button { pickingBase = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right").font(.system(size: T.k * 9, weight: .bold)).foregroundStyle(T.text3)
                        Text(base ?? branch).font(T.mono(11)).foregroundStyle(base == nil ? T.text3 : T.text2).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight(radius: 6, padding: 0).pointerCursor()
                .help(base.map { "Changes compared against \($0): everything since this branch diverged from it" }
                      ?? "Changes compared against \(branch) (HEAD): uncommitted work only. Click to compare against another branch")
                .opacity(base != nil || hover || pickingBase ? 1 : 0)
                .background(DropdownAnchor(isPresented: $pickingBase) {
                    BranchPicker(path: path, mode: .base, current: GitInfo.compareBase(for: path)) { pickingBase = false }
                })
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["branchPicker"] as? String { if v == "base" { pickingBase = true } else if v == "none" { picking = false; pickingBase = false } else { picking = true } }
        }
    }
}

/// Searchable branch list: switch branch, or choose what the Changes views compare against.
struct BranchPicker: View {
    enum Mode { case checkout, base }
    @EnvironmentObject var model: AppModel
    let path: String
    let mode: Mode
    let current: String?
    let done: () -> Void
    @State private var query = ""
    @State private var branches: [String] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: T.k * 11)).foregroundStyle(T.text3)
                TextField(mode == .checkout ? "Search or create branch" : "Search branches", text: $query)
                    .textFieldStyle(.plain).font(.system(size: T.k * 13))
                    .onSubmit { if let first = filtered.first { pick(first) } else if mode == .checkout, !query.isEmpty { create(query) } }
            }
            .padding(.horizontal, 12).frame(height: 36)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if mode == .base {
                        row("HEAD · uncommitted changes only", selected: current == nil, mono: false) { choose(nil) }
                        PanelSectionTitle("Since branch")
                    } else {
                        PanelSectionTitle("Recent")
                    }
                    ForEach(filtered, id: \.self) { b in row(b, selected: b == current) { pick(b) } }
                    if mode == .checkout, !query.isEmpty, !branches.contains(query) {
                        row("Create branch “\(query)”", selected: false, mono: false, icon: "plus") { create(query) }
                    }
                    if filtered.isEmpty && (mode == .base || query.isEmpty) {
                        Text("No branches").font(T.body).foregroundStyle(T.text3).padding(10)
                    }
                }
                .padding(6)
            }
            .frame(height: min(320, CGFloat(filtered.count + (mode == .base ? 2 : 1) + (mode == .checkout && !query.isEmpty && !branches.contains(query) ? 1 : 0)) * 29 + 26))
            if let error {
                Hairline()
                Text(error).font(T.caption).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true).padding(10)
            }
        }
        .frame(width: 300)
        .background(T.raised)
        .disabled(busy)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let b = GitInfo.branches(in: path, remotes: mode == .base)
                DispatchQueue.main.async { branches = b }
            }
        }
    }

    private var filtered: [String] {
        query.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func row(_ text: String, selected: Bool, mono: Bool = true, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon ?? "checkmark").font(.system(size: T.k * 10, weight: .bold)).foregroundStyle(icon != nil ? T.text2 : T.accent)
                    .opacity(icon != nil || selected ? 1 : 0).frame(width: 12)
                Text(text).font(mono ? T.mono(12) : .system(size: T.k * 13)).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HoverFill())
        .panelPointer()
    }

    private func pick(_ b: String) {
        if mode == .base { choose(b); return }
        guard b != current else { done(); return }
        run(["checkout", b])
    }

    private func create(_ name: String) { run(["checkout", "-b", name.trimmingCharacters(in: .whitespaces)]) }

    private func choose(_ b: String?) {
        GitInfo.shared.setCompareBase(b, for: path)
        done()
    }

    private func run(_ args: [String]) {
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GitInfo.gitResult(args, in: path)
            DispatchQueue.main.async {
                busy = false
                GitInfo.shared.invalidate(path)
                if r.ok { done() } else {
                    error = r.err.split(separator: "\n").filter { !$0.hasPrefix("hint:") }.prefix(4).joined(separator: "\n").nilIfEmpty ?? "git \(args.joined(separator: " ")) failed"
                }
            }
        }
    }
}



/// The work area: the current tab's panes (or doc), the browser beside them, the dock on its side, and the aquarium
/// strip above when the layout has it. The classic window and the layout engine's workArea block both use it.
struct WorkAreaBlock: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("octomux.dockPosition") private var dockPosition = "bottom"
    /// The aquarium strip above the panes when the layout turns it on (off where a layout places it as a block).
    var strip = true

    /// Terminal area plus the dock on the chosen side.
    @ViewBuilder private var workArea: some View {
        let m = T.m
        let open = model.isDockOpen(model.currentProject?.id)
        switch dockPosition {
        case "top":
            VStack(spacing: m.inset) { if open { DockView(position: "top") }; WorkAreaWithBrowser { TerminalArea() } }
        case "left":
            HStack(spacing: m.inset) { if open { DockView(position: "left") }; WorkAreaWithBrowser { TerminalArea() } }
        case "right":
            HStack(spacing: m.inset) { WorkAreaWithBrowser { TerminalArea() }; if open { DockView(position: "right") } }
        default:
            VStack(spacing: m.inset) { WorkAreaWithBrowser { TerminalArea() }; if open { DockView(position: "bottom") } }
        }
    }

    /// The work area, with the aquarium above it when the layout has it.
    var body: some View {
        // Not while the Aquarium tab itself is open (one aquarium on screen).
        if strip, model.layout.has("aquarium", in: .views), !{ if case .aquarium? = model.activeDoc?.kind { return true }; return false }() {
            VStack(spacing: T.m.inset) {
                AquariumView(style: .strip)
                    .overlay(alignment: .top) { AquariumHeader().padding(.horizontal, 14).padding(.top, 10) }
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: T.m.cardR, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: T.m.cardR, style: .continuous).stroke(T.border))
                workArea
            }
        } else {
            workArea
        }
    }

}
