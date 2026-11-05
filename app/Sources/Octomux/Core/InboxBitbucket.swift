import Foundation

// Bitbucket Cloud in the Inbox: pull requests that wait for your review and your own ones, read through the REST API
// (2.0) with an Atlassian API token that has Bitbucket scopes. The token is in the Keychain and goes only to
// api.bitbucket.org.
//
// Bitbucket has no call that lists every pull request you review across a workspace, so those are found repo by repo:
// the repos updated lately (and the ones of your local projects) are scanned every few minutes, and the repos that
// already hold one of your items on every refresh. A user's API token gets about 1,000 requests an hour, so the scan
// keeps a budget and slows down when Bitbucket says so (429).

extension InboxPrefs {
    static let bbAuth = "octomux.inbox.bb.auth"                 // bearer | basic, saved by a successful connect
    static let bbEmail = "octomux.inbox.bb.email"               // basic auth only
    static let bbAccount = "octomux.inbox.bb.account"           // your account id
    static let bbUuid = "octomux.inbox.bb.uuid"                 // your user uuid ("{…}")
    static let bbName = "octomux.inbox.bb.name"
    static let bbSkipped = "octomux.inbox.bb.skipped"           // workspace slugs kept out (comma-separated)
    static let bbReview = "octomux.inbox.bb.review"
    static let bbMine = "octomux.inbox.bb.mine"
    static let bbSweepAll = "octomux.inbox.bb.sweepAll"         // look for review requests in every repo, not only lately updated ones
    static let bbUserForm = "octomux.inbox.bb.userForm"         // account | uuid: what the workspace pull request list takes
    static let bbReviewFilter = "octomux.inbox.bb.reviewFilter" // server | client: whether Bitbucket filters by reviewer
    static let bbApprovedHead = "octomux.inbox.bb.approvedHead" // pr id → the commit you approved (it leaves Review requested until a new one)
}

/// Bitbucket said to slow down: nothing is asked again before `until`.
struct BitbucketRateLimit: Error, CustomStringConvertible {
    let until: Date
    var description: String {
        let f = DateFormatter(); f.timeStyle = .short
        return "Bitbucket asked to slow down; checking again at \(f.string(from: until))."
    }
}

/// An answer other than 2xx.
struct BitbucketHTTPError: Error, CustomStringConvertible {
    let code: Int
    let message: String
    var description: String {
        switch code {
        case 401: return "Bitbucket refused the token (401)." + (message.isEmpty ? "" : " " + message)
        case 403: return "The token may not read this (403). It needs read:user, read:workspace, read:repository and read:pullrequest (all :bitbucket)." + (message.isEmpty ? "" : " " + message)
        default: return "Bitbucket answered \(code)." + (message.isEmpty ? "" : " " + message)
        }
    }
}

enum BitbucketClient {
    static let api = "https://api.bitbucket.org/2.0"
    static let host = "api.bitbucket.org"
    static let keychainAccount = "bitbucket"

    struct Me: Equatable { var accountId: String; var uuid: String; var name: String }

    static var configured: Bool { UserDefaults.standard.string(forKey: InboxPrefs.bbAuth) != nil }
    static var email: String? { UserDefaults.standard.string(forKey: InboxPrefs.bbEmail) }
    static var savedMe: Me? {
        let d = UserDefaults.standard
        guard let a = d.string(forKey: InboxPrefs.bbAccount) else { return nil }
        return Me(accountId: a, uuid: d.string(forKey: InboxPrefs.bbUuid) ?? "", name: d.string(forKey: InboxPrefs.bbName) ?? "")
    }

