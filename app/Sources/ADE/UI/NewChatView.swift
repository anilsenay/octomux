import SwiftUI

/// Start screen of a chat session (⌘N, "New Chat…"): ask first, the agent starts with that message as
/// its CLI prompt and the session opens in the chat view. It is the same agent session as any other, so
/// the terminal is one switch away (header "Terminal" button, ⌘⇧C).
struct NewChatView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wt = Worktrees.shared
    @ObservedObject var git = GitInfo.shared
    let docId: String
    @State private var draft = ""
    @State private var profileId: String? = UserDefaults.standard.string(forKey: "ade.chatProfile")
    @State private var worktree: String?    // nil = the project's own checkout
    @State private var sending = false
    @FocusState private var focused: Bool

    private var doc: DocTab? { model.docTabs.first { $0.id == docId } }
    private var project: Project? { model.project(doc?.projectId ?? "") }

    /// Agents the chat view can render (Claude and Codex transcripts).
    private var profiles: [Profile] {
        model.enabledProfiles(forProject: project?.id).filter { $0.kind == .claude || $0.kind == .codex || $0.icon == "claude" || $0.icon == "codex" }
    }
    private var profile: Profile? { profiles.first { $0.id == profileId } ?? profiles.first }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 14) {
                Text("What should we work on in \(project?.name ?? "this project")?")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(T.text)
                composer
                context
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            Spacer(minLength: 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground())
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask, build, plan… (↩ to send, ⌥↩ for a new line)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...12)
                .focused($focused)
                .onSubmit(send)
                .disabled(sending)
            HStack(spacing: 6) {
                agentPicker
                Spacer()
                if sending { WorkingRing() }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(canSend ? T.accent : T.text3.opacity(0.5)))
                .disabled(!canSend).pointerCursor()
                .help("Start \(profile?.name ?? "the agent") with this message (↩)")
            }
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(ThemeStore.shared.isDark ? 0.55 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(focused ? WorkspaceTintColor.ring(model).opacity(0.55) : T.border))
        .shadow(color: .black.opacity(ThemeStore.shared.isDark ? 0 : 0.06), radius: 8, y: 2)
    }

    private var canSend: Bool { !sending && profile != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var agentPicker: some View {
        Menu {
            ForEach(profiles) { p in
                Button { profileId = p.id; UserDefaults.standard.set(p.id, forKey: "ade.chatProfile") } label: {
                    Text((p.id == profile?.id ? "✓ " : "") + p.name)
                }
            }
            if profiles.isEmpty { Text("No Claude or Codex profile") }
            Divider()
            Button("Manage Agents…") { SettingsWindow.show(section: .agents) }
        } label: {
            HStack(spacing: 5) {
                if let profile { AgentIcon(icon: profile.icon, size: 11) }
                Text(profile?.name ?? "No agent").font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(T.text3)
            }
            .foregroundStyle(T.text2)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
            .contentShape(Rectangle())
        }
        .plainMenu().fixedSize().pointerCursor()
        .help("Which agent to start")
    }

    /// Where it runs: the project checkout or one of its worktrees, and that checkout's branch.
    private var context: some View {
        let path = worktree ?? project?.path ?? ""
        let linked = project.map { wt.linked($0.path) } ?? []
        return HStack(spacing: 14) {
            Menu {
                Button((worktree == nil ? "✓ " : "") + "Current checkout") { worktree = nil }
                if !linked.isEmpty { Divider() }
                ForEach(linked) { w in
                    Button((worktree == w.path ? "✓ " : "") + w.label) { worktree = w.path }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: worktree == nil ? "folder" : "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(worktree.map { (($0 as NSString).lastPathComponent) } ?? "Current checkout").font(.system(size: 11.5))
                    if !linked.isEmpty { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
                }
                .foregroundStyle(T.text3).contentShape(Rectangle())
            }
            .plainMenu().fixedSize().pointerCursor()
            .help(path)
            if let b = git.branch(for: path) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(b).font(T.mono(11))
                }
                .foregroundStyle(T.text3)
            }
            Spacer()
            Text("Opens as a chat; the terminal is one click away.").font(.system(size: 11)).foregroundStyle(T.text3.opacity(0.8))
        }
        .padding(.horizontal, 4)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let project, let profile else { return }
        sending = true
        let docId = self.docId
        model.newSession(profileId: profile.id, projectId: project.id, worktree: worktree, prompt: text, chat: true) { id in
            ChatFirstMessage.set(id, text)
            // The new tab takes the start screen's place.
            if let i = model.docTabs.firstIndex(where: { $0.id == docId }) { model.docTabs.remove(at: i) }
            if model.activeDocId == docId { model.activeDocId = nil }
        }
    }
}

/// The accent ring color of the current workspace (focused composer border).
enum WorkspaceTintColor {
    static func ring(_ model: AppModel) -> Color { Color(nsColor: WorkspaceTint.accent(dark: ThemeStore.shared.isDark)) }
}
