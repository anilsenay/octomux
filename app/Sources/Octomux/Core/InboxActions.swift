import AppKit
import Foundation

/// Changing a pull request from the Inbox: on GitHub (merge, ready / draft, close / reopen) through the GitHub CLI; on
/// Bitbucket (approve, request changes, merge, decline) through its API. Every action is confirmed first, naming
/// exactly what will happen.
enum InboxPRAction: String, CaseIterable, Identifiable {
    case merge, squash, rebase, fastForward, ready, draft, close, reopen
    case approve, unapprove, requestChanges, undoRequestChanges, decline
    var id: String { rawValue }
    var isMerge: Bool { [.merge, .squash, .rebase, .fastForward].contains(self) }
    var isReview: Bool { [.approve, .unapprove, .requestChanges, .undoRequestChanges].contains(self) }

    var title: String {
        switch self {
        case .merge: return "Create a Merge Commit"
        case .squash: return "Squash and Merge"
        case .rebase: return "Rebase and Merge"
        case .fastForward: return "Fast-Forward Merge"
        case .approve: return "Approve"
        case .unapprove: return "Remove Your Approval"
        case .requestChanges: return "Request Changes"
        case .undoRequestChanges: return "Withdraw Request for Changes"
        case .decline: return "Decline Pull Request"
        case .ready: return "Mark Ready for Review"
        case .draft: return "Convert to Draft"
        case .close: return "Close Pull Request"
        case .reopen: return "Reopen Pull Request"
        }
    }

    /// The `gh` command (the head branch is never deleted).
    func args(_ i: InboxItem) -> [String] {
        let n = "\(i.number ?? 0)", repo = i.repo ?? ""
        switch self {
        case .merge: return ["gh", "pr", "merge", n, "--repo", repo, "--merge"]
        case .squash: return ["gh", "pr", "merge", n, "--repo", repo, "--squash"]
        case .rebase: return ["gh", "pr", "merge", n, "--repo", repo, "--rebase"]
        case .ready: return ["gh", "pr", "ready", n, "--repo", repo]
        case .draft: return ["gh", "pr", "ready", n, "--repo", repo, "--undo"]
        case .close: return ["gh", "pr", "close", n, "--repo", repo]
        case .reopen: return ["gh", "pr", "reopen", n, "--repo", repo]
        case .fastForward, .approve, .unapprove, .requestChanges, .undoRequestChanges, .decline: return []
        }
    }

    /// What can be done to the pull request as it is now.
    static func available(_ i: InboxItem) -> [InboxPRAction] {
        if i.source == .bitbucket {
            guard i.kind == .pr, i.number != nil, i.ended == nil else { return [] }
            var out: [InboxPRAction] = []
            // You can't review your own pull request.
            if i.author != "You" {
                out.append(i.youApproved ? .unapprove : .approve)
                out.append(i.youRequestedChanges ? .undoRequestChanges : .requestChanges)
            }
            if !i.isDraft { out += [.merge, .squash, .fastForward] }
            out.append(.decline)
            return out
        }
        guard i.kind == .pr, i.source == .github, i.number != nil, i.repo != nil else { return [] }
        if let e = i.ended { return e.merged ? [] : [.reopen] }
        if i.isDraft { return [.ready, .close] }
        return [.merge, .squash, .rebase, .draft, .close]
    }

