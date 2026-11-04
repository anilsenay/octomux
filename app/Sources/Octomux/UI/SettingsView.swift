import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", terminal = "Terminal", notifications = "Notifications", keyboard = "Keyboard"
    case agents = "Agents", workspaces = "Workspaces", hosts = "Hosts"
    case features = "Features", advanced = "Advanced"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .workspaces: return "square.stack"
        case .agents: return "sparkles"
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .notifications: return "bell"
        case .hosts: return "network"
        case .features: return "flask"
        case .keyboard: return "keyboard"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
    /// One line under the page title.
    var subtitle: String {
        switch self {
        case .general: return "The version you run, how Octomux updates itself, and the apps it opens projects in."
        case .appearance: return "Theme, scene, and the icons in the Dock and the menu bar."
        case .terminal: return "Font, cursor and scrollback of every terminal, and what happens when you close one."
        case .notifications: return "When Octomux tells you an agent finished or needs you."
        case .keyboard: return "Every shortcut Octomux handles. Keys not bound here go straight to the terminal program."
        case .agents: return "The agents in the + menu, how they start, and how Octomux follows their state."
        case .workspaces: return "Workspaces group projects. Switch with the dots under the sidebar, a two-finger swipe on it, or ⌃1…⌃9."
        case .hosts: return "Machines that run their own Octomux daemon, reached over SSH."
        case .features: return "Optional parts of Octomux you can turn on or off."
        case .advanced: return "The daemon behind your sessions, its data and its logs."
        }
    }
    /// Sections whose settings can be overridden per workspace.
    var scoped: Bool { self == .notifications || self == .appearance }

    /// Sidebar groups, in order.
    static let groups: [(title: String, items: [SettingsSection])] = [
        ("App", [.general, .appearance, .terminal, .notifications, .keyboard]),
        ("Work", [.agents, .workspaces, .hosts]),
        ("Advanced", [.features, .advanced]),
    ]
}

final class SettingsWindow {
    static var window: NSWindow?
    static let selection = SettingsSelection()

    static func show(section: SettingsSection? = nil) {
        if let section { selection.section = section; selection.query = "" }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared).environmentObject(selection))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var section: SettingsSection = .general
    /// "global" or "workspace:<id>"
    @Published var scope: String = "global"
    /// Text in the sidebar's search field; while it is not empty the page shows the matching settings.
    @Published var query = ""
    /// A row to scroll to and flash once its page is shown (a search result that was picked).
    @Published var target: String?
    @Published var flash: String?
    /// Scroll position per section. The view is rebuilt when the theme or scene changes (`.id(revision)`),
    /// which would otherwise jump back to the top after every pick.
    var scrollOffsets: [SettingsSection: CGFloat] = [:]
    /// Where each row starts in the page (`SettingAnchor`), and the page's scroll view, to scroll to a row.
    var anchors: [String: CGFloat] = [:]
    weak var scrollView: NSScrollView?
    /// The page's group titles, top to bottom (the sidebar lists them under the page).
    @Published var groups: [String] = []
    /// Scroll position of the page, for the sidebar's current group (its own object: only the sidebar redraws).
    let scroll = SettingsScroll()

    func open(_ s: SettingsSection, row: String?) {
        query = ""
        section = s
        target = row
    }
}

final class SettingsScroll: ObservableObject {
    @Published var y: CGFloat = 0
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 220)
                .background(T.frame)
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if sel.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        SettingsHeader(section: sel.section)
                        page
                    } else {
                        SettingsSearchResults()
                    }
                }
                .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 40)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: SettingAnchor.space)
                .onPreferenceChange(SettingAnchor.Key.self) { [sel] in sel.anchors = $0 }
                .onPreferenceChange(SettingAnchor.Groups.self) { [sel] g in
                    let names = g.sorted { $0.value < $1.value }.map(\.key)
                    if names != sel.groups { sel.groups = names }
                }
                .background(ScrollOffsetKeeper(initial: sel.scrollOffsets[sel.section] ?? 0, onScrollView: { [sel] in sel.scrollView = $0 }) { [sel] y in
                    if sel.query.isEmpty { sel.scrollOffsets[sel.section] = y }
                    sel.scroll.y = y
                })
                .id(sel.query.isEmpty ? sel.section.rawValue : "search")
            }
            .onChange(of: sel.target) { _, t in jump(t) }
            .onAppear { jump(sel.target) }
            .frame(maxWidth: .infinity)
            .background(T.surface)
        }
        .foregroundStyle(T.text)
        .tint(T.accent)
        .ignoresSafeArea()
        .id(theme.revision)
    }

    @ViewBuilder private var page: some View {
        switch sel.section {
        case .general: GeneralSettings()
        case .workspaces: WorkspacesSettings()
        case .agents: AgentsSettings()
        case .appearance: AppearanceSettings()
        case .terminal: TerminalSettings()
        case .notifications: NotificationSettings()
        case .hosts: HostsSettings()
        case .features: FeatureSettings()
        case .keyboard: KeyboardSettings()
        case .advanced: AdvancedSettings()
        }
    }

    /// Scrolls to a picked search result and flashes it.
    private func jump(_ t: String?) {
        guard let t else { return }
        // After ScrollOffsetKeeper has put back the page's last position (it does so for 0.15 s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let y = sel.anchors[t], let sv = sel.scrollView {
                let clip = sv.contentView
                let maxY = max(0, (sv.documentView?.frame.height ?? 0) - clip.bounds.height)
                let target = min(max(0, y - clip.bounds.height / 3), maxY)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
                }
                sv.reflectScrolledClipView(clip)
            }
            sel.flash = t
            sel.target = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if sel.flash == t { withAnimation { sel.flash = nil } } }
        }
    }
}

// MARK: Sidebar

