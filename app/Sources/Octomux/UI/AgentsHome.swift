import AppKit
import SwiftUI

// Home's agents: what each agent's transcript says (its digest), the board of every agent by state and its cards.
// What each card says comes from the agent's own transcript (the chat view's reader): its last words, what it
// waits for (a permission or a question, answerable from the card as the keys you would press), the steps of
// its turn and the files it changed.

/// What an agent's transcript says right now.
struct AgentDigest: Equatable {
    enum Pending: Equatable {
        case permission(String)                 // "Bash(git push)"
        case question(String, [String])         // text, option labels
    }
    var summary = ""
    var pending: Pending?
    var steps = ""
    var files: [String] = []
}

/// Follows the transcripts of the agents the home shows (one reader each, dropped when the home closes).
final class AgentDigests: ObservableObject {
    @Published private(set) var digests: [String: AgentDigest] = [:]
    private var readers: [String: ChatModel] = [:]
    private var timer: Timer?

    /// Readers running in the whole app (the engine window's checks: none while no block that shows them is on screen).
    nonisolated(unsafe) static var running = 0

    func start() {
        guard timer == nil else { return }
        Self.running += 1
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { if timer != nil { Self.running -= 1 }; timer?.invalidate() }

    func stop() {
        if timer != nil { Self.running -= 1 }
        timer?.invalidate(); timer = nil
        readers.values.forEach { $0.attach(nil) }
        readers = [:]
    }

    private func refresh() {
        let model = AppModel.shared
        let sessions = model.agentSessions(onlyCurrentWorkspace: false).filter { !$0.isDormant && !model.host(for: $0.id).isRemote }
        let ids = Set(sessions.map(\.id))
        for (id, r) in readers where !ids.contains(id) { r.attach(nil); readers[id] = nil }
        var out: [String: AgentDigest] = [:]
        for s in sessions {
            let r = readers[s.id] ?? { let c = ChatModel(); readers[s.id] = c; return c }()
            if r.path == nil, let p = s.transcriptPath ?? TranscriptLocator.path(for: s, model: model) { r.attach(p) }
            out[s.id] = Self.digest(r.items, waiting: s.activity == .needsInput)
        }
        if out != digests { digests = out }
    }

    static func digest(_ items: [ChatItem], waiting: Bool) -> AgentDigest {
        var d = AgentDigest()
        let start = (items.lastIndex { $0.kind == .user }).map { $0 + 1 } ?? 0
        let turn = start < items.count ? Array(items[start...]) : []
        if let a = items.last(where: { $0.kind == .assistant }) {
            // One plain line: markdown marks out.
            var one = a.text.replacingOccurrences(of: "\n", with: " ")
            for m in ["**", "__", "`", "### ", "## ", "# "] { one = one.replacingOccurrences(of: m, with: "") }
            one = one.trimmingCharacters(in: .whitespaces)
            d.summary = one.count > 220 ? String(one.prefix(219)) + "…" : one
        }
        let tools = turn.filter { $0.kind == .tool }
        var reads = 0, edits = Set<String>(), runs = 0
        for t in tools {
            switch t.tool {
            case "Read", "Grep", "Glob", "LS": reads += 1
            case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
                edits.insert(t.detail)
            case "Bash", "shell", "exec_command": runs += 1
            default: break
            }
        }
        d.steps = [reads > 0 ? "Read \(reads) file\(reads == 1 ? "" : "s")" : nil, edits.isEmpty ? nil : "Edited \(edits.count) file\(edits.count == 1 ? "" : "s")",
                   runs > 0 ? "Ran \(runs) command\(runs == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
        d.files = edits.map { ($0 as NSString).lastPathComponent }.sorted()
        if waiting, let t = items.last(where: { $0.kind == .tool }), t.result == nil {
            if t.tool == "AskUserQuestion", let data = t.input.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let q = (o["questions"] as? [[String: Any]])?.first, let text = q["question"] as? String {
                let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                d.pending = .question(text, opts)
            } else {
                d.pending = .permission(t.detail.isEmpty ? t.tool : "\(t.tool)(\(t.detail))")
            }
        }
        return d
    }

    /// Answers the agent's question or permission prompt as the keys you would press in its terminal.
    static func answer(_ sessionId: String, option i: Int) {
        guard AppModel.shared.session(sessionId)?.activity == .needsInput else { return }
        keys(sessionId, Array(repeating: "\u{1b}[B", count: i) + ["\r"])
    }
    static func deny(_ sessionId: String) {
        guard AppModel.shared.session(sessionId)?.activity == .needsInput else { return }
        keys(sessionId, ["\u{1b}"])
    }
    private static func keys(_ id: String, _ seq: [String]) {
        let c = AppModel.shared.client(for: id)
        for (i, k) in seq.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                c.call("session.input", ["id": id, "data": k], completion: AppModel.shared.report)
            }
        }
    }
}

