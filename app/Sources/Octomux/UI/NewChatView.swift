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
    /// Picked on this screen; else the workspace's default agent, else the last one used.
    @State private var profileId: String?
    @State private var worktree: String?    // nil = the project's own checkout
    @State private var sending = false
    @State private var pickingWorkspace = false
    @State private var pickingBranch = false
    @State private var pickingModel = false
    @State private var pickingPermission = false
    @State private var options = ChatLaunchOptions()
    @State private var files: [URL] = []
    @State private var dropTarget = false
    @StateObject private var completion = ComposerCompletion()
    @State private var focused = false

    private var doc: DocTab? { model.docTabs.first { $0.id == docId } }
    private var project: Project? { model.project(doc?.projectId ?? "") }

    /// Agents the chat view can render (Claude and Codex transcripts).
    private var profiles: [Profile] {
        model.enabledProfiles(forProject: project?.id).filter { $0.kind == .claude || $0.kind == .codex || $0.icon == "claude" || $0.icon == "codex" }
    }
    private var profile: Profile? {
        let ws = model.defaultChatProfile(workspace: project?.workspaceId)
        let last = UserDefaults.standard.string(forKey: "octomux.chatProfile")
        return profiles.first { $0.id == profileId } ?? profiles.first { $0.id == ws?.id } ?? profiles.first { $0.id == last } ?? profiles.first
    }

    var body: some View {
        let path = worktree ?? project?.path ?? ""
        VStack(spacing: 0) {
            // One block above the composer, which stays where the chat's composer will be (no jump when the
            // first message goes out): the mark and the question, what waits and what ran here, starters.
            Spacer(minLength: 16)
            VStack(spacing: 0) {
                FloatingOctoMark(size: 60)
                Text("What should we build in \(project?.name ?? "this project")?")
                    .font(.system(size: T.k * 26, weight: .regular, design: .serif)).foregroundStyle(T.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                statusLine(path: path).padding(.top, 10)
                lists.padding(.top, 24)
            }
            .shadow(color: .black.opacity(ThemeStore.shared.activeScene != nil ? 0.35 : 0), radius: 12)  // legible over a scene
            .frame(maxWidth: Self.column)
            .padding(.horizontal, 28)
            if draft.isEmpty && files.isEmpty {
                // Starters: fill the composer (never send); the text can be edited first.
                HStack(spacing: 6) {
                    ForEach(Self.starters, id: \.text) { st in
                        StarterChip(icon: st.icon, text: st.label) { draft = st.text; focused = true }.help(st.text)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 18)
            }
            composer
                .frame(maxWidth: Self.column)
                .padding(.horizontal, 28).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground(scene: true))
        .onAppear {
            // The pane may be rebuilt right after opening: keep the text until it is sent, and follow edits.
            var prefilled = false
            if draft.isEmpty, let d = NewChatDraft.pending[docId] { draft = d; prefilled = true }
            DispatchQueue.main.async { focused = true }
            // Focus selects the whole text; with a prefilled instruction put the caret at its end instead,
            // so typing continues it rather than replacing it.
            if prefilled {
                for delay in [0.05, 0.2, 0.45] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard let tv = (NSApp.keyWindow ?? (NSApp.delegate as? AppDelegate)?.mainWindow)?.firstResponder as? NSTextView else { return }
                        let end = NSRange(location: (tv.string as NSString).length, length: 0)
                        tv.setSelectedRange(end)
                        tv.scrollRangeToVisible(end)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["chatPicker"] as? String {
                pickingWorkspace = v == "workspace"; pickingBranch = v == "branch"; pickingModel = v == "model"; pickingPermission = v == "permission"
            }
        }
    }

    /// Width of the start screen's column and of the chat's (the same, so nothing moves when the chat starts).
    static let column: CGFloat = 720

    /// "octomux · main" and pills for what is waiting and working in this project (the Waiting card below lists
    /// every project's).
    private func statusLine(path: String) -> some View {
        let live = model.agentSessions(onlyCurrentWorkspace: false).filter { !$0.isDormant && $0.projectId == project?.id }
        let waiting = live.filter { $0.activity == .needsInput }.count
        let working = live.filter { $0.activity == .working }.count
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                if let p = project { ProjectIconView(project: p, size: 14) }
                Text(project?.name ?? "").font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text2)
                if let b = git.branch(for: path) {
                    Image(systemName: "arrow.triangle.branch").font(T.icon(10)).foregroundStyle(T.text3)
                    Text(b).font(T.mono(11)).foregroundStyle(T.text3)
                }
            }
            if waiting > 0 { StatusPill(text: "\(waiting) waiting", color: T.amber) }
            if working > 0 { StatusPill(text: "\(working) working", color: T.accent, spinning: true) }
        }
    }

    /// What waits for you (any project) and what ran last in this project; each row opens its session.
    /// At most three rows each; the header counts them all. Both cards keep the same height, so the block (and
    /// the composer under it) doesn't move with the numbers.
    @ViewBuilder private var lists: some View {
        let waitingAll = model.agentSessions(onlyCurrentWorkspace: false).filter { $0.activity == .needsInput && !$0.isDormant }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let recentAll = (project.map { model.sessions(ofProject: $0.id) } ?? [])
            .filter { s in !waitingAll.contains { $0.id == s.id } }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        if !waitingAll.isEmpty || !recentAll.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if !waitingAll.isEmpty {
                    StartList(title: "Waiting for you", tint: T.amber, sessions: Array(waitingAll.prefix(3)), total: waitingAll.count,
                              showProject: true, showAll: {
                                  if !model.sidebarVisible { model.toggleSidebar() }
                                  withAnimation(.easeOut(duration: 0.18)) { model.sidebarAgents = true }
                              })
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                if !recentAll.isEmpty {
                    StartList(title: "Recent in \(project?.name ?? "this project")", tint: nil, sessions: Array(recentAll.prefix(3)),
                              total: recentAll.count, showProject: false, showAll: nil)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let starters: [(icon: String, label: String, text: String)] = [
        ("doc.text.magnifyingglass", "Explain this repository", "Explain how this repository is organized"),
        ("checklist", "Review my changes", "Review my uncommitted changes"),
        ("ladybug", "Find and fix a bug", "Find and fix a small bug"),
    ]

    /// "Anıl returns!" with the account's first name, else a plain question.
    static var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "What should we work on?" : "\(first) returns!"
    }

    private var composer: some View {
        let path = worktree ?? project?.path ?? ""
        let kind = profile?.kind ?? .generic
        let flags = kind == .claude || kind == .codex
        return VStack(alignment: .leading, spacing: 10) {
            AttachmentChips(files: $files)
            ComposerField(text: Binding(
                get: { draft },
                set: { draft = $0; if NewChatDraft.pending[docId] != nil { NewChatDraft.pending[docId] = $0 } }),
                placeholder: "Type a message… (↩ to send, ⇧↩ for a new line)",
                minLines: 3, maxLines: 14, enabled: !sending, focused: $focused, onSubmit: send,
                onPasteFiles: { let f = AttachmentChips.pasted(); files += f; return !f.isEmpty }, completion: completion)
            HStack(spacing: 2) {
                modelChip(flags: flags)
                if NewChatDraft.asks[docId] != nil {
                    ContextChip(icon: "eye", text: "Read only", open: .constant(false),
                                help: "Asking about an Inbox item: the agent reads but changes nothing (Claude: plan mode; Codex: read-only sandbox)", tint: T.accent)
                } else if flags {
                    let perm = ChatLaunchOptions.permissions(kind).first { $0.id == options.permission }
                    ContextChip(icon: perm?.warn == true ? "exclamationmark.shield" : "lock", text: perm?.title ?? "CLI settings",
                                open: $pickingPermission, help: perm?.detail ?? "Permission mode", tint: perm?.warn == true ? T.amber : nil)
                        .background(DropdownAnchor(isPresented: $pickingPermission) {
                            PermissionPicker(kind: kind, options: $options) { pickingPermission = false }
                        })
                }
                Rectangle().fill(T.border).frame(width: 1, height: 14).padding(.horizontal, 4)
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
                if sending { WorkingRing().padding(.trailing, 6) }
                TemplateMenu(projectId: project?.id, folder: path, pick: { t in
                    draft = PromptTemplate.insert(t, into: draft)
                    if NewChatDraft.pending[docId] != nil { NewChatDraft.pending[docId] = draft }
                    focused = true
                }) {
                    Image(systemName: "text.bubble").font(.system(size: T.k * 13)).foregroundStyle(T.text2)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 26)
                .tint(T.text2)
                .help("Saved prompts")
                Button { files += AttachmentChips.pick() } label: {
                    Image(systemName: "paperclip").font(.system(size: T.k * 13)).foregroundStyle(T.text2).frame(width: 26, height: 26)
                }
                .buttonStyle(IconButtonStyle(size: 26)).help("Attach files (or drop them here, or paste a screenshot)")
                SendButton(enabled: canSend, help: "Start \(profile?.name ?? "the agent") with this message (↩)", action: send)
            }
        }
        .composerCard(focused: focused || dropTarget)
        .overlay(alignment: .top) { CompletionMenu(completion: completion).alignmentGuide(.top) { $0[.bottom] + 8 } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { if !files.contains(u) { files.append(u) } } }
                }
            }
            return true
        }
        .onAppear {
            if let k = profile?.kind { options = ChatLaunchOptions.load(k) }
            completion.configure(kind: { profile?.kind }, configDir: { ChatAgentDirs.config(profile) },
                                 folder: { worktree ?? project?.path })
        }
        .onChange(of: profile?.id) { _, _ in if let k = profile?.kind { options = ChatLaunchOptions.load(k) } }
        .onChange(of: options) { _, v in if let k = profile?.kind { v.save(k) } }
    }

    /// "✳ Opus · High ⌄": provider (agent profile), model and effort in one dropdown.
    private func modelChip(flags: Bool) -> some View {
        let kind = profile?.kind ?? .generic
        let effort = options.effort.map(ChatLaunchOptions.label)
        return Button { pickingModel.toggle() } label: {
            HStack(spacing: 5) {
                if let profile { AgentIcon(icon: profile.icon, size: 11) }
                Text(flags && options.model != nil ? options.modelTitle(kind) : (profile?.name ?? "No agent"))
                    .font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text)
                if flags, let effort { Text(effort).font(.system(size: T.k * 12)).foregroundStyle(T.text3) }
                Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pickingModel ? T.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: 6).pointerCursor()
        .help("\(profile?.name ?? "Agent") · model and effort")
        .background(DropdownAnchor(isPresented: $pickingModel) {
            ModelEffortPicker(profiles: profiles, selected: profile, options: $options,
                              workspace: model.state.workspaces.first { $0.id == project?.workspaceId },
                              isDefault: profile.map { $0.id == model.defaultChatProfile(workspace: project?.workspaceId)?.id } ?? false,
                              makeDefault: { if let p = profile, let ws = project?.workspaceId { model.setDefaultChatProfile(p.id, workspace: ws) } }) { p in
                profileId = p.id; UserDefaults.standard.set(p.id, forKey: "octomux.chatProfile")
            }
        })
    }

    private var canSend: Bool { !sending && profile != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let project, let profile else { return }
        sending = true
        NewChatDraft.pending[docId] = nil
        let docId = self.docId
        let kind = profile.kind
        let message = AttachmentChips.message(text, files: files, kind: kind)
        let images = kind == .codex ? files.filter(AttachmentChips.isImage).map(\.path) : []
        let ask = NewChatDraft.asks[docId]
        var opts = options
        if ask != nil { opts.permission = nil }       // replaced by the read-only flags
        let args = opts.args(kind, images: images) + (ask != nil ? ChatLaunchOptions.readOnlyArgs(kind) : [])
        model.newSession(profileId: profile.id, projectId: project.id, worktree: worktree, prompt: message, chat: true,
                         extraArgs: args) { id in
            ChatFirstMessage.set(id, text)
            if let item = NewChatDraft.links.removeValue(forKey: docId) { InboxStore.shared.link(item, session: id) }
            if let item = NewChatDraft.asks.removeValue(forKey: docId) { InboxStore.shared.setAsk(item, session: id) }
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
    var tint: Color? = nil
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: T.k * 11))
                Text(text).font(mono ? T.mono(12) : .system(size: T.k * 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(tint ?? (open || hover ? T.text : T.text2))
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
            Text("Workspace").font(.system(size: T.k * 11, weight: .semibold)).foregroundStyle(T.text3)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            row("folder", "Current checkout", checked: selected == nil) { pick(nil) }
            if naming {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 11)).foregroundStyle(T.text2).frame(width: 16)
                    TextField("New branch name", text: $branch).textFieldStyle(.plain).font(.system(size: T.k * 13))
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
                Image(systemName: icon).font(.system(size: T.k * 11)).foregroundStyle(T.text2).frame(width: 16)
                Text(title).font(.system(size: T.k * 13)).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").font(.system(size: T.k * 10, weight: .bold)).foregroundStyle(T.text) }
                if let trailing { Image(systemName: trailing).font(.system(size: T.k * 9, weight: .semibold)).foregroundStyle(T.text3) }
            }
            .padding(.leading, 10 + indent).padding(.trailing, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(checked ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(HoverFill()).panelPointer()
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

/// The composer card shared by the chat start screen and the chat view (same look and place).
extension View {
    func composerCard(focused: Bool) -> some View {
        self
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .background {
                if ThemeStore.shared.activeScene != nil { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial) }
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.raised.opacity(ThemeStore.shared.isDark ? 0.8 : 1))
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? WorkspaceTintColor.ring(AppModel.shared).opacity(0.6) : T.border, lineWidth: 1))
            .shadow(color: .black.opacity(ThemeStore.shared.isDark ? 0.25 : 0.07), radius: 10, y: 3)
    }
}

