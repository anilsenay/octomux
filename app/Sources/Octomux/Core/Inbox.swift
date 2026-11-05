import AppKit
import Foundation
import Security

// The Inbox: pull requests, reviews and issues from GitHub (through the gh CLI, so Octomux keeps no GitHub token)
// and Jira Cloud (site + email + API token, the token in the Keychain). Polled while the app runs.

enum InboxSource: String, CaseIterable, Identifiable, Codable {
    case github, jira
    var id: String { rawValue }
    var name: String { self == .github ? "GitHub" : "Jira" }
}

struct InboxItem: Identifiable, Equatable {
    enum Kind: String { case pr, issue }
    /// Why it is in the inbox (an item found by several searches keeps the first of these).
    enum Reason: String, CaseIterable {
        case review = "Review requested", mine = "Your pull request", assigned = "Assigned to you"
        case mention = "Mentioned you", project = "In your projects"
    }
    enum Checks: String { case passing, failing, pending }
    struct Comment: Equatable { let author: String; let date: Date?; let text: String }

    let id: String            // "gh:owner/repo#12", "jira:DC-4162"
    let source: InboxSource
    let kind: Kind
    let key: String           // "#12", "DC-4162"
    let place: String         // owner/repo, or the Jira project's name
    let title: String
    let author: String
    let assignee: String?
    let status: String        // Open / Draft / the Jira status
    let statusTone: String    // done | progress | todo (status chip color)
    var reason: Reason
    var checks: Checks? = nil
    var checkCounts: (passed: Int, failed: Int, pending: Int) = (0, 0, 0)
    var failedChecks: [String] = []
    let updated: Date
    let body: String
    let url: String
    var branch: String? = nil
    var number: Int? = nil

    static func == (a: InboxItem, b: InboxItem) -> Bool {
        a.id == b.id && a.updated == b.updated && a.reason == b.reason && a.checks == b.checks && a.status == b.status
    }
    var kindName: String { kind == .pr ? "Pull request" : "Issue" }
    /// Jira: the project key ("DC" of DC-12).
    var projectKey: String { String(key.split(separator: "-").first ?? "") }
    /// GitHub: the repo. Jira: none.
    var repo: String? { source == .github ? place : nil }
}

enum InboxPrefs {
    static let githubOn = "octomux.inbox.github"
    static let jiraSite = "octomux.inbox.jira.site"
    static let jiraEmail = "octomux.inbox.jira.email"
    static let jiraBase = "octomux.inbox.jira.base"            // site, or the API gateway for scoped tokens
    static let jiraProjects = "octomux.inbox.jira.projects"    // comma-separated project keys
    static let jiraScope = "octomux.inbox.jira.scope"          // assigned | all
    static let ghReview = "octomux.inbox.gh.review"
    static let ghMine = "octomux.inbox.gh.mine"
    static let ghAssigned = "octomux.inbox.gh.assigned"
    static let ghMention = "octomux.inbox.gh.mention"
    static let poll = "octomux.inbox.poll"                     // minutes
    static let nReview = "octomux.inbox.n.review"
    static let nChecks = "octomux.inbox.n.checks"
    static let nAssigned = "octomux.inbox.n.assigned"
    static let nUpdates = "octomux.inbox.n.updates"            // changes on your own items (yours / assigned / review)
    static let jiraWatched = "octomux.inbox.jira.watched"      // project keys whose every change notifies (the bell)
    static let startMode = "octomux.inbox.start"               // tab | worktree | ask
    static let profile = "octomux.inbox.profile"
    static let foldersCollapsed = "octomux.inbox.foldersCollapsed"
    static let hidden = "octomux.inbox.hidden"                 // repos / Jira projects kept out of the Inbox
    static let seen = "octomux.inbox.seen"                     // item id → updated (unix seconds) when last read
    static let links = "octomux.inbox.links"                   // item id → session id
    static let placeProject = "octomux.inbox.placeProject"     // repo / Jira project → Octomux project id

