import SwiftUI

// Home: its sections (Core/Home.swift) drawn in their bands. The row on top spans the page; the main and side
// columns sit under it. A big section (the board, the aquarium) alone fills the page, else it is a tall strip on top.
// Every section is one of today's parts, so a preset looks like the Home it replaces.

/// The agents Home shows, grouped once per draw for every section.
struct HomeAgents {
    let all: [Session]
    let waiting: [Session]
    let working: [Session]
    let done: [Session]
    /// Not waiting, newest first.
    let recent: [Session]

    init(_ list: [Session]) {
        all = list
        let g = Dictionary(grouping: list, by: RailGroup.of)
        waiting = (g[.waiting] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        working = (g[.working] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        done = (g[.done] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        recent = list.filter { RailGroup.of($0) != .waiting }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

struct HomePage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = InboxStore.shared
    let layout: HomeLayout
    /// Customize: each section with its handle, name and eye; "+ Add section" under the columns.
    var editing: HomeEditing? = nil
    /// The agents of the project the agent rail shows (the Agents layout's Home, beside the rail); else the workspace's.
    var railFilter = true

    /// The two columns' width, measured (0 until the first layout pass).
    @State private var columnsWidth: CGFloat = 0
    /// The split while you drag the line between the columns (Customize).
    @State private var dragging: Double?
    @State private var dragStart: Double = 0

    static let columnGap: CGFloat = 18

    /// The main and side columns' widths for the columns' width `w` and the side's share `split`.
    static func columnWidths(_ w: CGFloat, split: Double) -> (main: CGFloat, side: CGFloat) {
        let inner = max(0, w - columnGap)
        let side = (inner * split).rounded()
        return (inner - side, side)
    }

    var body: some View {
        let agents = HomeAgents(model.railSessions(filtered: railFilter))
        Group {
            if let big = layout.filling, editing == nil {
                filled(big, agents)
            } else {
                scrolled(agents)
            }
        }
    }

    /// A big section filling the page (with what is above it).
    @ViewBuilder private func filled(_ big: HomeSectionID, _ agents: HomeAgents) -> some View {
        let above = layout.top.dropLast()
        if above.isEmpty, big == .aquarium {
            HomeSectionView(id: big, agents: agents, filling: true)   // edge to edge, as the aquarium was
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(above), id: \.self) { s in section(s, agents) }
                HomeSectionView(id: big, agents: agents, filling: true).frame(maxHeight: .infinity)
            }
            .padding(16)
        }
    }

    private func scrolled(_ agents: HomeAgents) -> some View {
        let empty = layout.isEmpty && editing == nil
        let both = editing != nil || (!layout.main.isEmpty && !layout.side.isEmpty)
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let e = editing { e.toolbar }
                band(.top, agents)
                if both {
                    let w = Self.columnWidths(columnsWidth, split: dragging ?? layout.split)
                    HStack(alignment: .top, spacing: 0) {
                        band(.main, agents).frame(width: columnsWidth > 0 ? w.main : nil, alignment: .topLeading)
                            .frame(maxWidth: columnsWidth > 0 ? nil : .infinity, alignment: .topLeading)
                        splitLine
                        band(.side, agents).frame(width: columnsWidth > 0 ? w.side : nil, alignment: .topLeading)
                            .frame(maxWidth: columnsWidth > 0 ? nil : .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { columnsWidth = g.size.width }
                            .onChange(of: g.size.width) { _, v in columnsWidth = v }
                    })
                } else if !layout.main.isEmpty {
                    band(.main, agents).frame(maxWidth: .infinity, alignment: .topLeading)
                } else if !layout.side.isEmpty {
                    band(.side, agents).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if empty {
                    Text("This Home has no sections. Home ⌄ → Customize this Home… adds them.").font(T.meta).foregroundStyle(T.text3)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 40)
            .frame(maxWidth: layout.width.points.map { CGFloat($0) } ?? .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The gap between the columns; while customizing, a line to drag (the split is saved when you let go).
    @ViewBuilder private var splitLine: some View {
        if editing != nil {
            Capsule().fill(dragging != nil ? T.accent : T.border).frame(width: 3, height: 44)
                .frame(width: Self.columnGap, height: 120)
                .contentShape(Rectangle())
                .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragging == nil { dragStart = layout.split }
                        let inner = max(1, columnsWidth - Self.columnGap)
                        let r = HomeLayout.splitRange
                        dragging = min(max(dragStart - Double(g.translation.width / inner), r.lowerBound), r.upperBound)
                    }
                    .onEnded { _ in
                        if let f = dragging { model.setHomeSplit(f) }
                        dragging = nil
                    })
                .help("Drag to change the columns' widths")
        } else {
            Color.clear.frame(width: Self.columnGap, height: 1)
        }
    }

    @ViewBuilder private func band(_ b: HomeBand, _ agents: HomeAgents) -> some View {
        let list = layout[b]
        VStack(alignment: .leading, spacing: b == .top ? 26 : 18) {
            if let e = editing { e.bandLabel(b) }
            ForEach(Array(list.enumerated()), id: \.element) { i, s in
                if let e = editing { e.frame(s, band: b, index: i) { section(s, agents) } } else { section(s, agents) }
            }
            if let e = editing { e.addButton(b) }
        }
    }

    @ViewBuilder private func section(_ s: HomeSectionID, _ agents: HomeAgents) -> some View {
        if s.isBig {
            HomeSectionView(id: s, agents: agents, filling: false)
                .frame(height: s.stripHeight)
        } else {
            HomeSectionView(id: s, agents: agents, firstInbox: firstInbox == s)
        }
    }

    /// The first of the pull request / review / issue sections (it says how to connect while none is connected).
    private var firstInbox: HomeSectionID? { layout.all.first { [.pullRequests, .reviews, .issues].contains($0) } }
}

/// What Customize puts around Home's sections (HomeCustomize.swift).
struct HomeEditing {
    var toolbar: AnyView
    var bandLabel: (HomeBand) -> AnyView
    var frame: (HomeSectionID, HomeBand, Int, AnyView) -> AnyView
    var addButton: (HomeBand) -> AnyView

    func frame<V: View>(_ s: HomeSectionID, band: HomeBand, index: Int, @ViewBuilder content: @escaping () -> V) -> AnyView {
        frame(s, band, index, AnyView(content()))
    }
}

/// One section.
struct HomeSectionView: View {
    let id: HomeSectionID
    let agents: HomeAgents
    /// A big section as tall as the page (else a strip).
    var filling = false
    var firstInbox = false

    var body: some View {
        switch id {
        case .greeting: HomeGreeting(agents: agents)
        case .today: HomeToday(agents: agents)
        case .composer: HomeComposer()
        case .stats: HomeStats(agents: agents)
        case .waiting: HomeWaiting(list: agents.waiting)
        case .working: HomeWorking(list: agents.working)
        case .away: HomeAway(done: agents.done)
        case .recent: HomeRecent(list: agents.recent)
        case .pullRequests, .reviews, .issues: HomeInboxSection(id: id, first: firstInbox)
        case .usage:
            VStack(alignment: .leading, spacing: 10) {
                HomeSection(title: "Usage")
                UsageBars().homeCard()
            }
        case .board: AgentBoard(agents: agents.all)
        case .aquarium:
            if filling {
                AquariumHomeView(home: true)
            } else {
                AquariumHomeView(home: true)
                    .clipShape(RoundedRectangle(cornerRadius: R.xl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.border))
            }
        }
    }
}

// MARK: Sections

/// "Good evening, Ada." and who is waiting.
struct HomeGreeting: View {
    let agents: HomeAgents

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
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.greeting()).font(.system(size: T.k * 30, weight: .regular, design: .serif))
            Text(Self.status(waiting: agents.waiting.count, working: agents.working.count, done: agents.done.count))
                .font(.system(size: T.k * 13)).foregroundStyle(T.text2)
        }
    }
}

