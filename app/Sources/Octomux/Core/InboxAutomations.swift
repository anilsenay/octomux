import AppKit
import Foundation

/// A rule that starts an agent on its own when a matching item comes into the Inbox. Off until turned on.
struct InboxRule: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable {
        case review     // a read-only session in the project that reviews it
        case reviewWorktree // the pull request checked out in a worktree of its own, reviewed there by a read-only agent
        case work       // a new worktree with an agent working on it
        var title: String {
            switch self {
            case .review: return "Review it (read-only)"
            case .reviewWorktree: return "Review it in a worktree (read-only), and its new commits"
            case .work: return "Work on it in a new worktree"
            }
        }
    }
    var id = UUID().uuidString
    var name: String
    var enabled = false
    var source: String? = nil       // github | jira | nil: any
    var kind: String? = nil         // pr | issue | nil: any
    var reason: String? = nil       // an InboxItem.Reason raw value, nil: any
    var place: String = ""          // part of the repo / Jira project name, "" any
    var action: Action = .review
    var profileId: String? = nil

    func matches(_ i: InboxItem) -> Bool {
        (source == nil || source == i.source.rawValue)
            && (kind == nil || kind == i.kind.rawValue)
            && (reason == nil || reason == i.reason.rawValue)
            && (place.trimmingCharacters(in: .whitespaces).isEmpty || i.place.localizedCaseInsensitiveContains(place.trimmingCharacters(in: .whitespaces)))
            && i.ended == nil
            && (action == .work || i.kind == .pr)          // reviewing needs a pull request
    }

    /// "New review requests in octo/storefront → review it (read-only)".
    var summary: String {
        let what = [kind == "pr" ? "pull requests" : kind == "issue" ? "issues" : "items",
                    source.map { "from " + (InboxSource(rawValue: $0)?.name ?? $0) }].compactMap { $0 }.joined(separator: " ")
        let why = reason.flatMap { InboxItem.Reason(rawValue: $0)?.rawValue.lowercased() }.map { " (\($0))" } ?? ""
        let whereText = place.isEmpty ? "" : " in “\(place)”"
        return "New \(what)\(why)\(whereText) → \(action.title.lowercased())"
    }
}

/// Runs the rules on items that just came in: each item at most once per rule, a few per refresh.
final class InboxAutomations: ObservableObject {
    static let shared = InboxAutomations()
    static let maxPerRefresh = 3

    @Published private(set) var rules: [InboxRule]
    private var runs: [String]
    let defaults: UserDefaults