    /// The confirmation: what exactly happens, on which repository and branch.
    func confirmation(_ i: InboxItem) -> (title: String, message: String, button: String) {
        let what = "\(i.key) “\(i.title)” in \(i.place)"
        let into = i.base.map { " into \($0)" } ?? ""
        switch self {
        case .merge: return ("Merge \(i.key)\(into)?", "Merges \(what)\(into) with a merge commit. The branch \(i.branch ?? "") stays.", "Merge")
        case .squash: return ("Squash and merge \(i.key)\(into)?", "Squashes the commits of \(what) into one and merges it\(into). The branch \(i.branch ?? "") stays.", "Squash and Merge")
        case .rebase: return ("Rebase and merge \(i.key)\(into)?", "Rebases the commits of \(what) onto\(i.base.map { " " + $0 } ?? " the base") and merges them. The branch \(i.branch ?? "") stays.", "Rebase and Merge")
        case .ready: return ("Mark \(i.key) ready for review?", "Takes \(what) out of draft; reviewers get notified.", "Mark Ready")
        case .draft: return ("Convert \(i.key) to a draft?", "Turns \(what) back into a draft.", "Convert to Draft")
        case .close: return ("Close \(i.key)?", "Closes \(what) without merging it.", "Close")
        case .reopen: return ("Reopen \(i.key)?", "Reopens \(what).", "Reopen")
        case .fastForward: return ("Fast-forward merge \(i.key)\(into)?", "Moves\(i.base.map { " " + $0 } ?? " the base") up to the commits of \(what) without a merge commit (only if it can). The branch \(i.branch ?? "") stays.", "Fast-Forward Merge")
        case .approve: return ("Approve \(i.key)?", "Approves \(what) on \(i.source.name) as you.", "Approve")
        case .unapprove: return ("Remove your approval of \(i.key)?", "Takes back your approval of \(what).", "Remove Approval")
        case .requestChanges: return ("Request changes on \(i.key)?", "Marks \(what) as needing changes, as you. Leave a comment to say which.", "Request Changes")
        case .undoRequestChanges: return ("Withdraw your request for changes on \(i.key)?", "Takes back your request for changes on \(what).", "Withdraw")
        case .decline: return ("Decline \(i.key)?", "Declines \(what) without merging it. Bitbucket can't reopen a declined pull request.", "Decline")
        }
    }
}

/// Runs a confirmed change (gh; tests and the fixture swap the runner and the confirmation).
final class InboxActions: ObservableObject {
    static let shared = InboxActions()

    @Published private(set) var busy: Set<String> = []
    /// The last result per item: nil while nothing was done, else a message (error or done).
    @Published private(set) var results: [String: (ok: Bool, text: String)] = [:]

    var run: ([String]) throws -> String = { try InboxShell.run($0) }
    /// Bitbucket's API for its pull requests (tests and the fixture swap it).
    var bitbucket: (InboxPRAction, InboxItem) throws -> String = BitbucketWrites.perform
    /// Asks the user (a sheet on the main window); calls back with the answer.
    var confirm: (_ title: String, _ message: String, _ button: String, _ done: @escaping (Bool) -> Void) -> Void = InboxConfirm.ask
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// After a change: the store treats what the next refresh sees of the item as read, then refreshes.
    var changed: (InboxItem) -> Void = { i in InboxStore.shared.ownChange(i) }

    func perform(_ a: InboxPRAction, on i: InboxItem) {
        guard InboxPRAction.available(i).contains(a), !busy.contains(i.id) else { return }
        let c = a.confirmation(i)
        confirm(c.title, c.message, c.button) { [weak self] yes in
            guard let self, yes else { return }
            self.busy.insert(i.id)
            self.results[i.id] = nil
            let run = self.run, bb = self.bitbucket
            self.background {
                let r = Result { i.source == .bitbucket ? try bb(a, i) : try run(a.args(i)) }
                self.onMain {
                    self.busy.remove(i.id)
                    switch r {
                    case .success: self.results[i.id] = (true, "Done: \(a.title.lowercased()).")
                    case .failure(let e): self.results[i.id] = (false, "\(e)".trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    if case .success = r { self.changed(i) }
                }
            }
        }
    }

    func clear(_ i: InboxItem) { results[i.id] = nil }
}

/// A confirmation sheet on the main window (does not block the app like a modal alert).
enum InboxConfirm {
    /// The sheet on screen (the debug fixture answers it).
    static weak var current: NSAlert?

    static func ask(_ title: String, _ message: String, _ button: String, _ done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        // A sheet on our window even while the app is in the background (no main window then); never a blocking modal.
        let win = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil }
        guard let win else { done(false); return }
        current = a
        a.beginSheetModal(for: win) { r in current = nil; done(r == .alertFirstButtonReturn) }
    }
}

/// Changing Jira issues from the Inbox: status, assignee, new issues. Every change is confirmed first.
final class InboxJiraActions: ObservableObject {
    static let shared = InboxJiraActions()