/// "Sunday, November 8" and what needs you today.
struct HomeToday: View {
    @ObservedObject private var store = InboxStore.shared
    let agents: HomeAgents

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

    var body: some View {
        let w = HomeWork(store)
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dayTitle()).font(.system(size: T.k * 22, weight: .semibold))
            Text(Self.statusLine(needs: agents.waiting.count, reviews: w.reviews.count, steps: w.steps))
                .font(.system(size: T.k * 13)).foregroundStyle(T.text2)
        }
    }
}

/// Your pull requests, reviews and issues from the Inbox.
struct HomeWork {
    let mine: [InboxItem]
    let reviews: [InboxItem]
    let issues: [InboxItem]
    var steps: Int { mine.filter(PRNextStep.actionable).count }
    init(_ store: InboxStore) {
        mine = store.items.filter { $0.kind == .pr && $0.reason == .mine && $0.ended == nil }
        reviews = store.items.filter { $0.kind == .pr && $0.reason == .review && $0.ended == nil }
        issues = store.items.filter { $0.kind == .issue && $0.reason == .assigned && $0.ended == nil }
    }
}

/// Needs you · Working · Reviews for you · Your pull requests · Usage.
struct HomeStats: View {
    @EnvironmentObject var digests: AgentDigests
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var log = ActivityLog.shared
    let agents: HomeAgents

