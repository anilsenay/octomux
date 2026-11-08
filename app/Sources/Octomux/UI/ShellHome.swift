import SwiftUI

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

/// Usage as bars: each agent's limits with how much is used (Home's Usage card).
struct UsageBars: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UsageReading.windowsKey) private var windows = "all"
    var body: some View {
        let shown = model.usageProfilesShown()
        VStack(alignment: .leading, spacing: 10) {
            if shown.isEmpty { Text("No usage readings yet.").font(T.meta).foregroundStyle(T.text3) }
            ForEach(shown, id: \.0.id) { prof, readings in
                HStack(spacing: 14) {
                    ForEach(UsageReading.shown(readings, windows)) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.window == "five_hour" ? "\(prof.name) · \(r.shortName)" : r.shortName).font(T.meta).foregroundStyle(T.text2).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(r.isReset ? "—" : r.label(left: false)).font(T.mono(11)).foregroundStyle(r.isReset ? T.text3 : T.text)
                            }
                            UsageMeter(used: r.effectivePercent, primary: r.window == "five_hour")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.usagePopoverOpen = true }
        .help("Usage limits")
    }
}
