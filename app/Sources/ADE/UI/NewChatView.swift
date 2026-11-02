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
    @State private var pickingWorkspace = false
    @State private var pickingBranch = false
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
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["chatPicker"] as? String { pickingWorkspace = v == "workspace"; pickingBranch = v == "branch" }
        }
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

    /// Where it runs (project checkout or a worktree) and that checkout's branch, as two buttons.
    private var context: some View {
        let path = worktree ?? project?.path ?? ""
        return HStack(spacing: 4) {
            ContextChip(icon: worktree == nil ? "folder" : "arrow.triangle.branch",
                        text: worktree.map { ($0 as NSString).lastPathComponent } ?? "Current checkout",
                        open: $pickingWorkspace, help: path)
                .background(DropdownAnchor(isPresented: $pickingWorkspace) {
                    WorkspaceChoice(project: project, selected: worktree) { worktree = $0; pickingWorkspace = false }
                })
            if let b = git.branch(for: path) {
                ContextChip(icon: "arrow.triangle.branch", text: b, mono: true, open: $pickingBranch, help: "Switch or create a branch in \(path)")
                    .background(DropdownAnchor(isPresented: $pickingBranch) {
                        BranchPicker(path: path, mode: .checkout, current: b) { pickingBranch = false }
                    })
            }
            Spacer()
            Text("Opens as a chat; the terminal is one click away.").font(.system(size: 11)).foregroundStyle(T.text3.opacity(0.8))
        }
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

/// A small pill under the composer (workspace, branch): hover fill, pressed look while its list is open.
struct ContextChip: View {
    let icon: String
    let text: String
    var mono = false
    @Binding var open: Bool
    var help = ""
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5))
                Text(text).font(mono ? T.mono(11.5) : .system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(open || hover ? T.text : T.text2)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(open ? T.border : hover ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.pointerCursor().help(help)
    }
}

/// "Workspace" list: current checkout, a new worktree (branch name typed inline), or an existing one.
struct WorkspaceChoice: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wt = Worktrees.shared
    let project: Project?
    let selected: String?
    let pick: (String?) -> Void
    @State private var naming = false
    @State private var branch = ""
    @State private var showExisting = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let linked = project.map { wt.linked($0.path) } ?? []
        VStack(alignment: .leading, spacing: 1) {
            Text("Workspace").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            row("folder", "Current checkout", checked: selected == nil) { pick(nil) }
            if naming {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(T.text2).frame(width: 16)
                    TextField("New branch name", text: $branch).textFieldStyle(.plain).font(.system(size: 12.5))
                        .focused($nameFocused).onSubmit(create).disabled(busy)
                    if busy { WorkingRing() }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
                .onAppear { nameFocused = true }
            } else {
                row("plus.square.on.square", "New worktree", checked: false) { naming = true }
            }
            if !linked.isEmpty {
                row("square.stack", "Existing worktree", checked: false, trailing: showExisting ? "chevron.down" : "chevron.right") {
                    withAnimation(.easeOut(duration: 0.12)) { showExisting.toggle() }
                }
                if showExisting || selected != nil {
                    ForEach(linked) { w in
                        row("arrow.triangle.branch", w.label, checked: selected == w.path, indent: 18) { pick(w.path) }
                    }
                }
            }
            if let error {
                Text(error).font(T.caption).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 4)
            }
            Hairline().padding(.vertical, 4)
            row("gearshape", "Worktree settings", checked: false) { SettingsWindow.show(section: .features); pick(selected) }
        }
        .padding(.horizontal, 5).padding(.bottom, 6)
        .frame(width: 260)
    }

    private func row(_ icon: String, _ title: String, checked: Bool, trailing: String? = nil, indent: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(T.text2).frame(width: 16)
                Text(title).font(.system(size: 12.5)).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(T.text) }
                if let trailing { Image(systemName: trailing).font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3) }
            }
            .padding(.leading, 10 + indent).padding(.trailing, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(checked ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(HoverFill()).pointerCursor()
    }

    private func create() {
        let b = branch.trimmingCharacters(in: .whitespaces)
        guard let project, !b.isEmpty else { return }
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Worktrees.create(project: project.path, branch: b)
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let path): pick(path)
                case .failure(let e): error = "\(e)".split(separator: "\n").filter { !$0.hasPrefix("hint:") }.prefix(3).joined(separator: "\n")
                }
            }
        }
    }
}