    /// Starts the agent for a rule (tests and the fixture swap it); returns why it couldn't, or nil.
    var start: (InboxItem, InboxRule) -> String? = InboxAutomations.startAgent
    var notify: (String, String) -> Void = { t, b in
        Notifier.shared.deliver(AppNotification(sessionId: "", projectId: "", kind: "inbox", title: t, body: b))
    }
    var confirm: (_ title: String, _ message: String, _ button: String, _ done: @escaping (Bool) -> Void) -> Void = InboxConfirm.ask

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = (defaults.data(forKey: InboxPrefs.rules)).flatMap { try? JSONDecoder().decode([InboxRule].self, from: $0) } ?? []
        runs = defaults.stringArray(forKey: InboxPrefs.ruleRuns) ?? []
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(rules), forKey: InboxPrefs.rules)
    }

    func upsert(_ r: InboxRule) {
        var r = r
        if let i = rules.firstIndex(where: { $0.id == r.id }) { r.enabled = rules[i].enabled; rules[i] = r } else { r.enabled = false; rules.append(r) }
        save()
    }
    func remove(_ id: String) { rules.removeAll { $0.id == id }; save() }

    /// Turning a rule on asks first: from then on it starts agents by itself.
    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        guard on else { rules[i].enabled = false; save(); return }
        let r = rules[i]
        confirm("Turn on “\(r.name)”?",
                "From now on Octomux starts an agent by itself for: \(r.summary). Items already in the Inbox are left alone.",
                "Turn On") { [weak self] yes in
            guard yes, let self, let j = self.rules.firstIndex(where: { $0.id == id }) else { return }
            self.rules[j].enabled = true
            self.save()
        }
    }

    /// Items that just came in (never the first fetch, a widened one, or hidden places).
    func handle(_ appeared: [InboxItem]) {
        var started = 0
        for item in appeared {
            guard started < Self.maxPerRefresh else { break }
            for r in rules where r.enabled && r.matches(item) {
                let key = r.id + "|" + item.id
                guard !runs.contains(key) else { continue }
                runs.append(key)
                if runs.count > 500 { runs.removeFirst(runs.count - 500) }
                defaults.set(runs, forKey: InboxPrefs.ruleRuns)
                if let why = start(item, r) {
                    // "" = skipped on purpose (a draft, one you approved): no news.
                    if !why.isEmpty { notify("“\(r.name)” didn't start: \(item.key)", why) }
                } else {
                    started += 1
                    notify("Started an agent on \(item.key)", "\(r.name): \(item.title)")
                    ActivityLog.shared.record(.automation, "\(r.name) started an agent on \(item.key)", detail: item.title, item: item.id)
                }
                break            // one rule per item
            }
        }
    }

    /// Starts the review of what changed (tests swap it); returns why it couldn't, or nil.
    var restart: (InboxItem, InboxReviewRun, InboxRule) -> String? = { item, run, r in
        guard let p = AppModel.shared.project(run.projectId) else { return "Its project is gone." }
        return InboxReviews.shared.start(item, in: p, clone: run.clone, profileId: r.profileId ?? run.profileId, auto: true, again: true)
    }

    /// Pull requests an automation reviewed that got new commits since: what changed is reviewed, once per new head,
    /// while a rule that reviews them is on. Reviews you started yourself are left to you.
    func followUp(_ items: [InboxItem], run: (String) -> InboxReviewRun? = { InboxReviews.shared.run($0) }) {
        var started = 0
        for item in items where started < Self.maxPerRefresh {
            guard let last = run(item.id), last.auto, last.state == .done, let h = last.head, let now = item.head,
                  !InboxReviews.sameCommit(h, now), item.ended == nil, !item.isDraft,
                  let r = rules.first(where: { $0.enabled && $0.action == .reviewWorktree && $0.matches(item) }) else { continue }
            let key = r.id + "|" + item.id + "@" + now
            guard !runs.contains(key) else { continue }
            runs.append(key)
            if runs.count > 500 { runs.removeFirst(runs.count - 500) }
            defaults.set(runs, forKey: InboxPrefs.ruleRuns)
            if let why = restart(item, last, r) {
                if !why.isEmpty { notify("“\(r.name)” didn't review the new commits: \(item.key)", why) }
            } else {
                started += 1
                notify("Reviewing new commits on \(item.key)", "\(r.name): \(item.title)")
                ActivityLog.shared.record(.automation, "\(r.name) is reviewing new commits on \(item.key)", detail: item.title, item: item.id)
            }
        }
    }

    /// The real start: in the item's own project only (never a guess), without switching to it.
    static func startAgent(_ item: InboxItem, _ r: InboxRule) -> String? {
        let model = AppModel.shared, store = InboxStore.shared
        guard let project = store.project(for: item) else { return "No project is set for \(item.place). Open the item and pick one." }
        let profile = r.profileId.flatMap { model.profile($0) }
            ?? UserDefaults.standard.string(forKey: InboxPrefs.profile).flatMap { model.profile($0) }
            ?? model.enabledProfiles.first { $0.kind == .claude || $0.kind == .codex }
        guard let profile else { return "No Claude or Codex agent is set up." }
        switch r.action {
        case .reviewWorktree:
            if item.isDraft || store.yourReview(item) == .approved { return "" }
            guard let own = store.checkoutProject(for: item) else {
                return "No local project is a checkout of \(item.place); add one to review its pull requests in a worktree."
            }
            return InboxReviews.shared.start(item, in: own, profileId: profile.id, auto: true)
        case .work:
            InboxStart.start(item, in: project, worktree: true, task: .work, model: model, select: false, profile: profile.id)
        case .review:
            let text = InboxStart.prompt(item, .review)
            model.newSession(profileId: profile.id, projectId: project.id, prompt: text, chat: true,
                             extraArgs: ChatLaunchOptions.readOnlyArgs(profile.kind), select: false) { sid in
                ChatFirstMessage.set(sid, text)
                store.link(item.id, session: sid)
            }
        }
        return nil
    }
}
