import SwiftUI

/// The Agents layout's left rail: the workspace's sessions by what they need from you (Waiting for you, Working,
/// Done, Idle), each with the last thing it said; projects as filter chips above. Terminals without an agent are
/// listed under Idle. ↑ ↓ move, ↩ opens (while the rail has the keys); ⌘1…9 open the first nine.
enum RailGroup: String, CaseIterable, Identifiable {
    case waiting, working, done, idle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .waiting: return "Waiting for you"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
    var tone: Color {
        switch self {
        case .waiting: return T.amber
        case .working: return T.accent
        case .done: return T.green
        case .idle: return T.text3
        }
    }

    static func of(_ s: Session) -> RailGroup {
        guard s.isAgent, !s.isDormant else { return .idle }
        switch s.activity {
        case .needsInput, .error: return .waiting
        case .working: return .working
        case .done: return .done
        case .idle: return s.unread ? .done : .idle
        }
    }
}

enum AgentRailModel {
    /// The sessions the rail lists (tab sessions of the given projects; no dock terminals or action runs).
    static func sessions(_ all: [Session], projects: Set<String>, filter: String?) -> [Session] {
        all.filter { s in
            guard projects.contains(s.projectId), s.placement == .tab, s.kind != .action else { return false }
            if let f = filter { return s.projectId == f }
            return true
        }
    }

    /// The groups in order, each newest first; empty groups left out.
    static func grouped(_ list: [Session]) -> [(RailGroup, [Session])] {
        let g = Dictionary(grouping: list, by: RailGroup.of)
        return RailGroup.allCases.compactMap { k in
            guard let l = g[k], !l.isEmpty else { return nil }
            return (k, l.sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id })
        }
    }

    /// The rail top to bottom (⌘1…9, ↑ ↓).
    static func flat(_ list: [Session]) -> [Session] { grouped(list).flatMap(\.1) }
}

extension AppModel {
    /// The rail's sessions in order, for the current workspace and the chosen project filter.
    var railSessions: [Session] {
        let ps = Set(projects.map(\.id))
        let filter = UserDefaults.standard.string(forKey: AgentRail.filterKey).flatMap { ps.contains($0) ? $0 : nil }
        return AgentRailModel.flat(AgentRailModel.sessions(state.sessions, projects: ps, filter: filter))
    }
}