/// Every agent by state, in four columns: waiting for you, working, finished, idle (Home's Board section).
struct AgentBoard: View {
    let agents: [Session]

    var body: some View {
        let g = Dictionary(grouping: agents.sorted { $0.lastActivityAt > $1.lastActivityAt }, by: AgentsList.Group.of)
        let cols: [(String, Color, [Session])] = [
            ("Waiting for you", T.amber, (g[.needsInput] ?? []) + (g[.error] ?? [])),
            ("Working", T.accent, g[.working] ?? []),
            ("Finished", T.green, g[.finished] ?? []),
            ("Idle", T.text3, (g[.idle] ?? []) + (g[.stopped] ?? []).prefix(8)),
        ]
        HStack(alignment: .top, spacing: 10) {
            ForEach(cols, id: \.0) { title, color, list in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(title).font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(T.text2)
                        Text("\(list.count)").font(T.meta).foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 4).padding(.top, 2)
                    ScrollView {
                        VStack(spacing: 8) { ForEach(list) { AgentCard(session: $0, compact: true) } }
                    }
                    .scrollIndicators(.never)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.hover))
            }
        }
    }
}

/// An agent as a card: its name, project and checkout, its question to answer or what it did, and its next step.
struct AgentCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests
    let session: Session
    var compact = false

    var body: some View {
        let s = session
        let g = AgentsList.Group.of(s)
        let d = digests.digests[s.id] ?? AgentDigest()
        let p = model.project(s.projectId)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
                Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if g == .working { WorkingRing().scaleEffect(0.85) }
                if g == .finished { Circle().fill(T.green).frame(width: 7, height: 7) }
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            HStack(spacing: 5) {
                if let p { ProjectIconView(project: p, size: 14) }
                Text(p?.name ?? "").font(T.meta).foregroundStyle(T.text3)
                if let b = branch(s) { Text("· \(b)").font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1) }
                Spacer(minLength: 4)
                WorkChips(session: s, limit: compact ? 1 : 2)
            }
            if let pending = d.pending {
                PendingAnswer(session: s, pending: pending, compact: compact) { open(s) }
            } else {
                let line = d.summary.isEmpty ? (s.firstPrompt ?? "") : d.summary
                if !line.isEmpty {
                    Text(line).font(.system(size: T.k * 12)).foregroundStyle(d.summary.isEmpty ? T.text3 : T.text2)
                        .lineLimit(compact ? 3 : 2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if g == .working, !d.steps.isEmpty { Text(d.steps).font(T.meta).foregroundStyle(T.text3) }
            if !compact, g != .working, !d.files.isEmpty {
                Text(d.files.prefix(4).joined(separator: ", ") + (d.files.count > 4 ? " +\(d.files.count - 4)" : ""))
                    .font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if g == .needsInput && d.pending == nil {
                    // Its question isn't in a transcript we read (a terminal-only agent): it is on its screen.
                    Image(systemName: "hand.raised.fill").font(T.icon(10)).foregroundStyle(T.amber)
                    Text("Answer in its terminal").font(T.meta).foregroundStyle(T.text2)
                }
                SinceLookedBadge(session: s)
                Spacer(minLength: 4)
                if g == .finished { Button("Review Changes") { reviewChanges(s) }.buttonStyle(SmallButtonStyle()) }
                if d.pending == nil { openLink(s) }
            }
        }
        .frame(minHeight: compact ? 0 : 96, alignment: .topLeading)
        .homeCard(attention: g == .needsInput)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(s) }
    }


    private func openLink(_ s: Session) -> some View {
        Button { open(s) } label: { Text(s.isDormant ? "Resume ›" : "Open ›").font(T.meta).foregroundStyle(T.accent) }
            .buttonStyle(.plain).pointerCursor()
    }

    private func open(_ s: Session) {
        if s.isDormant { model.restart(s.id) }
        model.selectSession(s.id)
    }

    private func reviewChanges(_ s: Session) {
        let base = s.worktree ?? model.project(s.projectId)?.path ?? s.cwd
        if model.selectedProjectId != s.projectId { model.selectedProjectId = s.projectId }
        model.openDoc(.changes, workPath: base)
        model.lookedAt(s.id)
    }

    private func branch(_ s: Session) -> String? {
        let path = s.worktree ?? model.project(s.projectId)?.path ?? s.cwd
        return GitInfo.shared.branch(for: path)
    }
}

/// Answer buttons that wrap.
struct FlowButtons: View {
    let options: [String]
    let action: (Int) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }
    @ViewBuilder private var buttons: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { i, o in
            if i == 0 { Button(o) { action(i) }.buttonStyle(PrimaryButtonStyle()) }
            else { Button(o) { action(i) }.buttonStyle(SecondaryButtonStyle()) }
        }
    }
}