    @Published private(set) var transitions: [String: [JiraClient.Transition]] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var results: [String: (ok: Bool, text: String)] = [:]

    // Network (tests and the fixture swap these).
    var loadTransitions: (String) throws -> [JiraClient.Transition] = JiraClient.transitions
    var doTransition: (String, String) throws -> Void = JiraClient.transition
    var doAssign: (String) throws -> Void = JiraClient.assignToMe
    var loadTypes: (String) throws -> [JiraClient.IssueType] = JiraClient.issueTypes
    var doCreate: (_ project: String, _ type: String, _ summary: String, _ description: String, _ mine: Bool) throws -> String = JiraClient.create
    var loadFilters: () throws -> [JiraClient.Filter] = JiraClient.favouriteFilters
    var loadUsers: (_ key: String, _ query: String) throws -> [JiraClient.User] = JiraClient.assignableUsers
    var doAssignTo: (_ key: String, _ accountId: String?) throws -> Void = JiraClient.assign
    var loadEditMeta: (String) throws -> (priorities: [JiraClient.Priority], editable: Set<String>) = JiraClient.editMeta
    var doFields: (_ key: String, _ fields: [String: Any]) throws -> Void = JiraClient.setFields
    var loadPlainDescription: (String) throws -> String? = JiraClient.plainDescription

    /// Item id → what can be changed on it (from onAppear of its detail).
    @Published private(set) var editMeta: [String: (priorities: [JiraClient.Priority], editable: Set<String>)] = [:]

    func loadEditMeta(_ i: InboxItem) {
        guard i.source == .jira, i.ended == nil, editMeta[i.id] == nil else { return }
        let load = loadEditMeta
        background { [weak self] in
            guard let m = try? load(i.key) else { return }
            self?.onMain { self?.editMeta[i.id] = m }
        }
    }

    /// Searches the people the issue can be assigned to; `done` gets them (or an error) on the main thread.
    func searchUsers(_ i: InboxItem, _ query: String, done: @escaping (Result<[JiraClient.User], Error>) -> Void) {
        let load = loadUsers
        background { [weak self] in
            let r = Result { try load(i.key, query) }
            self?.onMain { done(r) }
        }
    }

    func assign(_ i: InboxItem, to user: JiraClient.User?) {
        guard !busy.contains(i.id) else { return }
        let from = i.assignee.map { " (now \($0))" } ?? ""
        let (title, message, button) = user.map { ("Assign \(i.key) to \($0.name)?", "Makes \($0.name) the assignee of “\(i.title)”\(from) on Jira.", "Assign") }
            ?? ("Unassign \(i.key)?", "Leaves “\(i.title)”\(from) without an assignee on Jira.", "Unassign")
        confirm(title, message, button) { [weak self] yes in
            guard yes, let self else { return }
            let run = self.doAssignTo
            self.go(i, done: user.map { "Assigned to \($0.name)." } ?? "Unassigned.") { try run(i.key, user?.id) }
        }
    }

    func setPriority(_ i: InboxItem, _ p: JiraClient.Priority) {
        guard !busy.contains(i.id) else { return }
        confirm("Change \(i.key)'s priority to \(p.name)?", "Sets the priority of “\(i.title)”\(i.priority.map { " from \($0)" } ?? "") to \(p.name) on Jira.", "Change Priority") { [weak self] yes in
            guard yes, let self else { return }
            let run = self.doFields
            self.go(i, done: "Priority: \(p.name).") { try run(i.key, ["priority": ["id": p.id]]) }
        }
    }