struct SettingsSidebar: View {
    @EnvironmentObject var sel: SettingsSelection
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 38)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(T.text3)
                TextField("Search settings", text: $sel.query)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($searching)
                    .onExitCommand { sel.query = "" }
                if !sel.query.isEmpty {
                    Button { sel.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(T.text3) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.surface.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(searching ? T.accent.opacity(0.6) : T.border))
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SettingsSection.groups, id: \.title) { g in
                        Text(g.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3)
                            .padding(.horizontal, 10).padding(.top, g.title == SettingsSection.groups.first?.title ? 0 : 14).padding(.bottom, 4)
                        ForEach(g.items) { s in
                            item(s)
                            if sel.section == s, sel.query.isEmpty, sel.groups.count > 1 { SettingsSubItems() }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            Text(Updater.shared.isEnabled ? "Octomux \(Updater.shared.currentVersion)" : "Octomux · development build").font(.system(size: 11)).foregroundStyle(T.text3)
                .padding(.horizontal, 10).padding(.bottom, 4)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func item(_ s: SettingsSection) -> some View {
        let on = sel.section == s && sel.query.isEmpty
        return Button { sel.open(s, row: nil) } label: {
            HStack(spacing: 9) {
                Image(systemName: s.icon).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(on ? T.accent : T.text3)
                Text(s.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? T.text : T.text2)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: max(T.m.rowR, 6), style: .continuous).fill(on ? T.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The current page's groups under its sidebar item; the one in view is marked, a click scrolls to it.
struct SettingsSubItems: View {
    @EnvironmentObject var sel: SettingsSelection
    @ObservedObject private var scroll = SettingsWindow.selection.scroll

    var body: some View {
        let current = sel.groups.last { (sel.anchors[$0] ?? 0) <= scroll.y + 90 } ?? sel.groups.first
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sel.groups, id: \.self) { g in
                Button { sel.target = g } label: {
                    Text(g).font(.system(size: 12, weight: g == current ? .medium : .regular))
                        .foregroundStyle(g == current ? T.text : T.text3)
                        .lineLimit(1)
                        .padding(.leading, 12).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(g == current ? T.accent : T.border).frame(width: g == current ? 2 : 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 28).padding(.top, 2).padding(.bottom, 6)
    }
}

/// Title, subtitle and (on pages with per-workspace settings) the scope switch.
struct SettingsHeader: View {
    let section: SettingsSection
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: section.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(T.text2)
                Text(section.rawValue).font(.system(size: 22, weight: .bold))
            }
            Text(section.subtitle).font(.system(size: 13)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            if section.scoped { ScopeBar().padding(.top, 10) }
        }
    }
}

/// Global or one workspace, for the pages whose settings a workspace can override.
struct ScopeBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection

    var body: some View {
        let ws = model.state.workspaces.sorted { $0.sort < $1.sort }
        let current = ws.first { "workspace:\($0.id)" == sel.scope }
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { current == nil ? "global" : "workspace" },
                set: { v in
                    if v == "global" { sel.scope = "global" } else if current == nil, let w = ws.first(where: { $0.id == model.selectedWorkspaceId }) ?? ws.first {
                        sel.scope = "workspace:\(w.id)"
                    }
                })) {
                Text("Global").tag("global")
                Text("Workspace").tag("workspace")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if let current {
                Menu {
                    ForEach(ws) { w in Button(w.name) { sel.scope = "workspace:\(w.id)" } }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: current.color)).frame(width: 8, height: 8)
                        Text(current.name).font(.system(size: 12.5, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
        }
        Text(current == nil
             ? "These apply everywhere, unless a workspace sets its own."
             : "Only for \(current!.name). Settings marked with a dot override Global; Reset goes back to it.")
            .font(.system(size: 12)).foregroundStyle(T.text3)
    }
}

// MARK: Building blocks

/// A titled group of rows in one card, with hairlines between the rows.
struct SettingsGroup<Content: View, Trailing: View>: View {
    var title: String?
    var desc: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, desc: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.desc = desc; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if title != nil || desc != nil {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title { Text(title).font(.system(size: 13.5, weight: .semibold)) }
                        if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(.horizontal, 2)
                .settingAnchor(title ?? "", group: true)
            }
            SettingsCard { _VariadicView.Tree(DividedRows()) { content() } }
        }
    }
}

/// Rows of a card, a hairline between each two.
struct DividedRows: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { c in
                c
                if c.id != last { Hairline().padding(.horizontal, 14) }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: max(T.m.cardR, 8), style: .continuous).fill(T.frame.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: max(T.m.cardR, 8), style: .continuous).stroke(T.border))
    }
}

/// One setting: title and description on the left, its control on the right. A dot marks a value this
/// workspace overrides; `onReset` then shows a Reset button. The title is the row's id, for search.
struct SettingRow<Control: View>: View {
    @EnvironmentObject var sel: SettingsSelection
    let title: String
    var desc: String?
    var modified = false
    var onReset: (() -> Void)?
    var mono = false
    @ViewBuilder var control: () -> Control

    init(_ title: String, desc: String? = nil, modified: Bool = false, onReset: (() -> Void)? = nil, mono: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.desc = desc; self.modified = modified; self.onReset = onReset; self.mono = mono; self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if modified { Circle().fill(T.accent).frame(width: 6, height: 6).help("Set for this workspace") }
                    Text(title).font(.system(size: 13, weight: .medium))
                }
                if let desc {
                    Text(desc).font(mono ? T.mono(11) : .system(size: 11.5)).foregroundStyle(T.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if modified, let onReset {
                Button("Reset", action: onReset).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.accent)
                    .help("Use the Global value")
            }
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(minHeight: 46)
        .background(T.accent.opacity(sel.flash == title ? 0.14 : 0))
        .settingAnchor(title)
    }
}

/// A place on a settings page that search can scroll to: reports where it starts in the page.
enum SettingAnchor {
    static let space = "settings-page"
    struct Key: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { a, _ in a }
        }
    }
    /// Only the group titles (the sidebar's sub-items).
    struct Groups: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { a, _ in a }
        }
    }
}

extension View {
    func settingAnchor(_ name: String, group: Bool = false) -> some View {
        background(GeometryReader { g in
            let y = g.frame(in: .named(SettingAnchor.space)).minY
            Color.clear
                .preference(key: SettingAnchor.Key.self, value: name.isEmpty ? [:] : [name: y])
                .preference(key: SettingAnchor.Groups.self, value: name.isEmpty || !group ? [:] : [name: y])
        })
    }
}

/// Free content inside a card (pickers made of tiles, an editor), padded like a row.
struct SettingBlock<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small print under a group.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2).padding(.top, -12)
    }
}

/// The switch used on every page.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
}

// MARK: Search

/// What the sidebar's search finds: a page, the row's title (its scroll target) and words that describe it.
struct SettingsEntry: Identifiable {
    let section: SettingsSection
    let title: String
    let words: String
    var id: String { section.rawValue + "/" + title }
}

enum SettingsIndex {
    static let all: [SettingsEntry] = {
        func e(_ s: SettingsSection, _ t: String, _ w: String = "") -> SettingsEntry { SettingsEntry(section: s, title: t, words: w) }
        return [
            e(.general, "Version", "about update release check"),
            e(.general, "Check automatically", "updates sparkle background"),
            e(.general, "Open in", "editor finder apps vscode cursor zed order hide default external"),
            e(.general, "Default app", "open in editor ⌘O project"),
            e(.appearance, "Menu bar icon", "status item octopus hidden monochrome"),
            e(.appearance, "App icon", "dock icon monochrome color"),
            e(.appearance, "Theme", "ink grid glass look style"),
            e(.appearance, "Appearance", "dark light system mode"),
            e(.appearance, "Use theme colors in the terminal", "terminal colors palette"),
            e(.appearance, "Split tabs as one row", "sidebar panes stacked"),
            e(.appearance, "Scene", "backdrop background animation ambient"),
            e(.appearance, "Behind terminals", "scene transparent translucent opacity"),
            e(.appearance, "React to agents", "scene glow working"),
            e(.appearance, "Your scenes", "custom import template"),
            e(.terminal, "Font", "family typeface mono jetbrains"),
            e(.terminal, "Size", "font size points bigger smaller zoom"),
            e(.terminal, "Line height", "spacing cell height leading"),
            e(.terminal, "Cursor style", "block bar underline caret"),
            e(.terminal, "Blink", "cursor blinking"),
            e(.terminal, "Lines to keep", "scrollback history buffer limit"),
            e(.terminal, "Ask before closing a running program", "confirm close tab pane quit warn"),
            e(.terminal, "Config file", "ghostty terminal.conf import"),
            e(.appearance, "Icons", "dock menu bar"),
            e(.appearance, "Workspace color", "tint"),
            e(.notifications, "Notifications", "banners alerts mute"),
            e(.notifications, "Agent finished", "done turn"),
            e(.notifications, "Agent needs input", "permission question waiting"),
            e(.notifications, "Agent error", "failed crash"),
            e(.notifications, "Long-running command finished", "terminal command threshold"),
            e(.notifications, "Program notifications", "osc 9 777"),
            e(.notifications, "Command threshold", "seconds long running"),
            e(.notifications, "Sound", "audio"),
            e(.notifications, "Test notification", "try send sample banner focus"),
            e(.notifications, "Sound: Agent finished", "audio done tone"),
            e(.notifications, "Sound: Agent needs input", "audio permission tone"),
            e(.notifications, "Sound: Agent error", "audio failed tone"),
            e(.notifications, "Sound: Commands and programs", "audio terminal tone"),
            e(.notifications, "Dock badge", "count"),
            e(.keyboard, "Shortcuts", "keys bindings hotkeys find by keys acts on"),
            e(.keyboard, "Reset all shortcuts", "defaults restore keybindings"),
            e(.agents, "Your agents", "claude codex profiles pin command arguments environment hooks"),
            e(.agents, "Detected on this Mac", "installed path"),
            e(.agents, "Meters show", "usage limits used left remaining quota plan"),
            e(.workspaces, "Workspaces", "rename color reorder default agent new chat"),
            e(.workspaces, "Archived projects", "unarchive"),
            e(.hosts, "Hosts", "remote ssh server daemon connect"),
            e(.features, "Git worktrees", "branch"),
            e(.features, "Remote hosts", "ssh"),
            e(.features, "Hosts side by side", "multi host"),
            e(.features, "Chat view for Claude", "transcript"),
            e(.features, "Usage via OAuth API", "limits plan"),
            e(.advanced, "Daemon", "pid protocol restart"),
            e(.advanced, "Data folder", "home files"),
            e(.advanced, "Logs", "diagnostics"),
            e(.advanced, "Restart daemon", ""),
            e(.advanced, "Stop Octomux", "quit end sessions start"),
        ]
    }()

