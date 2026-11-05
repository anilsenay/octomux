import AppKit
import Foundation

/// Changing a pull request from the Inbox (merge, ready / draft, close / reopen) through the GitHub CLI.
/// Every action is confirmed first, naming exactly what will happen.
enum InboxPRAction: String, CaseIterable, Identifiable {
    case merge, squash, rebase, ready, draft, close, reopen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return "Create a Merge Commit"
        case .squash: return "Squash and Merge"
        case .rebase: return "Rebase and Merge"
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
        }
    }

    /// What can be done to the pull request as it is now.
    static func available(_ i: InboxItem) -> [InboxPRAction] {
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
            let run = self.run
            self.background {
                let r = Result { try run(a.args(i)) }
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

    private func go(_ i: InboxItem, done: String, _ work: @escaping () throws -> Void) {
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
                    self.changed(i)
                case .failure(let e): self.results[i.id] = (false, "\(e)")
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