/// Round send button (arrow up), accent when there is something to send.
struct SendButton: View {
    let enabled: Bool
    var help = "Send (↩)"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up").font(.system(size: T.k * 12, weight: .bold)).frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : T.text3)
        .background(Circle().fill(enabled ? T.accent : T.hover))
        .overlay(Circle().stroke(enabled ? Color.clear : T.border))
        .disabled(!enabled).pointerCursor().help(help)
    }
}

/// Text a new chat's composer starts with, by doc id (set when the doc is opened, taken on appear).
enum NewChatDraft {
    static var pending: [String: String] = [:]
    /// Start screen opened from an Inbox item: doc id → item id, linked to the session once it starts.
    static var links: [String: String] = [:]
    /// Start screen opened by Ask on an Inbox item: doc id → item id. Such a session runs read-only.
    static var asks: [String: String] = [:]
}


/// A small list card on the start screen (waiting sessions, recent sessions).
struct StartList: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let tint: Color?
    let sessions: [Session]
    var total: Int
    let showProject: Bool
    /// Shown as "Show all ›" when there are more than the rows (nil: no link).
    var showAll: (() -> Void)?
    @State private var linkHover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: tint == nil ? "clock" : "hand.raised.fill").font(T.icon(10)).foregroundStyle(tint ?? T.text3)
                Text(title).font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(tint ?? T.text2).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(total)").font(T.meta).monospacedDigit().foregroundStyle(T.text3)
                if let showAll, total > sessions.count {
                    Button(action: showAll) {
                        HStack(spacing: 2) {
                            Text("Show all")
                            Image(systemName: "chevron.right").font(T.icon(8, .bold))
                        }
                        .font(.system(size: T.k * 11, weight: .medium))
                        .foregroundStyle(linkHover ? T.text : T.text2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).onHover { linkHover = $0 }.pointerCursor()
                    .help("All \(total) in the Agents list")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(sessions) { s in StartListRow(session: s, showProject: showProject) }
        }
        .padding(.top, 10).padding(.bottom, 6).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .startCard()
    }
}