    var body: some View {
        let needs = agents.waiting
        let w = HomeWork(store)
        let questions = needs.filter { if case .question? = digests.digests[$0.id]?.pending { return true }; return false }.count
        let perms = needs.filter { if case .permission? = digests.digests[$0.id]?.pending { return true }; return false }.count
        let parts = [questions > 0 ? "\(questions) question\(questions == 1 ? "" : "s")" : nil, perms > 0 ? "\(perms) permission\(perms == 1 ? "" : "s")" : nil]
        let needSub: String = needs.isEmpty ? "nobody waiting" : parts.compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "in their terminals"
        let finishedToday = log.today().filter { $0.kind == .finished }.count
        HStack(spacing: 12) {
            KPITile(label: "Needs you", value: "\(needs.count)", sub: needSub, tone: needs.isEmpty ? T.text : T.amber)
            KPITile(label: "Working", value: "\(agents.working.count)", sub: "\(finishedToday) finished today")
            KPITile(label: "Reviews for you", value: "\(w.reviews.count)", sub: w.reviews.isEmpty ? "all clear" : "waiting on you")
            KPITile(label: "Your pull requests", value: "\(w.mine.count)", sub: w.steps == 0 ? "nothing to do" : "\(w.steps) need\(w.steps == 1 ? "s" : "") a step")
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
}

/// The agents waiting for you in one card: each a row; one opens with its question and the answers (the first to
/// start with), answering opens the next.
struct HomeWaiting: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests
    let list: [Session]
    /// The row you opened (nil: the first).
    @State private var openId: String?
    /// You closed the open row: none is open until you open one.
    @State private var allClosed = false

    /// The open row: the one you opened while it waits, else the first (none once you closed it).
    static func open(_ ids: [String], picked: String?, allClosed: Bool) -> String? {
        if allClosed { return nil }
        if let p = picked, ids.contains(p) { return p }
        return ids.first
    }
    /// After the list changed: the row you had open left it (answered), so the one now in its place opens.
    static func next(after picked: String?, old: [String], new: [String]) -> String? {
        guard let p = picked, !new.contains(p), let i = old.firstIndex(of: p), !new.isEmpty else { return picked }
        return new[min(i, new.count - 1)]
    }

    var body: some View {
        let ids = list.map(\.id)
        let current = Self.open(ids, picked: openId, allClosed: allClosed)
        VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "Waiting for you", count: list.count, dot: list.isEmpty ? nil : T.amber,
                        trailing: AnyView(Text("answer here or open").font(T.meta).foregroundStyle(T.text3)))
            if list.isEmpty {
                Text("Nobody is waiting for you.").font(T.meta).foregroundStyle(T.text3).homeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline() }
                        if s.id == current { openRow(s) } else { closedRow(s) }
                    }
                }
                .homeCard(padding: 0)
                .clipShape(RoundedRectangle(cornerRadius: R.xl, style: .continuous))
            }
        }
        .onChange(of: ids) { old, new in
            let n = Self.next(after: openId, old: old, new: new)
            if n != openId { openId = n }
        }
    }

    private func toggle(_ s: Session, isOpen: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if isOpen { allClosed = true; openId = nil } else { allClosed = false; openId = s.id }
        }
    }

    private func line(_ s: Session) -> String {
        switch digests.digests[s.id]?.pending {
        case .permission(let p)?: return "Allow \(p)?"
        case .question(let q, _)?: return q
        case nil: return s.activity == .error ? "Stopped on an error" : "Answer in its terminal"
        }
    }

    private func title(_ s: Session, chevron: String) -> some View {
        HStack(spacing: 7) {
            AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
            Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
            Text(model.project(s.projectId)?.name ?? "").font(T.meta).foregroundStyle(T.text3).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit().fixedSize()
            Image(systemName: chevron).font(T.icon(8, .semibold)).foregroundStyle(T.text3).fixedSize()
        }
    }

    private func closedRow(_ s: Session) -> some View {
        HStack(spacing: 8) {
            Circle().fill(s.activity == .error ? T.red : T.amber).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                title(s, chevron: "chevron.down")
                Text(line(s)).font(T.meta).foregroundStyle(T.text2).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle(s, isOpen: false) }
        .pointerCursor()
    }

    private func openRow(_ s: Session) -> some View {
        let d = digests.digests[s.id] ?? AgentDigest()
        return VStack(alignment: .leading, spacing: 9) {
            title(s, chevron: "chevron.up")
                .contentShape(Rectangle())
                .onTapGesture { toggle(s, isOpen: true) }
                .pointerCursor()
            if let p = d.pending {
                PendingAnswer(session: s, pending: p) { open(s) }
            } else {
                if !d.summary.isEmpty { Text(d.summary).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(2) }
                HStack(spacing: 6) {
                    Image(systemName: s.activity == .error ? "exclamationmark.triangle.fill" : "hand.raised.fill").font(T.icon(10))
                        .foregroundStyle(s.activity == .error ? T.red : T.amber)
                    Text(s.activity == .error ? "Stopped on an error" : "Answer in its terminal").font(T.meta).foregroundStyle(T.text2)
                    Spacer()
                    Button("Open") { open(s) }.buttonStyle(SmallButtonStyle())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(T.amber).frame(width: 3) }
    }

    private func open(_ s: Session) {
        if s.isDormant { model.restart(s.id) }
        model.selectSession(s.id)
    }
}

/// A row for an agent: its dot, name, project, one line and how long ago (Working, While you were away).
struct HomeAgentRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let tone: Color
    let line: String
    var actions: AnyView? = nil

    var body: some View {
        let s = session
        HoverRow {
            Circle().fill(tone).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
                    Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    Text(model.project(s.projectId)?.name ?? "").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
                    WorkChips(session: s, limit: 1)
                }
                HStack(spacing: 8) {
                    if !line.isEmpty { Text(line).font(T.meta).foregroundStyle(T.text2).lineLimit(1) }
                    SinceLookedBadge(session: s)
                }
            }
        } actions: {
            HStack(spacing: 8) {
                if let actions { actions }
                Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
                LinkButton(title: s.isDormant ? "Resume ›" : "Open ›") {
                    if s.isDormant { model.restart(s.id) }
                    model.selectSession(s.id)
                }
            }
        }
    }
}

