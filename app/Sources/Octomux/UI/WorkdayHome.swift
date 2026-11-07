import SwiftUI

// Workday's home: your day on one page. Who needs you (answered in place), what happened while you were away
// (finished agents and what they changed since you looked, automations), and your pull requests, reviews and
// issues, each with its next step. Every part is a building block that lives elsewhere too (agent digests, work
// chips, "since you looked", the activity log, the next-step rule); this page only puts them together.

struct WorkdayHomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var log = ActivityLog.shared
    @StateObject private var digests = AgentDigests()
    @AppStorage(InboxPrefs.startMode) private var startMode = "tab"

    var body: some View {
        let agents = model.agentSessions(onlyCurrentWorkspace: false)
        let g = Dictionary(grouping: agents, by: AgentsList.Group.of)
        let needs = ((g[.needsInput] ?? []) + (g[.error] ?? [])).sorted { $0.lastActivityAt > $1.lastActivityAt }
        let finished = (g[.finished] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        let mine = store.items.filter { $0.kind == .pr && $0.reason == .mine && $0.ended == nil }
        let reviews = store.items.filter { $0.kind == .pr && $0.reason == .review && $0.ended == nil }
        let issues = store.items.filter { $0.kind == .issue && $0.reason == .assigned && $0.ended == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(needs: needs.count, working: g[.working]?.count ?? 0, reviews: reviews.count,
                       steps: mine.filter(PRNextStep.actionable).count)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        needsYou(needs)
                        away(finished)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 18) {
                        if store.anyConnected {
                            prs(mine)
                            reviewsFor(reviews)
                            issueList(issues)
                        } else {
                            notConnected
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(22)
            .frame(maxWidth: 1240, alignment: .topLeading)
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

    private func header(needs: Int, working: Int, reviews: Int, steps: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dayTitle()).font(.system(size: T.k * 22, weight: .semibold))
                Text(Self.statusLine(needs: needs, reviews: reviews, steps: steps))
                    .font(.system(size: T.k * 13)).foregroundStyle(needs > 0 ? T.amber : T.text2)
            }
            Spacer()
            tile("Working", "\(working)", T.accent)
            tile("Finished today", "\(log.today().filter { $0.kind == .finished }.count)", T.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("USAGE").font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(T.text3)
                UsageStatus(compact: true)
            }
            .padding(.horizontal, 12).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: R.lg, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: R.lg, style: .continuous).stroke(T.border))
            KeepAwakeControl()
                .padding(.horizontal, 10).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: R.lg, style: .continuous).fill(T.raised))
                .overlay(RoundedRectangle(cornerRadius: R.lg, style: .continuous).stroke(T.border))
        }
    }

    private func tile(_ label: String, _ value: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(T.text3)
            Text(value).font(.system(size: T.k * 20, weight: .semibold)).foregroundStyle(c).monospacedDigit()
        }
        .padding(.horizontal, 12).frame(minWidth: 86, alignment: .leading).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: R.lg, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.lg, style: .continuous).stroke(T.border))
    }

    private func section(_ title: String, _ n: Int, _ c: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(T.icon(10)).foregroundStyle(c)
            Text(title.uppercased()).font(.system(size: T.k * 11, weight: .semibold)).tracking(0.6).foregroundStyle(c)
            if n > 0 { Text("\(n)").font(.system(size: T.k * 11, weight: .semibold)).foregroundStyle(T.text3) }
        }
    }

    private func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.border))
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(T.meta).foregroundStyle(T.text3).padding(12)
    }

    // MARK: Needs you

    private func needsYou(_ list: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Needs you", list.count, T.amber, icon: "hand.raised.fill")
            if list.isEmpty {
                box { quiet("Nobody is waiting for you.") }
            } else {
                ForEach(list) { s in needsCard(s) }
            }
        }
    }

    private func needsCard(_ s: Session) -> some View {
        let d = digests.digests[s.id] ?? AgentDigest()
        return VStack(alignment: .leading, spacing: 7) {
            agentLine(s)
            switch d.pending {
            case .permission(let what)?:
                Text("Allow \(what)?").font(.system(size: T.k * 12, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Button("Allow") { AgentDigests.answer(s.id, option: 0) }.buttonStyle(PrimaryButtonStyle())
                    Button("Deny") { AgentDigests.deny(s.id) }.buttonStyle(SecondaryButtonStyle())
                    Spacer(); openLink(s)
                }
            case .question(let q, let opts)?:
                Text(q).font(.system(size: T.k * 12, weight: .semibold)).lineLimit(3)
                FlowButtons(options: Array(opts.prefix(4))) { AgentDigests.answer(s.id, option: $0) }
                HStack { Spacer(); openLink(s) }
            case nil:
                HStack {
                    Text(s.activity == .error ? "Stopped on an error" : "Waiting for your answer in its terminal")
                        .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                    Spacer(); openLink(s)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.amber.opacity(0.45)))
    }

    private func agentLine(_ s: Session) -> some View {
        HStack(spacing: 7) {
            AgentIcon(icon: iconName(for: s, model: model), size: 13).frame(width: 16)
            Text(s.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
            Text(model.project(s.projectId)?.name ?? "").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            WorkChips(session: s)
            Spacer(minLength: 4)
            Text(AgentRow.elapsed(since: s.lastActivityAt)).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
        }
    }

    private func openLink(_ s: Session) -> some View {
        Button { if s.isDormant { model.restart(s.id) }; model.selectSession(s.id) } label: {
            Text(s.isDormant ? "Resume ›" : "Open ›").font(T.meta).foregroundStyle(T.accent)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    // MARK: While you were away

    private func away(_ finished: [Session]) -> some View {
        let events = log.away()
        return VStack(alignment: .leading, spacing: 8) {
            section("While you were away", finished.count + events.count, T.accent, icon: "moon.zzz")
            if !finished.isEmpty {
                ForEach(finished) { s in finishedCard(s) }
            }
            box {
                if events.isEmpty {
                    quiet(log.left == nil ? "What happens while you're in other apps shows up here." : "Nothing happened since you left.")
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Hairline() }
                        eventRow(e)
                    }
                }
            }
        }
    }

    private func finishedCard(_ s: Session) -> some View {
        let d = digests.digests[s.id] ?? AgentDigest()
        return VStack(alignment: .leading, spacing: 6) {
            agentLine(s)
            if !d.summary.isEmpty { Text(d.summary).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(2) }
            HStack(spacing: 10) {
                SinceLookedBadge(session: s)
                if !d.files.isEmpty {
                    Text(d.files.prefix(3).joined(separator: ", ") + (d.files.count > 3 ? " +\(d.files.count - 3)" : ""))
                        .font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer()
                Button("Review Changes") {
                    if model.selectedProjectId != s.projectId { model.selectedProjectId = s.projectId }
                    model.openDoc(.changes, workPath: model.workPath(of: s))
                    model.lookedAt(s.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                openLink(s)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.border))
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
        return HStack(spacing: 8) {
            Image(systemName: icon).font(T.icon(11)).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: T.k * 13)).lineLimit(1)
                if !e.detail.isEmpty { Text(e.detail).font(T.meta).foregroundStyle(T.text3).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Text(AgentRow.elapsed(since: Int(e.date.timeIntervalSince1970))).font(T.meta).foregroundStyle(T.text3).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = e.sessionId, model.session(id) != nil { model.selectSession(id) }
            else if let id = e.itemId { store.select(id); model.openInbox() }
        }
        .pointerCursor()
    }

    // MARK: Pull requests and issues

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Pull requests and issues", 0, T.text3, icon: "tray")
            box {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect GitHub, Bitbucket or Jira to see your pull requests, reviews and issues here.").font(T.meta).foregroundStyle(T.text2)
                    Button("Open Inbox Settings") { SettingsWindow.show(section: .inbox) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(12)
            }
        }
    }

    private func prs(_ list: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Your pull requests", list.count, T.text2, icon: "arrow.triangle.pull")
            box {
                if list.isEmpty { quiet("No open pull requests of yours.") }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Hairline() }
                    itemRow(item) { nextStep(item) }
                }
            }
        }
    }

    private func reviewsFor(_ list: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Reviews for you", list.count, T.text2, icon: "eye")
            box {
                if list.isEmpty { quiet("No reviews waiting for you.") }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Hairline() }
                    itemRow(item) {
                        if let s = store.linkedSession(item) {
                            Button("Open agent") { model.selectSession(s.id) }.buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button("Review") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .review, model: model) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func issueList(_ list: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Your issues", list.count, T.text2, icon: "ticket")
            box {
                if list.isEmpty { quiet("No issues assigned to you.") }
                ForEach(Array(list.prefix(12).enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Hairline() }
                    itemRow(item) {
                        if let s = store.linkedSession(item) {
                            Button("Open agent") { model.selectSession(s.id) }.buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button("Work on it") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .work, model: model) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func itemRow<A: View>(_ item: InboxItem, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 8) {
            WorkChip(item: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: T.k * 13)).lineLimit(1)
                Text("\(item.place) · \(item.status)").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            action()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func nextStep(_ item: InboxItem) -> some View {
        let step = PRNextStep.of(item)
        let busy = InboxActions.shared.busy.contains(item.id)
        if let s = store.linkedSession(item), step != .merge, step != .markReady {
            Button("Open agent") { model.selectSession(s.id) }.buttonStyle(SecondaryButtonStyle())
        } else {
            switch step {
            case .merge:
                if let a = InboxPRAction.available(item).first(where: \.isMerge) {
                    Button("Merge") { InboxActions.shared.perform(a, on: item) }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                }
            case .markReady:
                if InboxPRAction.available(item).contains(.ready) {
                    Button("Mark ready") { InboxActions.shared.perform(.ready, on: item) }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
                } else {
                    Text("Draft").font(T.meta).foregroundStyle(T.text3)
                }
            case .fixChecks:
                Button("Fix with agent") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .fix, model: model) }
                    .buttonStyle(PrimaryButtonStyle())
            case .addressChanges:
                Button("Address changes") { InboxStart.begin(item, mode: startMode == "ask" ? nil : startMode, task: .work, model: model) }
                    .buttonStyle(SecondaryButtonStyle())
            case .waitChecks, .waitReview, .none:
                Text(step.title).font(T.meta).foregroundStyle(T.text3)
            }
        }
    }
}
