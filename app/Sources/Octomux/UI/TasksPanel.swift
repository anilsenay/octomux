import SwiftUI

/// The workspace's tasks: what needs you, what is ready to review, what works, what is planned. A task starts in its
/// own worktree with an agent; the assistant (and Autopilot) can plan and start them. The right panel's Tasks tab
/// (Settings → Layout → Panels and editor; the Tasks layout has it open and wide).
struct TasksPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var autopilot = TaskAutopilot.shared
    @State private var newTitle = ""
    @State private var adding = false
    @State private var query = ""
    @State private var filter: TaskState?
    @State private var collapsed: Set<TaskState> = [.done]
    @State private var moreDone = false

    var body: some View {
        let all = TaskRules.ordered(model.workspaceTasks)
        let matching = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.sourceKey ?? "").localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            AssistantBar()
            Hairline()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(T.icon(11)).foregroundStyle(T.text3)
                TextField("Filter tasks", text: $query).textFieldStyle(.plain).font(T.body)
                Button { adding.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(ChromeButtonStyle(active: adding)).help("New task in \(model.currentProject?.name ?? "the project")")
            }
            .padding(.horizontal, 12).frame(height: 36)
            if adding {
                HStack(spacing: 8) {
                    TextField("What needs doing? (↩ adds it to \(model.currentProject?.name ?? "the project"))", text: $newTitle)
                        .textFieldStyle(.plain).font(T.body).onSubmit(add)
                        .onExitCommand { adding = false; newTitle = "" }
                    Button("Add", action: add).buttonStyle(SmallButtonStyle(prominent: true)).disabled(newTitle.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(T.hover)
            }
            statusChips(all)
            Hairline()
            ScrollView {
                // A plain stack: a task moves between groups, and a lazy one kept its old row.
                VStack(alignment: .leading, spacing: 0) {
                    if all.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No tasks yet").font(.system(size: T.k * 13, weight: .semibold))
                            Text("Add one with +, or tell the assistant what needs doing: it splits the work into tasks, each with its own worktree and agent.")
                                .font(T.meta).foregroundStyle(T.text3)
                        }
                        .padding(14)
                    }
                    ForEach(TaskState.shown.filter { filter == nil || $0 == filter }, id: \.self) { st in
                        let list = matching.filter { $0.state == st }
                        if !list.isEmpty { group(st, list) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func statusChips(_ all: [WorkTask]) -> some View {
        let open = all.filter { $0.state != .done }
        return HStack(spacing: 4) {
            chip("All", open.count, nil)
            ForEach([TaskState.needsYou, .readyToReview, .working, .planned], id: \.self) { st in
                let n = all.filter { $0.state == st }.count
                if n > 0 { chip(st.title, n, st) }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func chip(_ title: String, _ n: Int, _ st: TaskState?) -> some View {
        let on = filter == st
        return Button { filter = st } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: T.k * 11, weight: on ? .semibold : .regular))
                Text("\(n)").font(.system(size: T.k * 11)).foregroundStyle(T.text3).monospacedDigit()
            }
            .foregroundStyle(on ? T.text : T.text2)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(on ? T.hover : .clear))
            .overlay(Capsule().stroke(on ? T.border : .clear))
        }
        .buttonStyle(.plain).pointerCursor()
    }

    @ViewBuilder private func group(_ s: TaskState, _ list: [WorkTask]) -> some View {
        let closed = collapsed.contains(s) && filter != s
        Button {
            withAnimation(.easeOut(duration: 0.15)) { if collapsed.contains(s) { collapsed.remove(s) } else { collapsed.insert(s) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: T.k * 9, weight: .bold)).foregroundStyle(T.text3)
                    .rotationEffect(.degrees(closed ? 0 : 90)).frame(width: 10)
                Text(s.title).font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(T.text2)
                Spacer()
                Text("\(list.count)").font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if !closed {
            let cut = s == .done && !moreDone ? Array(list.prefix(5)) : list
            ForEach(cut) { t in TaskRow(task: t, requested: autopilot.requested[t.id] != nil).id(t.id + t.state.rawValue) }
            if s == .done { MoreToggle(hidden: list.count - cut.count, expanded: $moreDone) }
        }
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let p = model.currentProject else { return }
        model.createTask(projectId: p.id, title: t, source: "manual")
        newTitle = ""
    }
}

/// The workspace assistant's row: open or start it, and how far Autopilot may go.
struct AssistantBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ws = model.selectedWorkspaceId
        let a = model.assistantSession(workspace: ws)
        let level = model.autopilot(workspace: ws)
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(T.icon(12)).foregroundStyle(T.accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Assistant").font(.system(size: T.k * 13, weight: .semibold))
                    if let a, let p = model.profile(a.profileId) { Text("· \(p.name)").font(.system(size: T.k * 13)).foregroundStyle(T.text3) }
                }
                Text(a.map { $0.isDormant ? "Stopped" : $0.activity == .working ? "Working…" : "Plans and starts tasks, never edits code" } ?? "Plans and starts tasks, never edits code")
                    .font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                ForEach(Autopilot.allCases) { l in
                    Button { model.setAutopilot(l, workspace: ws) } label: {
                        if l == level { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                    }
                }
                Divider()
                Text(level.desc)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(level == .off ? T.text3.opacity(0.5) : T.green).frame(width: 6, height: 6)
                    Text(level == .off ? "Autopilot off" : "Autopilot · \(level.title)").font(.system(size: T.k * 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold))
                }
                .foregroundStyle(level == .off ? T.text3 : T.text)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(T.hover))
            }
            .plainMenu().fixedSize().help("Autopilot: what the assistant may do without asking. \(level.desc)")
            Button(a == nil ? "Start" : "Open") { model.openAssistant() }.buttonStyle(SmallButtonStyle(prominent: a == nil))
                .help(a == nil ? "Start the workspace's assistant (your default agent, editing off)" : "Open the assistant")
        }
        .padding(.horizontal, 12).frame(height: 50)
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: WorkTask
    let requested: Bool
    @State private var hover = false

    static func color(_ s: TaskState) -> Color {
        switch s {
        case .needsYou: return T.amber
        case .working: return T.accent
        case .readyToReview: return T.green
        case .inReview: return T.blue
        case .planned: return T.text2
        case .done: return T.text3
        }
    }

    /// One glyph per state (the Tasks panel, the sidebar, the task chip).
    @ViewBuilder static func glyph(_ s: TaskState) -> some View {
        switch s {
        case .working: WorkingRing().scaleEffect(0.75)
        case .planned: Image(systemName: "circle.dashed").font(T.icon(12)).foregroundStyle(T.text3)
        case .needsYou: Image(systemName: "exclamationmark.circle.fill").font(T.icon(12)).foregroundStyle(T.amber)
        case .readyToReview: Image(systemName: "eye.circle.fill").font(T.icon(12)).foregroundStyle(T.green)
        case .inReview: Image(systemName: "arrow.triangle.pull").font(T.icon(11)).foregroundStyle(T.blue)
        case .done: Image(systemName: "checkmark.circle.fill").font(T.icon(12)).foregroundStyle(T.text3)
        }
    }

    var body: some View {
        let t = task
        let agent = t.sessions.compactMap { model.session($0) }.last
        let pinned = t.state == .needsYou || t.state == .readyToReview || requested
        HStack(alignment: .top, spacing: 9) {
            Self.glyph(t.state).frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let k = t.sourceKey { Text(k).font(T.mono(11)).foregroundStyle(T.text3) }
                    Text(t.title).font(.system(size: T.k * 13, weight: t.state == .needsYou ? .semibold : .regular))
                        .foregroundStyle(t.state == .done ? T.text3 : T.text).lineLimit(1)
                }
                let sub = subline(t, agent)
                if !sub.isEmpty { Text(sub).font(T.meta).foregroundStyle(requested ? T.amber : T.text3).lineLimit(1) }
            }
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                if let p = model.project(t.projectId), !(hover || pinned) {
                    Text(p.name).font(T.meta).foregroundStyle(T.text3).lineLimit(1)
                }
                if hover || pinned { action(t, agent) }
            }
            .frame(minHeight: 18)
        }
        .padding(.leading, t.parentId == nil ? 12 : 34).padding(.trailing, 10).padding(.vertical, 6)
        .background(hover ? T.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if let a = agent { model.selectSession(a.id) } }
        .contextMenu { menu(t) }
    }

    private func subline(_ t: WorkTask, _ agent: Session?) -> String {
        if requested { return "The assistant asks to start this" }
        var parts: [String] = []
        switch t.state {
        case .working: parts.append(agent.map { "\($0.displayTitle) · working" } ?? "working")
        case .needsYou: parts.append("its agent waits for your answer")
        case .readyToReview: parts.append("finished · ready to review")
        case .inReview: parts.append("pull request open")
        default: break
        }
        if let b = t.branch { parts.append(b) }
        if t.createdBy == "assistant" { parts.append("by the assistant") }
        if t.stateManual { parts.append("set by hand") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func action(_ t: WorkTask, _ agent: Session?) -> some View {
        HStack(spacing: 6) {
            switch t.state {
            case .planned:
                Menu {
                    ForEach(model.enabledProfiles.filter { $0.kind == .claude || $0.kind == .codex }) { p in
                        Button("Start with \(p.name)") { TaskAutopilot.shared.clearRequest(t.id); model.startTask(t, profileId: p.id) }
                    }
                } label: { Image(systemName: "chevron.down").font(T.icon(9)).foregroundStyle(T.text3) }
                .plainMenu().fixedSize().help("Start this once with another agent (your default stays)")
                Button("Start") { TaskAutopilot.shared.clearRequest(t.id); model.startTask(t) }.buttonStyle(SmallButtonStyle(prominent: requested))
            case .working:
                if let a = agent { Button("Open") { model.selectSession(a.id) }.buttonStyle(SmallButtonStyle()) }
            case .needsYou:
                if let a = agent { Button("Answer") { model.selectSession(a.id) }.buttonStyle(SmallButtonStyle(prominent: true)) }
            case .readyToReview:
                Button("Done") { model.setTaskState(t.id, .done) }.buttonStyle(SmallButtonStyle())
                Button("Review") {
                    if let wt = t.worktree ?? agent?.worktree { model.selectedProjectId = t.projectId; model.openDoc(.changes, workPath: wt) }
                    if let a = agent { model.lookedAt(a.id) }
                }
                .buttonStyle(SmallButtonStyle(prominent: true))
            case .inReview:
                if let u = t.prUrl, let url = URL(string: u) { Button("Pull Request") { NSWorkspace.shared.open(url) }.buttonStyle(SmallButtonStyle()) }
            case .done:
                if let wt = t.worktree, let p = model.project(t.projectId), Worktrees.shared.info(wt) != nil {
                    Button("Clean up…") { model.removeWorktree(project: p, path: wt) }.buttonStyle(SmallButtonStyle())
                        .help("Removes its worktree (asks first); the task stays")
                }
            }
        }
    }

    @ViewBuilder private func menu(_ t: WorkTask) -> some View {
        if let a = t.sessions.compactMap({ model.session($0) }).last { Button("Open Agent") { model.selectSession(a.id) } }
        Divider()
        Button("Mark as Planned") { model.setTaskState(t.id, .planned) }
        Button("Mark as Done") { model.setTaskState(t.id, .done) }
        if t.stateManual { Button("Follow Its Agents Again") { model.setTaskState(t.id, nil) } }
        if t.parentId == nil {
            Button("Add Subtask…") {
                let a = NSAlert()
                a.messageText = "Subtask of “\(t.title)”"
                let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
                a.accessoryView = f
                a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
                    model.createTask(projectId: t.projectId, title: f.stringValue, source: "manual", parent: t.id)
                }
            }
        }
        Divider()
        Button("Delete Task", role: .destructive) { model.deleteTask(t.id) }
    }
}

/// The sidebar's Tasks section (Settings → Layout → Sidebar): counts and the tasks that need you.
struct TasksSidebarSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let open = TaskRules.ordered(model.workspaceTasks).filter { $0.state != .done }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("Tasks")
                Spacer()
                Text("\(open.count)").font(T.meta).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
            ForEach(open.prefix(5)) { t in
                HStack(spacing: 7) {
                    TaskRow.glyph(t.state).frame(width: 14)
                    Text(t.title).font(.system(size: T.k * 13)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 24)
                .contentShape(Rectangle())
                .pointerCursor()
                .onTapGesture { model.showTasks() }
            }
        }
    }
}

extension AppModel {
    /// The Tasks tab of the right panel, open.
    func showTasks() {
        UserDefaults.standard.set(RightTab.tasks.rawValue, forKey: "octomux.rightTab")
        rightPanelVisible = true
    }
}