    static func bool(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
}

// MARK: - Store

final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    /// What the Inbox shows: everything fetched but the hidden repos and projects.
    @Published private(set) var items: [InboxItem] = []
    /// Everything the last refresh found, hidden places too.
    private var fetched: [InboxItem] = []
    @Published private(set) var hidden: Set<String>
    /// Repos and Jira projects seen in the last refresh (hidden ones too), for Settings.
    var places: [(place: String, source: InboxSource)] {
        var seen = Set<String>(), out: [(String, InboxSource)] = []
        for i in fetched where seen.insert(i.place).inserted { out.append((i.place, i.source)) }
        return out.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    func setHidden(_ place: String, _ on: Bool) {
        if on { hidden.insert(place) } else { hidden.remove(place) }
        defaults.set(hidden.sorted(), forKey: InboxPrefs.hidden)
        items = fetched.filter { !hidden.contains($0.place) }
        if let s = selectedId, !items.contains(where: { $0.id == s }) { selectedId = nil }
    }
    @Published var selectedId: String?
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [InboxSource: String] = [:]
    @Published private(set) var comments: [String: [InboxItem.Comment]] = [:]
    @Published private(set) var seen: [String: Double]
    @Published private(set) var links: [String: String]
    @Published var githubLogin: String?
    @Published var jiraProjects: [(id: String, key: String, name: String)] = []

    /// Where notifications go (tests catch them).
    var deliver: (AppNotification) -> Void = { Notifier.shared.deliver($0) }
    private var timer: Timer?
    private var lastFetch = Date.distantPast
    /// What the last refresh saw (id → updated), to tell new and changed items apart for notifications.
    private var known: [String: Double] = [:]
    private var knownChecks: [String: InboxItem.Checks] = [:]
    private var knownStatus: [String: String] = [:]
    private var readOnNextRefresh: Set<String> = []
    private var quietNext: Set<InboxSource> = []
    private var primed: Set<InboxSource> = []

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: InboxPrefs.hidden) ?? [])
        seen = defaults.dictionary(forKey: InboxPrefs.seen) as? [String: Double] ?? [:]
        links = defaults.dictionary(forKey: InboxPrefs.links) as? [String: String] ?? [:]
    }

    var githubOn: Bool { InboxPrefs.bool(InboxPrefs.githubOn, false) }
    var jiraOn: Bool { JiraClient.configured }
    var anyConnected: Bool { githubOn || jiraOn }

    func isUnread(_ i: InboxItem) -> Bool { (seen[i.id] ?? 0) < i.updated.timeIntervalSince1970 }
    var unreadCount: Int { items.filter(isUnread).count }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        refresh()
    }

    private func tick() {
        let minutes = max(1, defaults.integer(forKey: InboxPrefs.poll).nonZero ?? 2)
        let every = Double(minutes) * 60 * (NSApp.isActive ? 1 : 2.5)
        if Date().timeIntervalSince(lastFetch) >= every { refresh() }
    }

    func select(_ id: String?) {
        selectedId = id
        guard let id, let item = items.first(where: { $0.id == id }) else { return }
        loadComments(item)
        // Read once it has been on screen for a moment (arrowing past it does not count).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.selectedId == id else { return }
            self.markRead(item)
        }
    }

    func markRead(_ i: InboxItem) { setSeen([i.id: i.updated.timeIntervalSince1970]) }
    func markUnread(_ i: InboxItem) { setSeen([i.id: 0]) }
    func markAllRead() { setSeen(Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.updated.timeIntervalSince1970) })) }

    private func setSeen(_ v: [String: Double]) {
        seen.merge(v) { _, b in b }
        defaults.set(seen, forKey: InboxPrefs.seen)
    }

    /// Forgets read marks of items no longer listed that were last updated two months ago or more (the map would
    /// only grow). Newer ones stay, so an item that drops out for a while (a search turned off) comes back read.
    private func pruneSeen(live: Set<String>) {
        let cutoff = Date().timeIntervalSince1970 - 60 * 86400
        let kept = seen.filter { live.contains($0.key) || $0.value > cutoff || $0.value == 0 }
        if kept.count != seen.count { seen = kept; defaults.set(seen, forKey: InboxPrefs.seen) }
    }

    func link(_ itemId: String, session: String) {
        links[itemId] = session
        defaults.set(links, forKey: InboxPrefs.links)
    }

    func linkedSession(_ i: InboxItem) -> Session? {
        guard let id = links[i.id] else { return nil }
        return AppModel.shared.session(id)
    }

    // MARK: Refresh

    /// `widened`: the user just changed what is fetched (a bell, a scope, a project, a search). What that brings in
    /// is not news: it comes in read and rings nothing.
    /// Each source fetches on its own: Jira waiting on a Keychain prompt or a slow network does not hold GitHub.
    func refresh(widened: Bool = false) {
        if widened { widen() }
        lastFetch = Date()
        let on: [InboxSource: Bool] = [.github: githubOn, .jira: jiraOn]
        // A source turned off leaves.
        for (s, v) in on where !v && fetched.contains(where: { $0.source == s }) {
            fetched.removeAll { $0.source == s }; errors[s] = nil; primed.remove(s)
            items = fetched.filter { !hidden.contains($0.place) }
        }
        if !on.values.contains(true) { errors = [:] }
        for (s, v) in on where v {
            if inFlight.contains(s) { if widened { pending.insert(s) }; continue }
            inFlight.insert(s)
            refreshing = true
            if s == .github { fetchGitHub() } else { fetchJira() }
        }
    }

    private func fetchGitHub() {
        let m = AppModel.shared
        let local = m.projects.filter { !m.host(forPath: $0.path).0.isRemote }.map { ($0.id, $0.path) }
        DispatchQueue.global(qos: .utility).async {
            // Which local project is which GitHub repo (git runs here, never while a view is drawn).
            var repos: [String: String] = [:]
            for (id, path) in local {
                if let r = GitInfo.git(["remote", "get-url", "origin"], in: path).flatMap(PullRequest.githubRepo) { repos[r.lowercased()] = repos[r.lowercased()] ?? id }
            }
            let r = Result { try GitHubInbox.fetch() }
            DispatchQueue.main.async {
                self.repoProjects = repos
                if case .success(let v) = r { self.githubLogin = v.login }
                self.apply(.github, r.map(\.items))
            }
        }
    }

    private func fetchJira() {
        DispatchQueue.global(qos: .utility).async {
            let r = Result { try JiraClient.inbox() }
            DispatchQueue.main.async { self.apply(.jira, r) }
        }
    }

    /// The next refresh of every source brings things in read and quiet (see `refresh(widened:)`).
    func widen() { quietNext.formUnion(InboxSource.allCases) }

    private var inFlight: Set<InboxSource> = []
    private var pending: Set<InboxSource> = []

    /// One source's refresh. Internal (not private) for tests.
    func apply(_ source: InboxSource, _ result: Result<[InboxItem], Error>) {
        inFlight.remove(source)
        refreshing = !inFlight.isEmpty
        lastRefresh = Date()
        let found: [InboxItem]
        switch result {
        case .success(let v):
            found = v
            errors[source] = nil
        case .failure(let e):
            // A source that failed keeps its last items (a rate limit or a dropped network should not empty the list).
            errors[source] = "\(e)"
            finish(source)
            return
        }
        var next = fetched.filter { $0.source != source } + found
        next.sort { $0.updated > $1.updated }
        let mine = next.filter { $0.source == source }
        // First successful fetch of a source ever: what is there now counts as read.
        if !primed.contains(source), !seen.keys.contains(where: { $0.hasPrefix(source == .github ? "gh:" : "jira:") }) {
            setSeen(Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0.updated.timeIntervalSince1970) }))
        }
        // Brought in by a change of what is fetched: read, and no news.
        if quietNext.remove(source) != nil, primed.contains(source) {
            var q: [String: Double] = [:]
            for i in mine where known[i.id] == nil {
                q[i.id] = i.updated.timeIntervalSince1970
                known[i.id] = i.updated.timeIntervalSince1970; knownStatus[i.id] = i.status
            }
            if !q.isEmpty { setSeen(q) }
        }
        let own = readOnNextRefresh.intersection(mine.map(\.id))
        readOnNextRefresh.subtract(own)
        let ownSeen = Dictionary(uniqueKeysWithValues: mine.filter { own.contains($0.id) }.map { ($0.id, $0.updated.timeIntervalSince1970) })
        if !ownSeen.isEmpty { setSeen(ownSeen) }
        fetched = next
        notify(mine.filter { !hidden.contains($0.place) }, sources: [source])
        // Hidden ones count as seen by the notifier too: showing a repo again does not ring for all of it.
        for i in mine where hidden.contains(i.place) { known[i.id] = i.updated.timeIntervalSince1970; knownStatus[i.id] = i.status }
        primed.insert(source)
        items = next.filter { !hidden.contains($0.place) }
        pruneSeen(live: Set(next.map(\.id)))
        if let s = selectedId, !items.contains(where: { $0.id == s }) { selectedId = nil }
        finish(source)
    }

    /// A change made while this source was fetching: fetch it again with that change.
    private func finish(_ source: InboxSource) {
        guard pending.remove(source) != nil else { return }
        DispatchQueue.main.async { self.refresh(widened: true) }
    }

    // MARK: Notifications

    private func notify(_ next: [InboxItem], sources: Set<InboxSource>) {
        defer {
            for i in next { known[i.id] = i.updated.timeIntervalSince1970; knownStatus[i.id] = i.status; if let c = i.checks { knownChecks[i.id] = c } }
        }
        var lines: [(String, String)] = []
        for i in next where sources.contains(i.source) && primed.contains(i.source) {
            guard isUnread(i) else { continue }
            let before = known[i.id]
            let isNew = before == nil
            let changed = before.map { $0 < i.updated.timeIntervalSince1970 } ?? false
            if i.reason == .mine, i.checks == .failing, knownChecks[i.id] != .failing, InboxPrefs.bool(InboxPrefs.nChecks, true) {
                lines.append(("Checks failed on \(i.key)", i.title))
            } else if isNew, i.reason == .review, InboxPrefs.bool(InboxPrefs.nReview, true) {
                lines.append(("Review requested: \(i.key)", i.title))
            } else if isNew, i.reason == .assigned, InboxPrefs.bool(InboxPrefs.nAssigned, true) {
                lines.append(("Assigned to you: \(i.key)", i.title))
            } else if i.reason == .project, isNew || changed, JiraClient.watched.contains(i.projectKey) {
                lines.append((isNew ? "New in \(i.place): \(i.key)" : change(i), i.title))
            } else if i.reason != .project, changed, InboxPrefs.bool(InboxPrefs.nUpdates, true) {
                lines.append((change(i), i.title))
            }
        }
        guard !lines.isEmpty else { return }
        let n = lines.count == 1
            ? AppNotification(sessionId: "", projectId: "", kind: "inbox", title: lines[0].0, body: lines[0].1)
            : AppNotification(sessionId: "", projectId: "", kind: "inbox", title: "\(lines.count) new in your Inbox",
                              body: lines.prefix(3).map(\.0).joined(separator: " · "))
        deliver(n)
    }

    /// "DC-12 → Code Review" when the status moved, else "DC-12 updated" (a comment, a field, new commits).
    private func change(_ i: InboxItem) -> String {
        if let old = knownStatus[i.id], old != i.status, !i.status.isEmpty { return "\(i.key) → \(i.status)" }
        return "\(i.key) updated"
    }

    // MARK: Details

    func loadComments(_ i: InboxItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let c = (try? (i.source == .github ? GitHubInbox.comments(i) : JiraClient.comments(i.key))) ?? []
            DispatchQueue.main.async { self.comments[i.id] = c }
        }
    }

    func postComment(_ i: InboxItem, _ text: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do {
                if i.source == .github { try GitHubInbox.comment(i, text) } else { try JiraClient.addComment(i.key, text) }
            } catch { err = "\(error)" }
            DispatchQueue.main.async {
                done(err)
                if err == nil {
                    self.loadComments(i)
                    // Your own comment is no news: what the next refresh sees of this item counts as read.
                    self.readOnNextRefresh.insert(i.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
                }
            }
        }
    }

    // MARK: Projects

    /// The Octomux project an item's agent works in: the last one picked for its repo / Jira project, else the
    /// project whose origin is that GitHub repo.
    func project(for i: InboxItem) -> Project? {
        let m = AppModel.shared
        let chosen = defaults.dictionary(forKey: InboxPrefs.placeProject) as? [String: String] ?? [:]
        if let id = chosen[i.place], let p = m.project(id) { return p }
        if let repo = i.repo, let id = repoProjects[repo.lowercased()], let p = m.project(id) { return p }
        return nil
    }

    func choose(_ p: Project, for i: InboxItem) {
        var chosen = defaults.dictionary(forKey: InboxPrefs.placeProject) as? [String: String] ?? [:]
        chosen[i.place] = p.id
        defaults.set(chosen, forKey: InboxPrefs.placeProject)
        objectWillChange.send()
    }

    /// GitHub repo (lowercased owner/name) → the local project whose origin it is; filled by `refresh`.
    @Published private(set) var repoProjects: [String: String] = [:]
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

