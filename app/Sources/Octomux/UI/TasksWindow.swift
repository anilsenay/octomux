import SwiftUI

// The Tasks layout's window: the workspace's tasks on a rail on the left (by what they need from you), the work area
// in the middle (the assistant, or the agent of the task you picked), the picked task in detail on the right. The
// same task records, assistant and Autopilot as the Tasks panel; this window only arranges them.

/// What the tasks rail lists and in which order (⌘1…9, ⌘[ ⌘], ↑ ↓).
enum TasksRailModel {
    /// The groups in the panel's order (what needs you first); Done only when asked for. Empty groups left out.
    static func grouped(_ tasks: [WorkTask], filter: TaskState?, showDone: Bool) -> [(TaskState, [WorkTask])] {
        let ordered = TaskRules.ordered(tasks)
        return TaskState.shown.compactMap { st in
            guard filter == nil || filter == st, st != .done || showDone || filter == .done else { return nil }
            let l = ordered.filter { $0.state == st }
            return l.isEmpty ? nil : (st, l)
        }
    }
    static func flat(_ tasks: [WorkTask], filter: TaskState?, showDone: Bool) -> [WorkTask] {
        grouped(tasks, filter: filter, showDone: showDone).flatMap(\.1)
    }
    /// A project's tasks (nil: every project's).
    static func inProject(_ tasks: [WorkTask], _ project: String?) -> [WorkTask] {
        guard let project else { return tasks }
        return tasks.filter { $0.projectId == project }
    }
    /// The sessions no task has (agents you started yourself, terminals), as the agent rail orders them; not the
    /// assistant (it has its own row).
    static func untasked(_ sessions: [Session], tasks: [WorkTask], assistant: String?) -> [Session] {
        let tasked = Set(tasks.flatMap(\.sessions))
        return AgentRailModel.flat(sessions.filter { !tasked.contains($0.id) && $0.id != assistant })
    }
    /// Where a new task goes: the project the rail shows, else the one you picked last, else the first.
    static func newTaskProject(filter: String?, current: String?, projects: [String]) -> String? {
        if let filter, projects.contains(filter) { return filter }
        if let current, projects.contains(current) { return current }
        return projects.first
    }
}

extension AppModel {
    static let tasksFilterKey = "octomux.tasksRailFilter"
    static let tasksDoneKey = "octomux.tasksRailDone"
    static let tasksProjectKey = "octomux.tasksRailProject"

    /// The project the tasks rail shows (nil: all of the workspace's; a project of another workspace counts as none).
    var tasksProjectFilter: String? {
        UserDefaults.standard.string(forKey: Self.tasksProjectKey).flatMap { id in projects.contains { $0.id == id } ? id : nil }
    }

    /// The tasks rail top to bottom, as it shows now.
    var tasksRail: [WorkTask] {
        let f = UserDefaults.standard.string(forKey: Self.tasksFilterKey).flatMap(TaskState.init(rawValue:))
        return TasksRailModel.flat(TasksRailModel.inProject(workspaceTasks, tasksProjectFilter), filter: f,
                                   showDone: UserDefaults.standard.bool(forKey: Self.tasksDoneKey))
    }

    /// Picks a task in the Tasks window: its detail on the right, its agent (else the assistant) in the middle.
    func shellSelectTask(_ id: String) {
        shellTaskId = id
        guard let t = task(id) else { return }
        if let a = t.sessions.compactMap({ session($0) }).last {
            if a.isDormant { restart(a.id) }
            selectSession(a.id)
        } else if let a = assistantSession(workspace: selectedWorkspaceId) {
            selectSession(a.id)
        }
    }
}

