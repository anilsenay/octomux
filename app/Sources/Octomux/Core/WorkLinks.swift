import Foundation

/// What a session is working on, as the Inbox knows it: the items it was started from ("Work on it", Review,
/// Fix with agent), the pull request whose branch it has checked out, and the issue its branch is named after.
/// Shown as chips (PR number with its checks, issue key with its status) wherever a session is shown.
enum WorkLinks {
    /// Branches that are never one pull request's (a session on them is linked only by the Inbox's own links).
    static let sharedBranches: Set<String> = ["main", "master", "develop", "dev", "trunk", "HEAD"]

    /// The items of `items` that belong to the session: linked to it, its branch's pull request, or the issue whose
    /// key its branch carries ("shop-12-fix-cart" → SHOP-12). Pull requests first.
    static func items(session: String, branch: String?, items: [InboxItem], links: [String: String]) -> [InboxItem] {
        var out: [InboxItem] = []
        func add(_ i: InboxItem) { if !out.contains(where: { $0.id == i.id }) { out.append(i) } }
        for i in items where links[i.id] == session { add(i) }
        if let b = branch, !sharedBranches.contains(b) {
            for i in items where i.kind == .pr && i.branch == b && i.ended == nil { add(i) }
            let lower = b.lowercased()
            for i in items where i.source == .jira && containsKey(lower, i.key.lowercased()) { add(i) }
        }
        let prs: [InboxItem] = out.filter { $0.kind == .pr }
        let rest: [InboxItem] = out.filter { $0.kind != .pr }
        return prs + rest
    }

    /// The key as a whole word of the branch ("shop-12" in "feature/shop-12-x", not in "shop-123").
    static func containsKey(_ branch: String, _ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        var from = branch.startIndex
        while let r = branch.range(of: key, range: from..<branch.endIndex) {
            let before = r.lowerBound == branch.startIndex ? nil : branch[branch.index(before: r.lowerBound)]
            let after = r.upperBound == branch.endIndex ? nil : branch[r.upperBound]
            if !(before.map { $0.isLetter || $0.isNumber } ?? false) && !(after.map { $0.isNumber } ?? false) { return true }
            from = r.upperBound
        }
        return false
    }
}

/// What a pull request of yours needs next (Workday's "Your pull requests"; any Inbox view can use it).
enum PRNextStep: Equatable {
    case fixChecks          // checks fail: hand them to an agent
    case addressChanges     // a reviewer asked for changes
    case markReady          // a draft whose checks pass
    case waitChecks         // checks still running
    case merge              // approved, checks pass
    case waitReview         // nothing to do but wait for reviewers
    case none               // not an open pull request of yours

    static func of(_ i: InboxItem) -> PRNextStep {
        guard i.kind == .pr, i.ended == nil else { return .none }
        if i.checks == .failing { return .fixChecks }
        if i.changesRequested > 0 { return .addressChanges }
        if i.isDraft { return i.checks == .pending ? .waitChecks : .markReady }
        if i.checks == .pending { return .waitChecks }
        if i.approvals > 0 { return .merge }
        return .waitReview
    }

    var title: String {
        switch self {
        case .fixChecks: return "Fix with agent"
        case .addressChanges: return "Address changes"
        case .markReady: return "Mark ready"
        case .waitChecks: return "Checks running"
        case .merge: return "Merge"
        case .waitReview: return "Waiting for review"
        case .none: return ""
        }
    }
    /// The step is something you do (a button), not something you wait for.
    var isAction: Bool { [.fixChecks, .addressChanges, .markReady, .merge].contains(self) }

    /// The item's next step is one you can take from here (a Bitbucket draft can't be marked ready from Octomux).
    static func actionable(_ i: InboxItem) -> Bool {
        let s = of(i)
        switch s {
        case .markReady: return InboxPRAction.available(i).contains(.ready)
        case .merge: return InboxPRAction.available(i).contains(where: \.isMerge)
        default: return s.isAction
        }
    }
}