struct AgentRail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests
    static let filterKey = "octomux.railFilter"
    @AppStorage(AgentRail.filterKey) private var filter = ""
    @ObservedObject private var keys = RailKeys.shared
    private var focused: Bool { keys.active }
    @State private var cursor: String?
    @State private var moreIdle = false
    /// Idle sessions shown before "Show N more".
    static let idleShown = 6

    var body: some View {
        let ps = Set(model.projects.map(\.id))
        let list = AgentRailModel.sessions(model.state.sessions, projects: ps, filter: ps.contains(filter) ? filter : nil)
        let groups = AgentRailModel.grouped(list)
        let flat = groups.flatMap(\.1)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: T.m.topH)            // traffic lights and the top-left buttons
            Button { model.shellNew() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(T.icon(11, .semibold))
                    Text("New session").font(.system(size: T.k * 13, weight: .medium))
                    Spacer()
                    Text("⌘T").font(T.mono(11)).foregroundStyle(T.text3)
                        .padding(.horizontal, 5).background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(T.border))
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().padding(.horizontal, 10)
            chips(ps)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { g, sessions in
                        HomeSection(title: g.title, count: sessions.count, dot: g.tone).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        let cut = g == .idle && !moreIdle ? Array(sessions.prefix(Self.idleShown)) : sessions
                        ForEach(cut) { s in row(s, selected: isSelected(s), cursor: focused && cursor == s.id) }
                        if g == .idle { MoreToggle(hidden: sessions.count - cut.count, expanded: $moreIdle) }
                    }
                    if flat.isEmpty {
                        Text(model.projects.isEmpty ? "Add a project to start (⌘⇧O)." : "No sessions yet. Start one above.")
                            .font(T.meta).foregroundStyle(T.text3).padding(14)
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            RailFooter()
        }
        .contentShape(Rectangle())
        .onTapGesture { keys.active = true }            // a click on the rail's free space gives it the keys
        .background(RailKeyMonitor(active: keys.active) { code in
            switch code {
            case 125: move(1, flat)
            case 126: move(-1, flat)
            case 36, 76:
                guard let id = cursor else { return false }
                keys.active = false; model.selectSession(id)
            case 53: keys.active = false
            default: return false
            }
            return true
        })
        .onReceive(NotificationCenter.default.publisher(for: .octomuxRailFocus)) { _ in keys.active = true }
        .onChange(of: keys.active) { _, f in if f { cursor = model.shellHome ? flat.first?.id : (model.focusedSessionId ?? flat.first?.id) } }
    }

    private func isSelected(_ s: Session) -> Bool { !model.shellHome && model.focusedSessionId == s.id }

    private func move(_ d: Int, _ flat: [Session]) {
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex { $0.id == cursor } ?? (d > 0 ? -1 : flat.count)
        cursor = flat[min(max(0, i + d), flat.count - 1)].id
    }

    private func chips(_ ps: Set<String>) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            chip("All", nil, on: !ps.contains(filter))
            ForEach(model.projects) { p in chip(p.name, p, on: filter == p.id) }
        }
        .padding(.horizontal, 10).padding(.top, 10)
    }

    private func chip(_ title: String, _ p: Project?, on: Bool) -> some View {
        Button { filter = p?.id ?? "" } label: {
            HStack(spacing: 5) {
                if let p { Circle().fill(Color(hex: p.color)).frame(width: 6, height: 6) }
                Text(title).font(.system(size: T.k * 11, weight: on ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(on ? T.text : T.text2)
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous).fill(on ? T.selection : T.hover.opacity(0.6)))
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func row(_ s: Session, selected: Bool, cursor: Bool) -> some View {
        let d = digests.digests[s.id]
        let line: String = {
            switch d?.pending {
            case .permission(let p)?: return "Allow \(p)?"
            case .question(let q, _)?: return q
            case nil:
                if RailGroup.of(s) == .waiting { return s.activity == .error ? "Stopped on an error" : "Waiting for your answer" }
                if let sm = d?.summary, !sm.isEmpty { return sm }
                if !s.isAgent { return "terminal" }
                return s.firstPrompt ?? ""
            }
        }()
        return Button { keys.active = false; model.selectSession(s.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.displayTitle).font(.system(size: T.k * 13, weight: selected || s.unread ? .semibold : .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if RailGroup.of(s) == .working { WorkingRing().scaleEffect(0.7).frame(width: 12, height: 12) }
                        Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
                    }
                    Text(line + (model.project(s.projectId).map { (line.isEmpty ? "" : " · ") + $0.name } ?? ""))
                        .font(T.meta).foregroundStyle(T.text3).lineLimit(1)
                    WorkChips(session: s, limit: 1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(selected ? T.selection : cursor ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(cursor && !selected ? T.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contextMenu { SessionMenu(session: s) }
    }
}

/// The rail's bottom row: the same buttons as the classic sidebar's (+, workspace dots, Settings).
struct RailFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            AddMenu()
            Spacer(minLength: 4)
            WorkspaceSwitcher()
            Spacer(minLength: 4)
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: {
                Image(systemName: "gearshape").font(.system(size: T.k * 13))
            }.buttonStyle(IconButtonStyle(size: 26)).help("Settings (⌘,)")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

/// Whether the agent rail has the keys (↑ ↓ ↩ Esc). On: a click on the rail, ⌥⌘A; off: opening a session, a click in a
/// terminal, Esc.
final class RailKeys: ObservableObject {
    static let shared = RailKeys()
    @Published var active = false
}

/// Sees key presses while the rail has the keys (an app-local monitor, so it works whatever the first responder is,
/// and only then: the terminal gets every key otherwise). `handle` returns whether it used the key.
struct RailKeyMonitor: NSViewRepresentable {
    let active: Bool
    let handle: (UInt16) -> Bool
    final class V: NSView {
        var handle: ((UInt16) -> Bool)?
        var monitor: Any?
        func set(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard let self, RailKeyMonitor.mine(e.window, flags: e.modifierFlags, rail: self.window, modal: NSApp.modalWindow) else { return e }
                    return self.handle?(e.keyCode) == true ? nil : e
                }
            } else if !on, let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
        override func viewDidMoveToWindow() { if window == nil { set(false) } }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
    /// A key is the rail's only in the rail's own window, with no ⌘ ⌃ ⌥, no sheet or alert up, and nobody typing in a
    /// field there; Settings, alerts and other windows keep their ↩ Esc ↑ ↓.
    static func mine(_ eventWindow: NSWindow?, flags: NSEvent.ModifierFlags, rail: NSWindow?, modal: NSWindow?) -> Bool {
        guard let rail, eventWindow === rail, modal == nil, rail.attachedSheet == nil,
              flags.intersection([.command, .control, .option]).isEmpty else { return false }
        return !(rail.firstResponder is NSTextView)                                    // typing in a field: its keys
    }
    func makeNSView(context: Context) -> V { let v = V(); v.handle = handle; v.set(active); return v }
    func updateNSView(_ v: V, context: Context) { v.handle = handle; v.set(active) }
}
