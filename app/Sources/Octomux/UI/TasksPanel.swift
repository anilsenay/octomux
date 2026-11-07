import SwiftUI

/// The workspace's tasks: what needs you, what is ready to review, what works, what is planned. A task starts in its
/// own worktree with an agent; the assistant (and Autopilot) can plan and start them. The right panel's Tasks tab
/// (Settings → Layout → Panels and editor; the Tasks layout has it open and wide).
struct TasksPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var autopilot = TaskAutopilot.shared
    @State private var newTitle = ""
    @State private var showDone = false

    var body: some View {
        let all = TaskRules.ordered(model.workspaceTasks)
        let open = all.filter { $0.state != .done }
        let done = all.filter { $0.state == .done }
        VStack(spacing: 0) {
            AssistantBar()
            Hairline()
            HStack(spacing: 8) {
                Image(systemName: "plus").font(T.icon(11)).foregroundStyle(T.text3)
                TextField("Add a task to \(model.currentProject?.name ?? "the project")…", text: $newTitle)
                    .textFieldStyle(.plain).font(T.body).onSubmit(add)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Hairline()
            ScrollView {
                // A plain stack: a task moves between groups, and a lazy one kept its old row.
                VStack(alignment: .leading, spacing: 0) {
                    if all.isEmpty {
                        Text("No tasks yet. Add one above, or tell the assistant what needs doing and it splits the work into tasks.")
                            .font(T.meta).foregroundStyle(T.text3).padding(14)
                    }
                    ForEach(TaskState.shown.filter { $0 != .done }, id: \.self) { st in
                        let list = open.filter { $0.state == st }
                        if !list.isEmpty {
                            group(st, list.count)
                            ForEach(list) { t in TaskRow(task: t, requested: autopilot.requested[t.id] != nil).id(t.id + t.state.rawValue) }
                        }
                    }
                    if !done.isEmpty {
                        Button { showDone.toggle() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: T.k * 9, weight: .bold)).rotationEffect(.degrees(showDone ? 90 : 0))
                                Text("DONE").font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6)
                                Text("\(done.count)").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text3)
                            }
                            .foregroundStyle(T.text3).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        }
                        .buttonStyle(.plain)
                        if showDone { ForEach(done) { t in TaskRow(task: t, requested: false) } }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func group(_ s: TaskState, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(TaskRow.color(s)).frame(width: 6, height: 6)
            Text(s.title.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(TaskRow.color(s))
            Text("\(n)").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text3)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
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
                Text("Assistant").font(.system(size: T.k * 13, weight: .semibold))
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
                HStack(spacing: 4) {
                    Image(systemName: "airplane").font(T.icon(10))
                    Text(level == .off ? "Autopilot off" : level.title).font(T.meta)
                }
                .foregroundStyle(level == .off ? T.text3 : T.accent)
            }
            .plainMenu().fixedSize().help("Autopilot: what the assistant may do without asking. \(level.desc)")
            Button(a == nil ? "Start" : "Open") { model.openAssistant() }.buttonStyle(SecondaryButtonStyle())
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

    var body: some View {
        let t = task
        let agent = t.sessions.compactMap { model.session($0) }.last
        HStack(alignment: .top, spacing: 8) {
            if t.state == .working { WorkingRing().scaleEffect(0.8).frame(width: 12) }
            else { Circle().fill(Self.color(t.state)).frame(width: 7, height: 7).padding(.top, 5).frame(width: 12) }
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: T.k * 13, weight: t.state == .needsYou ? .semibold : .medium))
                    .foregroundStyle(t.state == .done ? T.text3 : T.text).lineLimit(2)
                if agent != nil || !meta(t).isEmpty || t.sourceKey != nil || t.stateManual {
                HStack(spacing: 5) {
                    if let a = agent { AgentIcon(icon: iconName(for: a, model: model), size: 10) }
                    Text(meta(t)).font(T.meta).foregroundStyle(T.text3).lineLimit(1)
                    if let k = t.sourceKey { Text(k).font(T.mono(10)).foregroundStyle(T.text2).padding(.horizontal, 4).background(Capsule().fill(T.hover)) }
                    if t.stateManual { Image(systemName: "hand.point.up.left").font(T.icon(9)).foregroundStyle(T.text3).help("State set by hand") }
                }
                }
                if requested { Text("The assistant asks to start this").font(T.meta).foregroundStyle(T.amber) }
                actions(t, agent)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, t.parentId == nil ? 12 : 30).padding(.trailing, 10).padding(.vertical, 7)
        .background(hover ? T.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if let a = agent { model.selectSession(a.id) } }
        .contextMenu { menu(t) }
    }

    private func meta(_ t: WorkTask) -> String {
        var parts: [String] = []
        if model.project(t.projectId)?.id != model.currentProject?.id { parts.append(model.project(t.projectId)?.name ?? "") }
        if let b = t.branch { parts.append(b) }
        if t.createdBy == "assistant" { parts.append("by the assistant") }
        else if t.createdBy.hasPrefix("agent:") { parts.append("by an agent") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func actions(_ t: WorkTask, _ agent: Session?) -> some View {
        HStack(spacing: 6) {
            switch t.state {
            case .planned:
                Button("Start") { TaskAutopilot.shared.clearRequest(t.id); model.startTask(t) }.buttonStyle(PrimaryButtonStyle())
                Menu {
                    ForEach(model.enabledProfiles.filter { $0.kind == .claude || $0.kind == .codex }) { p in
                        Button("Start with \(p.name)") { TaskAutopilot.shared.clearRequest(t.id); model.startTask(t, profileId: p.id) }
                    }
                } label: { Text("Start with…").font(T.meta).foregroundStyle(T.text2) }
                .plainMenu().fixedSize().help("Start this once with another agent (your default stays)")
            case .working, .needsYou:
                if let a = agent {
                    if t.state == .needsYou { Button("Answer") { model.selectSession(a.id) }.buttonStyle(PrimaryButtonStyle()) }
                    else { Button("Open") { model.selectSession(a.id) }.buttonStyle(SecondaryButtonStyle()) }
                }
            case .readyToReview:
                Button("Review") {
                    if let wt = t.worktree ?? agent?.worktree { model.selectedProjectId = t.projectId; model.openDoc(.changes, workPath: wt) }
                    if let a = agent { model.lookedAt(a.id) }
                }
                .buttonStyle(PrimaryButtonStyle())
                if let a = agent { Button("Open agent") { model.selectSession(a.id) }.buttonStyle(SecondaryButtonStyle()) }
                Button("Done") { model.setTaskState(t.id, .done) }.buttonStyle(SecondaryButtonStyle())
            case .inReview:
                if let u = t.prUrl, let url = URL(string: u) { Button("Open Pull Request") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButtonStyle()) }
                if let a = agent { Button("Open agent") { model.selectSession(a.id) }.buttonStyle(SecondaryButtonStyle()) }
            case .done:
                if let wt = t.worktree, let p = model.project(t.projectId), Worktrees.shared.info(wt) != nil {
                    Button("Clean up worktree…") { model.removeWorktree(project: p, path: wt) }.buttonStyle(SecondaryButtonStyle())
                        .help("Removes its worktree (asks first); the task stays")
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func menu(_ t: WorkTask) -> some View {
        if let a = t.sessions.compactMap({ model.session($0) }).last { Button("Open Agent") { model.selectSession(a.id) } }
        Divider()
        Button("Mark as Planned") { model.setTaskState(t.id, .planned) }
        Button("Mark as Done") { model.setTaskState(t.id, .done) }
        if t.stateManual { Button("Follow Its Agents Again") { model.setTaskState(t.id, nil) } }
        if t.parentId == nil, let p = model.currentProject {
            Button("Add Subtask…") {
                let a = NSAlert()
                a.messageText = "Subtask of “\(t.title)”"
                let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
                a.accessoryView = f
                a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
                    model.createTask(projectId: t.projectId == p.id ? p.id : t.projectId, title: f.stringValue, source: "manual", parent: t.id)
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
                    Circle().fill(TaskRow.color(t.state)).frame(width: 6, height: 6)
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