/// A pill with a dot (or a spinning ring) and a short state: "3 waiting", "1 working".
struct StatusPill: View {
    let text: String
    let color: Color
    var spinning = false
    var body: some View {
        HStack(spacing: 5) {
            if spinning { WorkingRing().frame(width: 9, height: 9) } else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: T.k * 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// The octopus, bobbing slowly (still with Reduce Motion). The bob is a Core Animation layer animation, so the
/// window server moves it: a repeating SwiftUI animation re-renders the view every frame (~17% CPU while the
/// start screen shows).
struct FloatingOctoMark: View {
    var size: CGFloat = 60
    private static let glow: CGFloat = 20   // room for the glow inside the bobbing layer
    var body: some View {
        let h = size * 13 / 16
        BobbingHost(content: AnyView(
            OctoMark(size: size)
                .shadow(color: Color(hex: "#8B5CF6").opacity(0.35), radius: 14, y: 4)
                .padding(Self.glow)))
            .frame(width: size + Self.glow * 2, height: h + Self.glow * 2)
            .padding(-Self.glow)
            .accessibilityLabel("Octomux")
    }
}

/// Hosts SwiftUI content in a layer that moves up and down by 3 pt, forever (nothing with Reduce Motion).
private struct BobbingHost: NSViewRepresentable {
    let content: AnyView
    func makeNSView(context: Context) -> BobbingView { BobbingView(content: content) }
    func updateNSView(_ v: BobbingView, context: Context) { v.hosting.rootView = content }

    final class BobbingView: NSView {
        let hosting: NSHostingView<AnyView>
        init(content: AnyView) {
            hosting = NSHostingView(rootView: content)
            super.init(frame: .zero)
            wantsLayer = true
            hosting.wantsLayer = true
            addSubview(hosting)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); hosting.frame = bounds }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let layer = hosting.layer else { return }
            layer.removeAnimation(forKey: "bob")
            guard window != nil, !Motion.reduced else { return }
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = -3; a.toValue = 3
            a.duration = 2.4; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "bob")
        }
    }
}

