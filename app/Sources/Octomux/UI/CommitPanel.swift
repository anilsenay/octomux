import AppKit
import SwiftUI

/// The top bar's git button: the next step for this checkout. Uncommitted work → Commit (a panel with the
/// message, written by the commit-message agent, and Commit / Commit & Push); commits not pushed → Push ↑n;
/// pushed, no pull request → Create PR; an open pull request (from the Inbox) → PR #n. ▾ has all of them.
struct TopBarCommitButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var git = GitInfo.shared
    @ObservedObject private var inbox = InboxStore.shared
    @State private var hover = false
    @State private var panel = false
    @State private var pushing = false
    @State private var pushError: String?

    enum Step: Equatable { case commit(Int), push(Int), createPR, openPR(InboxItem), clean }

    private func step(_ path: String) -> Step {
        guard let y = git.sync(for: path) else { return .clean }
        if y.dirty > 0 { return .commit(y.dirty) }
        if y.ahead > 0 || (!y.upstream && y.sinceBase > 0) { return .push(max(y.ahead, 1)) }
        if let pr = openPR(path) { return .openPR(pr) }
        if y.sinceBase > 0 { return .createPR }
        return .clean
    }

    /// An open pull request from this branch, in the Inbox, for this project's repo.
    private func openPR(_ path: String) -> InboxItem? {
        guard let branch = git.branch(for: path), let p = model.currentProject else { return nil }
        return inbox.items.first { $0.kind == .pr && $0.ended == nil && $0.branch == branch && inbox.isCheckout(p, of: $0) == true }
    }

    var body: some View {
        let path = model.currentWorkPath ?? ""
        let st = step(path)
        HStack(spacing: 0) {
            Button { primary(st, path) } label: {
                HStack(spacing: 5) {
                    if pushing { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12) }
                    else { Image(systemName: icon(st)).font(T.icon(11, .semibold)).foregroundStyle(pushError != nil ? T.red : tint(st)).frame(width: 13) }
                    Text(pushError != nil ? "Push failed" : title(st)).font(.system(size: T.k * 12, weight: .medium))
                }
                .foregroundStyle(st == .clean ? T.text3 : hover || panel ? T.text : T.text2)
                .padding(.leading, 9).padding(.trailing, 6).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pushing)
            .help(pushError ?? help(st))
            Rectangle().fill(T.border).frame(width: 1, height: 14)
            Menu {
                Button("Commit…") { panel = true }
                Button("Push") { push(path) }
                Divider()
                Button("Create Pull Request…") { DispatchQueue.main.async { PullRequestWindow.show(model: model) } }
                if case .openPR(let pr) = st { Button("Open \(pr.key) in Inbox") { openInInbox(pr) } }
                Divider()
                Button("Show Changes") { showChanges() }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: T.k * 8, weight: .bold)).foregroundStyle(T.text3).menuHitBox(18, 24)
            }
            .plainMenu().fixedSize()
        }
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(hover || panel ? T.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(T.border))
        .onHover { hover = $0 }
        .pointerCursor()
        .fixedSize()
        .floatingPanel(isPresented: $panel, alignment: .trailing) { CommitPanel(path: path) }
        .debugOpens("commit", $panel)
        // Fresh while the app is in front (a commit or push in a terminal shows within seconds); idle behind.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if NSApp.isActive, !path.isEmpty { _ = git.sync(for: path) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !path.isEmpty { git.invalidate(path) }
        }
    }

    private func title(_ s: Step) -> String {
        switch s {
        case .commit: return "Commit"
        case .push(let n): return "Push ↑\(n)"
        case .createPR: return "Create PR"
        case .openPR(let pr): return "PR \(pr.key)"
        case .clean: return "Commit"
        }
    }
    private func icon(_ s: Step) -> String {
        switch s {
        case .commit, .clean: return "checkmark.circle"
        case .push: return "arrow.up.circle"
        case .createPR: return "plus.circle"
        case .openPR: return "arrow.triangle.pull"
        }
    }
    private func tint(_ s: Step) -> Color {
        switch s {
        case .commit: return T.amber
        case .push: return T.accent
        case .openPR(let pr): return pr.checks == .failing ? T.red : pr.checks == .passing ? T.green : T.text2
        default: return T.text3
        }
    }
    private func help(_ s: Step) -> String {
        switch s {
        case .commit(let n): return "\(n) uncommitted file\(n == 1 ? "" : "s"): write the message and commit"
        case .push(let n): return "\(n) commit\(n == 1 ? "" : "s") not pushed: push now"
        case .createPR: return "Pushed: open a pull request for this branch"
        case .openPR(let pr): return "\(pr.title) (\(pr.status)): open in the Inbox"
        case .clean: return "Nothing to commit"
        }
    }

    private func primary(_ s: Step, _ path: String) {
        switch s {
        case .commit, .clean: panel.toggle()
        case .push: push(path)
        case .createPR: DispatchQueue.main.async { PullRequestWindow.show(model: model) }
        case .openPR(let pr): openInInbox(pr)
        }
    }

    private func openInInbox(_ pr: InboxItem) {
        model.openInbox()
        InboxStore.shared.select(pr.id)
    }

    private func showChanges() {
        UserDefaults.standard.set("Changes", forKey: "octomux.rightTab")
        model.setRightPanel(true)
    }

    /// `git push` (a branch with no upstream gets one on origin).
    private func push(_ path: String) {
        guard !path.isEmpty, !pushing else { return }
        let upstream = git.sync(for: path)?.upstream ?? true
        pushing = true
        pushError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = GitInfo.git(upstream ? ["push"] : ["push", "-u", "origin", "HEAD"], in: path) != nil
            DispatchQueue.main.async {
                pushing = false
                if !ok {
                    pushError = "Push failed (run git push in a terminal for details)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { pushError = nil }
                }
                GitInfo.shared.invalidate(path)
            }
        }
    }
}