struct TasksRail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var autopilot = TaskAutopilot.shared
    @ObservedObject private var keys = RailKeys.shared
    @AppStorage(AppModel.tasksFilterKey) private var filterRaw = ""
    @AppStorage(AppModel.tasksDoneKey) private var showDone = false
    @AppStorage(AppModel.tasksProjectKey) private var projectRaw = ""
    @AppStorage("octomux.tasksRailSessions") private var showSessions = false
    /// The project a new task goes to (nil: where the rail points, see TasksRailModel.newTaskProject).
    @State private var newProject: String?
    @State private var cursor: String?
    @State private var adding = false
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    private var filter: TaskState? { TaskState(rawValue: filterRaw) }

    var body: some View {
        let all = TasksRailModel.inProject(model.workspaceTasks, model.tasksProjectFilter)
        let groups = TasksRailModel.grouped(all, filter: filter, showDone: showDone)
        let flat = groups.flatMap(\.1)
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: T.m.topH)       // traffic lights and the top-left buttons: drags the window
            assistantRow
            newTask
            if model.projects.count > 1 {
                ProjectScopeButton(selected: model.tasksProjectFilter, count: { id in
                    TasksRailModel.inProject(model.workspaceTasks, id).filter { $0.state == .needsYou }.count
                }) { projectRaw = $0 ?? ""; newProject = nil }
                .padding(.horizontal, 10).padding(.top, 10)
            }
            chips(all)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { st, list in
                        HomeSection(title: st.title, count: list.count, dot: TaskRow.color(st))
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        ForEach(list) { t in row(t, cursor: keys.active && cursor == t.id).id(t.id + t.state.rawValue) }
                    }
                    if flat.isEmpty {
                        Text(all.isEmpty ? "No tasks yet. Add one above, or ask the assistant to plan the work." : "No tasks here.")
                            .font(T.meta).foregroundStyle(T.text3).padding(14)
                    }
                    let done = all.filter { $0.state == .done }.count
                    if filter == nil, done > 0 {
                        Button { showDone.toggle() } label: {
                            Text(showDone ? "Hide done" : "Show \(done) done").font(T.meta).foregroundStyle(T.text3)
                        }
                        .buttonStyle(.plain).pointerCursor().padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    untaskedSessions
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            RailFooter()
        }
        .contentShape(Rectangle())
        .onTapGesture { keys.active = true }
        .background(RailKeyMonitor(active: keys.active) { code in
            switch code {
            case 125: move(1, flat)
            case 126: move(-1, flat)
            case 36, 76:
                guard let id = cursor else { return false }
                keys.active = false; model.shellSelectTask(id)
            case 53: keys.active = false
            default: return false
            }
            return true
        })
        .onReceive(NotificationCenter.default.publisher(for: .octomuxRailFocus)) { _ in keys.active = true }
        .onReceive(NotificationCenter.default.publisher(for: .octomuxShellComposer)) { _ in adding = true; addFocused = true }
        .onChange(of: keys.active) { _, f in if f { cursor = model.shellTaskId.flatMap { id in flat.contains { $0.id == id } ? id : nil } ?? flat.first?.id } }
    }

    // MARK: Top

    /// The assistant: open it (it is the window's home) and how far Autopilot may go.
    private var assistantRow: some View {
        let ws = model.selectedWorkspaceId
        let a = model.assistantSession(workspace: ws)
        let level = model.autopilot(workspace: ws)
        let on = a != nil && model.focusedSessionId == a?.id && model.activeDoc == nil
        return HStack(spacing: 8) {
            Button { model.shellTaskId = nil; model.openAssistant() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(T.icon(11, .semibold)).foregroundStyle(T.accent)
                    Text("Assistant").font(.system(size: T.k * 13, weight: .medium))
                    if let a, a.activity == .working { WorkingRing().scaleEffect(0.65).frame(width: 12, height: 12) }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(a == nil ? "Start the workspace's assistant (your default agent, editing off) (⌘0)" : "Open the assistant (⌘0)")
            Menu {
                ForEach(Autopilot.allCases) { l in
                    Button { model.setAutopilot(l, workspace: ws) } label: {
                        if l == level { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                    }
                }
                Divider()
                Text(level.desc)
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(level == .off ? T.text3.opacity(0.5) : T.green).frame(width: 6, height: 6)
                    Text(level == .off ? "Autopilot off" : level.title).font(.system(size: T.k * 11, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(level == .off ? T.text3 : T.text)
            }
            .plainMenu().fixedSize().help("Autopilot: what the assistant may do without asking. \(level.desc)")
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(on ? T.selection : T.hover))
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var newTask: some View {
        if adding {
            HStack(spacing: 6) {
                if model.projects.count > 1 {
                    ProjectScopeButton(selected: targetProject?.id, allowsAll: false, compact: true) { id in
                        newProject = id; addFocused = true
                    }
                    .fixedSize()
                }
                TextField(model.projects.count > 1 ? "New task (↩)" : "New task in \(targetProject?.name ?? "the project") (↩)", text: $newTitle)
                    .textFieldStyle(.plain).font(.system(size: T.k * 12))
                    .focused($addFocused)
                    .onSubmit(add)
                    .onExitCommand { adding = false; newTitle = "" }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(T.accent.opacity(0.6)))
            .padding(.horizontal, 10).padding(.top, 6)
        } else {
            Button { adding = true; addFocused = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(T.icon(11, .semibold))
                    Text("New task").font(.system(size: T.k * 13))
                    Spacer()
                    Text("⌘T").font(T.mono(11)).foregroundStyle(T.text3)
                        .padding(.horizontal, 5).background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(T.border))
                }
                .foregroundStyle(T.text2)
                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().padding(.horizontal, 10).padding(.top, 6)
        }
    }

    private var targetProject: Project? {
        model.project(newProject ?? TasksRailModel.newTaskProject(filter: model.tasksProjectFilter, current: model.currentProject?.id,
                                                                 projects: model.projects.map(\.id)) ?? "")
    }

    private func chips(_ all: [WorkTask]) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            chip("All", all.filter { $0.state != .done }.count, nil)
            ForEach([TaskState.needsYou, .readyToReview, .working, .inReview, .planned], id: \.self) { st in
                let n = all.filter { $0.state == st }.count
                if n > 0 || filter == st { chip(st.title, n, st) }
            }
        }
        .padding(.horizontal, 10).padding(.top, 10)
    }

    private func chip(_ title: String, _ n: Int, _ st: TaskState?) -> some View {
        let on = filter == st
        return Button { filterRaw = st?.rawValue ?? "" } label: {
            HStack(spacing: 4) {
                if let st { Circle().fill(TaskRow.color(st)).frame(width: 6, height: 6) }
                Text(title).font(.system(size: T.k * 11, weight: on ? .semibold : .regular)).lineLimit(1)
                Text("\(n)").font(.system(size: T.k * 11)).foregroundStyle(T.text3).monospacedDigit()
            }
            .foregroundStyle(on ? T.text : T.text2)
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous).fill(on ? T.selection : T.hover.opacity(0.6)))
        }
        .buttonStyle(.plain).pointerCursor()
    }

    // MARK: Rows

    private func row(_ t: WorkTask, cursor: Bool) -> some View {
        let selected = model.shellTaskId == t.id
        let requested = autopilot.requested[t.id] != nil
        let agent = t.sessions.compactMap { model.session($0) }.last
        let sub: String = {
            if requested { return "The assistant asks to start this" }
            var parts: [String] = []
            switch t.state {
            case .working: parts.append(agent.map(\.displayTitle) ?? "working")
            case .needsYou: parts.append("its agent waits for you")
            case .readyToReview: parts.append("ready to review")
            case .inReview: parts.append("pull request open")
            default: break
            }
            if let p = model.project(t.projectId) { parts.append(p.name) }
            return parts.joined(separator: " · ")
        }()
        return Button { keys.active = false; model.shellSelectTask(t.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                TaskRow.glyph(t.state).frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let k = t.sourceKey { Text(k).font(T.mono(11)).foregroundStyle(T.text3) }
                        Text(t.title).font(.system(size: T.k * 13, weight: selected || t.state == .needsYou ? .semibold : .medium))
                            .foregroundStyle(t.state == .done ? T.text3 : T.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if let a = agent { Text(AgentRow.elapsed(since: a.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit() }
                    }
                    Text(sub).font(T.meta).foregroundStyle(requested ? T.amber : T.text3).lineLimit(1)
                }
            }
            .padding(.leading, t.parentId == nil ? 10 : 26).padding(.trailing, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(selected ? T.selection : cursor ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(cursor && !selected ? T.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// Sessions without a task, folded at the bottom: nothing in the workspace is out of reach from this window.
    @ViewBuilder private var untaskedSessions: some View {
        let ps = Set(model.projects.map(\.id))
        let sessions = AgentRailModel.sessions(model.state.sessions, projects: ps, filter: model.tasksProjectFilter)
        let list = TasksRailModel.untasked(sessions, tasks: model.workspaceTasks, assistant: model.assistantSession(workspace: model.selectedWorkspaceId)?.id)
        if !list.isEmpty {
            Button { showSessions.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSessions ? "chevron.down" : "chevron.right").font(T.icon(9, .semibold)).frame(width: 10)
                    Text("Sessions without a task").font(.system(size: T.k * 11, weight: .semibold))
                    Text("\(list.count)").font(.system(size: T.k * 11)).monospacedDigit()
                    Spacer()
                    let waiting = list.filter { RailGroup.of($0) == .waiting }.count
                    if waiting > 0 { Text("\(waiting) waiting").font(T.meta).foregroundStyle(T.amber) }
                }
                .foregroundStyle(T.text3).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            if showSessions { ForEach(list) { s in sessionRow(s) } }
        }
    }

    private func sessionRow(_ s: Session) -> some View {
        let selected = model.shellTaskId == nil && model.focusedSessionId == s.id && model.activeDoc == nil
        return Button { keys.active = false; model.selectSession(s.id) } label: {
            HStack(spacing: 8) {
                AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 16)
                Text(s.displayTitle).font(.system(size: T.k * 12, weight: selected ? .semibold : .regular)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 4)
                if RailGroup.of(s) == .waiting { Circle().fill(T.amber).frame(width: 6, height: 6) }
                else if RailGroup.of(s) == .working { WorkingRing().scaleEffect(0.6).frame(width: 10, height: 10) }
                if let p = model.project(s.projectId), model.tasksProjectFilter == nil { Text(p.name).font(T.meta).foregroundStyle(T.text3).lineLimit(1) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(selected ? T.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contextMenu { SessionMenu(session: s) }
    }

    private func move(_ d: Int, _ flat: [WorkTask]) {
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex { $0.id == cursor } ?? (d > 0 ? -1 : flat.count)
        cursor = flat[min(max(0, i + d), flat.count - 1)].id
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard let p = targetProject else { model.lastError = "Add a project first (⌘⇧O)."; return }
        model.createTask(projectId: p.id, title: t, source: "manual") { id in model.shellTaskId = id }
        newTitle = ""
        newProject = nil
        adding = false
    }
}

/// The picked task in full on the Tasks window's right: state, where it works, its agents and what they last said,
/// its pull request and source, subtasks, and what you can do next. With no task picked: the workspace's counts.
struct TaskDetailPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests
    @ObservedObject private var autopilot = TaskAutopilot.shared

    var body: some View {
        Group {
            if let t = model.task(model.shellTaskId) { detail(t) } else { overview }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var overview: some View {
        let all = model.workspaceTasks
        return VStack(alignment: .leading, spacing: 14) {
            Text("Tasks").font(.system(size: T.k * 15, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(Array(TaskState.shown.enumerated()), id: \.element) { i, st in
                    if i > 0 { Hairline() }
                    HStack(spacing: 8) {
                        TaskRow.glyph(st, still: true).frame(width: 16)
                        Text(st.title).font(.system(size: T.k * 12))
                        Spacer()
                        Text("\(all.filter { $0.state == st }.count)").font(T.meta).foregroundStyle(T.text3).monospacedDigit()
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                }
            }
            .homeCard(padding: 0)
            Text("Pick a task on the left to see it here. The assistant in the middle plans tasks and, with Autopilot, starts them; it never edits code.")
                .font(T.meta).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func detail(_ t: WorkTask) -> some View {
        let agents = t.sessions.compactMap { model.session($0) }
        let subtasks = model.workspaceTasks.filter { $0.parentId == t.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    TaskRow.glyph(t.state).frame(width: 16)
                    Text(t.state.title).font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(TaskRow.color(t.state))
                    if t.stateManual { Text("· set by hand").font(T.meta).foregroundStyle(T.text3) }
                    Spacer()
                    Button { model.shellTaskId = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 20)).help("Close")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.title).font(.system(size: T.k * 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let p = model.project(t.projectId) {
                            Circle().fill(Color(hex: p.color)).frame(width: 6, height: 6)
                            Text(p.name).font(T.meta).foregroundStyle(T.text2)
                        }
                        if let b = t.branch {
                            Image(systemName: "arrow.triangle.branch").font(T.icon(9)).foregroundStyle(T.text3)
                            Text(b).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                        }
                    }
                    if let parent = model.task(t.parentId) {
                        LinkButton(title: "Subtask of “\(parent.title)”") { model.shellSelectTask(parent.id) }
                    }
                }
                actions(t, agents.last)
                if !t.description.isEmpty {
                    Text(t.description).font(.system(size: T.k * 12)).foregroundStyle(T.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                links(t)
                if !agents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HomeSection(title: "Agents", count: agents.count)
                        ForEach(agents) { a in agentCard(a) }
                    }
                }
                if !subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HomeSection(title: "Subtasks", count: subtasks.count)
                        VStack(spacing: 0) {
                            ForEach(Array(subtasks.enumerated()), id: \.element.id) { i, s in
                                if i > 0 { Hairline() }
                                HoverRow(pinned: true) {
                                    TaskRow.glyph(s.state).frame(width: 14)
                                    Text(s.title).font(.system(size: T.k * 12)).lineLimit(1)
                                } actions: { EmptyView() }
                                .onTapGesture { model.shellSelectTask(s.id) }
                                .pointerCursor()
                            }
                        }
                        .homeCard(padding: 0)
                    }
                }
                HStack(spacing: 8) {
                    if t.state != .planned { Button("Mark as Planned") { model.setTaskState(t.id, .planned) }.buttonStyle(SmallButtonStyle()) }
                    if t.state != .done { Button("Mark as Done") { model.setTaskState(t.id, .done) }.buttonStyle(SmallButtonStyle()) }
                    if t.stateManual { Button("Follow Its Agents") { model.setTaskState(t.id, nil) }.buttonStyle(SmallButtonStyle()) }
                }
                Text(t.createdBy == "assistant" || t.createdBy.hasPrefix("agent:") ? "Made by the assistant." : "Made by you.")
                    .font(T.meta).foregroundStyle(T.text3)
            }
            .padding(16)
        }
    }

    @ViewBuilder private func actions(_ t: WorkTask, _ agent: Session?) -> some View {
        HStack(spacing: 8) {
            switch t.state {
            case .planned:
                Button(autopilot.requested[t.id] != nil ? "Start (the assistant asks)" : "Start") {
                    TaskAutopilot.shared.clearRequest(t.id); model.startTask(t)
                }
                .buttonStyle(SmallButtonStyle(prominent: true))
                Menu {
                    ForEach(model.enabledProfiles.filter { $0.kind == .claude || $0.kind == .codex }) { p in
                        Button("Start with \(p.name)") { TaskAutopilot.shared.clearRequest(t.id); model.startTask(t, profileId: p.id) }
                    }
                } label: { Text("Start with…").font(.system(size: T.k * 12)).foregroundStyle(T.text2) }
                .plainMenu().fixedSize().help("Start this once with another agent (your default stays)")
            case .needsYou:
                if let a = agent { Button("Answer") { model.selectSession(a.id) }.buttonStyle(SmallButtonStyle(prominent: true)) }
            case .working:
                if let a = agent { Button("Open Agent") { model.selectSession(a.id) }.buttonStyle(SmallButtonStyle()) }
            case .readyToReview:
                Button("Review Changes") {
                    if let wt = t.worktree ?? agent?.worktree { model.selectedProjectId = t.projectId; model.openDoc(.changes, workPath: wt) }
                    if let a = agent { model.lookedAt(a.id) }
                }
                .buttonStyle(SmallButtonStyle(prominent: true))
            case .inReview:
                if let u = t.prUrl, let url = URL(string: u) { Button("Open Pull Request") { NSWorkspace.shared.open(url) }.buttonStyle(SmallButtonStyle()) }
            case .done:
                if let wt = t.worktree, let p = model.project(t.projectId), Worktrees.shared.info(wt) != nil {
                    Button("Clean up worktree…") { model.removeWorktree(project: p, path: wt) }.buttonStyle(SmallButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func links(_ t: WorkTask) -> some View {
        let source = t.source.flatMap { s in s.hasPrefix("http") ? URL(string: s) : nil }
        if t.sourceKey != nil || t.prUrl != nil {
            HStack(spacing: 8) {
                if let k = t.sourceKey {
                    if let source { LinkButton(title: k) { NSWorkspace.shared.open(source) } }
                    else { Text(k).font(T.mono(11)).foregroundStyle(T.text3) }
                }
                if let u = t.prUrl, let url = URL(string: u) {
                    LinkButton(title: "Pull request") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func agentCard(_ a: Session) -> some View {
        let d = digests.digests[a.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentIcon(icon: iconName(for: a, model: model), size: 12).frame(width: 14)
                Text(a.displayTitle).font(.system(size: T.k * 12, weight: .semibold)).lineLimit(1)
                ActivityIndicator(session: a)
                Spacer()
                Text(AgentRow.elapsed(since: a.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            if let p = d?.pending {
                PendingAnswer(session: a, pending: p) { model.selectSession(a.id) }
            } else if let s = d?.summary, !s.isEmpty {
                Text(s).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(3)
            }
            WorkChips(session: a, limit: 2)
        }
        .homeCard(attention: RailGroup.of(a) == .waiting)
        .onTapGesture { model.selectSession(a.id) }
    }
}