    /// Read from the Keychain once per launch, kept in memory after (like Jira's).
    private static var cachedToken: String??
    private static let tokenLock = NSLock()
    static var token: String? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if let t = cachedToken { return t }
        guard configured else { return nil }
        let t = InboxKeychain.get(keychainAccount)
        if t != nil { cachedToken = .some(t) }
        return t
    }
    private static func setCachedToken(_ t: String?) { tokenLock.lock(); cachedToken = .some(t); tokenLock.unlock() }

    enum Auth: Equatable { case bearer, basic(String) }

    static func header(_ auth: Auth, _ token: String) -> String {
        switch auth {
        case .bearer: return "Bearer " + token
        case .basic(let email): return "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        }
    }

    /// The saved way in, or nil when not connected.
    static var savedAuth: Auth? {
        switch UserDefaults.standard.string(forKey: InboxPrefs.bbAuth) {
        case "bearer": return .bearer
        case "basic": return email.map { .basic($0) }
        default: return nil
        }
    }

    /// A path under the API ("/user") or a full URL Bitbucket handed back (a `next` page), on api.bitbucket.org only.
    static func url(_ pathOrURL: String) throws -> URL {
        let s = pathOrURL.contains("://") ? pathOrURL : api + pathOrURL
        guard let u = URL(string: s), u.scheme == "https", u.host?.lowercased() == host else { throw InboxError("Not a Bitbucket API address") }
        return u
    }

    /// One request with the saved token (or the given one while connecting).
    /// `range`: an HTTP Range (a log's tail). `logRedirect`: a step log answers with a redirect to its storage; that is
    /// followed without the token (the link carries its own signature).
    static func request(_ pathOrURL: String, method: String = "GET", body: Any? = nil, accept: String = "application/json",
                        auth: Auth? = nil, token: String? = nil, range: String? = nil, logRedirect: Bool = false) throws -> Data {
        guard let a = auth ?? savedAuth, let tok = token ?? self.token else {
            throw InboxError(configured ? "Couldn't read the Bitbucket token from the Keychain. Connect again in Settings → Inbox." : "Bitbucket is not connected.")
        }
        var r = URLRequest(url: try url(pathOrURL), timeoutInterval: 25)
        r.httpMethod = method
        r.setValue(header(a, tok), forHTTPHeaderField: "Authorization")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        BitbucketInbox.shared.counted()
        let (data, resp) = try sync(r, session: logRedirect ? logSession : session)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 429 {
            let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "").flatMap { $0 > 0 ? $0 : nil }
            throw BitbucketInbox.shared.slowDown(retryAfter: wait)
        }
        guard (200..<300).contains(code) else { throw BitbucketHTTPError(code: code, message: message(data)) }
        return data
    }

    /// Bitbucket's error text: {"type": "error", "error": {"message": "…"}}.
    static func message(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let e = o["error"] as? [String: Any]
        return (e?["message"] as? String ?? "") + ((e?["detail"] as? String).map { " " + $0 } ?? "")
    }

    /// Redirects are followed only to https on api.bitbucket.org (a diff answers with one), carrying the token there and nowhere else.
    private final class SameHost: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme == "https", request.url?.host?.lowercased() == BitbucketClient.host else { completionHandler(nil); return }
            var r = request
            r.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            completionHandler(r)
        }
    }

    /// Step logs: on api.bitbucket.org as above; a redirect elsewhere (https only) goes without the token.
    private final class LogRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme == "https" else { completionHandler(nil); return }
            var r = request
            let same = request.url?.host?.lowercased() == BitbucketClient.host
            r.setValue(same ? task.originalRequest?.value(forHTTPHeaderField: "Authorization") : nil, forHTTPHeaderField: "Authorization")
            r.setValue(task.originalRequest?.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
            completionHandler(r)
        }
    }

    private static func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        return c
    }
    private static let session = URLSession(configuration: config(), delegate: SameHost(), delegateQueue: nil)
    private static let logSession = URLSession(configuration: config(), delegate: LogRedirects(), delegateQueue: nil)

    private static func sync(_ r: URLRequest, session: URLSession) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error> = .failure(InboxError("No answer"))
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: r) { d, resp, e in
            if let e { result = .failure(InboxError(e.localizedDescription)) }
            else if let d, let resp { result = .success((d, resp)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    static func object(_ d: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw InboxError("Bitbucket sent no JSON") }
        return o
    }

    static func me(_ o: [String: Any]) -> Me? {
        guard let a = o["account_id"] as? String else { return nil }
        return Me(accountId: a, uuid: o["uuid"] as? String ?? "", name: o["display_name"] as? String ?? o["nickname"] as? String ?? "")
    }

    /// Thrown when the token alone (Bearer) is refused: Basic auth needs the account's email.
    struct NeedsEmail: Error, CustomStringConvertible {
        var description: String { "Bitbucket didn't take the token on its own. Enter your Atlassian account's email and connect again." }
    }

    /// Checks the token and saves it: Bearer first; when that is refused (401), email + token if an email is given.
    static func connect(token raw: String, email rawEmail: String) throws -> Me {
        let tok = raw.trimmingCharacters(in: .whitespacesAndNewlines), mail = rawEmail.trimmingCharacters(in: .whitespaces)
        guard !tok.isEmpty else { throw InboxError("Enter an API token.") }
        var auth = Auth.bearer
        var o: [String: Any]
        do {
            o = try object(request("/user", auth: .bearer, token: tok))
        } catch let e as BitbucketHTTPError where e.code == 401 {
            guard !mail.isEmpty else { throw NeedsEmail() }
            auth = .basic(mail)
            o = try object(request("/user", auth: auth, token: tok))
        }
        guard let me = me(o) else { throw InboxError("Bitbucket didn't say who you are.") }
        guard InboxKeychain.set(keychainAccount, tok, label: "Octomux Inbox: Bitbucket") else { throw InboxError("Couldn't save the token to the Keychain.") }
        setCachedToken(tok)
        let d = UserDefaults.standard
        if case .basic(let m) = auth { d.set("basic", forKey: InboxPrefs.bbAuth); d.set(m, forKey: InboxPrefs.bbEmail) }
        else { d.set("bearer", forKey: InboxPrefs.bbAuth); d.removeObject(forKey: InboxPrefs.bbEmail) }
        d.set(me.accountId, forKey: InboxPrefs.bbAccount)
        d.set(me.uuid, forKey: InboxPrefs.bbUuid)
        d.set(me.name, forKey: InboxPrefs.bbName)
        BitbucketInbox.shared.reset()
        return me
    }

    static func disconnect() {
        InboxKeychain.delete(keychainAccount)
        setCachedToken(nil)
        for k in [InboxPrefs.bbAuth, InboxPrefs.bbEmail, InboxPrefs.bbAccount, InboxPrefs.bbUuid, InboxPrefs.bbName,
                  InboxPrefs.bbUserForm, InboxPrefs.bbReviewFilter] { UserDefaults.standard.removeObject(forKey: k) }
        BitbucketInbox.shared.reset()
    }

    /// `owner/repo` of a Bitbucket remote (ssh, https, with or without a user and .git).
    static func repo(fromRemote url: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = u.range(of: "bitbucket.org[:/]", options: .regularExpression) { u = String(u[r.upperBound...]) } else { return nil }
        if u.hasSuffix(".git") { u = String(u.dropLast(4)) }
        let parts = u.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#\"{}")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    static func encPath(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "{}")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Pull requests as Inbox items

    /// Extra fields on list answers: who reviews and who approved, the description, draft. The `+` (add to the
    /// default fields) is sent encoded: a bare one reads as a space, and the answer then has only these fields.
    static let prFields = "%2Bvalues.participants,%2Bvalues.reviewers,%2Bvalues.summary,%2Bvalues.draft"

    static func item(_ pr: [String: Any], reason: InboxItem.Reason, me: String?) -> InboxItem? {
        guard let id = pr["id"] as? Int, let title = pr["title"] as? String else { return nil }
        let dest = pr["destination"] as? [String: Any], src = pr["source"] as? [String: Any]
        guard let repo = ((dest?["repository"] as? [String: Any])?["full_name"] as? String)
                ?? ((src?["repository"] as? [String: Any])?["full_name"] as? String) else { return nil }
        let author = pr["author"] as? [String: Any]
        let draft = pr["draft"] as? Bool ?? false
        let html = ((pr["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? "https://bitbucket.org/\(repo)/pull-requests/\(id)"
        var item = InboxItem(
            id: "bb:\(repo.lowercased())#\(id)", source: .bitbucket, kind: .pr, key: "#\(id)", place: repo, title: title,
            author: me != nil && (author?["account_id"] as? String) == me ? "You" : (author?["display_name"] as? String ?? "someone"),
            assignee: nil, status: draft ? "Draft" : "Open", statusTone: draft ? "todo" : "done", reason: reason,
            updated: InboxDates.iso(pr["updated_on"] as? String) ?? Date(),
            body: ((pr["summary"] as? [String: Any])?["raw"] as? String) ?? (pr["description"] as? String ?? ""), url: html,
            branch: (src?["branch"] as? [String: Any])?["name"] as? String, number: id,
            base: (dest?["branch"] as? [String: Any])?["name"] as? String)
        item.head = (src?["commit"] as? [String: Any])?["hash"] as? String
        item.commentCount = pr["comment_count"] as? Int
        for p in pr["participants"] as? [[String: Any]] ?? [] {
            let mine = me != nil && ((p["user"] as? [String: Any])?["account_id"] as? String) == me
            if p["approved"] as? Bool == true { item.approvals += 1; if mine { item.youApproved = true } }
            if (p["state"] as? String) == "changes_requested" { item.changesRequested += 1; if mine { item.youRequestedChanges = true } }
        }
        return item
    }

    /// Whether you are among the pull request's reviewers (for when Bitbucket can't filter by reviewer).
    static func isReviewer(_ pr: [String: Any], me: String) -> Bool {
        let reviewers = (pr["reviewers"] as? [[String: Any]] ?? []).compactMap { $0["account_id"] as? String }
        if reviewers.contains(me) { return true }
        return (pr["participants"] as? [[String: Any]] ?? []).contains {
            ($0["role"] as? String) == "REVIEWER" && (($0["user"] as? [String: Any])?["account_id"] as? String) == me
        }
    }

    /// Build statuses of a pull request as the Inbox's checks.
    struct Checks: Equatable {
        var state: InboxItem.Checks?
        var passed = 0, failed = 0, pending = 0
        var failedNames: [String] = []
        var failedDetails: [InboxItem.FailedCheck] = []
    }

    static func checks(_ values: [[String: Any]]) -> Checks {
        var c = Checks(state: nil)
        // A rerun of a build reports under the same key: the newest one counts.
        var byKey: [String: [String: Any]] = [:]
        var order: [String] = []
        for v in values {
            let k = v["key"] as? String ?? v["name"] as? String ?? UUID().uuidString
            if let old = byKey[k], (InboxDates.iso(old["updated_on"] as? String) ?? .distantPast) > (InboxDates.iso(v["updated_on"] as? String) ?? .distantPast) { continue }
            if byKey[k] == nil { order.append(k) }
            byKey[k] = v
        }
        for k in order {
            guard let v = byKey[k] else { continue }
            let name = v["name"] as? String ?? k
            switch (v["state"] as? String ?? "").uppercased() {
            case "SUCCESSFUL": c.passed += 1
            case "FAILED", "STOPPED":
                c.failed += 1; c.failedNames.append(name)
                c.failedDetails.append(.init(name: name, url: v["url"] as? String ?? "", title: v["description"] as? String))
            default: c.pending += 1
            }
        }
        if c.failed > 0 { c.state = .failing } else if c.pending > 0 { c.state = .pending } else if c.passed > 0 { c.state = .passing }
        return c
    }

    static func apply(_ c: Checks, to i: inout InboxItem) {
        i.checks = c.state
        i.checkCounts = (c.passed, c.failed, c.pending)
        i.failedChecks = c.failedNames
        i.failedCheckDetails = c.failedDetails
    }

    // MARK: History

    /// The activity log (comments, updates, approvals, changes requested) as events, oldest first.
    static func events(_ values: [[String: Any]], me: String?) -> [InboxEvent] {
        func who(_ u: Any?) -> String {
            let u = u as? [String: Any]
            if let me, (u?["account_id"] as? String) == me { return "You" }
            return u?["display_name"] as? String ?? u?["nickname"] as? String ?? "someone"
        }
        var out: [InboxEvent] = []
        var updates: [[String: Any]] = []
        for v in values {
            if let c = v["comment"] as? [String: Any] {
                guard c["deleted"] as? Bool != true, let d = InboxDates.iso(c["created_on"] as? String) else { continue }
                var e = InboxEvent(kind: .comment, actor: who(c["user"]), date: d, summary: "commented",
                                   detail: (c["content"] as? [String: Any])?["raw"] as? String ?? "")
                if let inline = c["inline"] as? [String: Any], let path = inline["path"] as? String {
                    e.path = path
                    e.line = inline["to"] as? Int ?? inline["from"] as? Int
                }
                let user = c["user"] as? [String: Any]
                e.bot = (user?["type"] as? String) == "app_user" || InboxHistory.looksLikeBot(user?["display_name"] as? String ?? user?["nickname"] as? String ?? "")
                out.append(e)
            } else if let a = v["approval"] as? [String: Any], let d = InboxDates.iso(a["date"] as? String) {
                out.append(InboxEvent(kind: .review, actor: who(a["user"]), date: d, summary: "approved", field: "review"))
            } else if let r = v["changes_requested"] as? [String: Any], let d = InboxDates.iso(r["date"] as? String) {
                out.append(InboxEvent(kind: .review, actor: who(r["user"]), date: d, summary: "requested changes", field: "review"))
            } else if let u = v["update"] as? [String: Any] {
                updates.append(u)
            }
        }
        // Updates are snapshots of the pull request: compare each with the one before it.
        let sorted = updates.compactMap { u -> (Date, [String: Any])? in InboxDates.iso(u["date"] as? String).map { ($0, u) } }.sorted { $0.0 < $1.0 }
        var prev: [String: Any]?
        for (d, u) in sorted {
            let actor = who(u["author"])
            let state = (u["state"] as? String ?? "").uppercased()
            let hash = ((u["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String
            let title = u["title"] as? String ?? ""
            if let p = prev {
                let pState = (p["state"] as? String ?? "").uppercased()
                let pHash = ((p["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String
                if state != pState, !state.isEmpty {
                    let s = ["MERGED": "merged it", "DECLINED": "declined it", "SUPERSEDED": "superseded it", "OPEN": "reopened it"][state] ?? "moved it to \(state.lowercased())"
                    out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: s, field: "status"))
                } else if let hash, let pHash, hash != pHash {
                    out.append(InboxEvent(kind: .commits, actor: actor, date: d, summary: "pushed new commits", detail: String(hash.prefix(7))))
                }
                if let pt = p["title"] as? String, !title.isEmpty, pt != title {
                    out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: "renamed it to “\(title)”", field: "title"))
                }
            } else {
                out.append(InboxEvent(kind: .change, actor: actor, date: d, summary: "opened it", field: "opened"))
            }
            prev = u
        }
        return out.sorted { $0.date < $1.date }
    }

    static func ended(_ pr: [String: Any]) -> InboxItem.Ended? {
        let at = InboxDates.iso(pr["updated_on"] as? String) ?? Date()
        switch (pr["state"] as? String ?? "").uppercased() {
        case "MERGED": return .init(label: "Merged", merged: true, at: at)
        case "DECLINED": return .init(label: "Declined", at: at)
        case "SUPERSEDED": return .init(label: "Superseded", at: at)
        default: return nil
        }
    }
}

/// Changing a pull request on Bitbucket (each one confirmed by the user first; see InboxActions). Needs a token with
/// write:pullrequest:bitbucket.
enum BitbucketWrites {
    static func path(_ i: InboxItem, _ tail: String) -> String { "/repositories/\(i.place)/pullrequests/\(i.number ?? 0)/\(tail)" }

    /// The request an action makes. Merges never delete the source branch.
    static func request(_ a: InboxPRAction, _ i: InboxItem) -> (method: String, path: String, body: [String: Any]?)? {
        func merge(_ strategy: String) -> (String, String, [String: Any]?) {
            ("POST", path(i, "merge"), ["type": "pullrequest", "merge_strategy": strategy, "close_source_branch": false])
        }
        switch a {
        case .approve: return ("POST", path(i, "approve"), nil)
        case .unapprove: return ("DELETE", path(i, "approve"), nil)
        case .requestChanges: return ("POST", path(i, "request-changes"), nil)
        case .undoRequestChanges: return ("DELETE", path(i, "request-changes"), nil)
        case .merge: return merge("merge_commit")
        case .squash: return merge("squash")
        case .fastForward: return merge("fast_forward")
        case .decline: return ("POST", path(i, "decline"), nil)
        case .rebase, .ready, .draft, .close, .reopen: return nil
        }
    }

    static func perform(_ a: InboxPRAction, _ i: InboxItem) throws -> String {
        guard let r = request(a, i) else { throw InboxError("Bitbucket can't \(a.title.lowercased()).") }
        do { _ = try BitbucketClient.request(r.path, method: r.method, body: r.body) }
        catch let e as BitbucketHTTPError where e.code == 403 { throw writeRefused(e) }
        return ""
    }

    static func comment(_ i: InboxItem, _ text: String) throws {
        do { _ = try BitbucketClient.request(path(i, "comments"), method: "POST", body: ["content": ["raw": text]]) }
        catch let e as BitbucketHTTPError where e.code == 403 { throw writeRefused(e) }
    }

    static func writeRefused(_ e: BitbucketHTTPError) -> InboxError {
        InboxError("Bitbucket refused (403): the token needs write:pullrequest:bitbucket to approve, comment, merge or decline." + (e.message.isEmpty ? "" : " " + e.message))
    }
}

/// What the Bitbucket part of the Inbox keeps between refreshes, and how it spends its requests.
final class BitbucketInbox {
    static let shared = BitbucketInbox()

    /// GET of a path or a `next` URL (network; tests swap it).
    var get: (String) throws -> Data = { try BitbucketClient.request($0) }
    var now: () -> Date = Date.init
    var defaults: UserDefaults = .standard

    /// How often the repos updated lately are scanned for review requests, and the repo list read again.
    static let discoveryEvery: TimeInterval = 600
    static let reposEvery: TimeInterval = 3600
    /// "Updated lately": in this many days.
    static let activeDays: Double = 14
    /// Requests per hour the Inbox lets itself spend; past it only the repos holding your items are read.
    static let budget = 600
    /// Most repos read in one scan, and most build statuses read in one refresh.
    static let maxScan = 80
    static let maxStatuses = 20

    private let lock = NSLock()
    private(set) var me: BitbucketClient.Me?
    private(set) var workspaces: [String] = []
    private var workspacesAt = Date.distantPast
    /// Workspace → repos updated lately (or all of them with "every repo").
    private(set) var activeRepos: [String: [String]] = [:]
    private var reposAt = Date.distantPast
    /// Repo → the open pull requests in it that wait for your review (raw), as of its last scan.
    private var reviewByRepo: [String: [[String: Any]]] = [:]
    private var lastDiscovery = Date.distantPast
    /// Item id → the head commit its build statuses were read for, and what they said.
    private var statusCache: [String: (head: String, checks: BitbucketClient.Checks)] = [:]
    private var stamps: [Date] = []
    private(set) var pausedUntil: Date?
    private var backoff: TimeInterval = 0
    /// Repos of the local projects (from their origin remotes); always scanned.
    var localRepos: Set<String> = []
    /// Repos hidden in the Inbox (lowercased): not scanned for review requests.
    var skippedRepos: Set<String> = []
    /// The repos the last scan for review requests read, in order (for Settings).
    private(set) var lastScan: [String] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        me = nil; workspaces = []; workspacesAt = .distantPast; activeRepos = [:]; reposAt = .distantPast
        reviewByRepo = [:]; lastDiscovery = .distantPast; statusCache = [:]; pausedUntil = nil; backoff = 0
    }

    // MARK: Budget

    func counted() {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        stamps.append(t)
        stamps.removeAll { t.timeIntervalSince($0) > 3600 }
    }

    var requestsLastHour: Int {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        return stamps.filter { t.timeIntervalSince($0) <= 3600 }.count
    }

    /// A 429: wait what Bitbucket asks, else twice as long as last time (1 minute to 15).
    func slowDown(retryAfter: Double?) -> BitbucketRateLimit {
        lock.lock(); defer { lock.unlock() }
        backoff = retryAfter ?? min(900, max(60, backoff * 2))
        let until = now().addingTimeInterval(backoff)
        pausedUntil = until
        return BitbucketRateLimit(until: until)
    }

    // MARK: Paging

    private func json(_ pathOrURL: String) throws -> [String: Any] { try BitbucketClient.object(get(pathOrURL)) }

    /// A list's values over at most `pages` pages.
    func values(_ path: String, pages: Int) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var next: String? = path
        var n = 0
        while let p = next, n < pages {
            let o = try json(p)
            out += o["values"] as? [[String: Any]] ?? []
            next = o["next"] as? String
            n += 1
        }
        return out
    }

    // MARK: Reading

    func loadMe() throws -> BitbucketClient.Me {
        if let m = lockedMe() { return m }
        guard let m = BitbucketClient.me(try json("/user")) else { throw InboxError("Bitbucket didn't say who you are.") }
        lock.lock(); me = m; lock.unlock()
        return m
    }
    private func lockedMe() -> BitbucketClient.Me? { lock.lock(); defer { lock.unlock() }; return me }

    /// Workspaces you are in (slugs).
    func listWorkspaces() throws -> [String] {
        try values("/user/workspaces?pagelen=100", pages: 3).compactMap { v in
            (v["workspace"] as? [String: Any])?["slug"] as? String ?? v["slug"] as? String
        }
    }

    /// The workspace's repos you are a member of, updated in the last `activeDays` (all of them with `all`).
    func listRepos(_ ws: String, all: Bool) throws -> [String] {
        var path = "/repositories/\(BitbucketClient.encPath(ws))?role=member&pagelen=100&sort=-updated_on&fields=values.full_name,values.updated_on,next"
        if !all {
            let since = ISO8601DateFormatter().string(from: now().addingTimeInterval(-Self.activeDays * 86400))
            path += "&q=" + BitbucketClient.enc("updated_on>\(since)")
        }
        return try values(path, pages: all ? 5 : 3).compactMap { $0["full_name"] as? String }
    }

    /// Your open pull requests in a workspace. The list takes your account id or your uuid; whichever works is remembered.
    func minePRs(_ ws: String, me: BitbucketClient.Me) throws -> [[String: Any]] {
        let saved = defaults.string(forKey: InboxPrefs.bbUserForm)
        let forms = saved == "uuid" ? ["uuid", "account"] : ["account", "uuid"]
        var lastError: Error?
        for form in forms {
            let who = form == "uuid" ? me.uuid : me.accountId
            guard !who.isEmpty else { continue }
            do {
                let v = try values("/workspaces/\(BitbucketClient.encPath(ws))/pullrequests/\(BitbucketClient.encPath(who))?state=OPEN&pagelen=50&fields=\(BitbucketClient.prFields)", pages: 2)
                if saved != form { defaults.set(form, forKey: InboxPrefs.bbUserForm) }
                return v
            } catch let e as BitbucketHTTPError where e.code == 404 || e.code == 400 {
                lastError = e
            }
        }
        throw lastError ?? InboxError("Couldn't read your pull requests in \(ws)")
    }

    /// The repo's open pull requests that wait for your review: Bitbucket filters by reviewer when it can; when it
    /// refuses the filter, every open one is read and you are looked for among the reviewers.
    func reviewPRs(_ repo: String, me: BitbucketClient.Me) throws -> [[String: Any]] {
        let base = "/repositories/\(repo.split(separator: "/").map { BitbucketClient.encPath(String($0)) }.joined(separator: "/"))/pullrequests"
        if defaults.string(forKey: InboxPrefs.bbReviewFilter) != "client" {
            let q = "state=\"OPEN\" AND reviewers.account_id=\"\(me.accountId)\""
            do {
                return try values("\(base)?pagelen=50&fields=\(BitbucketClient.prFields)&q=\(BitbucketClient.enc(q))", pages: 2)
                    .filter { BitbucketClient.isReviewer($0, me: me.accountId) || ($0["participants"] == nil && $0["reviewers"] == nil) }
            } catch let e as BitbucketHTTPError where e.code == 400 {
                defaults.set("client", forKey: InboxPrefs.bbReviewFilter)
            }
        }
        return try values("\(base)?state=OPEN&pagelen=50&fields=\(BitbucketClient.prFields)", pages: 3)
            .filter { BitbucketClient.isReviewer($0, me: me.accountId) }
    }

    func statuses(_ i: InboxItem) throws -> BitbucketClient.Checks {
        guard let n = i.number else { return .init(state: nil) }
        return BitbucketClient.checks(try values("/repositories/\(i.place)/pullrequests/\(n)/statuses?pagelen=50", pages: 2))
    }

    // MARK: A refresh

    /// One refresh: your pull requests (every time), review requests (repos holding your items every time, the repos
    /// updated lately every `discoveryEvery`), and the build statuses of pull requests whose head moved.
    /// `force`: the user asked (a scan now, past the budget too).
    func fetch(review: Bool, mine: Bool, force: Bool = false) throws -> [InboxItem] {
        lock.lock()
        if let p = pausedUntil, now() < p { lock.unlock(); throw BitbucketRateLimit(until: p) }
        lock.unlock()
        let me = try loadMe()
        let t = now()
        if workspaces.isEmpty || t.timeIntervalSince(workspacesAt) >= Self.reposEvery {
            let w = try listWorkspaces()
            lock.lock(); workspaces = w; workspacesAt = t; lock.unlock()
        }
        let skipped = Set((defaults.string(forKey: InboxPrefs.bbSkipped) ?? "").split(separator: ",").map(String.init))
        let wss = workspaces.filter { !skipped.contains($0) }
        var found: [(pr: [String: Any], reason: InboxItem.Reason)] = []
        if mine {
            for ws in wss { found += try minePRs(ws, me: me).map { ($0, .mine) } }
        }
        if review {
            let all = defaults.bool(forKey: InboxPrefs.bbSweepAll)
            if activeRepos.isEmpty || t.timeIntervalSince(reposAt) >= Self.reposEvery {
                var r: [String: [String]] = [:]
                for ws in wss { r[ws] = try listRepos(ws, all: all) }
                lock.lock(); activeRepos = r; reposAt = t; lock.unlock()
            }
            let inWorkspaces = { (repo: String) in wss.contains { repo.lowercased().hasPrefix($0.lowercased() + "/") } }
            // Repos holding one of your items: read every time (cheap, and where news is).
            var hot = Set(reviewByRepo.filter { !$0.value.isEmpty }.keys)
            for f in found { if let r = BitbucketClient.item(f.pr, reason: f.reason, me: me.accountId)?.place { hot.insert(r) } }
            let overBudget = requestsLastHour >= Self.budget
            let discovery = force || (!overBudget && t.timeIntervalSince(lastDiscovery) >= Self.discoveryEvery)
            // Repos holding your items first, then your projects', then the most recently updated (the list's order):
            // past the cap, the ones left out are the stalest.
            var ordered = hot.sorted()
            if discovery { ordered += localRepos.sorted() + wss.flatMap { activeRepos[$0] ?? [] } }
            var seenRepo = Set<String>()
            let list = ordered.filter { inWorkspaces($0) && !skippedRepos.contains($0.lowercased()) && seenRepo.insert($0.lowercased()).inserted }
                .prefix(Self.maxScan)
            var fresh: [String: [[String: Any]]] = [:]
            for repo in list { fresh[repo] = try reviewPRs(repo, me: me) }
            lock.lock()
            if discovery {
                lastScan = Array(list)
                // Repos that left the scan (no longer updated lately) and held nothing: forgotten.
                reviewByRepo = reviewByRepo.filter { fresh[$0.key] != nil || !$0.value.isEmpty }
                lastDiscovery = t
            }
            reviewByRepo.merge(fresh) { _, b in b }
            reviewByRepo = reviewByRepo.filter { inWorkspaces($0.key) }
            let reviews = reviewByRepo.values.flatMap { $0 }
            lock.unlock()
            found += reviews.map { ($0, .review) }
        }
        var byId: [String: InboxItem] = [:]
        var order: [String] = []
        for f in found {
            guard let i = BitbucketClient.item(f.pr, reason: f.reason, me: me.accountId) else { continue }
            if byId[i.id] == nil { order.append(i.id); byId[i.id] = i }
        }
        var items = order.compactMap { byId[$0] }.filter { keepForReview($0) }
        // Build statuses: read again only when the head moved.
        var read = 0
        for k in items.indices {
            let i = items[k]
            guard let head = i.head else { continue }
            lock.lock(); let cached = statusCache[i.id]; lock.unlock()
            if let c = cached, c.head == head { BitbucketClient.apply(c.checks, to: &items[k]); continue }
            guard read < Self.maxStatuses else { if let c = cached { BitbucketClient.apply(c.checks, to: &items[k]) }; continue }
            read += 1
            if let c = try? statuses(i) {
                lock.lock(); statusCache[i.id] = (head, c); lock.unlock()
                BitbucketClient.apply(c, to: &items[k])
            }
        }
        lock.lock(); backoff = 0; pausedUntil = nil; lock.unlock()
        return items
    }

    /// A review request you approved leaves the list until a new commit comes (asking for changes keeps it there).
    func keepForReview(_ i: InboxItem) -> Bool {
        guard i.reason == .review else { return true }
        var approved = defaults.dictionary(forKey: InboxPrefs.bbApprovedHead) as? [String: String] ?? [:]
        defer { defaults.set(approved, forKey: InboxPrefs.bbApprovedHead) }
        guard i.youApproved, !i.youRequestedChanges else { approved[i.id] = nil; return true }
        let head = i.head ?? ""
        if let at = approved[i.id] { return at != head }
        approved[i.id] = head
        return false
    }

    /// The history of a pull request (newest 150 entries).
    func activity(_ i: InboxItem) throws -> InboxActivity {
        guard let n = i.number else { return InboxActivity(events: []) }
        let me = (try? loadMe())?.accountId ?? BitbucketClient.savedMe?.accountId
        let v = try values("/repositories/\(i.place)/pullrequests/\(n)/activity?pagelen=50", pages: 3)
        return InboxActivity(events: BitbucketClient.events(v, me: me))
    }

    /// Which of these pull requests were merged, declined or superseded (one request each, at most 20).
    func ended(_ items: [InboxItem]) throws -> [String: InboxItem.Ended] {
        var out: [String: InboxItem.Ended] = [:]
        for i in items.prefix(20) {
            guard let n = i.number, let o = try? json("/repositories/\(i.place)/pullrequests/\(n)?fields=state,updated_on") else { continue }
            if let e = BitbucketClient.ended(o) { out[i.id] = e }
        }
        return out
    }

    // MARK: Pipelines

    /// A Pipelines build's number from its status link (…/pipelines/results/318…, …#!/results/318).
    static func buildNumber(_ url: String) -> Int? {
        guard let r = url.range(of: #"results/(\d+)"#, options: .regularExpression) else { return nil }
        return Int(url[r].split(separator: "/").last ?? "")
    }

    /// Reads a step log's tail (`BitbucketClient.request` with a Range; tests swap it).
    var stepLog: (String) throws -> String = { path in
        String(decoding: try BitbucketClient.request(path, accept: "*/*", range: "bytes=-60000", logRedirect: true), as: UTF8.self)
    }

    /// The failed steps' logs of a failed Pipelines build (Fix with agent's evidence). Needs read:pipeline:bitbucket;
    /// other builds (not Pipelines) have no log here.
    func pipelineLog(_ i: InboxItem, _ c: InboxItem.FailedCheck) throws -> String {
        guard let n = Self.buildNumber(c.url), c.url.contains("pipelines") || c.url.contains("addon/pipelines") else {
            throw InboxError("not a Pipelines build")
        }
        let base = "/repositories/\(i.place)/pipelines"
        var query = "?sort=-created_on&pagelen=30"
        if let h = i.head { query += "&target.commit.hash=" + BitbucketClient.enc(h) }
        let list = try values(base + query, pages: 1)
        guard let p = list.first(where: { ($0["build_number"] as? Int) == n }), let uuid = p["uuid"] as? String else {
            throw InboxError("build \(n) not found")
        }
        let steps = try values("\(base)/\(BitbucketClient.encPath(uuid))/steps?pagelen=50", pages: 1)
        let failed = steps.filter { s in
            let result = ((s["state"] as? [String: Any])?["result"] as? [String: Any])?["name"] as? String ?? ""
            return ["FAILED", "ERROR"].contains(result.uppercased())
        }
        var out: [String] = []
        for s in failed.prefix(2) {
            guard let su = s["uuid"] as? String else { continue }
            let log = try stepLog("\(base)/\(BitbucketClient.encPath(uuid))/steps/\(BitbucketClient.encPath(su))/log")
            out.append((failed.count > 1 ? "== \(s["name"] as? String ?? "step") ==\n" : "") + log)
        }
        guard !out.isEmpty else { throw InboxError("no failed step") }
        return out.joined(separator: "\n")
    }

    /// The pull request's unified diff.
    func diff(_ i: InboxItem) throws -> String {
        guard let n = i.number else { return "" }
        return String(decoding: try BitbucketClient.request("/repositories/\(i.place)/pullrequests/\(n)/diff", accept: "text/plain"), as: UTF8.self)
    }
}
