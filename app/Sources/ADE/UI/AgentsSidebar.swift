import SwiftUI

/// "Projects | Agents" at the top of the sidebar: always visible, so the agents view is easy to find
/// and to leave (⌥⌘A toggles it too).
struct SidebarModeSwitch: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let busy = model.state.sessions.filter { $0.kind == .agent && !$0.isDormant && ($0.activity == .working || $0.activity == .needsInput) }.count
        let waiting = model.state.sessions.contains { $0.kind == .agent && $0.activity == .needsInput }
        HStack(spacing: 2) {
            segment("Projects", selected: !model.sidebarAgents, badge: nil) { model.sidebarAgents = false }
            segment("Agents", selected: model.sidebarAgents, badge: busy > 0 ? (busy, waiting ? T.amber : T.accent) : nil) { model.sidebarAgents = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.hover))
        .help("Projects, or every agent across workspaces (⌥⌘A)")
    }

    private func segment(_ title: String, selected: Bool, badge: (Int, Color)?, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { action() } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let (n, c) = badge {
                    Text("\(n)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(c))
                }
            }
            .foregroundStyle(selected ? T.text : T.text2)
            .frame(maxWidth: .infinity).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? (ThemeStore.shared.isDark ? Color.white.opacity(0.12) : T.raised) : .clear)
                .shadow(color: .black.opacity(selected && !ThemeStore.shared.isDark ? 0.12 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// Every agent session in every workspace, most urgent first.
struct AgentsList: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("ade.agentsGrouping") private var byProject = false
    /// Collapsed group headers (state raw values or project ids), comma-separated.
    @AppStorage("ade.agentsCollapsed") private var collapsedRaw = ""
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
            HStack {
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
                        // Every state is listed, empty ones too, so the counts read like a dashboard.
                        ForEach(Group.allCases, id: \.rawValue) { g in
                            let list = sorted(agents.filter { Group.of($0) == g })
                            let key = "s:\(g.rawValue)"
                            let open = !collapsed.contains(key) && !list.isEmpty
                            header(g.title, count: list.count, color: list.isEmpty ? nil : g.color, open: open) { if !list.isEmpty { toggle(key) } }
                            if open { ForEach(list) { s in AgentRow(session: s, showProject: true) } }
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
