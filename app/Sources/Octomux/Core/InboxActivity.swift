import Foundation

/// One thing that happened to an Inbox item: a comment, a field change, commits, a review.
struct InboxEvent: Equatable, Identifiable {
    enum Kind: String { case comment, change, commits, review }
    var kind: Kind
    /// Who did it ("You" for the signed-in user).
    var actor: String
    var date: Date
    /// What they did, after the actor's name: "moved it to Code Review", "commented", "approved".
    var summary: String
    /// Comment or review text, or one commit headline per line.
    var detail: String = ""
    /// For changes: the field ("status", "assignee", "labels", "title", …), used for summaries.
    var field: String = ""
    var id: String { "\(date.timeIntervalSince1970)|\(actor)|\(kind.rawValue)|\(summary)" }
}

/// An item's history, oldest first. `note` says why part of it is missing (the token can't read history).
struct InboxActivity: Equatable {
    var events: [InboxEvent]
    var note: String? = nil
}

enum InboxHistory {
    /// Back-to-back commit events by one author read as one push ("pushed 3 commits").
    static func grouped(_ events: [InboxEvent]) -> [InboxEvent] {
        var out: [InboxEvent] = []
        for e in events.sorted(by: { $0.date < $1.date }) {
            if e.kind == .commits, var last = out.last, last.kind == .commits, last.actor == e.actor {
                last.detail += "\n" + e.detail
                let n = last.detail.split(separator: "\n").count
                last.summary = "pushed \(n) commits"
                last.date = e.date
                out[out.count - 1] = last
            } else {
                out.append(e)
            }
        }
        return out
    }

    /// The events after `since` (unix seconds), oldest first.
    static func after(_ events: [InboxEvent], _ since: Double) -> [InboxEvent] {
        events.filter { $0.date.timeIntervalSince1970 > since + 0.5 }.sorted { $0.date < $1.date }
    }

    /// "Since you looked" in one line: "Ann moved it to Code Review · 2 comments by Bob · 3 commits".
    static func summary(_ events: [InboxEvent]) -> String {
        guard !events.isEmpty else { return "" }
        var parts: [String] = []
        // The latest status move tells the most.
        if let s = events.last(where: { $0.kind == .change && $0.field == "status" }) { parts.append("\(s.actor) \(s.summary)") }
        if let r = events.last(where: { $0.kind == .review }) { parts.append("\(r.actor) \(r.summary)") }
        let comments = events.filter { $0.kind == .comment }
        if !comments.isEmpty {
            parts.append("\(comments.count) comment\(comments.count == 1 ? "" : "s") by \(names(comments.map(\.actor)))")
        }
        let commits = events.filter { $0.kind == .commits }.reduce(0) { $0 + max(1, $1.detail.split(separator: "\n").count) }
        if commits > 0 { parts.append("\(commits) commit\(commits == 1 ? "" : "s")") }
        let others = events.filter { $0.kind == .change && $0.field != "status" }
        if others.count == 1, let o = others.first { parts.append("\(o.actor) \(o.summary)") }
        else if others.count > 1 { parts.append("\(others.count) other changes") }
        return parts.joined(separator: " · ")
    }

    /// What a notification says about a change: the newest thing someone else did, or nil when every new
    /// event is yours (then it is no news at all).
    static func notice(_ events: [InboxEvent]) -> (text: String, onlyMine: Bool)? {
        guard !events.isEmpty else { return nil }
        let others = events.filter { $0.actor != "You" }
        guard let last = others.last else { return ("", true) }
        var text: String
        switch last.kind {
        case .comment:
            let body = last.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            text = "\(last.actor) commented" + (body.isEmpty ? "" : ": " + String(body.prefix(90)))
        default:
            text = "\(last.actor) \(last.summary)"
        }
        if others.count > 1 { text += " (+\(others.count - 1) more)" }
        return (text, false)
    }

    private static func names(_ all: [String]) -> String {
        var seen = Set<String>(), out: [String] = []
        for n in all where seen.insert(n).inserted { out.append(n) }
        return out.count <= 2 ? out.joined(separator: " and ") : "\(out[0]), \(out[1]) and \(out.count - 2) more"
    }