    static func search(_ q: String) -> [SettingsEntry] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { e in
            let hay = (e.title + " " + e.words + " " + e.section.rawValue).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

struct SettingsSearchResults: View {
    @EnvironmentObject var sel: SettingsSelection

    var body: some View {
        let hits = SettingsIndex.search(sel.query)
        VStack(alignment: .leading, spacing: 6) {
            Text("Search").font(.system(size: 22, weight: .bold))
            Text(hits.isEmpty ? "Nothing matches “\(sel.query)”." : "\(hits.count) \(hits.count == 1 ? "setting matches" : "settings match") “\(sel.query)”.")
                .font(.system(size: 13)).foregroundStyle(T.text2)
        }
        let bySection = Dictionary(grouping: hits, by: \.section)
        ForEach(SettingsSection.allCases.filter { bySection[$0] != nil }) { s in
            SettingsGroup(s.rawValue) {
                ForEach(bySection[s] ?? []) { e in
                    Button { sel.open(e.section, row: e.title) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.icon).font(.system(size: 12)).foregroundStyle(T.text3).frame(width: 16)
                            Text(e.title).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(s.rawValue)  ›").font(.system(size: 12)).foregroundStyle(T.text3)
                        }
                        .padding(.horizontal, 14).frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var updater = Updater.shared

    var body: some View {
        SettingsGroup("About") {
            SettingRow("Version", desc: updater.isEnabled ? "Octomux updates itself from the release feed: \(statusText)" : "Updates are off in this build (development builds don't check the release feed).") {
                Text(updater.isEnabled ? updater.currentVersion : "dev").font(T.mono(12)).foregroundStyle(T.text2)
                if updater.isEnabled {
                    Button("Check for Updates") { updater.checkNow() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if updater.isEnabled {
                SettingRow("Check automatically", desc: "Looks for a new version in the background once a day and offers it when it's ready.") {
                    SettingSwitch(isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                }
            }
        }
        OpenInSettings()
    }

    private var statusText: String {
        switch updater.phase {
        case .checking: return "checking…"
        case .upToDate: return "you have the latest version."
        case .available(let v): return "version \(v) is available."
        case .downloading, .extracting: return "downloading an update…"
        case .ready(let v): return "version \(v) installs when you relaunch."
        case .installing: return "installing…"
        case .failed(let e): return "the last check failed (\(e))."
        case .idle: return "new versions show up as a note in the main window."
        }
    }
}

// MARK: Workspaces

struct WorkspacesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var picking: String?

    var body: some View {
        let ws = model.state.workspaces.sorted { $0.sort < $1.sort }
        SettingsGroup("Workspaces", desc: "Click the dot to pick a color, the name to rename it. New Chat starts with the agent set here.") {
            ForEach(Array(ws.enumerated()), id: \.element.id) { i, w in
                HStack(spacing: 12) {
                    Button { picking = w.id } label: {
                        Circle().fill(Color(hex: w.color)).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(T.text.opacity(0.15)))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Color")
                    .popover(isPresented: Binding(get: { picking == w.id }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
                        ColorDots(selected: w.color) { model.updateWorkspace(w.id, ["color": $0]); picking = nil }.padding(12)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: Binding(get: { w.name }, set: { model.updateWorkspace(w.id, ["name": $0]) }))
                            .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                        let n = model.state.projects.filter { $0.workspaceId == w.id }.count
                        Text("\(n) \(n == 1 ? "project" : "projects")").font(.system(size: 11.5)).foregroundStyle(T.text2)
                    }
                    Spacer()
                    let def = model.defaultChatProfile(workspace: w.id)
                    Menu {
                        Button((def == nil ? "✓ " : "") + "Last used") { model.setDefaultChatProfile(nil, workspace: w.id) }
                        Divider()
                        ForEach(model.chatProfiles) { p in
                            Button((def?.id == p.id ? "✓ " : "") + p.name) { model.setDefaultChatProfile(p.id, workspace: w.id) }
                        }
                    } label: {
                        Text("New chat: \(def?.name ?? "last used agent")").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize().tint(T.text2)
                    .help("Agent the New Chat screen starts with in this workspace")
                    Menu {
                        Button("Move Up") { model.updateWorkspace(w.id, ["sort": w.sort - 2]) }.disabled(i == 0)
                        Button("Move Down") { model.updateWorkspace(w.id, ["sort": w.sort + 2]) }.disabled(i == ws.count - 1)
                        Divider()
                        Button("Delete Workspace", role: .destructive) { model.deleteWorkspace(w.id) }.disabled(ws.count <= 1)
                    } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(T.text2) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(T.text2)
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(T.text3).frame(width: 22)
                TextField("New workspace", text: $newName).textFieldStyle(.plain).onSubmit(add)
                Button("Add", action: add).buttonStyle(SecondaryButtonStyle()).disabled(newName.isEmpty)
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
        }
        let archived = model.state.projects.filter { $0.archived }
        SettingsGroup("Archived projects", desc: "Archive a project from its right-click menu to hide it from the sidebar; its sessions are kept.") {
            if archived.isEmpty {
                Text("No archived projects.").font(.system(size: 12.5)).foregroundStyle(T.text2).padding(14)
            }
            ForEach(archived) { p in
                SettingRow(p.name, desc: (p.path as NSString).abbreviatingWithTildeInPath, mono: true) {
                    Button("Unarchive") { model.updateProject(p.id, ["archived": false]) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    func add() {
        guard !newName.isEmpty else { return }
        model.createWorkspace(name: newName)
        newName = ""
    }
}

/// The workspace colors as a row of dots.
struct ColorDots: View {
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Palette.colors, id: \.self) { c in
                Circle().fill(Color(hex: c)).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(T.text, lineWidth: selected.caseInsensitiveCompare(c) == .orderedSame ? 2 : 0).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { pick(c) }
                    .pointerCursor()
            }
        }
    }
}

// MARK: Agents

struct AgentsSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UsageReading.showsLeftKey) private var showsLeft = false
    @State private var editing: Profile?
    @State private var detected: [[String: Any]] = []
    /// Claude integration per profile id: config_dir, status (installed / outdated / missing).
    @State private var integration: [String: (dir: String, status: String)] = [:]
    /// Codex per profile id: its version and whether it reports its own state (reports / old / unknown).
    @State private var codex: [String: (version: String?, status: String)] = [:]
    @State private var confirming: (profile: Profile, install: Bool)?

    var body: some View {
        SettingsGroup("Your agents", desc: "They appear in the + menu; pinned ones also get a button in the tab bar. Claude and Codex sessions pick up their conversation after a crash or reboot.", trailing: {
            Button { editing = Profile(id: "", name: "", icon: "terminal", kind: .generic, command: "", args: [], env: [:], viaLoginShell: true, resumeTemplate: "", enabled: true, pinned: false, sort: 99) } label: {
                Label("Add Agent", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
        }) {
            ForEach(model.state.profiles.filter { model.owner[$0.id] == nil }.sorted { $0.sort < $1.sort }) { p in
                HStack(spacing: 12) {
                    AgentIcon(icon: p.icon, size: 15).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(([p.command] + p.args).joined(separator: " ") + (p.env.isEmpty ? "" : "  ·  " + p.env.map { "\($0)=\($1)" }.joined(separator: " ")))
                            .font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                        if p.kind == .claude, let i = integration[p.id] { integrationLine(i) }
                        if p.kind == .codex, let c = codex[p.id] { codexLine(c) }
                    }
                    .opacity(p.enabled ? 1 : 0.55)
                    Spacer(minLength: 8)
                    if p.kind == .claude, let i = integration[p.id] { integrationButton(p, i) }
                    Button { update(p, ["pinned": !p.pinned]) } label: {
                        Image(systemName: p.pinned ? "pin.fill" : "pin").font(.system(size: 12))
                            .foregroundStyle(p.pinned ? T.accent : T.text3).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).help(p.pinned ? "Pinned to the tab bar" : "Pin to the tab bar")
                    SettingSwitch(isOn: Binding(get: { p.enabled }, set: { update(p, ["enabled": $0]) }))
                        .help(p.enabled ? "Shown in the + menu" : "Hidden from the + menu")
                    Button { editing = p } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3).frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain).help("Edit command, arguments and environment")
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
        }
        let notAdded = detected.filter { d in
            let cmd = d["command"] as? String ?? ""
            return (d["installed"] as? Bool) == true && !model.state.profiles.contains { $0.command == cmd }
        }
        if !notAdded.isEmpty {
            SettingsGroup("Detected on this Mac", desc: "Agent programs on your PATH that aren't in your list yet.") {
                ForEach(Array(notAdded.enumerated()), id: \.offset) { _, d in
                    HStack(spacing: 12) {
                        AgentIcon(icon: d["icon"] as? String ?? "agent", size: 15).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d["command"] as? String ?? "").font(.system(size: 13, weight: .medium))
                            Text(d["path"] as? String ?? "").font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Add") {
                            model.client.call("profile.create", ["name": d["command"] as? String ?? "", "command": d["command"] as? String ?? "",
                                                                 "icon": d["icon"] as? String ?? "agent", "kind": d["kind"] as? String ?? "generic"])
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        SettingsGroup("Usage limits", desc: "The Claude and Codex plan limits in the status bar. Click them there to pick which agents show.") {
            SettingRow("Meters show", desc: showsLeft ? "How much of each limit is left: the bar empties as you use it." : "How much of each limit is used: the bar fills as you use it.") {
                Picker("", selection: $showsLeft) { Text("Used").tag(false); Text("Left").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        SettingsFootnote("Tip: for a second Claude account, duplicate the claude agent and set CLAUDE_CONFIG_DIR, or point Command at a wrapper like `claude-work`.")
            .padding(.top, 12)
            .sheet(item: $editing) { p in ProfileEditor(profile: p) { editing = nil } }
            .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
                if let name = n.userInfo?["editProfile"] as? String { editing = model.state.profiles.first { $0.name == name } }
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                if let c = confirming {
                    Button(c.install ? "Install" : "Remove", role: c.install ? nil : .destructive) { setIntegration(c.profile, install: c.install) }
                }
            } message: { Text(confirmMessage) }
            .onAppear {
                loadIntegration()
                model.client.call("profile.detect") { r in
                    if case .success(let v) = r { detected = v as? [[String: Any]] ?? [] }
                }
            }
    }

    /// Hooks in the profile's Claude config, so a `claude` typed in a terminal tab shows up as an agent with its
    /// state (sessions started from the + menu always get them). Claude 2.1.296+ also reports by itself.
    @ViewBuilder private func integrationLine(_ i: (dir: String, status: String)) -> some View {
        let dir = (i.dir as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 5) {
            Circle().fill(i.status == "installed" ? T.green : i.status == "outdated" ? T.amber : T.text3.opacity(0.5)).frame(width: 6, height: 6)
            Text(i.status == "installed" ? "Terminal tabs: hooks installed in \(dir)"
                 : i.status == "outdated" ? "Terminal tabs: hooks in \(dir) are out of date"
                 : "Terminal tabs: hooks not installed (\(dir))")
        }
        .font(.system(size: 11.5)).foregroundStyle(T.text2).lineLimit(1)
        .help("With hooks, a claude you type in a terminal tab shows in Agents with its state and notifications, and \"done\" shows the moment a turn ends.")
    }

    /// Codex needs no hooks: from 0.164 on it reports its state itself (launched sessions and terminal tabs).
    @ViewBuilder private func codexLine(_ c: (version: String?, status: String)) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c.status == "reports" ? T.green : c.status == "old" ? T.amber : T.text3.opacity(0.5)).frame(width: 6, height: 6)
            Text(c.status == "reports" ? "Reports its state itself (Codex \(c.version ?? ""))"
                 : c.status == "old" ? "Codex \(c.version ?? "") shows working and done only: update to 0.164 or later"
                 : "Codex version unknown")
        }
        .font(.system(size: 11.5)).foregroundStyle(T.text2).lineLimit(1)
        .help("Codex 0.164 and later tell Octomux when they work, wait for your approval or finish, also when you type codex in a terminal tab. Older versions only show working and done.")
    }

    private func integrationButton(_ p: Profile, _ i: (dir: String, status: String)) -> some View {
        Group {
            switch i.status {
            case "installed": Button("Remove Hooks") { confirming = (p, false) }
            case "outdated": Button("Update Hooks") { setIntegration(p, install: true) }
            default: Button("Install Hooks") { confirming = (p, true) }
            }
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var confirmTitle: String {
        guard let c = confirming else { return "" }
        return c.install ? "Install Octomux hooks for \(c.profile.name)?" : "Remove Octomux hooks from \(c.profile.name)?"
    }

    private var confirmMessage: String {
        guard let c = confirming else { return "" }
        let file = ((integration[c.profile.id]?.dir ?? "~/.claude") as NSString).abbreviatingWithTildeInPath + "/settings.json"
        return c.install
            ? "Adds Octomux's hooks to \(file). They do nothing outside Octomux terminal tabs; your other settings and hooks stay as they are. A backup is saved next to the file."
            : "Removes only Octomux's hooks from \(file). A backup is saved next to the file."
    }

    private func loadIntegration() {
        model.client.call("integration.status") { r in
            guard case .success(let v) = r, let list = (v as? [String: Any])?["profiles"] as? [[String: Any]] else { return }
            var m: [String: (dir: String, status: String)] = [:]
            var cx: [String: (version: String?, status: String)] = [:]
            for e in list {
                guard let id = e["profile_id"] as? String else { continue }
                if e["kind"] as? String == "codex" {
                    cx[id] = (e["version"] as? String, e["status"] as? String ?? "unknown")
                } else {
                    m[id] = (e["config_dir"] as? String ?? "", e["status"] as? String ?? "missing")
                }
            }
            DispatchQueue.main.async { integration = m; codex = cx }
        }
    }

    private func setIntegration(_ p: Profile, install: Bool) {
        model.client.call(install ? "integration.install" : "integration.uninstall", ["profile_id": p.id]) { r in
            if case .failure = r { model.report(r) }
            loadIntegration()
        }
    }

    func update(_ p: Profile, _ fields: [String: Any]) {
        var f = fields
        f["id"] = p.id
        model.client.call("profile.update", f, completion: model.report)
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @State var profile: Profile
    let done: () -> Void
    @State private var argsText = ""
    @State private var envText = ""
    @State private var resolved = ""

    init(profile: Profile, done: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.id.isEmpty ? "Add agent" : "Edit \(profile.name)").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                Picker("Type", selection: $profile.kind) {
                    Text("Claude Code").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                    Text("Other").tag(AgentKind.generic)
                }
                Picker("Icon", selection: $profile.icon) {
                    ForEach(["claude", "codex", "gemini", "terminal", "agent"], id: \.self) { i in Text(i).tag(i) }
                }
                TextField("Command", text: $profile.command).font(.system(.body, design: .monospaced))
                    .onSubmit(check)
                if !resolved.isEmpty { Text(resolved).font(.caption).foregroundStyle(T.text2) }
                TextField("Arguments", text: $argsText).font(.system(.body, design: .monospaced))
                if profile.kind == .claude || profile.kind == .codex { startOptions }
                VStack(alignment: .leading) {
                    Text("Environment (KEY=value per line)").font(.caption)
                    TextEditor(text: $envText).font(.system(.body, design: .monospaced)).frame(height: 60)
                }
                Toggle("Run through my login shell (aliases, PATH)", isOn: $profile.viaLoginShell)
                if profile.kind == .claude {
                    Toggle("Read usage limits through Claude's status line (runs your own status line too)", isOn: $profile.statusline)
                }
                if !profile.id.isEmpty {
                    Toggle("Always show usage limits in the status bar (workspaces without their own list)", isOn: Binding(
                        get: { AppModel.shared.alwaysShowList(scope: "global")?.contains(profile.id) ?? false },
                        set: { AppModel.shared.setUsageAlwaysShown(profile.id, $0, scope: "global") }))
                }
                if profile.kind == .generic {
                    TextField("Resume command after reboot (optional)", text: $profile.resumeTemplate).font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                if !profile.id.isEmpty {
                    Button(role: .destructive) {
                        model.client.call("profile.delete", ["id": profile.id], completion: model.report)
                        done()
                    } label: { Text("Delete").foregroundStyle(T.red) }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(profile.command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            argsText = profile.args.map(\.shellQuoted).joined(separator: " ")
            envText = profile.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            check()
        }
    }

    /// Model, effort and permissions as pickers; they rewrite the matching flags in Arguments.
    @ViewBuilder private var startOptions: some View {
        let kind = profile.kind
        Section {
            if kind == .claude {
                choicePicker("Model", ChatLaunchOptions.models(kind), \.model)
            } else {
                TextField("Model", text: option(\.model), prompt: Text("CLI default"))
                    .font(.system(.body, design: .monospaced))
            }
            choicePicker("Effort", ChatLaunchOptions.efforts(kind), \.effort)
            choicePicker(kind == .codex ? "Approvals" : "Permission mode", ChatLaunchOptions.permissions(kind), \.permission)
            if kind == .codex { choicePicker("Sandbox", ProfileStartOptions.sandboxes, \.sandbox) }
        } header: {
            Text("Start options").font(.caption)
        } footer: {
            Text("Every new session of this agent starts with these. They are flags in Arguments above; a new chat's own choices go on top.")
                .font(.caption).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ key: WritableKeyPath<ProfileStartOptions, String?>) -> Binding<String> {
        Binding(get: { ProfileStartOptions(kind: profile.kind, args: ShellWords.split(argsText))[keyPath: key] ?? "" },
                set: { v in
                    var o = ProfileStartOptions(kind: profile.kind, args: ShellWords.split(argsText))
                    let t = v.trimmingCharacters(in: .whitespaces)
                    o[keyPath: key] = t.isEmpty ? nil : t
                    argsText = o.args.map(\.shellQuoted).joined(separator: " ")
                })
    }

    private func choicePicker(_ title: String, _ choices: [ChatLaunchOptions.Choice], _ key: WritableKeyPath<ProfileStartOptions, String?>) -> some View {
        let b = option(key)
        let extra = b.wrappedValue.isEmpty || choices.contains { $0.id == b.wrappedValue } ? nil : b.wrappedValue
        return Picker(title, selection: b) {
            ForEach(choices) { c in
                Text(c.warn ? "\(c.title) ⚠︎" : c.title).tag(c.id ?? "")
            }
            if let extra { Text(extra).tag(extra) }
        }
        .help(choices.first { $0.id == b.wrappedValue }?.detail ?? "")
    }

    func check() {
        guard !profile.command.isEmpty else { return }
        model.client.call("profile.check", ["command": profile.command.split(separator: " ").first.map(String.init) ?? profile.command]) { r in
            if case .success(let v) = r { resolved = ((v as? [String: Any])?["path"] as? String).map { "Found: \($0)" } ?? "Not found on PATH (it may still work through your login shell)" }
        }
    }

    func save() {
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        var params: [String: Any] = [
            "name": profile.name, "kind": profile.kind.rawValue, "icon": profile.icon, "command": profile.command,
            "args": ShellWords.split(argsText), "env": env, "via_login_shell": profile.viaLoginShell,
            "resume_template": profile.resumeTemplate, "enabled": profile.enabled, "pinned": profile.pinned,
            "statusline": profile.statusline,
        ]
        if profile.id.isEmpty {
            model.client.call("profile.create", params, completion: model.report)
        } else {
            params["id"] = profile.id
            model.client.call("profile.update", params, completion: model.report)
        }
        done()
    }
}

enum ShellWords {
    /// Splits a command line into words (handles '…', "…" and backslash escapes).
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch)
            inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection

    var body: some View {
        if sel.scope == "global" {
            ThemePicker()
        }
        if sel.scope.hasPrefix("workspace:"), let w = model.state.workspaces.first(where: { "workspace:\($0.id)" == sel.scope }) {
            SettingsGroup("Workspace") {
                VisualSettingRow("Workspace color", desc: "Its dot in the sidebar, and the tint of the window while it is shown.", scrolls: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 84), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                        // A color set elsewhere (not one of the palette's) shows first, as the picked one.
                        let colors = (Palette.colors.contains { $0.caseInsensitiveCompare(w.color) == .orderedSame } ? [] : [w.color]) + Palette.colors
                        ForEach(colors, id: \.self) { c in
                            ChoiceTile(title: Palette.colors.contains(c) ? Palette.name(c) : "Current", selected: w.color.caseInsensitiveCompare(c) == .orderedSame, width: 84, height: 52,
                                       action: { model.updateWorkspace(w.id, ["color": c]) }) {
                                MiniWindow(colors: ThemeStore.shared.preset.dark, metrics: ThemeStore.shared.preset.metrics, tint: Color(hex: c))
                                    .overlay(alignment: .topTrailing) { Circle().fill(Color(hex: c)).frame(width: 7, height: 7).padding(5) }
                            }
                        }
                    }
                }
            }
        }
        SceneSettingsCard(scope: sel.scope)
        if sel.scope == "global" { IconSettings() }
    }
}

struct ThemePicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = ThemeStore.shared
    @AppStorage("octomux.sidebarStackedTabs") private var stackedTabs = true

    var body: some View {
        SettingsGroup("Theme", desc: "The shape of the window: chrome, spacing and the accent color.") {
            SettingBlock {
                HStack(spacing: 12) {
                    ForEach(Themes.all) { p in
                        let on = p.id == store.preset.id
                        Button { store.set(theme: p.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ThemeSwatch(preset: p)
                                HStack(spacing: 6) {
                                    Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.text)
                                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(T.accent) }
                                }
                                Text(p.summary).font(.system(size: 11)).foregroundStyle(T.text2).lineLimit(2, reservesSpace: true)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? T.selection : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? T.accent : T.border, lineWidth: on ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .settingAnchor("Theme")
            VisualSettingRow("Appearance", desc: store.scene.map { "The current workspace's scene (\($0.name)) is \($0.dark ? "dark" : "light"), so it decides while it is shown." }
                             ?? "System follows the macOS appearance.") {
                HStack(spacing: 12) {
                    ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { m in
                        ChoiceTile(title: m.1, selected: store.mode == m.0, action: { store.set(mode: m.0) }) { ModePreview(mode: m.0) }
                    }
                }
            }
            let themeColors = model.settingValue("appearance.terminal_colors", scope: "global")?.bool ?? true
            VisualSettingRow("Use theme colors in the terminal", desc: "Terminal background, text and palette follow the theme, or come from your terminal config (below).") {
                HStack(spacing: 12) {
                    ChoiceTile(title: "Theme colors", selected: themeColors, action: { model.setSetting("appearance.terminal_colors", nil) }) {
                        TerminalColorsPreview(themeColors: true)
                    }
                    ChoiceTile(title: "My terminal config", selected: !themeColors, action: { model.setSetting("appearance.terminal_colors", false) }) {
                        TerminalColorsPreview(themeColors: false)
                    }
                }
            }
            VisualSettingRow("Split tabs as one row", desc: "How a tab with several panes shows in the sidebar.") {
                HStack(spacing: 12) {
                    ChoiceTile(title: "One row", selected: stackedTabs, action: { stackedTabs = true }) { SplitTabsPreview(stacked: true) }
                    ChoiceTile(title: "A row per pane", selected: !stackedTabs, action: { stackedTabs = false }) { SplitTabsPreview(stacked: false) }
                }
            }
        }
    }
}

/// Appearance › Icons: the Dock icon and the menu bar icon, each picked from what it looks like.
struct IconSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppIconStyle.key) private var appIcon = "color"

    var body: some View {
        let menubar = model.settingValue("menubar.style", scope: "global")?.string ?? "color"
        SettingsGroup("Icons", desc: "How Octomux looks in the Dock and in the menu bar.") {
            if !Paths.isDevVariant {
                VisualSettingRow("App icon", desc: "In the Dock while Octomux runs. Finder, and the Dock while Octomux is quit, keep the color icon.") {
                    HStack(spacing: 12) {
                        ForEach([("color", "Color"), ("mono", "Monochrome")], id: \.0) { o in
                            ChoiceTile(title: o.1, selected: appIcon == o.0, width: 100, height: 76, action: { appIcon = o.0; AppIconStyle.set(o.0) }) {
                                AppIconPreview(style: o.0)
                            }
                        }
                    }
                }
            }
            VisualSettingRow("Menu bar icon", desc: "It bounces while an agent works and shows a dot for unread notifications; a click opens recent activity.") {
                HStack(spacing: 12) {
                    ForEach([(StatusItemController.Style.color, "Color"), (.mono, "Monochrome"), (.hidden, "Hidden")], id: \.0.rawValue) { o in
                        ChoiceTile(title: o.1, selected: menubar == o.0.rawValue, width: 128, height: 40,
                                   action: { model.setSetting("menubar.style", o.0.rawValue, scope: "global") }) {
                            MenuBarPreview(style: o.0)
                        }
                    }
                }
            }
        }
    }
}

/// Miniature of a preset: frame, sidebar rows, terminal card, accent.
struct ThemeSwatch: View {
    let preset: ThemePreset
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let c = scheme == .dark ? preset.dark : preset.light
        let r = preset.metrics.cardR > 0 ? 4.0 : 0.0
        HStack(spacing: preset.metrics.inset > 0 ? 4 : 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i == 1 ? Color(nsColor: c.accent) : Color(nsColor: c.text3).opacity(0.5))
                        .frame(width: i == 0 ? 26 : 34, height: 3)
                }
                Spacer()
            }
            .padding(6)
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: i == 4 ? c.accent : c.termFg).opacity(i == 4 ? 1 : 0.55))
                        .frame(width: [60, 44, 70, 30, 6][i], height: 3)
                }
                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: r).fill(Color(nsColor: c.surface)))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(Color(nsColor: c.border)))
            .padding(.vertical, preset.metrics.inset > 0 ? 4 : 0)
            .padding(.trailing, preset.metrics.inset > 0 ? 4 : 0)
        }
        .frame(width: 150, height: 74)
        .background(Color(nsColor: c.frame))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color(nsColor: c.border)))
    }
}

// MARK: Notifications

/// Top of the Notifications page: whether macOS shows Octomux's notifications, with a way to turn them on.
struct SystemNotificationStatus: View {
    @ObservedObject var permission: NotificationPermission
    var soundWanted = true

    var body: some View {
        switch permission.status {
        case .checking:
            EmptyView()
        case .allowed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(T.green)
                Text(permission.soundOff && soundWanted ? "Allowed in System Settings, but sounds are off there." : "Allowed in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(T.text2)
                Spacer()
                if permission.soundOff && soundWanted { settingsButton(prominent: false) }
            }
            .padding(.horizontal, 4)
        case .unavailable:
            warning("Not running from Octomux.app",
                    "This build runs outside the app bundle, so macOS has no notification settings for it. It only plays a sound and bounces the Dock icon.",
                    icon: "info.circle.fill", color: T.text3, button: nil)
        case .notDetermined:
            warning("Notifications aren't allowed yet",
                    "macOS hasn't asked yet. Allow them to see a banner when an agent finishes, needs input or fails.",
                    icon: "bell.badge.fill", color: T.amber, button: AnyView(Button("Allow Notifications") { permission.request() }.buttonStyle(.borderedProminent)))
        case .denied:
            warning("Notifications are off for Octomux",
                    "macOS doesn't show Octomux's notifications, so you won't see when an agent finishes, needs input or fails. Turn on Allow Notifications in System Settings.",
                    icon: "bell.slash.fill", color: T.red, button: AnyView(settingsButton(prominent: true)))
        case .noBanners:
            warning("Notifications are allowed, but without banners",
                    "Their alert style is None in System Settings, so they only collect in Notification Center. Pick Banners or Alerts to see them.",
                    icon: "exclamationmark.triangle.fill", color: T.amber, button: AnyView(settingsButton(prominent: true)))
        }
    }

    private func settingsButton(prominent: Bool) -> some View {
        Group {
            if prominent { Button("Open System Settings") { permission.openSystemSettings() }.buttonStyle(.borderedProminent) }
            else { Button("Open System Settings") { permission.openSystemSettings() } }
        }
    }

    private func warning(_ title: String, _ text: String, icon: String, color: Color, button: AnyView?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                Text(text).font(.system(size: 12)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                if let button { button.padding(.top, 6) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35)))
    }
}

struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection

    @ObservedObject var permission = NotificationPermission.shared

    var body: some View {
        SystemNotificationStatus(permission: permission, soundWanted: model.settingValue("notifications.sound", scope: sel.scope)?.bool ?? true)
            .onAppear { permission.refresh() }
        SettingsGroup {
            toggle("Notifications", key: "notifications.enabled",
                   desc: "Banners for agents and terminals in every project. Mute a single project from its right-click menu.")
            SettingRow("Test notification", desc: "A sample “needs input” notification with its sound, to check banners, sounds and Focus. It shows even while Octomux is in front.") {
                Button("Send Test") { Notifier.shared.sendTest() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        SettingsGroup("Notify me when") {
            toggle("Agent finished", key: "notifications.done", desc: "An agent ends its turn and waits for your next message.")
            toggle("Agent needs input", key: "notifications.needs_input", desc: "An agent asks you something or wants a permission.")
            toggle("Agent error", key: "notifications.error", desc: "An agent stops with an error.")
            toggle("Long-running command finished", key: "notifications.command_done", desc: "A terminal command that ran longer than the threshold below is done.")
            let explicit = model.settingValue("notifications.command_threshold_secs", scope: sel.scope)?.number
            let v = Int(explicit ?? model.settingValue("notifications.command_threshold_secs", scope: "global")?.number ?? 10)
            SettingRow("Command threshold", desc: "How long a command has to run before its end is worth a notification.",
                       modified: sel.scope != "global" && explicit != nil,
                       onReset: { model.setSetting("notifications.command_threshold_secs", nil, scope: sel.scope) }) {
                Stepper("\(v) s", value: Binding(get: { v }, set: { model.setSetting("notifications.command_threshold_secs", $0, scope: sel.scope) }), in: 1...600)
                    .monospacedDigit().fixedSize()
            }
            toggle("Program notifications", key: "notifications.program", desc: "Programs in a terminal that send their own notifications (OSC 9 and 777).")
        }
        SettingsGroup("Alerts") {
            toggle("Sound", key: "notifications.sound", desc: "Plays with each notification.")
            if (model.settingValue("notifications.sound", scope: sel.scope)?.bool ?? model.settingValue("notifications.sound", scope: "global")?.bool ?? true) {
                ForEach(Notifier.soundKinds, id: \.kind) { k in soundRow(k.kind, title: k.title, key: k.key) }
            }
            toggle("Dock badge", key: "notifications.badge", desc: "The number of agents waiting for you, on the Dock icon.")
        }
        SettingsFootnote("You are never notified about the pane you are looking at.")
    }

    /// The sound of one kind: picking one plays it, the speaker sends a test notification of that kind.
    func soundRow(_ kind: String, title: String, key: String) -> some View {
        let explicit = model.settingValue(key, scope: sel.scope)?.string
        let current = explicit ?? model.settingValue(key, scope: "global")?.string ?? "default"
        return SettingRow("Sound: \(title)", modified: sel.scope != "global" && explicit != nil,
                          onReset: { model.setSetting(key, nil, scope: sel.scope) }) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { current }, set: { v in
                    model.setSetting(key, v == "default" && sel.scope == "global" ? nil : v, scope: sel.scope)
                    if v != "default" { NSSound(named: v)?.play() }
                })) {
                    Text("Default").tag("default")
                    Divider()
                    ForEach(Notifier.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button { Notifier.shared.sendTest(kind: kind) } label: { Image(systemName: "speaker.wave.2").font(.system(size: 11)) }
                    .buttonStyle(ChromeButtonStyle()).help("Send a test notification with this sound")
            }
        }
    }

    func toggle(_ title: String, key: String, desc: String) -> some View {
        let explicit = model.settingValue(key, scope: sel.scope)?.bool
        let inherited = sel.scope == "global" ? true : (model.settingValue(key, scope: "global")?.bool ?? true)
        return SettingRow(title, desc: desc, modified: sel.scope != "global" && explicit != nil,
                          onReset: { model.setSetting(key, nil, scope: sel.scope) }) {
            SettingSwitch(isOn: Binding(get: { explicit ?? inherited }, set: { model.setSetting(key, $0, scope: sel.scope) }))
        }
    }
}

// MARK: Features

struct FeatureSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsGroup {
            feature("Git worktrees", key: "features.worktrees", desc: "New Worktree… in the project menu, and worktree groups in the sidebar.", available: true, defaultOn: true)
            feature("Remote hosts", key: "features.remote", desc: "Connect the window to an Octomux daemon on another machine over SSH (Settings › Hosts).", available: true, defaultOn: true)
            feature("Hosts side by side", key: "features.multi_host", desc: "Show projects of chosen remote hosts next to this Mac's, in the workspace with the same name (Hosts › Show here).", available: true, defaultOn: false)
            feature("Chat view for Claude", key: "features.chat", desc: "Show a Claude session as a chat (its transcript) and type into the same session. ⌘⇧C.", available: true, defaultOn: true)
            feature("Usage via OAuth API", key: "features.usage_oauth", desc: "Read Claude plan limits from Anthropic's usage endpoint even with no session open.", available: false)
        }
    }

    func feature(_ title: String, key: String, desc: String, available: Bool, defaultOn: Bool = false) -> some View {
        SettingRow(title, desc: desc) {
            if !available {
                Text("Later").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.text3)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(T.hover))
            }
            SettingSwitch(isOn: Binding(get: { model.setting(key)?.bool ?? defaultOn }, set: { model.setSetting(key, $0) }))
                .disabled(!available)
        }
    }
}