/// The agents at work, with their steps.
struct HomeWorking: View {
    @EnvironmentObject var digests: AgentDigests
    let list: [Session]
    @State private var more = false
    var body: some View {
        let shown = more ? list : Array(list.prefix(HomeAway.shown))
        VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "Working", count: list.count, dot: list.isEmpty ? nil : T.accent)
            if list.isEmpty {
                Text("No agent is working.").font(T.meta).foregroundStyle(T.text3).homeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline() }
                        let d = digests.digests[s.id]
                        HomeAgentRow(session: s, tone: T.accent, line: [d?.steps ?? "", d?.summary ?? ""].first { !$0.isEmpty } ?? "")
                    }
                    MoreToggle(hidden: list.count - shown.count, expanded: $more)
                }
                .homeCard(padding: 0)
            }
        }
    }
}

/// While you were away: finished agents and what happened (automations, tasks).
struct HomeAway: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var digests: AgentDigests
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var store = InboxStore.shared
    let done: [Session]
    @State private var more = false

    static let shown = 6

    var body: some View {
        let finished = done
        let events = log.away().filter { e in !(e.kind == .finished && finished.contains { $0.id == e.sessionId }) }
        let total = finished.count + events.count
        let cut = more ? Int.max : Self.shown
        let agents = Array(finished.prefix(cut))
        let ev = Array(events.prefix(max(0, cut - agents.count)))
        VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "While you were away", count: total)
            if total == 0 {
                Text(log.left == nil ? "What happens while you're in other apps shows up here." : "Nothing happened since you left.")
                    .font(T.meta).foregroundStyle(T.text3).homeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline() }
                        HomeAgentRow(session: s, tone: T.green, line: digests.digests[s.id]?.summary ?? "", actions: AnyView(
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
                    MoreToggle(hidden: max(0, total - agents.count - ev.count), expanded: $more)
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
}

/// Your latest sessions.
struct HomeRecent: View {
    @EnvironmentObject var model: AppModel
    let list: [Session]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: "Recent", count: list.count)
            VStack(spacing: 0) {
                if list.isEmpty { Text("Nothing yet.").font(T.meta).foregroundStyle(T.text3).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                ForEach(Array(list.prefix(6).enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Hairline() }
                    HoverRow(pinned: true) {
                        AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 14)
                        Text(s.displayTitle).font(.system(size: T.k * 12)).lineLimit(1)
                    } actions: {
                        Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
                    }
                    .onTapGesture { if s.isDormant { model.restart(s.id) }; model.selectSession(s.id) }
                    .pointerCursor()
                }
            }
            .homeCard(padding: 0)
        }
    }
}