extension View {
    /// Card on the start screen: a frosted fill (a scene's art blurs behind it), hairline edge.
    func startCard(radius: CGFloat = R.xl) -> some View {
        let scene = ThemeStore.shared.activeScene != nil
        let dark = ThemeStore.shared.isDark
        return self
            .background {
                ZStack {
                    if scene { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial) }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(T.raised.opacity(scene ? 0.55 : (dark ? 0.45 : 0.9)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(T.border))
    }
}

struct StartListRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let showProject: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(icon: iconName(for: session, model: model), size: 12).frame(width: 16)
            Text(session.displayTitle).font(T.body).foregroundStyle(T.text).lineLimit(1)
            Spacer(minLength: 6)
            Text([showProject ? model.project(session.projectId)?.name : nil, AgentRow.elapsed(since: session.lastActivityAt)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(T.meta).foregroundStyle(T.text3).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.selectSession(session.id) }
        .help("Open \(session.displayTitle)")
    }
}

/// A suggestion chip above the start screen's composer: fills it, never sends.
struct StarterChip: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(T.icon(11)).foregroundStyle(T.text3)
            Text(text).font(.system(size: T.k * 12)).foregroundStyle(hover ? T.text : T.text2).lineLimit(1)
        }
        .padding(.horizontal, 11).frame(height: 28)
        .background {
            if ThemeStore.shared.activeScene != nil { Capsule().fill(.ultraThinMaterial) }
            Capsule().fill(hover ? T.raised : T.raised.opacity(ThemeStore.shared.activeScene != nil ? 0.5 : 0.35))
        }
        .overlay(Capsule().stroke(T.border))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture(perform: action)
    }
}