    // MARK: Jira changelog

    /// Jira's changelog histories (GET /issue/{key}/changelog `values`) as events, one per changed field.
    static func jiraChanges(_ histories: [[String: Any]], me: String?) -> [InboxEvent] {
        var out: [InboxEvent] = []
        for h in histories {
            let a = h["author"] as? [String: Any]
            let actor = (a?["accountId"] as? String).flatMap { $0 == me ? "You" : nil } ?? (a?["displayName"] as? String ?? "Someone").htmlUnescaped
            guard let date = InboxDates.iso(h["created"] as? String) else { continue }
            for i in h["items"] as? [[String: Any]] ?? [] {
                let field = (i["fieldId"] as? String ?? i["field"] as? String ?? "").lowercased()
                let name = i["field"] as? String ?? field
                let from = (i["fromString"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let to = (i["toString"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let s: String, f: String
                switch field {
                case "status": f = "status"; s = "moved it to \(to)"
                case "assignee": f = "assignee"; s = to.isEmpty ? "unassigned it" : "assigned it to \(to)"
                case "priority": f = "priority"; s = "set priority to \(to)"
                case "summary": f = "title"; s = "renamed it to “\(to)”"
                case "description": f = "description"; s = "edited the description"
                case "resolution": f = "resolution"; s = to.isEmpty ? "cleared the resolution" : "resolved it as \(to)"
                case "labels": f = "labels"; s = to.isEmpty ? "removed the labels" : "set labels to \(to)"
                default:
                    if name.lowercased() == "sprint" { f = "sprint"; s = to.isEmpty ? "removed it from \(from)" : "moved it to \(lastOf(to))" }
                    else if name.lowercased() == "rank" { continue }      // board reordering is noise
                    else { f = name.lowercased(); s = to.isEmpty ? "cleared \(name)" : "changed \(name) to \(to)" }
                }
                out.append(InboxEvent(kind: .change, actor: actor, date: date, summary: s, field: f))
            }
        }
        return out
    }

    /// "Sprint 41, Sprint 42" → "Sprint 42".
    private static func lastOf(_ s: String) -> String {
        s.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? s
    }

    // MARK: GitHub timeline

    static let prTimelineTypes = "ISSUE_COMMENT, PULL_REQUEST_COMMIT, PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, RENAMED_TITLE_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT"
    static let issueTimelineTypes = "ISSUE_COMMENT, LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, CLOSED_EVENT, REOPENED_EVENT, RENAMED_TITLE_EVENT"
    /// The fragments an issue's timeline accepts (the PR-only ones are refused there).
    static let issueTimelineFragments = """
    __typename
    ... on IssueComment { author { login } body createdAt }
    ... on LabeledEvent { actor { login } createdAt label { name } }
    ... on UnlabeledEvent { actor { login } createdAt label { name } }
    ... on AssignedEvent { actor { login } createdAt assignee { ... on User { login } } }
    ... on UnassignedEvent { actor { login } createdAt assignee { ... on User { login } } }
    ... on ClosedEvent { actor { login } createdAt }
    ... on ReopenedEvent { actor { login } createdAt }
    ... on RenamedTitleEvent { actor { login } createdAt currentTitle }
    """
    static let timelineFragments = """
    __typename
    ... on IssueComment { author { login } body createdAt }
    ... on PullRequestCommit { commit { messageHeadline committedDate author { name user { login } } } }
    ... on PullRequestReview { author { login } state body submittedAt createdAt }
    ... on ReviewRequestedEvent { actor { login } createdAt requestedReviewer { ... on User { login } ... on Team { name } } }
    ... on LabeledEvent { actor { login } createdAt label { name } }
    ... on UnlabeledEvent { actor { login } createdAt label { name } }
    ... on AssignedEvent { actor { login } createdAt assignee { ... on User { login } } }
    ... on UnassignedEvent { actor { login } createdAt assignee { ... on User { login } } }
    ... on MergedEvent { actor { login } createdAt }
    ... on ClosedEvent { actor { login } createdAt }
    ... on ReopenedEvent { actor { login } createdAt }
    ... on RenamedTitleEvent { actor { login } createdAt currentTitle }
    ... on HeadRefForcePushedEvent { actor { login } createdAt }
    ... on ReadyForReviewEvent { actor { login } createdAt }
    ... on ConvertToDraftEvent { actor { login } createdAt }
    """

    /// GitHub timeline nodes as events.
    static func githubEvents(_ nodes: [[String: Any]], me: String?) -> [InboxEvent] {
        func login(_ o: Any?) -> String? { (o as? [String: Any])?["login"] as? String }
        func who(_ l: String?) -> String { guard let l else { return "ghost" }; return l == me ? "You" : l }
        func when(_ n: [String: Any], _ k: String = "createdAt") -> Date? { InboxDates.iso(n[k] as? String) }
        var out: [InboxEvent] = []
        for n in nodes {
            let t = n["__typename"] as? String ?? ""
            let actor = who(login(n["actor"]))
            switch t {
            case "IssueComment":
                guard let d = when(n) else { continue }
                out.append(InboxEvent(kind: .comment, actor: who(login(n["author"])), date: d, summary: "commented", detail: n["body"] as? String ?? ""))
            case "PullRequestCommit":
                guard let c = n["commit"] as? [String: Any], let d = InboxDates.iso(c["committedDate"] as? String) else { continue }
                let a = c["author"] as? [String: Any]
                let name = login(a?["user"]).map { who($0) } ?? (a?["name"] as? String ?? "ghost")
                out.append(InboxEvent(kind: .commits, actor: name, date: d, summary: "pushed a commit", detail: c["messageHeadline"] as? String ?? ""))
            case "PullRequestReview":
                guard let d = when(n, "submittedAt") ?? when(n) else { continue }
                let s: String
                switch (n["state"] as? String ?? "").uppercased() {
                case "APPROVED": s = "approved"
                case "CHANGES_REQUESTED": s = "requested changes"
                case "DISMISSED": s = "had a review dismissed"
                case "PENDING": continue                      // a draft review only its author sees
                default: s = "reviewed"
                }
                out.append(InboxEvent(kind: .review, actor: who(login(n["author"])), date: d, summary: s, detail: n["body"] as? String ?? "", field: "review"))
            case "ReviewRequestedEvent":
                guard let d = when(n) else { continue }
                let r = n["requestedReviewer"] as? [String: Any]
                let target = (r?["login"] as? String).map { who($0) } ?? (r?["name"] as? String ?? "someone")
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: "asked \(target == "You" ? "you" : target) for a review", field: "review request"))
            case "LabeledEvent", "UnlabeledEvent":
                guard let d = when(n) else { continue }
                let l = (n["label"] as? [String: Any])?["name"] as? String ?? ""
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: (t == "LabeledEvent" ? "added the label " : "removed the label ") + l, field: "labels"))
            case "AssignedEvent", "UnassignedEvent":
                guard let d = when(n) else { continue }
                let a = who(login(n["assignee"]))
                let target = a == "You" ? "you" : a
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: t == "AssignedEvent" ? "assigned \(target)" : "unassigned \(target)", field: "assignee"))
            case "MergedEvent", "ClosedEvent", "ReopenedEvent", "HeadRefForcePushedEvent", "ReadyForReviewEvent", "ConvertToDraftEvent":
                guard let d = when(n) else { continue }
                let (s, f): (String, String) = [
                    "MergedEvent": ("merged it", "status"), "ClosedEvent": ("closed it", "status"), "ReopenedEvent": ("reopened it", "status"),
                    "HeadRefForcePushedEvent": ("force-pushed the branch", "push"), "ReadyForReviewEvent": ("marked it ready for review", "status"),
                    "ConvertToDraftEvent": ("turned it into a draft", "status"),
                ][t]!
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: s, field: f))
            case "RenamedTitleEvent":
                guard let d = when(n) else { continue }
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: "renamed it to “\(n["currentTitle"] as? String ?? "")”", field: "title"))
            default: continue
            }
        }
        return out
    }
}