/// Your pull requests, reviews for you, or your issues, each with its next step.
struct HomeInboxSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = InboxStore.shared
    let id: HomeSectionID
    /// The first such section on Home: while nothing is connected it says how to connect (the others stay out).
    var first = true
    @AppStorage(InboxPrefs.startMode) private var startMode = "tab"
    @State private var more = false

    var body: some View {
        if !store.anyConnected {
            if first { notConnected }
        } else {
            let w = HomeWork(store)
            switch id {
            case .pullRequests: list("Your pull requests", w.mine, empty: "No open pull requests of yours.") { nextStep($0) }
            case .reviews: list("Reviews for you", w.reviews, empty: "No reviews waiting for you.") { reviewAction($0) }
            default: list("Your issues", w.issues, empty: "No issues assigned to you.") { workAction($0) }
            }
        }
    }

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

    private func list<A: View>(_ title: String, _ list: [InboxItem], empty: String, @ViewBuilder action: @escaping (InboxItem) -> A) -> some View {
        let shown = more ? list : Array(list.prefix(HomeAway.shown))
        return VStack(alignment: .leading, spacing: 10) {
            HomeSection(title: title, count: list.count)
            VStack(spacing: 0) {
                if list.isEmpty { Text(empty).font(T.meta).foregroundStyle(T.text3).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Hairline() }
                    row(item) { action(item) }
                }
                MoreToggle(hidden: list.count - shown.count, expanded: $more)
            }
            .homeCard(padding: 0)
        }
    }

    private func row<A: View>(_ item: InboxItem, @ViewBuilder action: () -> A) -> some View {
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

    private var mode: String? { startMode == "ask" ? nil : startMode }

    @ViewBuilder private func reviewAction(_ item: InboxItem) -> some View {
        if let s = store.linkedSession(item) {
            LinkButton(title: "Open agent ›") { model.selectSession(s.id) }
        } else {
            Button("Review") { InboxStart.begin(item, mode: mode, task: .review, model: model) }.buttonStyle(SmallButtonStyle())
        }
    }

    @ViewBuilder private func workAction(_ item: InboxItem) -> some View {
        if let s = store.linkedSession(item) {
            LinkButton(title: "Open agent ›") { model.selectSession(s.id) }
        } else {
            Button("Work on it") { InboxStart.begin(item, mode: mode, task: .work, model: model) }.buttonStyle(SmallButtonStyle())
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
                Button("Fix with agent") { InboxStart.begin(item, mode: mode, task: .fix, model: model) }.buttonStyle(SmallButtonStyle(prominent: true))
            case .addressChanges:
                Button("Address changes") { InboxStart.begin(item, mode: mode, task: .work, model: model) }.buttonStyle(SmallButtonStyle())
            case .waitChecks, .waitReview, .none:
                Text(step.title).font(T.meta).foregroundStyle(T.text3)
            }
        }
    }
}
