import SwiftUI

// Workday's home: your day on one page. Who needs you (the next one answered in place), what happened while you
// were away (finished agents and what they changed since you looked, automations), and your pull requests, reviews
// and issues, each with its next step. Every part is a building block that lives elsewhere too (agent digests, work
// chips, "since you looked", the activity log, the next-step rule); this page only puts them together.

struct WorkdayHomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var log = ActivityLog.shared
    @StateObject private var digests = AgentDigests()
    @AppStorage(InboxPrefs.startMode) private var startMode = "tab"
    @State private var moreAway = false
    @State private var moreItems: Set<String> = []

    static let shown = 6

    var body: some View {
        let agents = model.agentSessions(onlyCurrentWorkspace: false)
        let g = Dictionary(grouping: agents, by: AgentsList.Group.of)
        let needs = ((g[.needsInput] ?? []) + (g[.error] ?? [])).sorted { $0.lastActivityAt > $1.lastActivityAt }
        let finished = (g[.finished] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        let mine = store.items.filter { $0.kind == .pr && $0.reason == .mine && $0.ended == nil }
        let reviews = store.items.filter { $0.kind == .pr && $0.reason == .review && $0.ended == nil }
        let issues = store.items.filter { $0.kind == .issue && $0.reason == .assigned && $0.ended == nil }
        let steps = mine.filter(PRNextStep.actionable).count
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(needs: needs.count, reviews: reviews.count, steps: steps)
                tiles(needs: needs, working: g[.working]?.count ?? 0, reviews: reviews.count, mine: mine.count, steps: steps)
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        needsYou(needs)
                        away(finished)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 22) {
                        if store.anyConnected {
                            itemSection("Your pull requests", mine, empty: "No open pull requests of yours.") { nextStep($0) }
                            itemSection("Reviews for you", reviews, empty: "No reviews waiting for you.") { reviewAction($0) }
                            itemSection("Your issues", issues, empty: "No issues assigned to you.") { workAction($0) }
                        } else {
                            notConnected
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .background(T.surface)
        .onAppear { digests.start() }
        .onDisappear { digests.stop() }
    }

    // MARK: Header

    static func dayTitle(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: d)
    }

    /// "2 agents need you · 1 review for you · 1 pull request needs a step" (or that all is quiet).
    static func statusLine(needs: Int, reviews: Int, steps: Int) -> String {
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(c) \(c == 1 ? one : many)" }
        let parts = [n(needs, "agent needs you", "agents need you"), n(reviews, "review for you", "reviews for you"),
                     n(steps, "pull request needs a step", "pull requests need a step")].compactMap { $0 }
        return parts.isEmpty ? "Nothing needs you right now." : parts.joined(separator: " · ")
    }

    private func header(needs: Int, reviews: Int, steps: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dayTitle()).font(.system(size: T.k * 22, weight: .semibold))
            Text(Self.statusLine(needs: needs, reviews: reviews, steps: steps)).font(.system(size: T.k * 13)).foregroundStyle(T.text2)
        }
    }

    private func tiles(needs: [Session], working: Int, reviews: Int, mine: Int, steps: Int) -> some View {
        let questions = needs.filter { if case .question? = digests.digests[$0.id]?.pending { return true }; return false }.count
        let perms = needs.filter { if case .permission? = digests.digests[$0.id]?.pending { return true }; return false }.count
        let parts = [questions > 0 ? "\(questions) question\(questions == 1 ? "" : "s")" : nil, perms > 0 ? "\(perms) permission\(perms == 1 ? "" : "s")" : nil]
        let needSub: String = needs.isEmpty ? "nobody waiting" : parts.compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "in their terminals"
        let finishedToday = log.today().filter { $0.kind == .finished }.count
        return HStack(spacing: 12) {
            KPITile(label: "Needs you", value: "\(needs.count)", sub: needSub, tone: needs.isEmpty ? T.text : T.amber)
            KPITile(label: "Working", value: "\(working)", sub: "\(finishedToday) finished today")
            KPITile(label: "Reviews for you", value: "\(reviews)", sub: reviews == 0 ? "all clear" : "waiting on you")
            KPITile(label: "Your pull requests", value: "\(mine)", sub: steps == 0 ? "nothing to do" : "\(steps) need\(steps == 1 ? "s" : "") a step")
            VStack(alignment: .leading, spacing: 8) {
                Text("USAGE").font(.system(size: T.k * 10, weight: .semibold)).tracking(0.5).foregroundStyle(T.text3)
                UsageStatus(compact: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .homeCard()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Needs you

    private func needsYou(_ list: [Session]) -> some View {
        // The next move: the latest one with a question or permission we can answer here.
        let next = list.first { digests.digests[$0.id]?.pending != nil } ?? list.first
        let rest = list.filter { $0.id != next?.id }
        return VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "Needs you", count: list.count, dot: list.isEmpty ? nil : T.amber)
            if let s = next {
                nextMove(s)
                if !rest.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(rest.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Hairline() }
                            agentRow(s, tone: T.amber, line: pendingLine(s))
                        }
                    }
                    .homeCard(padding: 0)
                }
            } else {
                Text("Nobody is waiting for you.").font(T.meta).foregroundStyle(T.text3).homeCard()
            }
        }
    }

    private func nextMove(_ s: Session) -> some View {
        let d = digests.digests[s.id] ?? AgentDigest()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("NEXT MOVE").font(.system(size: T.k * 10, weight: .semibold)).tracking(0.5).foregroundStyle(T.amber)
                Spacer()
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
            }
            agentTitle(s)
            if let p = d.pending {
                PendingAnswer(session: s, pending: p) { open(s) }
            } else {
                if !d.summary.isEmpty { Text(d.summary).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(2) }
                HStack(spacing: 6) {
                    Image(systemName: s.activity == .error ? "exclamationmark.triangle.fill" : "hand.raised.fill").font(T.icon(10))
                        .foregroundStyle(s.activity == .error ? T.red : T.amber)
                    Text(s.activity == .error ? "Stopped on an error" : "Answer in its terminal").font(T.meta).foregroundStyle(T.text2)
                    Spacer()
                    Button("Open") { open(s) }.buttonStyle(SmallButtonStyle(prominent: true))
                }
            }
        }
        .homeCard(attention: true, padding: 14)
    }

    private func pendingLine(_ s: Session) -> String {
        switch digests.digests[s.id]?.pending {
        case .permission(let p)?: return "Allow \(p)?"
        case .question(let q, _)?: return q
        case nil: return s.activity == .error ? "Stopped on an error" : "Answer in its terminal"
        }
    }

    // MARK: Rows

    private func agentTitle(_ s: Session) -> some View {
        HStack(spacing: 7) {
            AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
            Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text(model.project(s.projectId)?.name ?? "").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            WorkChips(session: s, limit: 1)
        }
    }

    private func agentRow(_ s: Session, tone: Color, line: String, actions: AnyView? = nil) -> some View {
        HoverRow {
            Circle().fill(tone).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                agentTitle(s)
                HStack(spacing: 8) {
                    if !line.isEmpty { Text(line).font(T.meta).foregroundStyle(T.text2).lineLimit(1) }
                    SinceLookedBadge(session: s)
                }
            }
        } actions: {
            HStack(spacing: 8) {
                if let actions { actions }
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
                LinkButton(title: s.isDormant ? "Resume ›" : "Open ›") { open(s) }
            }
        }
    }

    private func open(_ s: Session) {
        if s.isDormant { model.restart(s.id) }
        model.selectSession(s.id)
    }

    // MARK: While you were away

    private func away(_ finished: [Session]) -> some View {
        let events = log.away().filter { e in !(e.kind == .finished && finished.contains { $0.id == e.sessionId }) }
        let total = finished.count + events.count
        let cut = moreAway ? Int.max : Self.shown
        let agents = Array(finished.prefix(cut))
        let ev = Array(events.prefix(max(0, cut - agents.count)))
        return VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "While you were away", count: total)
            if total == 0 {
                Text(log.left == nil ? "What happens while you're in other apps shows up here." : "Nothing happened since you left.")
                    .font(T.meta).foregroundStyle(T.text3).homeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline() }
                        agentRow(s, tone: T.green, line: digests.digests[s.id]?.summary ?? "", actions: AnyView(
                            Button("Review") {
                                if model.selectedProjectId != s.projectId { model.selectedProjectId = s.projectId }
                                model.openDoc(.changes, workPath: model.workPath(of: s))
                                model.lookedAt(s.id)
                            }.buttonStyle(SmallButtonStyle())))
                    }
                    ForEach(Array(ev.enumerated()), id: \.element.id) { i, e in
                        if i > 0 || !agents.isEmpty { Hairline() }
                        eventRow(e)
                    }
                    MoreToggle(hidden: max(0, total - agents.count - ev.count), expanded: $moreAway)
                }
                .homeCard(padding: 0)
            }
        }
    }

    private func eventRow(_ e: WorkEvent) -> some View {
        let (icon, color): (String, Color) = {
            switch e.kind {
            case .finished: return ("checkmark.circle.fill", T.green)
            case .waiting: return ("hand.raised.fill", T.amber)
            case .error: return ("exclamationmark.triangle.fill", T.red)
            case .automation: return ("bolt.fill", T.accent)
            case .autopilot: return ("airplane", T.accent)
            case .task: return ("checklist", T.text2)
            }
        }()
        return HoverRow(pinned: true) {
            Image(systemName: icon).font(T.icon(10)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: T.k * 12)).lineLimit(1)
                if !e.detail.isEmpty { Text(e.detail).font(T.meta).foregroundStyle(T.text3).lineLimit(1) }
            }
        } actions: {
            Text(AgentRow.elapsed(since: Int(e.date.timeIntervalSince1970))).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
        }
        .onTapGesture {
            if let id = e.sessionId, model.session(id) != nil { model.selectSession(id) }
            else if let id = e.itemId { store.select(id); model.openInbox() }
        }
        .pointerCursor()
    }

    // MARK: Pull requests and issues

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "Pull requests and issues")
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect GitHub, Bitbucket or Jira to see your pull requests, reviews and issues here.").font(T.meta).foregroundStyle(T.text2)
                Button("Open Inbox Settings") { SettingsWindow.show(section: .inbox) }.buttonStyle(SmallButtonStyle())
            }
            .homeCard()
        }
    }

    private func itemSection<A: View>(_ title: String, _ list: [InboxItem], empty: String, @ViewBuilder action: @escaping (InboxItem) -> A) -> some View {
        let open = moreItems.contains(title)
        let shown = open ? list : Array(list.prefix(Self.shown))
        return VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: title, count: list.count)
            VStack(spacing: 0) {
                if list.isEmpty { Text(empty).font(T.meta).foregroundStyle(T.text3).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Hairline() }
                    itemRow(item) { action(item) }
                }
                MoreToggle(hidden: list.count - shown.count, expanded: Binding(get: { open }, set: { v in
                    if v { moreItems.insert(title) } else { moreItems.remove(title) }
                }))
            }
            .homeCard(padding: 0)
        }
    }

    private func itemRow<A: View>(_ item: InboxItem, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            WorkChip(item: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: T.k * 12, weight: .medium)).lineLimit(1)
                Text("\(item.place) · \(item.status) · \(AgentRow.elapsed(since: Int(item.updated.timeIntervalSince1970)))")
                    .font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            action()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func reviewAction(_ item: InboxItem) -> some View {
        if let s = store.linkedSession(item) {
            LinkButton(title: "Open agent ›") { model.selectSession(s.id) }
        } else {
            Button("Review") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .review, model: model) }
                .buttonStyle(SmallButtonStyle())
        }
    }

    @ViewBuilder private func workAction(_ item: InboxItem) -> some View {
        if let s = store.linkedSession(item) {
            LinkButton(title: "Open agent ›") { model.selectSession(s.id) }
        } else {
            Button("Work on it") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .work, model: model) }
                .buttonStyle(SmallButtonStyle())
        }
    }

    @ViewBuilder private func nextStep(_ item: InboxItem) -> some View {
        let step = PRNextStep.of(item)
        let busy = InboxActions.shared.busy.contains(item.id)
        if let s = store.linkedSession(item), step != .merge, step != .markReady {
            LinkButton(title: "Open agent ›") { model.selectSession(s.id) }
        } else {
            switch step {
            case .merge:
                if let a = InboxPRAction.available(item).first(where: \.isMerge) {
                    Button("Merge") { InboxActions.shared.perform(a, on: item) }.buttonStyle(SmallButtonStyle(prominent: true)).disabled(busy)
                }
            case .markReady:
                if InboxPRAction.available(item).contains(.ready) {
                    Button("Mark ready") { InboxActions.shared.perform(.ready, on: item) }.buttonStyle(SmallButtonStyle()).disabled(busy)
                } else {
                    Text("Draft").font(T.meta).foregroundStyle(T.text3)
                }
            case .fixChecks:
                Button("Fix with agent") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .fix, model: model) }
                    .buttonStyle(SmallButtonStyle(prominent: true))
            case .addressChanges:
                Button("Address changes") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .work, model: model) }
                    .buttonStyle(SmallButtonStyle())
            case .waitChecks, .waitReview, .none:
                Text(step.title).font(T.meta).foregroundStyle(T.text3)
            }
        }
    }
}