/// Commit without leaving the terminal: the changed files, the message (the agent writes one when the box is
/// empty), amend, Commit / Commit & Push.
struct CommitPanel: View {
    @EnvironmentObject var model: AppModel
    let path: String
    @StateObject private var changes = ChangesModel()
    @State private var amend = false
    @FocusState private var focused: Bool

    var body: some View {
        let files = changes.changes
        let stat = GitInfo.shared.diffStat(for: path)
        let staged = files.filter(\.isStaged).count
        let hasMsg = !changes.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canCommit = !changes.busy && changes.generating == nil && (amend || (!files.isEmpty && hasMsg))
        PanelCard(width: 400) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(amend ? "Amend last commit" : "Commit").font(.system(size: T.k * 13, weight: .semibold)).foregroundStyle(T.text)
                    if let b = GitInfo.shared.branch(for: path) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(T.icon(9))
                            Text(b).font(T.mono(11)).lineLimit(1)
                        }
                        .foregroundStyle(T.text3)
                    }
                    Spacer(minLength: 6)
                    if let stat, stat.added + stat.removed > 0 {
                        Text("+\(stat.added)").font(T.mono(11)).foregroundStyle(T.diffAdd)
                        Text("−\(stat.removed)").font(T.mono(11)).foregroundStyle(T.diffDel)
                    }
                }
                fileList(files, staged: staged)
                messageBox
                HStack(spacing: 8) {
                    Toggle(isOn: $amend) { Text("Amend").font(.system(size: T.k * 12)).foregroundStyle(T.text2) }
                        .toggleStyle(.checkbox).controlSize(.small)
                    Spacer()
                    Button { commit(push: true) } label: {
                        Text("Commit & Push").font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(canCommit ? T.text : T.text3)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.text.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(T.border))
                    }
                    .buttonStyle(.plain).disabled(!canCommit).pointerCursor()
                    Button { commit(push: false) } label: {
                        HStack(spacing: 6) {
                            Text(amend ? "Amend" : staged > 0 ? "Commit \(staged) staged" : "Commit")
                            Text("⌘↩").opacity(0.7)
                        }
                        .font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.accent.opacity(canCommit ? 1 : 0.45)))
                    }
                    .buttonStyle(.plain).disabled(!canCommit).pointerCursor()
                }
                if !changes.status.isEmpty, changes.generating == nil {
                    Text(changes.status).font(T.meta).foregroundStyle(changes.status.contains("failed") ? T.red : T.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(9)
        }
        .onAppear {
            changes.attach(path: path)
            focused = true
            // Write a message as soon as the files are known, when an agent is set up for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if changes.message.isEmpty, changes.generating == nil, !changes.changes.isEmpty,
                   CommitMessageGen.profile(model: model, project: model.currentProject?.id) != nil {
                    changes.generateMessage(projectId: model.currentProject?.id, model: model)
                }
            }
        }
        .onDisappear {
            changes.generating?.cancel()
            changes.detach()
        }
    }

    private func fileList(_ files: [GitChange], staged: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files.prefix(6)) { c in
                HStack(spacing: 8) {
                    Text(c.badge).font(T.mono(10)).fontWeight(.bold).foregroundStyle(c.color).frame(width: 12)
                    Text((c.path as NSString).lastPathComponent).font(.system(size: T.k * 12)).foregroundStyle(T.text).lineLimit(1)
                    Text((c.path as NSString).deletingLastPathComponent).font(T.meta).foregroundStyle(T.text3)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    if staged > 0 && c.isStaged { Text("staged").font(T.meta).foregroundStyle(T.green) }
                }
                .frame(height: 22)
            }
            HStack {
                if files.count > 6 { Text("and \(files.count - 6) more").font(T.meta).foregroundStyle(T.text3) }
                if files.isEmpty { Text(changes.isRepo ? "No uncommitted changes" : "Not a git repository").font(T.meta).foregroundStyle(T.text3) }
                Spacer()
                Button {
                    FloatingPanelController.shared.close()
                    UserDefaults.standard.set("Changes", forKey: "octomux.rightTab")
                    model.setRightPanel(true)
                } label: {
                    HStack(spacing: 2) { Text("Review in Changes"); Image(systemName: "chevron.right").font(T.icon(8, .bold)) }
                        .font(.system(size: T.k * 11, weight: .medium)).foregroundStyle(T.text2)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.text.opacity(0.035)))
    }

    private var messageBox: some View {
        let generating = changes.generating != nil
        return TextField(generating ? "Writing a message…" : "Message", text: $changes.message, axis: .vertical)
            .lineLimit(3...8).textFieldStyle(.plain).font(T.body)
            .focused($focused)
            .padding(.leading, 10).padding(.trailing, 30).padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                Button { changes.generateMessage(projectId: model.currentProject?.id, model: model) } label: {
                    Group {
                        if generating { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                    }
                    .font(.system(size: T.k * 12))
                }
                .buttonStyle(IconButtonStyle(size: 22)).padding(4)
                .disabled(changes.changes.isEmpty && !generating)
                .help(generating ? "Stop writing the message"
                      : "Write a commit message with \(CommitMessageGen.profile(model: model, project: model.currentProject?.id)?.name ?? "an agent")")
            }
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.frame.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous)
                .stroke(focused ? WorkspaceTintColor.ring(model).opacity(0.6) : T.border))
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                commit(push: false)
                return .handled
            }
    }

    private func commit(push: Bool) {
        let hasMsg = !changes.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !changes.busy, changes.generating == nil, amend || (!changes.changes.isEmpty && hasMsg) else { return }
        changes.commit(push: push, amend: amend)
        // Closes once it went through; a failure stays on screen.
        func check(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if changes.busy, tries > 0 { return check(tries - 1) }
                GitInfo.shared.invalidate(path)
                if !changes.status.contains("failed") { FloatingPanelController.shared.close() }
            }
        }
        check(300)
    }
}