// MARK: Keyboard

struct KeyboardSettings: View {
    @ObservedObject var kb = KeyBindings.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var filter = ""
    /// "Find by keys": the keys pressed, or `findingKeys` while waiting for them.
    @State private var keyFilter: Shortcut?
    @State private var findingKeys = false

    var body: some View {
        let shown = kb.commands.filter { c in
            if let k = keyFilter { return kb.current(c.id) == k }
            return filter.isEmpty || c.title.localizedCaseInsensitiveContains(filter) || (kb.current(c.id)?.display ?? "").contains(filter)
                || KeyBindings.target(c.id).localizedCaseInsensitiveContains(filter)
        }
        let groups = Dictionary(grouping: shown, by: \.group)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shortcuts").font(.system(size: 13.5, weight: .semibold))
                Text("Click a shortcut to record new keys. Esc cancels, Delete removes it.").font(.system(size: 12)).foregroundStyle(T.text2)
            }
            .settingAnchor("Shortcuts")
            Spacer()
            Text("\(shown.count) of \(kb.commands.count)").font(.system(size: 11.5)).foregroundStyle(T.text3).monospacedDigit()
            if let k = keyFilter {
                Button { keyFilter = nil } label: {
                    HStack(spacing: 5) {
                        Text(k.display).font(T.mono(12, .medium))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.selection))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.accent))
                }
                .buttonStyle(.plain).help("Show every shortcut again")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(T.text3)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 8).frame(width: 160, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.frame.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.border))
            }
            Button { findingKeys ? stopRecording() : startFinding() } label: {
                Label(findingKeys ? "Press keys…" : "Find by Keys", systemImage: "keyboard")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Press a key combination to see what it does")
        }
        .padding(.horizontal, 2)
        ForEach(["Octomux", "File", "Session", "View", "Window"].filter { groups[$0] != nil }, id: \.self) { g in
            SettingsGroup(g) {
                ForEach(groups[g] ?? []) { c in
                    HStack(spacing: 10) {
                        Text(c.title).font(.system(size: 13))
                        if kb.isOverridden(c.id) {
                            Circle().fill(T.accent).frame(width: 6, height: 6).help("Changed from the default")
                        }
                        Spacer()
                        if let sc = kb.current(c.id), recording != c.id, let other = kb.conflict(sc, except: c.id) {
                            Label("also \(other.title)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(T.amber).lineLimit(1)
                        }
                        Text(KeyBindings.target(c.id)).font(.system(size: 11.5)).foregroundStyle(T.text3)
                            .frame(width: 112, alignment: .leading).lineLimit(1)
                        Button { kb.reset(c.id) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10)) }
                            .buttonStyle(ChromeButtonStyle()).help("Reset to default")
                            .opacity(kb.isOverridden(c.id) ? 1 : 0).disabled(!kb.isOverridden(c.id))
                        Button { startRecording(c.id) } label: {
                            Text(recording == c.id ? "Press keys…" : (kb.current(c.id)?.display ?? "—"))
                                .font(T.mono(12, .medium))
                                .foregroundStyle(recording == c.id ? T.accent : kb.current(c.id) == nil ? T.text3 : T.text)
                                .frame(minWidth: 96)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(recording == c.id ? T.accent : T.border))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                }
            }
        }
        if shown.isEmpty {
            Text(keyFilter.map { "Nothing uses \($0.display). It goes to the terminal program." } ?? "No shortcut matches “\(filter)”.")
                .font(.system(size: 12.5)).foregroundStyle(T.text2)
        }
        HStack {
            SettingsFootnote("“Acts on” is what the command works on: the focused pane, the tabs of the current project, and so on.")
            Spacer()
            Button("Reset All Shortcuts…") { resetAll() }
                .buttonStyle(SecondaryButtonStyle()).disabled(!kb.hasOverrides)
                .settingAnchor("Reset all shortcuts")
        }
        Color.clear.frame(height: 0).onDisappear { stopRecording() }
    }

    private func resetAll() {
        let a = NSAlert()
        a.messageText = "Reset all shortcuts?"
        a.informativeText = "Every shortcut you changed goes back to its default."
        a.addButton(withTitle: "Reset All")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { kb.resetAll() }
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let id = recording else { return e }
            if e.keyCode == 53 { stopRecording(); return nil }                           // esc
            if e.keyCode == 51 || e.keyCode == 117 { kb.set(id, nil); stopRecording(); return nil }  // delete
            if let sc = Shortcut(event: e) { kb.set(id, sc); stopRecording() }
            return nil
        }
    }

    /// The next key combination filters the list to what it does (the keys don't run the command).
    private func startFinding() {
        stopRecording()
        findingKeys = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }
            if let sc = Shortcut(event: e) { keyFilter = sc; stopRecording() }
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
        findingKeys = false
    }
}

