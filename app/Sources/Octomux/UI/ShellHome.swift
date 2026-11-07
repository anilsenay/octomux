import SwiftUI

/// The Agents layout's Home: hello, what waits, a big composer (project · checkout · agent), the agents waiting for
/// you answered in place, recent sessions and usage. Not a tab: the window comes back to it (⌘0, ⌘T, Home).
struct ShellHome: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests

    static func greeting(_ d: Date = Date(), name: String = NSFullUserName()) -> String {
        let h = Calendar.current.component(.hour, from: d)
        let part = h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part + "." : "\(part), \(first)."
    }

    /// "3 agents are waiting for you · 1 working · 2 done" (or that nothing is running).
    static func status(waiting: Int, working: Int, done: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "1 agent is waiting for you" : "\(waiting) agents are waiting for you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) done") }
        return parts.isEmpty ? "No agent is running. Start one below." : parts.joined(separator: " · ")
    }

    var body: some View {
        let list = model.railSessions
        let groups = Dictionary(grouping: list, by: RailGroup.of)
        let waiting = groups[.waiting] ?? []
        let recent = list.filter { RailGroup.of($0) != .waiting }.sorted { $0.lastActivityAt > $1.lastActivityAt }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.greeting()).font(.system(size: T.k * 30, weight: .regular, design: .serif))
                    Text(Self.status(waiting: waiting.count, working: groups[.working]?.count ?? 0, done: groups[.done]?.count ?? 0))
                        .font(.system(size: T.k * 13)).foregroundStyle(T.text2)
                }
                HomeComposer()
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HomeSection(title: "Waiting for you", count: waiting.count, dot: waiting.isEmpty ? nil : T.amber,
                                    trailing: AnyView(Text("answer here or open").font(T.meta).foregroundStyle(T.text3)))
                        if waiting.isEmpty {
                            Text("Nobody is waiting for you.").font(T.meta).foregroundStyle(T.text3).homeCard()
                        }
                        ForEach(waiting.prefix(6)) { s in waitingCard(s) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            HomeSection(title: "Recent", count: recent.count)
                            VStack(spacing: 0) {
                                if recent.isEmpty { Text("Nothing yet.").font(T.meta).foregroundStyle(T.text3).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                                ForEach(Array(recent.prefix(6).enumerated()), id: \.element.id) { i, s in
                                    if i > 0 { Hairline() }
                                    recentRow(s)
                                }
                            }
                            .homeCard(padding: 0)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HomeSection(title: "Usage")
                            UsageStatus().frame(maxWidth: .infinity, alignment: .leading).homeCard()
                        }
                    }
                    .frame(width: 300, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 40)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }

    private func waitingCard(_ s: Session) -> some View {
        let d = digests.digests[s.id] ?? AgentDigest()
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
                Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
                Text(model.project(s.projectId)?.name ?? "").font(T.meta).foregroundStyle(T.text3)
                Spacer()
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            if let p = d.pending {
                PendingAnswer(session: s, pending: p) { model.selectSession(s.id) }
            } else {
                if !d.summary.isEmpty { Text(d.summary).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(2) }
                HStack(spacing: 6) {
                    Image(systemName: s.activity == .error ? "exclamationmark.triangle.fill" : "hand.raised.fill").font(T.icon(10))
                        .foregroundStyle(s.activity == .error ? T.red : T.amber)
                    Text(s.activity == .error ? "Stopped on an error" : "Answer in its terminal").font(T.meta).foregroundStyle(T.text2)
                    Spacer()
                    Button("Open") { model.selectSession(s.id) }.buttonStyle(SmallButtonStyle())
                }
            }
        }
        .homeCard(attention: true)
    }

    private func recentRow(_ s: Session) -> some View {
        HoverRow(pinned: false) {
            AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 14)
            Text(s.displayTitle).font(.system(size: T.k * 12)).lineLimit(1)
        } actions: {
            Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
        }
        .onTapGesture { if s.isDormant { model.restart(s.id) }; model.selectSession(s.id) }
        .pointerCursor()
    }
}

/// Home's composer: what to work on, then project · checkout · agent; ↩ starts a chat session there.
struct HomeComposer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wt = Worktrees.shared
    @State private var text = ""
    @State private var projectId: String?
    @State private var checkout: String?        // a worktree path; nil = the project's own checkout
    @State private var newWorktree = false
    @State private var profileId: String?
    @FocusState private var focused: Bool

    private var project: Project? { model.project(projectId ?? "") ?? model.currentProject ?? model.projects.first }
    private var profiles: [Profile] { model.enabledProfiles(forProject: project?.id).filter { $0.kind == .claude || $0.kind == .codex } }
    private var profile: Profile? { profiles.first { $0.id == profileId } ?? model.profile(model.defaultAgentProfileId(projectId: project?.id)) ?? profiles.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What should we work on? Describe the task, paste an issue link…", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: T.k * 15)).lineLimit(2...6)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.projects) { p in Button(p.name) { projectId = p.id; checkout = nil; newWorktree = false } }
                } label: { picker(dot: project.map { Color(hex: $0.color) }, project?.name ?? "No project") }
                .plainMenu().fixedSize()
                Menu {
                    Button("Current checkout") { checkout = nil; newWorktree = false }
                    if let p = project {
                        let list = wt.linked(p.path).filter { !$0.isMain }
                        if !list.isEmpty { Divider() }
                        ForEach(list, id: \.path) { w in Button(w.branch.isEmpty ? (w.path as NSString).lastPathComponent : w.branch) { checkout = w.path; newWorktree = false } }
                    }
                    Divider()
                    Button("New worktree") { checkout = nil; newWorktree = true }
                } label: {
                    picker(icon: "arrow.triangle.branch", newWorktree ? "New worktree" : checkout.flatMap { c in wt.linked(project?.path ?? "").first { $0.path == c }?.branch } ?? "Current checkout")
                }
                .plainMenu().fixedSize()
                Menu {
                    ForEach(profiles) { p in Button(p.name) { profileId = p.id } }
                } label: {
                    HStack(spacing: 5) {
                        if let p = profile { AgentIcon(icon: p.icon, size: 11) }
                        Text(profile?.name ?? "No agent").font(.system(size: T.k * 12))
                        Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
                    }
                    .foregroundStyle(T.text2)
                }
                .plainMenu().fixedSize()
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(T.icon(12, .bold)).foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? T.accent : T.text3.opacity(0.4)))
                }
                .buttonStyle(.plain).disabled(!canSend).help("Start (↩)")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(focused ? T.accent.opacity(0.6) : T.border))
        .onReceive(NotificationCenter.default.publisher(for: .octomuxShellComposer)) { _ in focused = true }
    }

    private func picker(dot: Color? = nil, icon: String? = nil, _ title: String) -> some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon).font(T.icon(10)).foregroundStyle(T.text3) }
            Text(title).font(.system(size: T.k * 12)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
        }
        .foregroundStyle(T.text2)
    }

    private var canSend: Bool { project != nil && profile != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let p = project, let prof = profile else { return }
        text = ""
        if newWorktree {
            let branch = "agent/" + TaskRules.branch(t, id: String(UUID().uuidString.prefix(6)).lowercased()).dropFirst("task/".count)
            model.newWorktree(project: p, branch: branch, open: prof.id, prompt: t)
        } else {
            model.newSession(profileId: prof.id, projectId: p.id, worktree: checkout, prompt: t, chat: true,
                             extraArgs: ChatLaunchOptions.load(prof.kind).args(prof.kind)) { ChatFirstMessage.set($0, t) }
        }
    }
}
