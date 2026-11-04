import AppKit
import SwiftUI

/// The Agents panel pinned to the bottom of the sidebar. Closed it is only a header bar whose right
/// side shows what agents are doing (working, need input, error, finished); open it grows upward to a resizable
/// height (drag its top edge). It never opens by itself.
/// ⌥⌘A or clicking the header opens and closes it.
struct AgentsPanel: View {
    @EnvironmentObject var model: AppModel
    let maxHeight: CGFloat
    static let minHeight: CGFloat = 140
    @AppStorage("octomux.agentsPanelHeight") private var height: Double = 300
    @AppStorage(AgentsMenu.onlyHereKey) private var onlyHere = false
    @State private var dragStart: Double?
    @State private var hover = false

    var body: some View {
        let open = model.sidebarAgents
        let agents = model.agentSessions(onlyCurrentWorkspace: onlyHere && model.state.workspaces.count > 1)
        let live = agents.filter { !$0.isDormant }
        let counts = Counts(working: live.filter { $0.activity == .working }.count,
                            waiting: live.filter { $0.activity == .needsInput }.count,
                            failed: live.filter { $0.activity == .error }.count,
                            finished: live.filter { AgentsList.Group.of($0) == .finished }.count)
        VStack(spacing: 0) {
            Rectangle().fill(T.border).frame(height: 1)
            headerBar(open: open, total: agents.count, counts: counts)
                .overlay(alignment: .top) { if open { resizeHandle.offset(y: -3) } }
            if open {
                AgentsList(embedded: true)
                    .frame(height: CGFloat(min(max(height, Self.minHeight), maxHeight)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.18)) { model.sidebarAgents.toggle() }
    }

    struct Counts { var working = 0, waiting = 0, failed = 0, finished = 0
        var isEmpty: Bool { working + waiting + failed + finished == 0 } }

    private func headerBar(open: Bool, total: Int, counts: Counts) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
                .rotationEffect(.degrees(open ? 180 : 0)).frame(width: 12)
            SectionLabel("Agents")
            if onlyHere && model.state.workspaces.count > 1 {
                Text("this workspace").font(.system(size: 10.5)).foregroundStyle(T.text3).lineLimit(1)
                    .help("Showing only \(model.workspace?.name ?? "this workspace")'s agents. Change it in the panel's menu.")
            }
            Spacer(minLength: 4)
            indicators(counts)
            if counts.isEmpty && !open && total > 0 {
                Text("\(total)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(T.text3)
                    .help("\(total) agents, none busy")
            }
            if open {
                AgentsMenu()
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).frame(height: 30)
        .background(hover ? T.hover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
        .help(open ? "Hide agents (⌥⌘A)" : onlyHere && model.state.workspaces.count > 1 ? "Show this workspace's agents (⌥⌘A)" : "Show every agent across workspaces (⌥⌘A)")
    }

    /// What agents are doing, most urgent first, each with its count; the same marks as the session rows.
    @ViewBuilder private func indicators(_ c: Counts) -> some View {
        HStack(spacing: 9) {
            if c.waiting > 0 {
                mark(c.waiting, T.amber, "\(c.waiting) need\(c.waiting == 1 ? "s" : "") your input") {
                    Image(systemName: "hand.raised.fill").font(.system(size: 9.5)).foregroundStyle(T.amber)
                }
            }
            if c.failed > 0 {
                mark(c.failed, T.red, "\(c.failed) failed") {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(T.red)
                }
            }
            if c.working > 0 {
                mark(c.working, T.text2, "\(c.working) working") { WorkingRing().scaleEffect(0.85) }
            }
            if c.finished > 0 {
                mark(c.finished, T.green, "\(c.finished) finished, not looked at yet") {
                    Circle().fill(T.green).frame(width: 7, height: 7)
                }
            }
        }
    }

    private func mark(_ n: Int, _ color: Color, _ help: String, @ViewBuilder _ icon: () -> some View) -> some View {
        HStack(spacing: 3) {
            icon().frame(width: 12, height: 12)
            Text("\(n)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
        .help(help)
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
    @AppStorage(AgentsMenu.onlyHereKey) private var onlyHere = false
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
            // Its turn is over but shells it started still run: not idle yet.
            default: return s.unread || (s.backgroundShells ?? 0) > 0 ? .finished : .idle
            }
        }
    }

    var body: some View {
        let filtered = onlyHere && model.state.workspaces.count > 1
        let agents = model.agentSessions(onlyCurrentWorkspace: filtered)
        VStack(spacing: 0) {
            if !embedded { HStack {
                SectionLabel(agents.isEmpty ? "Agents" : "\(agents.count) agents")
                Spacer()
                AgentsMenu()
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

    @ViewBuilder private var empty: some View {
        let filtered = onlyHere && model.state.workspaces.count > 1
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(T.text3)
            Text(filtered ? "No agents in this workspace" : "No agents yet").font(T.body).foregroundStyle(T.text2)
            if filtered {
                Button("Show all workspaces") { onlyHere = false }.buttonStyle(.link).font(T.caption)
            } else {
                Text("Agents you start in any workspace show up here, most urgent first.")
                    .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center)
            }
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
    @AppStorage(AgentsMenu.onlyHereKey) private var onlyHere = false
    let session: Session
    let showProject: Bool
    @State private var hover = false

    var body: some View {
        let s = session
        let selected = model.activeDoc == nil && model.focusedSessionId == s.id
        let project = model.project(s.projectId)
        let ws = model.state.workspaces.first { $0.id == project?.workspaceId }
        // The workspace name tells agents apart only while others' agents are listed too.
        let multiWs = model.state.workspaces.count > 1 && !onlyHere
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
        .help("\(model.profile(s.profileId)?.name ?? s.agentApp.map(agentAppLabel) ?? "Agent") · \(ws.map { $0.name + " › " } ?? "")\(project?.name ?? "")")
    }

    static func elapsed(since t: Int) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970) - t)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// The Agents panel's menu: how agents are sorted, and (with several workspaces) whose are shown.
struct AgentsMenu: View {
    static let onlyHereKey = "octomux.agentsOnlyWorkspace"
    @EnvironmentObject var model: AppModel
    @AppStorage("octomux.agentsGrouping") private var byProject = false
    @AppStorage(onlyHereKey) private var onlyHere = false

    var body: some View {
        let several = model.state.workspaces.count > 1
        Menu {
            Picker("Sort agents", selection: $byProject) {
                Label("Priority", systemImage: "clock").tag(false)
                Label("Grouped by project", systemImage: "square.stack.3d.up").tag(true)
            }
            .pickerStyle(.inline)
            if several {
                Picker("Show", selection: $onlyHere) {
                    Label("All workspaces", systemImage: "square.grid.2x2").tag(false)
                    Label("This workspace", systemImage: "square").tag(true)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: byProject ? "square.stack.3d.up" : "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(several && onlyHere ? T.accent : T.text3).menuHitBox(22, 20)
        }
        .plainMenu().fixedSize().hoverHighlight(radius: 5).help(several ? "Sort and filter agents" : "Sort agents")
    }
}