// MARK: Hosts

struct HostsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var hosts = HostStore.all
    @State private var editing: Host?
    @State private var status: [String: String] = [:]

    var body: some View {
        SettingsGroup("Hosts", desc: "Octomux reaches a host with `ssh <host> octomux stdio` (no open ports); panes attach with `ssh -t`. Sessions keep running there when you disconnect. Install `octomux` on the host first (Linux build: see README).", trailing: {
            Button { editing = Host(id: String(UUID().uuidString.prefix(8)).lowercased(), name: "", kind: "ssh") } label: {
                Label("Add Host", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
        }) {
            ForEach(HostStore.withLocal) { h in
                HStack(spacing: 12) {
                    Image(systemName: h.isRemote ? "server.rack" : "laptopcomputer").font(.system(size: 14)).foregroundStyle(T.text3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(h.name).font(.system(size: 13, weight: .medium))
                            if model.hostId == h.id {
                                Text("Connected").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.green)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(T.green.opacity(0.14)))
                            }
                        }
                        Text(h.subtitle).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                        if let st = status[h.id] {
                            Text(st).font(.system(size: 11.5)).foregroundStyle(st.hasPrefix("OK") ? T.green : st.hasPrefix("Testing") ? T.text2 : T.red).lineLimit(1)
                        }
                    }
                    Spacer()
                    if h.isRemote, model.multiHost, model.hostId != h.id {
                        Toggle("Show here", isOn: Binding(get: { HostStore.attached.contains(h.id) }, set: { model.setAttached(h.id, $0); hosts = HostStore.all }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                    if h.isRemote {
                        Button("Test") { test(h) }.buttonStyle(SecondaryButtonStyle())
                    }
                    if model.hostId != h.id {
                        Button("Connect") { model.switchHost(h.id) }.buttonStyle(SecondaryButtonStyle())
                    }
                    if h.isRemote {
                        Menu {
                            Button("Edit…") { editing = h }
                            Divider()
                            Button("Remove Host", role: .destructive) {
                                HostStore.all.removeAll { $0.id == h.id }; hosts = HostStore.all
                                if model.hostId == h.id { model.switchHost("local") }
                            }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(T.text2) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(T.text2)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        SettingsFootnote("Changes, History, Files and worktrees work on remote projects too: the host's daemon runs git (allowlisted commands) and serves file previews. Open in… is local only.")
            .sheet(item: $editing) { h in
                HostEditor(host: h) { saved in
                    if let saved {
                        var all = HostStore.all
                        if let i = all.firstIndex(where: { $0.id == saved.id }) { all[i] = saved } else { all.append(saved) }
                        HostStore.all = all
                        hosts = all
                    }
                    editing = nil
                }
            }
    }

    private func test(_ h: Host) {
        status[h.id] = "Testing…"
        DispatchQueue.global().async {
            var msg = "Failed: no answer"
            if let argv = h.controlArgv, let s = ProcessLineStream(argv: argv) {
                let req = try! JSONSerialization.data(withJSONObject: ["id": 1, "method": "hello", "params": [:]])
                if s.writeLine(req), let line = s.readLine(), let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let r = obj["result"] as? [String: Any] { msg = "OK · daemon \(r["version"] ?? r["protocol"] ?? "")" } else { msg = "Failed: \(obj["error"] ?? "?")" }
                }
                s.close()
            }
            DispatchQueue.main.async { status[h.id] = msg }
        }
    }
}

struct HostEditor: View {
    @State var host: Host
    let done: (Host?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host.name.isEmpty ? "Add host" : "Edit host").font(T.title)
            TextField("Name (e.g. devbox)", text: $host.name).textFieldStyle(.roundedBorder)
            Picker("Connect with", selection: $host.kind) {
                Text("SSH").tag("ssh")
                Text("Custom command").tag("command")
            }
            .pickerStyle(.segmented)
            if host.kind == "ssh" {
                TextField("SSH destination (user@host, or a Host from ~/.ssh/config)", text: $host.target).textFieldStyle(.roundedBorder)
                TextField("Extra ssh options (optional, e.g. -p 2222 -i ~/.ssh/devbox)", text: Binding(get: { host.sshOptions ?? "" }, set: { host.sshOptions = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(T.mono(12))
                Text("Uses your ssh config and keys; BatchMode, so keys/agent must work without prompts.").font(T.caption).foregroundStyle(T.text3)
            } else {
                TextField("Command prefix (e.g. ssh -p 2222 box, or env OCTOMUX_HOME=/tmp/x)", text: $host.prefix).textFieldStyle(.roundedBorder).font(T.mono(12))
                TextField("Prefix for panes, if it needs a TTY (e.g. ssh -t -p 2222 box) — optional", text: Binding(get: { host.attachPrefix ?? "" }, set: { host.attachPrefix = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(T.mono(12))
            }
            TextField("Path of octomux on the host", text: $host.cli).textFieldStyle(.roundedBorder).font(T.mono(12))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { done(host) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(host.name.isEmpty || (host.kind == "ssh" ? host.target.isEmpty : host.prefix.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(T.surface)
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var info: [String: Any] = [:]
    @State private var restarting = false
    @State private var confirmStop = false

    var body: some View {
        let home = (info["home"] as? String) ?? Paths.home.path
        SettingsGroup("Daemon", desc: "It runs your sessions; each tab's program lives in its own process, so they keep running while the daemon restarts.") {
            SettingRow("Status", desc: info.isEmpty ? "Not answering" : "Running · pid \(info["pid"] ?? "?") · protocol v\(info["version"] ?? "?")") {
                Circle().fill(info.isEmpty ? T.red : T.green).frame(width: 8, height: 8)
            }
            SettingRow("Restart daemon", desc: "Starts a fresh daemon process. Sessions keep running.") {
                Button(restarting ? "Restarting…" : "Restart") {
                    restarting = true
                    model.client.call("daemon.shutdown") { _ in
                        DispatchQueue.global().async {
                            _ = DaemonClient.ensureDaemon()
                            DispatchQueue.main.async { restarting = false; refresh() }
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(restarting)
            }
            SettingRow("Data folder", desc: (home as NSString).abbreviatingWithTildeInPath, mono: true) {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: home)) }.buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("Logs", desc: ((home as NSString).appendingPathComponent("logs") as NSString).abbreviatingWithTildeInPath, mono: true) {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: home).appendingPathComponent("logs")) }.buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("Command line tool", desc: (Paths.cliBinary as NSString).abbreviatingWithTildeInPath, mono: true) {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Paths.cliBinary, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        if !model.host.isRemote {
            SettingsGroup("Danger zone") {
                SettingRow("Stop Octomux", desc: "Ends the programs in every tab (shells, agents) and the daemon, like quitting a terminal app. The window waits with a Start button; starting brings the tabs back and agents pick up their conversations.") {
                    switch model.power {
                    case .running:
                        Button { confirmStop = true } label: { Text("Stop Octomux…").foregroundStyle(T.red) }.buttonStyle(SecondaryButtonStyle())
                    case .stopped: Button("Start Octomux") { model.startOctomux() }.buttonStyle(PrimaryButtonStyle())
                    case .stopping: Text("Stopping…").foregroundStyle(T.text2)
                    case .starting: Text("Starting…").foregroundStyle(T.text2)
                    }
                }
            }
            .alert("Stop Octomux?", isPresented: $confirmStop) {
                Button("Stop", role: .destructive) { model.stopOctomux() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every shell and agent running in your tabs will be ended. Unsaved work in them is lost. Start brings the tabs back; agents resume their conversations.")
            }
        }
        Color.clear.frame(height: 0).onAppear(perform: refresh)
    }

    func refresh() {
        model.client.call("hello") { r in
            DispatchQueue.main.async {
                if case .success(let v) = r, let d = v as? [String: Any] { info = d } else { info = [:] }
            }
        }
    }
}
