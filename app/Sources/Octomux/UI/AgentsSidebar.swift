import AppKit
import SwiftUI

/// The Agents panel pinned to the bottom of the sidebar (like Herdr). Closed it is a header bar that still lists
/// the agents that need input or are working; open it grows upward to a resizable height (drag its top edge).
/// ⌥⌘A or clicking the header opens and closes it.
struct AgentsPanel: View {
    @EnvironmentObject var model: AppModel
    let maxHeight: CGFloat
    static let minHeight: CGFloat = 140
    /// Agents shown in the closed panel before "+N more".
    static let closedRows = 3
    @AppStorage("octomux.agentsPanelHeight") private var height: Double = 300
    @AppStorage("octomux.agentsGrouping") private var byProject = false
    @State private var dragStart: Double?
    @State private var hover = false

    var body: some View {
        let open = model.sidebarAgents
        let agents = model.state.sessions.filter { $0.kind == .agent && model.project($0.projectId) != nil }
        let waiting = agents.filter { !$0.isDormant && $0.activity == .needsInput }.count
        let working = agents.filter { !$0.isDormant && $0.activity == .working }.count
        let active = agents.filter { !$0.isDormant && ($0.activity == .needsInput || $0.activity == .working) }
            .sorted { ($0.activity == .needsInput ? 0 : 1, -$0.lastActivityAt) < ($1.activity == .needsInput ? 0 : 1, -$1.lastActivityAt) }
        VStack(spacing: 0) {
            Rectangle().fill(T.border).frame(height: 1)
            headerBar(open: open, total: agents.count, waiting: waiting, working: working)
                .overlay(alignment: .top) { if open { resizeHandle.offset(y: -3) } }
            if open {
                AgentsList(embedded: true)
                    .frame(height: CGFloat(min(max(height, Self.minHeight), maxHeight)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !active.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(active.prefix(Self.closedRows)) { s in AgentRow(session: s, showProject: true) }
                    if active.count > Self.closedRows {
                        Button { toggle() } label: {
                            Text("+\(active.count - Self.closedRows) more").font(T.caption).foregroundStyle(T.text3)
                                .padding(.leading, 8).frame(height: 22)
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background { sceneVeil }
        .clipped()
    }

    /// With a scene the backdrop shows through the sidebar; the panel sits on the lower part where scenes draw
    /// art (Sakura's branch, Reef's coral…), so it gets a near-opaque frame color of its own to stay readable.
    @ViewBuilder private var sceneVeil: some View {
        if let s = ThemeStore.shared.activeScene {
            Color(nsColor: s.colors.frame).opacity(0.94)
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.18)) { model.sidebarAgents.toggle() }
    }

    private func headerBar(open: Bool, total: Int, waiting: Int, working: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
                .rotationEffect(.degrees(open ? 180 : 0)).frame(width: 12)
            SectionLabel("Agents")
            if waiting > 0 { badge(waiting, T.amber, "need input") }
            if working > 0 { badge(working, T.accent, "working") }
            Spacer(minLength: 4)
            if open {
                Menu {
                    Picker("Sort agents", selection: $byProject) {
                        Label("Priority", systemImage: "clock").tag(false)
                        Label("Grouped by project", systemImage: "square.stack.3d.up").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: byProject ? "square.stack.3d.up" : "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(T.text3).menuHitBox(22, 20)
                }
                .plainMenu().fixedSize().hoverHighlight(radius: 5).help("Sort agents")
            } else if total > 0 {
                Text("\(total)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(T.text3)
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).frame(height: 30)
        .background(hover ? T.hover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
        .help(open ? "Hide agents (⌥⌘A)" : "Show every agent across workspaces (⌥⌘A)")
    }

    private func badge(_ n: Int, _ c: Color, _ what: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text("\(n)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(c)
        }
        .help("\(n) \(what)")
    }

    /// Drag the panel's top edge: up grows it, down shrinks it.
    private var resizeHandle: some View {
        VerticalResizeGrip { dy in
            if dragStart == nil { dragStart = min(max(height, Self.minHeight), maxHeight) }
            height = Double(min(maxHeight, max(Self.minHeight, CGFloat(dragStart ?? height) + dy)))
        } onEnd: { dragStart = nil }
        .frame(height: 7)
    }
}

/// An up/down resize handle tracked in AppKit (like the split divider): reports the upward distance dragged.
struct VerticalResizeGrip: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    final class V: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            let y0 = e.locationInWindow.y
            while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                onDrag?(ev.locationInWindow.y - y0)
                if ev.type == .leftMouseUp { break }
            }
            onEnd?()
        }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.onDrag = onDrag; v.onEnd = onEnd; return v }
    func updateNSView(_ v: V, context: Context) { v.onDrag = onDrag; v.onEnd = onEnd }
}

/// Every agent session in every workspace, most urgent first.
struct AgentsList: View {
    @EnvironmentObject var model: AppModel
    /// Inside the bottom panel: the panel's header bar carries the title and sort menu.
    var embedded = false
    @AppStorage("octomux.agentsGrouping") private var byProject = false
    /// Collapsed group headers (state raw values or project ids), comma-separated.
    @AppStorage("octomux.agentsCollapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private func toggle(_ key: String) {
        var c = collapsed
        if c.contains(key) { c.remove(key) } else { c.insert(key) }
        withAnimation(.easeOut(duration: 0.15)) { collapsedRaw = c.sorted().joined(separator: ",") }
    }

    enum Group: Int, CaseIterable {
        case needsInput, working, error, finished, idle, stopped
        var title: String {
            switch self {
            case .needsInput: return "Needs input"
            case .working: return "Working"
            case .error: return "Error"
            case .finished: return "Finished"
            case .idle: return "Idle"
            case .stopped: return "Stopped"
            }
        }
        var color: Color {
            switch self {
            case .needsInput: return T.amber
            case .working: return T.accent
            case .error: return T.red
            case .finished: return T.green
            default: return T.text3
            }
        }
        static func of(_ s: Session) -> Group {
            if s.isDormant { return .stopped }
            switch s.activity {
            case .needsInput: return .needsInput
            case .working: return .working
            case .error: return .error
            case .done where s.unread: return .finished
            default: return s.unread ? .finished : .idle
            }
        }
    }

    var body: some View {
        let agents = model.state.sessions.filter { $0.kind == .agent && model.project($0.projectId) != nil }
        VStack(spacing: 0) {
            if !embedded { HStack {
                SectionLabel(agents.isEmpty ? "Agents" : "\(agents.count) agents")
                Spacer()
                Menu {
                    Picker("Sort agents", selection: $byProject) {
                        Label("Priority", systemImage: "clock").tag(false)
                        Label("Grouped by project", systemImage: "square.stack.3d.up").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: byProject ? "square.stack.3d.up" : "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(T.text3).menuHitBox(22, 20)
                }
                .plainMenu().fixedSize().hoverHighlight(radius: 5).help("Sort agents")
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if byProject {
                        if agents.isEmpty { empty }
                        let projects = orderedProjects(agents)
                        ForEach(projects, id: \.id) { p in
                            let list = sorted(agents.filter { $0.projectId == p.id })
                            let open = !collapsed.contains("p:" + p.id)
                            header(p.name, count: list.count, color: nil, open: open) { toggle("p:" + p.id) }
                            if open { ForEach(list) { s in AgentRow(session: s, showProject: false) } }
                        }
                    } else {
                        ForEach(Group.allCases, id: \.rawValue) { g in
                            let list = sorted(agents.filter { Group.of($0) == g })
                            if !list.isEmpty {
                                let key = "s:\(g.rawValue)"
                                let open = !collapsed.contains(key)
                                header(g.title, count: list.count, color: g.color, open: open) { toggle(key) }
                                if open { ForEach(list) { s in AgentRow(session: s, showProject: true) } }
                            }
                        }
                        if agents.isEmpty { empty }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(T.text3)
            Text("No agents yet").font(T.body).foregroundStyle(T.text2)
            Text("Agents you start in any workspace show up here, most urgent first.")
                .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 16)
    }

    /// A group row: name, then its count and a chevron at the right (like T3 Code's Working / Snoozed / Settled).
    /// Clicking folds the group; an empty group shows 0 and stays folded.
    private func header(_ title: String, count: Int, color: Color?, open: Bool, _ action: @escaping () -> Void) -> some View {
        GroupHeaderRow(title: title, count: count, color: color, open: open, action: action)
    }

    /// Most recent activity first; needs-input oldest first would hide new ones, so newest first everywhere.
    private func sorted(_ list: [Session]) -> [Session] {
        list.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Current workspace's projects first (in sidebar order), then the others.
    private func orderedProjects(_ agents: [Session]) -> [Project] {
        let ids = Set(agents.map(\.projectId))
        let cur = model.projects.filter { ids.contains($0.id) }
        let others = model.state.projects.filter { ids.contains($0.id) && !cur.contains($0) }.sorted { $0.name < $1.name }
        return cur + others
    }
}

private struct GroupHeaderRow: View {
    let title: String
    let count: Int
    let color: Color?
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let empty = count == 0
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(color ?? (empty ? T.text3 : T.text2))
            Spacer(minLength: 4)
            Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(empty ? T.text3.opacity(0.7) : T.text3)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(T.text3.opacity(empty ? 0.5 : 1))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(hover && !empty ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .padding(.top, 4)
        .help(empty ? "No agents" : open ? "Collapse" : "Expand")
    }
}

struct AgentRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let showProject: Bool
    @State private var hover = false

    var body: some View {
        let s = session
        let selected = model.activeDoc == nil && model.focusedSessionId == s.id
        let project = model.project(s.projectId)
        let ws = model.state.workspaces.first { $0.id == project?.workspaceId }
        let multiWs = model.state.workspaces.count > 1
        HStack(spacing: 9) {
            AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle)
                    .font(.system(size: 12.5, weight: selected || s.unread ? .semibold : .medium))
                    .foregroundStyle(selected ? T.text : T.text2).lineLimit(1)
                HStack(spacing: 4) {
                    if showProject {
                        if multiWs, let ws {
                            Text(ws.name).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        }
                        Text(project?.name ?? "").lineLimit(1)
                    } else {
                        Text(AgentsList.Group.of(s).title)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(T.text3)
            }
            Spacer(minLength: 4)
            TimelineView(.everyMinute) { _ in
                Text(Self.elapsed(since: s.lastActivityAt)).font(.system(size: 10.5)).foregroundStyle(T.text3).monospacedDigit()
            }
            ActivityIndicator(session: s)
        }
        .opacity(s.isDormant ? 0.5 : 1)
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous)
            .fill(selected ? WorkspaceTint.selection(model) : hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectSession(s.id) }
        .contextMenu { SessionMenu(session: s) }
        .help("\(model.profile(s.profileId)?.name ?? "Agent") · \(ws.map { $0.name + " › " } ?? "")\(project?.name ?? "")")
    }

    static func elapsed(since t: Int) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970) - t)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