struct InboxError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: - Shell (gh lives on the login shell's PATH)

enum InboxShell {
    static func run(_ args: [String], input: String? = nil, cwd: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", "exec " + args.map(\.shellQuoted).joined(separator: " ")]
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let inp = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = err
        try p.run()
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        // Read both pipes while it runs (a full pipe would block gh).
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw InboxError(msg.isEmpty ? "\(args.first ?? "") exited with \(p.terminationStatus)" : msg)
        }
        return String(decoding: o, as: UTF8.self)
    }
}

// MARK: - GitHub (gh api graphql)

enum GitHubInbox {
    /// Signed-in login, or an error saying what is wrong (no gh, not signed in).
    static func status() -> Result<String, InboxError> {
        do {
            let login = try InboxShell.run(["gh", "api", "user", "--jq", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return login.isEmpty ? .failure(InboxError("gh returned no user")) : .success(login)
        } catch {
            let s = "\(error)"
            if s.contains("command not found") || s.contains("no such file") { return .failure(InboxError("The GitHub CLI (gh) is not installed. brew install gh")) }
            if s.contains("auth login") || s.contains("401") { return .failure(InboxError("gh is not signed in. Run gh auth login in a terminal.")) }
            return .failure(InboxError(s))
        }
    }

    static let prFields = """
    number title url updatedAt isDraft state headRefName body
    repository { nameWithOwner } author { login } assignees(first: 3) { nodes { login } }
    commits(last: 1) { nodes { commit { statusCheckRollup { state
      contexts(first: 80) { nodes { __typename ... on CheckRun { name conclusion status } ... on StatusContext { context state } } } } } } }
    """
    static let issueFields = "number title url updatedAt state body repository { nameWithOwner } author { login } assignees(first: 3) { nodes { login } }"

    static func searches() -> [(alias: String, reason: InboxItem.Reason, query: String)] {
        var s: [(String, InboxItem.Reason, String)] = []
        if InboxPrefs.bool(InboxPrefs.ghReview, true) { s.append(("review", .review, "is:pr is:open archived:false review-requested:@me")) }
        if InboxPrefs.bool(InboxPrefs.ghMine, true) { s.append(("mine", .mine, "is:pr is:open archived:false author:@me")) }
        if InboxPrefs.bool(InboxPrefs.ghAssigned, true) { s.append(("assigned", .assigned, "is:open archived:false assignee:@me")) }
        if InboxPrefs.bool(InboxPrefs.ghMention, false) { s.append(("mention", .mention, "is:open archived:false mentions:@me")) }
        return s
    }

    static func query() -> String {
        let parts = searches().map { s in
            "\(s.alias): search(query: \"\(s.query) sort:updated-desc\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(prFields) } ... on Issue { \(issueFields) } } }"
        }
        return "query { viewer { login } \(parts.joined(separator: " ")) }"
    }

    static func fetch() throws -> (items: [InboxItem], login: String) {
        let out = try InboxShell.run(["gh", "api", "graphql", "-f", "query=\(query())"])
        return try parse(Data(out.utf8), searches: searches().map { ($0.alias, $0.reason) })
    }

    /// Items of a GraphQL search response; an item found by several searches keeps the earliest reason.
    static func parse(_ data: Data, searches: [(alias: String, reason: InboxItem.Reason)]) throws -> (items: [InboxItem], login: String) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InboxError("GitHub sent no JSON") }
        if let errs = root["errors"] as? [[String: Any]], root["data"] == nil {
            throw InboxError(errs.compactMap { $0["message"] as? String }.joined(separator: "; "))
        }
        let d = root["data"] as? [String: Any] ?? [:]
        let login = (d["viewer"] as? [String: Any])?["login"] as? String ?? ""
        var byId: [String: InboxItem] = [:]
        var order: [String] = []
        for s in searches {
            let nodes = ((d[s.alias] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for n in nodes {
                guard var item = item(n, reason: s.reason, me: login) else { continue }
                if let old = byId[item.id] { item.reason = old.reason } else { order.append(item.id) }
                byId[item.id] = item
            }
        }
        return (order.compactMap { byId[$0] }, login)
    }

    static func item(_ n: [String: Any], reason: InboxItem.Reason, me: String) -> InboxItem? {
        guard let number = n["number"] as? Int, let title = n["title"] as? String, let url = n["url"] as? String,
              let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
        let isPR = n["headRefName"] != nil || url.contains("/pull/")
        let author = (n["author"] as? [String: Any])?["login"] as? String ?? "ghost"
        let assignees = ((n["assignees"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        let draft = n["isDraft"] as? Bool ?? false
        var item = InboxItem(
            id: "gh:\(repo.lowercased())#\(number)", source: .github, kind: isPR ? .pr : .issue, key: "#\(number)", place: repo,
            title: title, author: author == me ? "You" : author,
            assignee: assignees.first.map { $0 == me ? "You" : $0 },
            status: draft ? "Draft" : "Open", statusTone: draft ? "todo" : "done", reason: reason,
            updated: InboxDates.iso(n["updatedAt"] as? String) ?? Date(), body: n["body"] as? String ?? "", url: url,
            branch: n["headRefName"] as? String, number: number)
        if isPR, let rollup = ((((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]) {
            var passed = 0, failed = 0, pending = 0
            var failedNames: [String] = []
            for c in ((rollup["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                let name = c["name"] as? String ?? c["context"] as? String ?? "check"
                let v = ((c["conclusion"] as? String) ?? (c["state"] as? String) ?? "").uppercased()
                let st = (c["status"] as? String ?? "").uppercased()
                if st == "IN_PROGRESS" || st == "QUEUED" || st == "PENDING" || v == "PENDING" || v == "EXPECTED" || (v.isEmpty && st != "COMPLETED") { pending += 1 }
                else if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(v) { failed += 1; failedNames.append(name) }
                else { passed += 1 }
            }
            item.checkCounts = (passed, failed, pending)
            item.failedChecks = failedNames
            switch (rollup["state"] as? String ?? "").uppercased() {
            case "SUCCESS": item.checks = .passing
            case "FAILURE", "ERROR": item.checks = .failing
            default: item.checks = failed > 0 ? .failing : .pending
            }
        }
        return item
    }

    static func comments(_ i: InboxItem) throws -> [InboxItem.Comment] {
        guard let repo = i.repo, let number = i.number else { return [] }
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return [] }
        let q = """
        query($o: String!, $n: String!, $num: Int!) { repository(owner: $o, name: $n) { issueOrPullRequest(number: $num) {
          ... on Issue { comments(last: 30) { nodes { author { login } body createdAt } } }
          ... on PullRequest { comments(last: 30) { nodes { author { login } body createdAt } } } } } }
        """
        let out = try InboxShell.run(["gh", "api", "graphql", "-f", "query=\(q)", "-F", "o=\(parts[0])", "-F", "n=\(parts[1])", "-F", "num=\(number)"])
        guard let root = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let node = (((root["data"] as? [String: Any])?["repository"] as? [String: Any])?["issueOrPullRequest"] as? [String: Any]),
              let nodes = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return [] }
        return nodes.map {
            InboxItem.Comment(author: ($0["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                              date: InboxDates.iso($0["createdAt"] as? String), text: $0["body"] as? String ?? "")
        }
    }

    static func comment(_ i: InboxItem, _ text: String) throws {
        guard let repo = i.repo, let number = i.number else { return }
        _ = try InboxShell.run(["gh", i.kind == .pr ? "pr" : "issue", "comment", "\(number)", "--repo", repo, "--body-file", "-"], input: text)
    }
}

enum InboxDates {
    private static let isoF: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    /// Jira: 2024-05-01T10:00:00.000+0300
    private static let jira: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f
    }()
    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoF.date(from: s) ?? isoFrac.date(from: s) ?? jira.date(from: s)
    }
}

// MARK: - Keychain

/// Secrets in the login keychain, one generic-password item per account.
/// - The app that created an item reads it without asking (its signature is on the item's access list). A rebuilt
///   debug binary is another app to macOS and is asked once ("Always Allow").
/// - This device only, readable after the first unlock (the Inbox polls in the background); never synced.
/// - Updated in place (deleting and re-adding would drop "Always Allow").
/// - Callers keep reads off the main thread: a read can wait on securityd or a prompt.
/// - Not the data protection keychain: it ties items to the app's keychain access group, which needs a provisioning
///   profile with a keychain entitlement; without one an unsigned build's items are lost to the next build.
enum InboxKeychain {
    static let service = "Octomux Inbox"
    private static let lock = NSLock()

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data else {
            if st != errSecItemNotFound { NSLog("Octomux Inbox: Keychain read failed (\(st))") }
            return nil
        }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult static func set(_ account: String, _ value: String, label: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let q = base(account)
        var attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                    kSecAttrDescription as String: "Octomux Inbox token"]
        if let label { attrs[kSecAttrLabel as String] = label }
        var st = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound { st = SecItemAdd(q.merging(attrs) { _, b in b } as CFDictionary, nil) }
        if st != errSecSuccess { NSLog("Octomux Inbox: Keychain write failed (\(st))") }
        return st == errSecSuccess
    }

    static func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(base(account) as CFDictionary)
    }
}

// MARK: - Jira Cloud (REST v3, basic auth with email + API token)

enum JiraClient {
    static var site: String? { UserDefaults.standard.string(forKey: InboxPrefs.jiraSite) }
    static var email: String? { UserDefaults.standard.string(forKey: InboxPrefs.jiraEmail) }
    /// Read from the Keychain once per launch (each read may ask for the login password), kept in memory after.
    private static var cachedToken: String??
    private static let tokenLock = NSLock()
    static var token: String? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if let t = cachedToken { return t }
        // Only a token found is kept: a read that failed (a prompt dismissed) is tried again on the next refresh.
        let t = site.flatMap { InboxKeychain.get("jira:" + $0) }
        if t != nil { cachedToken = .some(t) }
        return t
    }
    private static func setCachedToken(_ t: String?) { tokenLock.lock(); cachedToken = .some(t); tokenLock.unlock() }
    /// Connected once: the base is only saved after a successful connect. Does not touch the Keychain.
    static var configured: Bool { site != nil && email != nil && UserDefaults.standard.string(forKey: InboxPrefs.jiraBase) != nil }

    /// "mycompany", "mycompany.atlassian.net" or a full URL → https://mycompany.atlassian.net
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("http://") { t = String(t.dropFirst(7)) }
        if t.hasPrefix("https://") { t = String(t.dropFirst(8)) }
        t = String(t.split(separator: "/").first ?? "")
        if !t.isEmpty, !t.contains(".") { t += ".atlassian.net" }
        return t.isEmpty ? "" : "https://" + t
    }

    /// Checks the credentials and saves them. A token without scopes works on the site itself; one with scopes only
    /// through the API gateway (api.atlassian.com/ex/jira/<cloud id>), so the site is tried first, then the gateway.
    static func connect(site raw: String, email: String, token: String) throws -> String {
        let site = normalize(raw)
        guard !site.isEmpty else { throw InboxError("Enter your Jira site, like mycompany.atlassian.net") }
        let mail = email.trimmingCharacters(in: .whitespaces), tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mail.isEmpty, !tok.isEmpty else { throw InboxError("Enter your Atlassian email and an API token.") }
        var base = site
        var me: [String: Any]
        do {
            me = try object(request("/rest/api/3/myself", base: base, email: mail, token: tok))
        } catch let first {
            guard let cloud = try? cloudId(site) else { throw first }
            base = "https://api.atlassian.com/ex/jira/\(cloud)"
            do { me = try object(request("/rest/api/3/myself", base: base, email: mail, token: tok)) }
            catch { throw first }
        }
        let d = UserDefaults.standard
        if let old = self.site, old != site { InboxKeychain.delete("jira:" + old) }
        guard InboxKeychain.set("jira:" + site, tok, label: "Octomux Inbox: Jira (\(site.replacingOccurrences(of: "https://", with: "")))") else {
            throw InboxError("Couldn't save the token to the Keychain.")
        }
        setCachedToken(tok)
        d.set(site, forKey: InboxPrefs.jiraSite)
        d.set(mail, forKey: InboxPrefs.jiraEmail)
        d.set(base, forKey: InboxPrefs.jiraBase)
        return me["displayName"] as? String ?? mail
    }

    static func disconnect() {
        if let s = site { InboxKeychain.delete("jira:" + s) }
        setCachedToken(nil)
        for k in [InboxPrefs.jiraSite, InboxPrefs.jiraEmail, InboxPrefs.jiraBase] { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// The site's cloud id, from its public tenant info.
    static func cloudId(_ site: String) throws -> String {
        guard let url = URL(string: site + "/_edge/tenant_info") else { throw InboxError("Bad site") }
        let (data, _) = try sync(URLRequest(url: url))
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cloudId"] as? String else { throw InboxError("No cloud id for \(site)") }
        return id
    }

    static func request(_ path: String, method: String = "GET", body: Any? = nil,
                        base: String? = nil, email: String? = nil, token: String? = nil) throws -> Data {
        guard let b = base ?? UserDefaults.standard.string(forKey: InboxPrefs.jiraBase) ?? site,
              let mail = email ?? self.email, let tok = token ?? self.token, let url = URL(string: b + path) else {
            throw InboxError(configured ? "Couldn't read the Jira token from the Keychain. Connect again in Settings → Inbox." : "Jira is not connected.")
        }
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.httpMethod = method
        r.setValue("Basic " + Data("\(mail):\(tok)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try sync(r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var msg = ""
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                msg = ((o["errorMessages"] as? [String]) ?? []).joined(separator: "; ")
                if msg.isEmpty, let m = o["message"] as? String { msg = m }
            }
            switch code {
            case 401: throw InboxError("Jira refused the email or API token (401)." + (msg.isEmpty ? "" : " " + msg))
            case 403: throw InboxError("The token may not read this (403). A token with scopes needs read:jira-work and read:jira-user." + (msg.isEmpty ? "" : " " + msg))
            default: throw InboxError("Jira answered \(code)." + (msg.isEmpty ? "" : " " + msg))
            }
        }
        return data
    }

    private static func sync(_ r: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error> = .failure(InboxError("No answer"))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: r) { d, resp, e in
            if let e { result = .failure(InboxError(e.localizedDescription)) }
            else if let d, let resp { result = .success((d, resp)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    private static func object(_ d: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw InboxError("Jira sent no JSON") }
        return o
    }

    static func projects() throws -> [(id: String, key: String, name: String)] {
        var out: [(String, String, String)] = []
        var start = 0
        while true {
            let o = try object(request("/rest/api/3/project/search?maxResults=100&orderBy=name&startAt=\(start)"))
            let values = o["values"] as? [[String: Any]] ?? []
            out += values.compactMap { v in
                guard let id = v["id"] as? String, let key = v["key"] as? String else { return nil }
                return (id, key, ((v["name"] as? String) ?? key).htmlUnescaped)
            }
            if (o["isLast"] as? Bool) ?? true || values.isEmpty || out.count >= 1000 { break }
            start += values.count
        }
        return out
    }

    static var pickedProjects: [String] {
        (UserDefaults.standard.string(forKey: InboxPrefs.jiraProjects) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Projects with the bell on: every open issue of them is fetched (even in "assigned to me"), and any change notifies.
    static var watched: Set<String> {
        Set((UserDefaults.standard.string(forKey: InboxPrefs.jiraWatched) ?? "").split(separator: ",").map(String.init))
    }

    static func setWatched(_ key: String, _ on: Bool) {
        var w = watched
        if on {
            w.insert(key)
            // A watched project is a ticked one.
            var p = Set(pickedProjects)
            if !p.isEmpty, !p.contains(key) { p.insert(key); UserDefaults.standard.set(p.sorted().joined(separator: ","), forKey: InboxPrefs.jiraProjects) }
        } else { w.remove(key) }
        UserDefaults.standard.set(w.sorted().joined(separator: ","), forKey: InboxPrefs.jiraWatched)
    }

    /// Open issues: in `projects` (all when empty), assigned to me when `assignedOnly`; plus every open one of `watched`.
    static func jql(assignedOnly: Bool, projects: [String], watched: [String] = []) -> String {
        func inList(_ p: [String]) -> String { "project in (\(p.map { "\"\($0)\"" }.joined(separator: ", ")))" }
        var mine: [String] = []
        if !projects.isEmpty { mine.append(inList(projects)) }
        if assignedOnly { mine.append("assignee = currentUser()") }
        var scope = mine.joined(separator: " AND ")
        if assignedOnly, !watched.isEmpty { scope = "(\(scope) OR \(inList(watched)))" }
        return (scope.isEmpty ? "" : scope + " AND ") + "statusCategory != Done ORDER BY updated DESC"
    }

    static func inbox() throws -> [InboxItem] {
        let picked = pickedProjects
        let all = (UserDefaults.standard.string(forKey: InboxPrefs.jiraScope) ?? "assigned") == "all"
        // Everything open in every project is too much: "all" needs picked projects.
        let w = watched.filter { picked.isEmpty || picked.contains($0) }.sorted()
        let body: [String: Any] = ["jql": jql(assignedOnly: !all || picked.isEmpty, projects: picked, watched: w), "maxResults": 60,
                                   "fields": ["summary", "status", "assignee", "reporter", "updated", "project", "issuetype", "description"]]
        let o = try object(request("/rest/api/3/search/jql", method: "POST", body: body))
        let me = try? object(request("/rest/api/3/myself"))
        return parse(o, me: me?["accountId"] as? String)
    }

    static func parse(_ o: [String: Any], me: String?) -> [InboxItem] {
        let site = self.site ?? ""
        return (o["issues"] as? [[String: Any]] ?? []).compactMap { i in
            guard let key = i["key"] as? String, let f = i["fields"] as? [String: Any] else { return nil }
            let assignee = f["assignee"] as? [String: Any]
            let mine = me != nil && (assignee?["accountId"] as? String) == me
            let status = f["status"] as? [String: Any]
            let cat = (status?["statusCategory"] as? [String: Any])?["key"] as? String ?? "new"
            return InboxItem(
                id: "jira:\(key)", source: .jira, kind: .issue, key: key,
                place: ((f["project"] as? [String: Any])?["name"] as? String ?? key.split(separator: "-").first.map(String.init) ?? "").htmlUnescaped,
                title: f["summary"] as? String ?? key,
                author: (f["reporter"] as? [String: Any])?["displayName"] as? String ?? "",
                assignee: mine ? "You" : assignee?["displayName"] as? String,
                status: status?["name"] as? String ?? "", statusTone: cat == "done" ? "done" : cat == "indeterminate" ? "progress" : "todo",
                reason: mine ? .assigned : .project,
                updated: InboxDates.iso(f["updated"] as? String) ?? Date(),
                body: ADF.text(f["description"]), url: "\(site)/browse/\(key)")
        }
    }

    static func comments(_ key: String) throws -> [InboxItem.Comment] {
        let o = try object(request("/rest/api/3/issue/\(key)/comment?orderBy=created&maxResults=50"))
        return (o["comments"] as? [[String: Any]] ?? []).map {
            InboxItem.Comment(author: ($0["author"] as? [String: Any])?["displayName"] as? String ?? "",
                              date: InboxDates.iso($0["created"] as? String), text: ADF.text($0["body"]))
        }
    }

    static func addComment(_ key: String, _ text: String) throws {
        _ = try request("/rest/api/3/issue/\(key)/comment", method: "POST", body: ["body": ADF.doc(text)])
    }
}

/// Atlassian Document Format (Jira descriptions and comments) to Markdown-ish text, and plain text to ADF.
enum ADF {
    static func text(_ node: Any?) -> String {
        if let s = node as? String { return s }
        guard let n = node as? [String: Any] else { return "" }
        var out = ""
        render(n, into: &out, list: nil, depth: 0)
        return out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ n: [String: Any], into out: inout String, list: String?, depth: Int) {
        let type = n["type"] as? String ?? ""
        let kids = n["content"] as? [[String: Any]] ?? []
        func inline() -> String { var s = ""; for k in kids { render(k, into: &s, list: nil, depth: depth) }; return s }
        switch type {
        case "text":
            var t = n["text"] as? String ?? ""
            for m in n["marks"] as? [[String: Any]] ?? [] {
                switch m["type"] as? String {
                case "strong": t = "**\(t)**"
                case "em": t = "*\(t)*"
                case "code": t = "`\(t)`"
                case "link": if let href = (m["attrs"] as? [String: Any])?["href"] as? String, href != t { t = "[\(t)](\(href))" }
                default: break
                }
            }
            out += t
        case "hardBreak": out += "\n"
        case "mention": out += (n["attrs"] as? [String: Any])?["text"] as? String ?? "@someone"
        case "emoji": out += (n["attrs"] as? [String: Any])?["text"] as? String ?? ""
        case "inlineCard", "blockCard": out += (n["attrs"] as? [String: Any])?["url"] as? String ?? ""
        case "paragraph": out += inline() + "\n\n"
        case "heading": out += "**" + inline() + "**\n\n"
        case "bulletList", "orderedList":
            for (i, k) in kids.enumerated() {
                render(k, into: &out, list: type == "bulletList" ? "-" : "\(i + 1).", depth: depth)
            }
            if depth == 0 { out += "\n" }
        case "listItem":
            // The item's own text on the marker line, nested lists on the lines under it.
            var parts: [String] = []
            for k in kids {
                var s = ""
                render(k, into: &s, list: nil, depth: depth + 1)
                let t = s.trimmingCharacters(in: .newlines)
                if !t.isEmpty { parts.append(["bulletList", "orderedList"].contains(k["type"] as? String) ? t : t.trimmingCharacters(in: .whitespaces)) }
            }
            let pad = String(repeating: "  ", count: depth)
            out += pad + (list ?? "-") + " " + parts.joined(separator: "\n") + "\n"
        case "codeBlock": out += "```\n" + inline() + "\n```\n\n"
        case "blockquote": out += inline().split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "rule": out += "---\n\n"
        case "mediaSingle", "mediaGroup", "media": out += "[attachment]\n\n"
        case "table":
            for row in kids {
                let cells = (row["content"] as? [[String: Any]] ?? []).map { c -> String in var s = ""; render(c, into: &s, list: nil, depth: depth); return s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
                out += "| " + cells.joined(separator: " | ") + " |\n"
            }
            out += "\n"
        default: out += inline()
        }
    }

    /// Plain text (paragraphs split on blank lines) as an ADF document.
    static func doc(_ text: String) -> [String: Any] {
        let paras = text.components(separatedBy: "\n\n").map { p -> [String: Any] in
            let lines = p.components(separatedBy: "\n")
            var content: [[String: Any]] = []
            for (i, l) in lines.enumerated() {
                if i > 0 { content.append(["type": "hardBreak"]) }
                if !l.isEmpty { content.append(["type": "text", "text": l]) }
            }
            return ["type": "paragraph", "content": content]
        }
        return ["type": "doc", "version": 1, "content": paras]
    }
}

extension String {
    /// Jira keeps some names HTML-escaped ("Crawler &amp; Updater").
    var htmlUnescaped: String {
        guard contains("&") else { return self }
        var t = self
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }
}