    /// Renames the issue (asks first); `done(true)` once it is saved.
    func rename(_ i: InboxItem, _ title: String, done: @escaping (Bool) -> Void = { _ in }) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != i.title, !busy.contains(i.id) else { done(false); return }
        confirm("Rename \(i.key)?", "Changes the title on Jira from “\(i.title)” to “\(t)”.", "Rename") { [weak self] yes in
            guard yes, let self else { done(false); return }
            let run = self.doFields
            self.go(i, done: "Renamed.", after: done) { try run(i.key, ["summary": t]) }
        }
    }

    /// Replaces a plain description (asks first); `done(true)` once it is saved.
    func describe(_ i: InboxItem, _ text: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard !busy.contains(i.id) else { done(false); return }
        confirm("Change \(i.key)'s description?", "Replaces the description of “\(i.title)” on Jira with the text you wrote.", "Save Description") { [weak self] yes in
            guard yes, let self else { done(false); return }
            let run = self.doFields
            self.go(i, done: "Description saved.", after: done) { try run(i.key, ["description": ADF.doc(text)]) }
        }
    }
    var confirm: (_ title: String, _ message: String, _ button: String, _ done: @escaping (Bool) -> Void) -> Void = InboxConfirm.ask
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    var changed: (InboxItem) -> Void = { i in InboxStore.shared.ownChange(i) }

    /// Reads where the issue can move (from onAppear of its detail).
    func loadTransitions(_ i: InboxItem) {
        guard i.source == .jira, i.ended == nil else { return }
        let load = loadTransitions
        background { [weak self] in
            let t = (try? load(i.key)) ?? []
            self?.onMain { self?.transitions[i.id] = t }
        }
    }

    func move(_ i: InboxItem, _ t: JiraClient.Transition) {
        guard !busy.contains(i.id) else { return }
        confirm("Move \(i.key) to \(t.to)?", "Changes “\(i.title)” from \(i.status) to \(t.to) on Jira (\(t.name)).", "Move to \(t.to)") { [weak self] yes in
            guard yes, let self else { return }
            let run = self.doTransition
            self.go(i, done: "Moved to \(t.to).") { try run(i.key, t.id) }
        }
    }

    func assignToMe(_ i: InboxItem) {
        guard !busy.contains(i.id) else { return }
        let from = i.assignee.map { " from \($0)" } ?? ""
        confirm("Assign \(i.key) to you?", "Makes you the assignee of “\(i.title)”\(from) on Jira.", "Assign to Me") { [weak self] yes in
            guard yes, let self else { return }
            let run = self.doAssign
            self.go(i, done: "Assigned to you.") { try run(i.key) }
        }
    }

    private func go(_ i: InboxItem, done: String, after: @escaping (Bool) -> Void = { _ in }, _ work: @escaping () throws -> Void) {
        busy.insert(i.id)
        results[i.id] = nil
        background { [weak self] in
            let r = Result { try work() }
            self?.onMain {
                guard let self else { return }
                self.busy.remove(i.id)
                switch r {
                case .success:
                    self.results[i.id] = (true, done)
                    self.transitions[i.id] = nil
                    self.editMeta[i.id] = nil
                    self.loadEditMeta(i)               // what can be changed may differ now (a new status)
                    self.changed(i)
                    after(true)
                case .failure(let e): self.results[i.id] = (false, "\(e)"); after(false)
                }
            }
        }
    }

    /// Creates an issue after asking; `done` gets its key or an error, or nil when the user said no.
    func create(project: String, type: JiraClient.IssueType, summary: String, description: String, mine: Bool,
                done: @escaping (Result<String, Error>?) -> Void) {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { done(nil); return }
        confirm("Create a \(type.name) in \(project)?", "Creates “\(s)” on Jira\(mine ? ", assigned to you" : "").", "Create") { [weak self] yes in
            guard yes, let self else { done(nil); return }
            let run = self.doCreate
            self.background {
                let r = Result { try run(project, type.id, s, description, mine) }
                self.onMain {
                    done(r)
                    if case .success = r { InboxStore.shared.refresh(widened: true) }
                }
            }
        }
    }

    func clear(_ i: InboxItem) { results[i.id] = nil }
}
