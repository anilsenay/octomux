import AppKit
import SwiftUI

// The Agents layout's home: every agent at a glance, drawn three ways to try (Board, Columns, Inbox).
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

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
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

enum AgentsHomeStyle: String, CaseIterable, Identifiable {
    case board, columns, inbox
    var id: String { rawValue }
    var title: String { switch self { case .board: return "Board"; case .columns: return "Columns"; case .inbox: return "Inbox" } }
    var icon: String { switch self { case .board: return "square.grid.2x2"; case .columns: return "rectangle.split.3x1"; case .inbox: return "tray.full" } }
}

struct AgentsHomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var digests = AgentDigests()
    @AppStorage("octomux.agentsHomeStyle") private var styleRaw = AgentsHomeStyle.board.rawValue
    @State private var selected: String?

    private var style: AgentsHomeStyle { AgentsHomeStyle(rawValue: styleRaw) ?? .board }

    var body: some View {
        let agents = model.agentSessions(onlyCurrentWorkspace: false).sorted { $0.lastActivityAt > $1.lastActivityAt }
        VStack(spacing: 0) {
            header(agents)
            Hairline()
            switch style {
            case .board: board(agents)
            case .columns: columns(agents)
            case .inbox: inbox(agents)
            }
        }
        .background(T.surface)
        .onAppear { digests.start() }
        .onDisappear { digests.stop() }
    }

    // MARK: Header

    private func header(_ agents: [Session]) -> some View {
        let groups = Dictionary(grouping: agents, by: AgentsList.Group.of)
        return HStack(spacing: 12) {
            Image(systemName: "sparkles").font(T.icon(13)).foregroundStyle(T.accent)
            Text("Agents").font(T.heading)
            HStack(spacing: 10) {
                count(groups[.needsInput]?.count ?? 0, "waiting", T.amber)
                count(groups[.working]?.count ?? 0, "working", T.accent)
                count(groups[.finished]?.count ?? 0, "finished", T.green)
            }
            Spacer()
            SegmentedTabs(items: AgentsHomeStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $styleRaw)
                .frame(width: 260)
            Button { model.openNewChat() } label: { Label("New Agent", systemImage: "plus") }
                .buttonStyle(ChromeButtonStyle()).help("Start an agent (⌘N)")
        }
        .padding(.horizontal, 16).frame(height: 46)
    }

    private func count(_ n: Int, _ label: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 6, height: 6); Text("\(n) \(label)").font(T.meta).foregroundStyle(n > 0 ? c : T.text3) }
    }

    // MARK: A · Board

    private func board(_ agents: [Session]) -> some View {
        let g = Dictionary(grouping: agents, by: AgentsList.Group.of)
        let waiting = (g[.needsInput] ?? []) + (g[.error] ?? [])
        let busy = (g[.working] ?? []) + (g[.finished] ?? [])
        let rest = (g[.idle] ?? []) + (g[.stopped] ?? [])
        let cols = [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StartBox()
                if !waiting.isEmpty {
                    sectionTitle("Waiting for you", waiting.count, T.amber)
                    LazyVGrid(columns: cols, spacing: 12) { ForEach(waiting) { card($0, prominent: true) } }
                }
                if !busy.isEmpty {
                    sectionTitle("Working and finished", busy.count, T.accent)
                    LazyVGrid(columns: cols, spacing: 12) { ForEach(busy) { card($0) } }
                }
                if !rest.isEmpty {
                    sectionTitle("Recent", rest.count, T.text3)
                    VStack(spacing: 6) { ForEach(rest.prefix(12)) { recentRow($0) } }
                }
                if agents.isEmpty { emptyState }
            }
            .padding(18)
        }
    }

    private func sectionTitle(_ t: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Text(t.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(c)
            Text("\(n)").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text3)
        }
        .padding(.top, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(T.icon(22)).foregroundStyle(T.text3)
            Text("No agents yet").font(T.heading)
            Text("Start one above or with ⌘N; it shows up here while it works and when it needs you.").font(T.meta).foregroundStyle(T.text3)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: B · Columns

    private func columns(_ agents: [Session]) -> some View {
        let g = Dictionary(grouping: agents, by: AgentsList.Group.of)
        let cols: [(String, Color, [Session])] = [
            ("Waiting for you", T.amber, (g[.needsInput] ?? []) + (g[.error] ?? [])),
            ("Working", T.accent, g[.working] ?? []),
            ("Finished", T.green, g[.finished] ?? []),
            ("Idle", T.text3, (g[.idle] ?? []) + (g[.stopped] ?? []).prefix(8)),
        ]
        return VStack(spacing: 10) {
            StartBox(compact: true)
            HStack(alignment: .top, spacing: 10) {
                ForEach(cols, id: \.0) { title, color, list in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(title).font(.system(size: T.k * 12, weight: .semibold)).foregroundStyle(color)
                            Text("\(list.count)").font(T.meta).foregroundStyle(T.text3)
                        }
                        .padding(.horizontal, 4).padding(.top, 2)
                        ScrollView {
                            VStack(spacing: 8) { ForEach(list) { card($0, compact: true) } }
                        }
                        .scrollIndicators(.never)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.hover))
                }
            }
        }
        .padding(16)
    }

    // MARK: C · Inbox

    private func inbox(_ agents: [Session]) -> some View {
        let order: [AgentsList.Group] = [.needsInput, .error, .finished, .working, .idle, .stopped]
        let sorted = agents.sorted { a, b in
            let ga = order.firstIndex(of: AgentsList.Group.of(a)) ?? 9, gb = order.firstIndex(of: AgentsList.Group.of(b)) ?? 9
            return ga != gb ? ga < gb : a.lastActivityAt > b.lastActivityAt
        }
        let current = selected.flatMap { id in sorted.first { $0.id == id } } ?? sorted.first
        return HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { s in
                        inboxRow(s, on: s.id == current?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = s.id }
                        Hairline()
                    }
                }
            }
            .frame(width: 330)
            .background(KeyCatcher { dir in
                guard let i = sorted.firstIndex(where: { $0.id == current?.id }) else { return }
                let j = min(max(0, i + dir), sorted.count - 1)
                selected = sorted[j].id
            })
            Rectangle().fill(T.border).frame(width: 1)
            if let s = current {
                if model.canChat(s) {
                    ChatView(sessionId: s.id).id(s.id)
                } else {
                    VStack(spacing: 10) {
                        AgentIcon(icon: iconName(for: s, model: model), size: 22)
                        Text(s.displayTitle).font(T.heading)
                        if let d = digests.digests[s.id], !d.summary.isEmpty { Text(d.summary).font(T.meta).foregroundStyle(T.text2).frame(maxWidth: 460) }
                        Button("Open Terminal") { model.selectSession(s.id) }.buttonStyle(ChromeButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyState.frame(maxWidth: .infinity)
            }
        }
    }

    private func inboxRow(_ s: Session, on: Bool) -> some View {
        let g = AgentsList.Group.of(s)
        let d = digests.digests[s.id]
        let line: String = {
            switch d?.pending {
            case .permission(let p)?: return "Allow \(p)?"
            case .question(let q, _)?: return q
            case nil: return d?.summary ?? ""
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 14)
                Text(s.displayTitle).font(.system(size: T.k * 13, weight: s.unread || g == .needsInput ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            HStack(spacing: 5) {
                Circle().fill(color(g)).frame(width: 6, height: 6)
                Text(label(g)).font(T.meta).foregroundStyle(color(g))
                Text("· \(model.project(s.projectId)?.name ?? "")").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            }
            if !line.isEmpty { Text(line).font(T.meta).foregroundStyle(T.text2).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(on ? T.selection : .clear)
    }

    // MARK: Cards

    private func label(_ g: AgentsList.Group) -> String {
        switch g {
        case .needsInput: return "Waiting for you"
        case .working: return "Working"
        case .error: return "Error"
        case .finished: return "Finished"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        }
    }
    private func color(_ g: AgentsList.Group) -> Color {
        switch g {
        case .needsInput: return T.amber
        case .working: return T.accent
        case .error: return T.red
        case .finished: return T.green
        default: return T.text3
        }
    }

    @ViewBuilder private func card(_ s: Session, prominent: Bool = false, compact: Bool = false) -> some View {
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
            if !d.summary.isEmpty {
                Text(d.summary).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(compact ? 3 : 2)
            } else if let fp = s.firstPrompt, !fp.isEmpty {
                Text(fp).font(.system(size: T.k * 12)).foregroundStyle(T.text3).lineLimit(2)
            }
            if let pending = d.pending { pendingBox(s, pending, compact: compact) }
            else if g == .needsInput {
                // Its question isn't in a transcript we read (a terminal-only agent): it is on its screen.
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(T.icon(10)).foregroundStyle(T.amber)
                    Text("Waiting for your answer in its terminal").font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.amber.opacity(0.08)))
            }
            if g == .working, !d.steps.isEmpty { Text(d.steps).font(T.meta).foregroundStyle(T.text3) }
            SinceLookedBadge(session: s)
            if g == .finished || (!compact && g != .working && !d.files.isEmpty) {
                if !d.files.isEmpty && !compact {
                    Text(d.files.prefix(4).joined(separator: ", ") + (d.files.count > 4 ? " +\(d.files.count - 4)" : ""))
                        .font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                }
                if g == .finished {
                    HStack(spacing: 6) {
                        Button("Review Changes") { reviewChanges(s) }.buttonStyle(PrimaryButtonStyle())
                        Spacer()
                        openLink(s)
                    }
                }
            } else if d.pending == nil {
                HStack { Spacer(); openLink(s) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(g == .needsInput ? T.amber.opacity(0.45) : T.border))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(s) }
    }

    @ViewBuilder private func pendingBox(_ s: Session, _ p: AgentDigest.Pending, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch p {
            case .permission(let what):
                Text("Allow \(what)?").font(.system(size: T.k * 12, weight: .semibold)).lineLimit(compact ? 3 : 2)
                HStack(spacing: 6) {
                    Button("Allow") { AgentDigests.answer(s.id, option: 0) }.buttonStyle(PrimaryButtonStyle())
                    Button("Deny") { AgentDigests.deny(s.id) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    openLink(s)
                }
            case .question(let q, let opts):
                Text(q).font(.system(size: T.k * 12, weight: .semibold)).lineLimit(compact ? 4 : 3)
                FlowButtons(options: Array(opts.prefix(compact ? 2 : 4))) { i in AgentDigests.answer(s.id, option: i) }
                HStack { Spacer(); openLink(s) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.amber.opacity(0.08)))
    }

    private func recentRow(_ s: Session) -> some View {
        HStack(spacing: 8) {
            AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 14)
            Text(s.displayTitle).font(.system(size: T.k * 13)).lineLimit(1)
            Text("\(model.project(s.projectId)?.name ?? "") · \(AgentRow.elapsed(since: s.lastActivityAt))").font(T.meta).foregroundStyle(T.text3)
            Spacer()
            openLink(s)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(T.border))
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

/// The home's "start an agent" box: the text goes to a new chat's start screen (project, checkout and agent are
/// picked there), so nothing starts by surprise.
private struct StartBox: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("What should an agent work on?", text: $text)
                .textFieldStyle(.plain).font(.system(size: T.k * (compact ? 13 : 15)))
                .onSubmit(start)
            Button(action: start) { Image(systemName: "arrow.up").font(T.icon(12, .bold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(text.isEmpty ? T.text3.opacity(0.4) : T.accent))
                .disabled(text.isEmpty).help("Continue on the start screen (↩)")
        }
        .padding(.horizontal, 14).frame(height: compact ? 42 : 54)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.border))
    }

    private func start() {
        guard !text.isEmpty else { return }
        model.openNewChat(draft: text)
        text = ""
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

/// ↑ ↓ in the Inbox list (while the list area has the keys).
private struct KeyCatcher: NSViewRepresentable {
    let move: (Int) -> Void
    final class V: NSView {
        var move: ((Int) -> Void)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, !(w.firstResponder is NSTextView) else { return e }
                if e.keyCode == 125 { self.move?(1); return nil }
                if e.keyCode == 126 { self.move?(-1); return nil }
                return e
            }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.move = move; return v }
    func updateNSView(_ v: V, context: Context) { v.move = move }
}
