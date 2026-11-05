import XCTest
@testable import Octomux

final class BitbucketInboxTests: XCTestCase {
    private func pr(_ id: Int, repo: String = "acme/api", author: String = "acc-ann", draft: Bool = false, head: String = "h1",
                    updated: String = "2026-11-05T10:00:00.000000+00:00", participants: [[String: Any]] = [],
                    reviewers: [String] = []) -> [String: Any] {
        [
            "id": id, "title": "PR \(id)", "draft": draft, "state": "OPEN", "updated_on": updated,
            "created_on": "2026-11-04T10:00:00.000000+00:00",
            "author": ["account_id": author, "display_name": author == "acc-me" ? "Me Myself" : "Ann"],
            "summary": ["raw": "Body of \(id)"],
            "links": ["html": ["href": "https://bitbucket.org/\(repo)/pull-requests/\(id)"]],
            "source": ["branch": ["name": "feature-\(id)"], "commit": ["hash": head], "repository": ["full_name": repo]],
            "destination": ["branch": ["name": "main"], "repository": ["full_name": repo]],
            "participants": participants,
            "reviewers": reviewers.map { ["account_id": $0] },
        ]
    }

    private func page(_ values: [[String: Any]], next: String? = nil) -> Data {
        var o: [String: Any] = ["values": values]
        if let next { o["next"] = next }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testItemParse() {
        let p = pr(7, draft: true, participants: [
            ["user": ["account_id": "acc-me"], "role": "REVIEWER", "approved": true, "state": "approved"],
            ["user": ["account_id": "acc-bob"], "role": "REVIEWER", "approved": false, "state": "changes_requested"],
            ["user": ["account_id": "acc-eve"], "role": "PARTICIPANT", "approved": true, "state": "approved"],
        ])
        let i = BitbucketClient.item(p, reason: .review, me: "acc-me")!
        XCTAssertEqual(i.id, "bb:acme/api#7")
        XCTAssertEqual(i.source, .bitbucket)
        XCTAssertEqual(i.key, "#7")
        XCTAssertEqual(i.place, "acme/api")
        XCTAssertEqual(i.status, "Draft")
        XCTAssertTrue(i.isDraft)
        XCTAssertEqual(i.author, "Ann")
        XCTAssertEqual(i.branch, "feature-7")
        XCTAssertEqual(i.base, "main")
        XCTAssertEqual(i.head, "h1")
        XCTAssertEqual(i.body, "Body of 7")
        XCTAssertEqual(i.url, "https://bitbucket.org/acme/api/pull-requests/7")
        XCTAssertEqual(i.approvals, 2)
        XCTAssertEqual(i.changesRequested, 1)
        XCTAssertTrue(i.youApproved)
        XCTAssertFalse(i.youRequestedChanges)
        XCTAssertNil(i.repo)                         // not a gh repo
        XCTAssertEqual(i.codeRepo, "acme/api")
        let mine = BitbucketClient.item(pr(8, author: "acc-me"), reason: .mine, me: "acc-me")!
        XCTAssertEqual(mine.author, "You")
        XCTAssertEqual(mine.status, "Open")
        XCTAssertNil(BitbucketClient.item(["title": "no id"], reason: .mine, me: nil))
        var counted = pr(10); counted["comment_count"] = 18
        XCTAssertEqual(BitbucketClient.item(counted, reason: .mine, me: nil)?.commentCount, 18)
        XCTAssertNil(i.commentCount)
    }

    func testSourceOfIdAndPrefixes() {
        XCTAssertEqual(InboxSource.of(id: "bb:a/b#1"), .bitbucket)
        XCTAssertEqual(InboxSource.of(id: "gh:a/b#1"), .github)
        XCTAssertEqual(InboxSource.of(id: "jira:X-1"), .jira)
        XCTAssertNil(InboxSource.of(id: "x"))
        XCTAssertTrue(InboxSource.bitbucket.isCodeHost)
        XCTAssertFalse(InboxSource.jira.isCodeHost)
    }

    func testRemoteParse() {
        XCTAssertEqual(BitbucketClient.repo(fromRemote: "git@bitbucket.org:acme/api.git"), "acme/api")
        XCTAssertEqual(BitbucketClient.repo(fromRemote: "https://ann@bitbucket.org/acme/api.git\n"), "acme/api")
        XCTAssertEqual(BitbucketClient.repo(fromRemote: "ssh://git@bitbucket.org/acme/web-shop"), "acme/web-shop")
        XCTAssertNil(BitbucketClient.repo(fromRemote: "git@github.com:acme/api.git"))
        XCTAssertNil(BitbucketClient.repo(fromRemote: "https://bitbucket.org/acme"))
        XCTAssertEqual(InboxStore.bitbucketKey("Acme/API"), "bitbucket.org/acme/api")
    }

    func testAuthHeaderAndHostGuard() throws {
        XCTAssertEqual(BitbucketClient.header(.bearer, "t0k"), "Bearer t0k")
        XCTAssertEqual(BitbucketClient.header(.basic("a@b.c"), "t0k"), "Basic " + Data("a@b.c:t0k".utf8).base64EncodedString())
        XCTAssertEqual(try BitbucketClient.url("/user").absoluteString, "https://api.bitbucket.org/2.0/user")
        XCTAssertNoThrow(try BitbucketClient.url("https://api.bitbucket.org/2.0/repositories/a/b/pullrequests?page=2"))
        // A `next` link anywhere else is refused: the token goes only to api.bitbucket.org.
        XCTAssertThrowsError(try BitbucketClient.url("https://evil.example.com/2.0/user"))
        XCTAssertThrowsError(try BitbucketClient.url("http://api.bitbucket.org/2.0/user"))
    }

    func testChecks() {
        let c = BitbucketClient.checks([
            ["key": "build", "name": "Pipeline #1", "state": "FAILED", "updated_on": "2026-11-05T10:00:00+00:00", "url": "u1", "description": "Tests failed"],
            ["key": "build", "name": "Pipeline #2", "state": "SUCCESSFUL", "updated_on": "2026-11-05T11:00:00+00:00"],   // the rerun counts
            ["key": "lint", "name": "Lint", "state": "STOPPED", "url": "u2"],
            ["key": "deploy", "name": "Deploy", "state": "INPROGRESS"],
        ])
        XCTAssertEqual(c.state, .failing)
        XCTAssertEqual(c.passed, 1)
        XCTAssertEqual(c.failed, 1)
        XCTAssertEqual(c.pending, 1)
        XCTAssertEqual(c.failedNames, ["Lint"])
        XCTAssertEqual(c.failedDetails.first?.url, "u2")
        XCTAssertEqual(BitbucketClient.checks([["key": "a", "state": "INPROGRESS"]]).state, .pending)
        XCTAssertEqual(BitbucketClient.checks([["key": "a", "state": "SUCCESSFUL"]]).state, .passing)
        XCTAssertNil(BitbucketClient.checks([]).state)
    }

    func testEvents() {
        let u: (String, String, String, String) -> [String: Any] = { date, state, hash, title in
            ["update": ["date": date, "state": state, "title": title, "author": ["account_id": "acc-ann", "display_name": "Ann"],
                        "source": ["commit": ["hash": hash]]]]
        }
        let ev = BitbucketClient.events([
            u("2026-11-05T13:00:00+00:00", "MERGED", "h2", "New title"),
            ["approval": ["date": "2026-11-05T12:00:00+00:00", "user": ["account_id": "acc-me", "display_name": "Me"]]],
            ["changes_requested": ["date": "2026-11-05T11:30:00+00:00", "user": ["account_id": "acc-bob", "display_name": "Bob"]]],
            ["comment": ["created_on": "2026-11-05T11:00:00+00:00", "user": ["account_id": "acc-bob", "display_name": "Bob"],
                         "content": ["raw": "Why?"], "inline": ["path": "src/a.ts", "to": 42]]],
            ["comment": ["created_on": "2026-11-05T11:10:00+00:00", "deleted": true, "user": ["display_name": "Bob"], "content": ["raw": "x"]]],
            u("2026-11-05T12:30:00+00:00", "OPEN", "h2", "Old title"),
            u("2026-11-05T10:00:00+00:00", "OPEN", "h1", "Old title"),
        ], me: "acc-me")
        XCTAssertEqual(ev.map(\.summary), ["opened it", "commented", "requested changes", "approved", "pushed new commits",
                                           "merged it", "renamed it to “New title”"])
        let inline = ev.first { $0.kind == .comment }
        XCTAssertEqual(inline?.detail, "Why?")
        XCTAssertEqual(inline?.path, "src/a.ts")
        XCTAssertEqual(inline?.line, 42)
        XCTAssertFalse(inline?.bot ?? true)
        let botComment = BitbucketClient.events([["comment": ["created_on": "2026-11-05T11:00:00+00:00", "content": ["raw": "Summary"],
                                                              "user": ["display_name": "Acme CodeRabbit", "type": "user"]]]], me: nil)
        XCTAssertTrue(botComment.first?.bot ?? false)
        XCTAssertTrue(InboxHistory.looksLikeBot("dependabot[bot]"))
        XCTAssertTrue(InboxHistory.looksLikeBot("renovate-bot"))
        XCTAssertFalse(InboxHistory.looksLikeBot("Abbot Smith"))
        XCTAssertFalse(InboxHistory.looksLikeBot("Robert"))
        XCTAssertEqual(ev.first { $0.summary == "approved" }?.actor, "You")
        XCTAssertEqual(ev.first { $0.summary == "merged it" }?.field, "status")
        XCTAssertEqual(ev.first { $0.summary == "opened it" }?.field, "opened")      // not news for a linked session
    }

    func testEnded() {
        XCTAssertEqual(BitbucketClient.ended(["state": "MERGED", "updated_on": "2026-11-05T10:00:00+00:00"])?.merged, true)
        XCTAssertEqual(BitbucketClient.ended(["state": "DECLINED"])?.label, "Declined")
        XCTAssertEqual(BitbucketClient.ended(["state": "SUPERSEDED"])?.label, "Superseded")
        XCTAssertNil(BitbucketClient.ended(["state": "OPEN"]))
    }

    func testIsReviewer() {
        XCTAssertTrue(BitbucketClient.isReviewer(pr(1, reviewers: ["acc-me"]), me: "acc-me"))
        XCTAssertTrue(BitbucketClient.isReviewer(pr(1, participants: [["user": ["account_id": "acc-me"], "role": "REVIEWER"]]), me: "acc-me"))
        XCTAssertFalse(BitbucketClient.isReviewer(pr(1, participants: [["user": ["account_id": "acc-me"], "role": "PARTICIPANT"]]), me: "acc-me"))
    }

    // MARK: Refreshes

    /// A fake Bitbucket: answers by path, records what was asked.
    private final class Fake {
        var asked: [String] = []
        var handlers: [(String) -> Data?] = []
        func get(_ p: String) throws -> Data {
            asked.append(p)
            for h in handlers { if let d = h(p) { return d } }
            throw BitbucketHTTPError(code: 404, message: "no fake for \(p)")
        }
        func count(_ s: String) -> Int { asked.filter { $0.contains(s) }.count }
    }

    private func world(_ fake: Fake, reviews: [String: [[String: Any]]], mine: [[String: Any]] = [], repos: [String] = ["acme/api", "acme/web"],
                       statuses: [[String: Any]] = [["key": "b", "state": "SUCCESSFUL"]]) {
        fake.handlers.append { p in
            if p == "/user" { return try! JSONSerialization.data(withJSONObject: ["account_id": "acc-me", "uuid": "{u-me}", "display_name": "Me"]) }
            if p.hasPrefix("/user/workspaces") { return self.page([["workspace": ["slug": "acme"]]]) }
            if p.hasPrefix("/workspaces/acme/pullrequests/acc-me") { return self.page(mine) }
            if p.hasPrefix("/repositories/acme?") { return self.page(repos.map { ["full_name": $0] }) }
            if p.contains("/statuses") { return self.page(statuses) }
            for (repo, list) in reviews where p.hasPrefix("/repositories/\(repo)/pullrequests?") { return self.page(list) }
            if p.hasPrefix("/repositories/") && p.contains("/pullrequests?") { return self.page([]) }
            return nil
        }
    }

    private func store() -> (BitbucketInbox, UserDefaults, Fake) {
        let name = "bb-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        let bb = BitbucketInbox()
        bb.defaults = d
        let f = Fake()
        bb.get = { try f.get($0) }
        return (bb, d, f)
    }

    func testFirstRefreshScansActiveReposThenOnlyHotOnes() throws {
        let (bb, _, f) = store()
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        bb.now = { t }
        bb.localRepos = ["acme/local-only"]
        world(f, reviews: ["acme/api": [pr(7, repo: "acme/api", reviewers: ["acc-me"])]],
              mine: [pr(9, repo: "acme/web", author: "acc-me")])
        let first = try bb.fetch(review: true, mine: true)
        XCTAssertEqual(Set(first.map(\.id)), ["bb:acme/api#7", "bb:acme/web#9"])
        XCTAssertEqual(first.first { $0.id == "bb:acme/api#7" }?.reason, .review)
        XCTAssertEqual(first.first { $0.id == "bb:acme/web#9" }?.reason, .mine)
        XCTAssertEqual(first.first?.checks, .passing)
        XCTAssertEqual(f.count("/repositories/acme/local-only/pullrequests?"), 1)   // the local project's repo too
        XCTAssertTrue(f.asked.contains { $0.contains("reviewers.account_id") })      // Bitbucket filters by reviewer
        // The extra fields are added to the defaults: their "+" goes encoded (a bare one is a space, and the
        // answer would carry only those fields).
        XCTAssertTrue(f.asked.contains { $0.contains("fields=%2Bvalues.participants,%2Bvalues.reviewers") })
        XCTAssertFalse(f.asked.contains { $0.contains("fields=+") })
        // Two minutes later: only repos holding an item (api: a review, web: yours) are read; statuses not again.
        f.asked = []
        t += 120
        let second = try bb.fetch(review: true, mine: true)
        XCTAssertEqual(Set(second.map(\.id)), Set(first.map(\.id)))
        XCTAssertEqual(f.count("/repositories/acme/api/pullrequests?"), 1)
        XCTAssertEqual(f.count("/repositories/acme/web/pullrequests?"), 1)
        XCTAssertEqual(f.count("/repositories/acme/local-only/"), 0)
        XCTAssertEqual(f.count("/statuses"), 0)
        XCTAssertEqual(f.count("/user/workspaces"), 0)
        XCTAssertEqual(f.count("/repositories/acme?"), 0)
        // Ten minutes after the first: the full scan again.
        f.asked = []
        t += 600
        _ = try bb.fetch(review: true, mine: true)
        XCTAssertEqual(f.count("/repositories/acme/local-only/pullrequests?"), 1)
        // The user's refresh scans right away.
        f.asked = []
        t += 60
        _ = try bb.fetch(review: true, mine: true, force: true)
        XCTAssertEqual(f.count("/repositories/acme/local-only/pullrequests?"), 1)
    }

    func testStatusesReadAgainWhenTheHeadMoves() throws {
        let (bb, _, f) = store()
        var head = "h1"
        f.handlers.append { p in
            p.hasPrefix("/workspaces/acme/pullrequests/acc-me") ? self.page([self.pr(9, repo: "acme/web", author: "acc-me", head: head)]) : nil
        }
        world(f, reviews: [:], statuses: [["key": "b", "state": "FAILED", "name": "Pipeline"]])
        XCTAssertEqual(try bb.fetch(review: false, mine: true).first?.checks, .failing)
        _ = try bb.fetch(review: false, mine: true)
        XCTAssertEqual(f.count("/statuses"), 1)
        head = "h2"
        let again = try bb.fetch(review: false, mine: true)
        XCTAssertEqual(f.count("/statuses"), 2)
        XCTAssertEqual(again.first?.failedChecks, ["Pipeline"])
    }

    func testReviewerFilterRefusedFallsBackToReadingTheRepo() throws {
        let (bb, d, f) = store()
        // A 400 for the filtered list: read the repo's open pull requests and look for you among the reviewers.
        bb.get = { p in
            if p.contains("reviewers.account_id") { f.asked.append(p); throw BitbucketHTTPError(code: 400, message: "Invalid field name") }
            return try f.get(p)
        }
        world(f, reviews: ["acme/api": [pr(7, repo: "acme/api", reviewers: ["acc-me"]), pr(8, repo: "acme/api", reviewers: ["acc-bob"])]],
              repos: ["acme/api"])
        let items = try bb.fetch(review: true, mine: false)
        XCTAssertEqual(items.map(\.id), ["bb:acme/api#7"])
        XCTAssertEqual(d.string(forKey: InboxPrefs.bbReviewFilter), "client")
        // From then on the filter is not tried.
        f.asked = []
        _ = try bb.fetch(review: true, mine: false, force: true)
        XCTAssertFalse(f.asked.contains { $0.contains("reviewers.account_id") })
    }

    func testWorkspaceListTakesTheUuidWhenTheAccountIdIsRefused() throws {
        let (bb, d, f) = store()
        f.handlers.append { p in p.hasPrefix("/workspaces/acme/pullrequests/%7Bu-me%7D") ? self.page([self.pr(9, author: "acc-me")]) : nil }
        f.handlers.append { p in
            if p == "/user" { return try! JSONSerialization.data(withJSONObject: ["account_id": "acc-me", "uuid": "{u-me}", "display_name": "Me"]) }
            if p.hasPrefix("/user/workspaces") { return self.page([["workspace": ["slug": "acme"]]]) }
            if p.contains("/statuses") { return self.page([]) }
            return nil
        }
        let items = try bb.fetch(review: false, mine: true)
        XCTAssertEqual(items.map(\.id), ["bb:acme/api#9"])
        XCTAssertEqual(d.string(forKey: InboxPrefs.bbUserForm), "uuid")
        f.asked = []
        _ = try bb.fetch(review: false, mine: true)
        XCTAssertTrue(f.asked.first { $0.hasPrefix("/workspaces/") }?.contains("%7Bu-me%7D") == true)   // the uuid first now
    }

    func testRateLimitPausesEveryRequest() throws {
        let (bb, _, f) = store()
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        bb.now = { t }
        bb.get = { p in f.asked.append(p); throw bb.slowDown(retryAfter: 120) }
        XCTAssertThrowsError(try bb.fetch(review: true, mine: true)) { XCTAssertTrue($0 is BitbucketRateLimit) }
        XCTAssertEqual(f.asked.count, 1)
        t += 60
        XCTAssertThrowsError(try bb.fetch(review: true, mine: true)) { XCTAssertTrue($0 is BitbucketRateLimit) }
        XCTAssertEqual(f.asked.count, 1)                                // nothing asked while paused
        // Without Retry-After the wait doubles from a minute up to 15.
        XCTAssertEqual(bb.slowDown(retryAfter: nil).until.timeIntervalSince(t), 240)
        XCTAssertEqual(bb.slowDown(retryAfter: nil).until.timeIntervalSince(t), 480)
        t += 3600
        world(f, reviews: [:])
        bb.get = { try f.get($0) }
        XCTAssertNoThrow(try bb.fetch(review: false, mine: true))   // past the pause it reads again
        XCTAssertNil(bb.pausedUntil)
    }

    func testScanCapKeepsYourReposAndTheFreshestOnes() throws {
        let (bb, _, f) = store()
        // More active repos than one scan reads, listed freshest first, named so that alphabetical order would differ.
        let repos = (0..<(BitbucketInbox.maxScan + 20)).map { "acme/r\(String(format: "%03d", 999 - $0))" }
        world(f, reviews: [:], mine: [pr(9, repo: "acme/zzz-mine", author: "acc-me")], repos: repos)
        _ = try bb.fetch(review: true, mine: true)
        let scanned = f.asked.filter { $0.hasPrefix("/repositories/acme/") && $0.contains("/pullrequests?") }
            .map { String($0.dropFirst("/repositories/".count).split(separator: "/").prefix(2).joined(separator: "/")) }
        XCTAssertEqual(scanned.count, BitbucketInbox.maxScan)
        XCTAssertEqual(scanned.first, "acme/zzz-mine")                       // where your pull request is
        XCTAssertTrue(scanned.contains("acme/r999"))                         // the freshest
        XCTAssertFalse(scanned.contains(repos.last!))                        // the stalest is left out
    }

    func testOverBudgetSkipsTheWideScan() throws {
        let (bb, _, f) = store()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        bb.now = { t }
        world(f, reviews: [:], repos: ["acme/api", "acme/web"])
        for _ in 0..<BitbucketInbox.budget { bb.counted() }
        _ = try bb.fetch(review: true, mine: true)
        XCTAssertEqual(f.count("/repositories/acme/api/pullrequests?"), 0)
        // Asked for by the user: scanned anyway.
        _ = try bb.fetch(review: true, mine: true, force: true)
        XCTAssertEqual(f.count("/repositories/acme/api/pullrequests?"), 1)
    }

    func testApprovedReviewLeavesUntilANewCommit() throws {
        let (bb, d, f) = store()
        var head = "h1", approved = true
        f.handlers.append { p in
            guard p.hasPrefix("/repositories/acme/api/pullrequests?") else { return nil }
            return self.page([self.pr(7, repo: "acme/api", head: head,
                                      participants: [["user": ["account_id": "acc-me"], "role": "REVIEWER", "approved": approved]])])
        }
        world(f, reviews: [:], repos: ["acme/api"])
        XCTAssertEqual(try bb.fetch(review: true, mine: false, force: true).count, 0)
        XCTAssertEqual(try bb.fetch(review: true, mine: false, force: true).count, 0)
        head = "h2"                                     // a new commit (Bitbucket kept the approval)
        XCTAssertEqual(try bb.fetch(review: true, mine: false, force: true).map(\.id), ["bb:acme/api#7"])
        approved = false
        XCTAssertEqual(try bb.fetch(review: true, mine: false, force: true).count, 1)
        XCTAssertNil((d.dictionary(forKey: InboxPrefs.bbApprovedHead) as? [String: String])?["bb:acme/api#7"])
        // Asking for changes keeps it in the list.
        var i = BitbucketClient.item(pr(7), reason: .review, me: "acc-me")!
        i.youApproved = true; i.youRequestedChanges = true
        XCTAssertTrue(bb.keepForReview(i))
    }

    func testSkippedWorkspacesAreNotRead() throws {
        let (bb, d, f) = store()
        d.set("acme", forKey: InboxPrefs.bbSkipped)
        world(f, reviews: ["acme/api": [pr(7, reviewers: ["acc-me"])]], mine: [pr(9, author: "acc-me")])
        XCTAssertEqual(try bb.fetch(review: true, mine: true).count, 0)
        XCTAssertEqual(f.count("/workspaces/acme/"), 0)
        XCTAssertEqual(f.count("/repositories/acme"), 0)
    }

    func testPagingFollowsNextOnTheApiHostOnly() throws {
        let (bb, _, f) = store()
        f.handlers.append { p in
            if p == "/list" { return self.page([["n": 1]], next: "https://api.bitbucket.org/2.0/list?page=2") }
            if p == "https://api.bitbucket.org/2.0/list?page=2" { return self.page([["n": 2]], next: "https://api.bitbucket.org/2.0/list?page=3") }
            return nil
        }
        XCTAssertEqual(try bb.values("/list", pages: 2).count, 2)
        XCTAssertEqual(f.asked.count, 2)          // stops at the page limit
    }

    // MARK: The store

    func testStoreAppliesBitbucketItemsAndReadMarks() {
        let name = "bbstore-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        let store = InboxStore(defaults: d)
        store.deliver = { _ in }; store.chime = {}
        store.background = { $0() }; store.onMain = { $0() }
        store.appeared = { _ in }
        let i = BitbucketClient.item(pr(7, reviewers: ["acc-me"]), reason: .review, me: "acc-me")!
        store.apply(.bitbucket, .success([i]))
        XCTAssertEqual(store.items.map(\.id), [i.id])
        XCTAssertFalse(store.isUnread(i))                         // the first fetch counts as read
        // A Bitbucket refresh doesn't prune GitHub marks.
        d.set(["gh:o/r#1": 1.0], forKey: InboxPrefs.seen)
        let s2 = InboxStore(defaults: d)
        s2.deliver = { _ in }; s2.chime = {}; s2.background = { $0() }; s2.onMain = { $0() }; s2.appeared = { _ in }
        s2.apply(.bitbucket, .success([i]))
        XCTAssertNotNil(s2.seen["gh:o/r#1"])
        XCTAssertEqual(InboxStore.repoKey(i), "bitbucket.org/acme/api")
    }

    // MARK: Agents, notifications, automations, Jira (B2)

    private func bbItem(_ reason: InboxItem.Reason = .review, failed: [InboxItem.FailedCheck] = []) -> InboxItem {
        var i = BitbucketClient.item(pr(7, reviewers: ["acc-me"]), reason: reason, me: "acc-me")!
        if !failed.isEmpty { i.checks = .failing; i.failedCheckDetails = failed; i.failedChecks = failed.map(\.name) }
        return i
    }

    func testPromptsUseGitNotGh() {
        let review = InboxStart.prompt(bbItem(), .review)
        XCTAssertTrue(review.contains("git fetch origin feature-7 main"))
        XCTAssertTrue(review.contains("git diff origin/main...origin/feature-7"))
        XCTAssertFalse(review.contains("gh "))
        XCTAssertTrue(review.contains("<work-item source=\"Bitbucket\">"))
        let fix = InboxStart.prompt(bbItem(failed: [.init(name: "Pipeline #3", url: "u")]), .fix)
        XCTAssertTrue(fix.contains("(Pipeline #3)"))
        XCTAssertTrue(fix.contains("git fetch origin feature-7 && git checkout feature-7"))
        XCTAssertTrue(fix.contains("Don't commit or push."))
        XCTAssertFalse(fix.contains("gh "))
        let work = InboxStart.prompt(bbItem(.mine), .work)
        XCTAssertTrue(work.hasPrefix("Work on pull request #7 of acme/api on Bitbucket"))
        XCTAssertTrue(InboxStart.askPrompt(bbItem()).contains("this Bitbucket pull request"))
    }

    func testFixEvidenceFromBuilds() {
        let i = bbItem(failed: [.init(name: "Pipeline #3", url: "https://bitbucket.org/acme/api/pipelines/results/3", title: "Tests failed")])
        // No gh log is read for Bitbucket; without a Pipelines reader the build's own words and link go in.
        let parts = InboxCI.collect(i, log: { _, _ in XCTFail("gh asked"); return "" })
        XCTAssertEqual(parts, [.init(name: "Pipeline #3", text: "Tests failed")])
        var bare = i; bare.failedCheckDetails = [.init(name: "Lint", url: "https://x/1")]
        XCTAssertEqual(InboxCI.collect(bare, log: { _, _ in "" }).first?.text, "(no log; see https://x/1)")
        XCTAssertEqual(InboxCI.collect(bare, log: { _, _ in "" }, bitbucketLog: { _, _ in "line\nError: boom" }).first?.text, "line\nError: boom")
    }

    func testRulesMatchBitbucket() {
        let r = InboxRule(name: "r", source: "bitbucket", kind: "pr", reason: InboxItem.Reason.review.rawValue, place: "acme")
        XCTAssertTrue(r.matches(bbItem()))
        XCTAssertFalse(r.matches(bbItem(.mine)))
        XCTAssertTrue(r.summary.contains("from Bitbucket"))
        XCTAssertFalse(InboxRule(name: "g", source: "github").matches(bbItem()))
    }

    func testJiraKeys() {
        let known: Set<String> = ["SHOP", "DC"]
        XCTAssertEqual(InboxStore.jiraKeys(title: "SHOP-7: fix and DC-12", branch: "feature/shop-7-x", known: known), ["SHOP-7", "DC-12"])
        XCTAssertEqual(InboxStore.jiraKeys(title: "Refunds", branch: "feature/dc-4162-split", known: known), ["DC-4162"])
        XCTAssertEqual(InboxStore.jiraKeys(title: "UTF-8 and SHOP-0", branch: nil, known: known), [])        // unknown project; no -0
        // No projects known yet: the title's keys only (branches are too loose then).
        XCTAssertEqual(InboxStore.jiraKeys(title: "ABC-1 tidy", branch: "xyz-2", known: []), ["ABC-1"])
        XCTAssertEqual(InboxStore.jiraKeys(title: "XSHOP-7", branch: nil, known: ["SHOP"]), [])
    }

    private func quietStore() -> (InboxStore, () -> [AppNotification]) {
        let name = "bbstore-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        let store = InboxStore(defaults: d)
        var sent: [AppNotification] = []
        store.deliver = { sent.append($0) }; store.chime = {}
        store.background = { $0() }; store.onMain = { $0() }
        store.appeared = { _ in }
        return (store, { sent })
    }

    func testJiraLinksInTheStore() {
        let (store, _) = quietStore()
        store.fixtureOn = [.jira, .bitbucket]
        store.jiraProjects = [(id: "1", key: "SHOP", name: "Shop")]
        var p = bbItem(); p = InboxItem(id: p.id, source: .bitbucket, kind: .pr, key: p.key, place: p.place, title: "Refunds", author: "Ann",
                                        assignee: nil, status: "Open", statusTone: "done", reason: .review, updated: Date(), body: "", url: "",
                                        branch: "feature/SHOP-7-split", number: 7, base: "main")
        let issue = InboxItem(id: "jira:SHOP-7", source: .jira, kind: .issue, key: "SHOP-7", place: "Shop", title: "Split refunds", author: "",
                              assignee: "You", status: "In Progress", statusTone: "progress", reason: .assigned, updated: Date(), body: "",
                              url: "https://x.atlassian.net/browse/SHOP-7")
        store.apply(.bitbucket, .success([p]))
        store.apply(.jira, .success([issue]))
        XCTAssertEqual(store.jiraKeys(p), ["SHOP-7"])
        XCTAssertEqual(store.jiraItem("SHOP-7")?.id, issue.id)
        XCTAssertEqual(store.pullRequests(naming: "SHOP-7").map(\.id), [p.id])
        XCTAssertEqual(InboxStart.relatedJira(p, store: store), "Jira: SHOP-7 Split refunds (https://x.atlassian.net/browse/SHOP-7)")
        store.fixtureOn = [.bitbucket]                      // Jira not connected: no links
        XCTAssertEqual(store.jiraKeys(p), [])
    }

    func testNotificationsForBitbucket() {
        let (store, sent) = quietStore()
        let first = bbItem(.mine)
        store.apply(.bitbucket, .success([first]))
        XCTAssertTrue(sent().isEmpty)                                        // the first fetch is quiet
        var review = BitbucketClient.item(pr(8, reviewers: ["acc-me"]), reason: .review, me: "acc-me")!
        review.updated = Date()
        var failing = first
        failing.checks = .failing
        failing.updated = first.updated.addingTimeInterval(30)             // a push whose build failed
        store.apply(.bitbucket, .success([failing, review]))
        XCTAssertEqual(sent().last?.title, "2 new in your Inbox")
        XCTAssertTrue(sent().last?.body.contains("Checks failed on #7") == true)
        XCTAssertTrue(sent().last?.body.contains("Review requested: #8") == true)
        // A change on your pull request says who did what, from its Activity.
        store.loadActivity = { _ in InboxActivity(events: [InboxEvent(kind: .review, actor: "Bob", date: Date(), summary: "approved", field: "review")]) }
        var approved = failing
        approved.updated = failing.updated.addingTimeInterval(60)
        store.apply(.bitbucket, .success([approved, review]))
        XCTAssertEqual(sent().last?.title, "#7: Bob approved")
    }

    func testLinkedNewsGoesToItsSession() {
        let (store, _) = quietStore()
        let i = bbItem(.mine)
        store.apply(.bitbucket, .success([i]))
        store.link(i.id, session: "s1", since: i.updated.timeIntervalSince1970)
        store.loadActivity = { _ in InboxActivity(events: [
            InboxEvent(kind: .comment, actor: "Bob", date: Date().addingTimeInterval(30), summary: "commented", detail: "Rename it?"),
            InboxEvent(kind: .change, actor: "Bob", date: Date().addingTimeInterval(30), summary: "opened it", field: "opened"),
        ]) }
        var later = i; later.updated = Date().addingTimeInterval(60)
        store.apply(.bitbucket, .success([later]))
        XCTAssertEqual(store.linkedNotices["s1"]?.events.map(\.summary), ["commented"])
        let text = InboxStore.linkedPrompt(store.linkedNotices["s1"]!, source: InboxSource.of(id: i.id)!.name)
        XCTAssertTrue(text.contains("<work-item-update source=\"Bitbucket\">"))
    }

    // MARK: Changes (B3)

    func testWriteRequests() {
        let i = bbItem()
        XCTAssertEqual(BitbucketWrites.request(.approve, i)?.method, "POST")
        XCTAssertEqual(BitbucketWrites.request(.approve, i)?.path, "/repositories/acme/api/pullrequests/7/approve")
        XCTAssertEqual(BitbucketWrites.request(.unapprove, i)?.method, "DELETE")
        XCTAssertEqual(BitbucketWrites.request(.requestChanges, i)?.path, "/repositories/acme/api/pullrequests/7/request-changes")
        XCTAssertEqual(BitbucketWrites.request(.undoRequestChanges, i)?.method, "DELETE")
        XCTAssertEqual(BitbucketWrites.request(.decline, i)?.path, "/repositories/acme/api/pullrequests/7/decline")
        for (a, strategy) in [(InboxPRAction.merge, "merge_commit"), (.squash, "squash"), (.fastForward, "fast_forward")] {
            let r = BitbucketWrites.request(a, i)
            XCTAssertEqual(r?.path, "/repositories/acme/api/pullrequests/7/merge")
            XCTAssertEqual(r?.body?["merge_strategy"] as? String, strategy)
            XCTAssertEqual(r?.body?["close_source_branch"] as? Bool, false)        // the branch stays
        }
        XCTAssertNil(BitbucketWrites.request(.rebase, i))
        XCTAssertNil(BitbucketWrites.request(.reopen, i))
    }

    func testAvailableBitbucketActions() {
        var i = bbItem()
        XCTAssertEqual(InboxPRAction.available(i), [.approve, .requestChanges, .merge, .squash, .fastForward, .decline])
        i.youApproved = true; i.youRequestedChanges = true
        XCTAssertEqual(InboxPRAction.available(i), [.unapprove, .undoRequestChanges, .merge, .squash, .fastForward, .decline])
        let mine = bbItem(.mine)
        var own = BitbucketClient.item(pr(9, author: "acc-me", draft: true), reason: .mine, me: "acc-me")!
        XCTAssertEqual(InboxPRAction.available(own), [.decline])                     // your own draft: no review, no merge
        own.ended = .init(label: "Declined", at: Date())
        XCTAssertEqual(InboxPRAction.available(own), [])
        XCTAssertFalse(InboxPRAction.available(mine).isEmpty)
        for a in InboxPRAction.available(i) {
            let c = a.confirmation(i)
            XCTAssertTrue(c.title.contains("#7"), a.rawValue)
            XCTAssertFalse(c.button.isEmpty)
        }
        XCTAssertTrue(InboxPRAction.decline.confirmation(i).message.contains("can't reopen"))
        // GitHub keeps its own list.
        XCTAssertFalse(InboxPRAction.available(InboxItem(id: "gh:o/r#1", source: .github, kind: .pr, key: "#1", place: "o/r", title: "t",
                                                         author: "a", assignee: nil, status: "Open", statusTone: "done", reason: .review,
                                                         updated: Date(), body: "", url: "", number: 1)).contains(.approve))
    }

    func testActionsGoThroughBitbucketAfterAYes() {
        let actions = InboxActions()
        var asked: [String] = [], answer = true, called: [String] = [], changed = 0
        actions.confirm = { t, _, _, done in asked.append(t); done(answer) }
        actions.background = { $0() }; actions.onMain = { $0() }
        actions.run = { _ in XCTFail("gh ran for Bitbucket"); return "" }
        actions.bitbucket = { a, i in called.append("\(a.rawValue) \(i.id)"); return "" }
        actions.changed = { _ in changed += 1 }
        let i = bbItem()
        answer = false
        actions.perform(.approve, on: i)
        XCTAssertEqual(called, [])
        answer = true
        actions.perform(.approve, on: i)
        XCTAssertEqual(called, ["approve bb:acme/api#7"])
        XCTAssertEqual(actions.results[i.id]?.ok, true)
        XCTAssertEqual(changed, 1)
        actions.perform(.unapprove, on: i)                       // not offered while you haven't approved
        XCTAssertEqual(called.count, 1)
        actions.bitbucket = { _, _ in throw InboxError("Bitbucket refused (403)") }
        actions.perform(.decline, on: i)
        XCTAssertEqual(actions.results[i.id]?.ok, false)
        XCTAssertEqual(asked.count, 3)
    }

    func testBuildNumber() {
        XCTAssertEqual(BitbucketInbox.buildNumber("https://bitbucket.org/acme/api/pipelines/results/318"), 318)
        XCTAssertEqual(BitbucketInbox.buildNumber("https://bitbucket.org/acme/api/addon/pipelines/home#!/results/42"), 42)
        XCTAssertNil(BitbucketInbox.buildNumber("https://ci.example.com/job/7"))
    }

    func testPipelineLog() throws {
        let (bb, _, f) = store()
        f.handlers.append { p in
            if p.hasPrefix("/repositories/acme/api/pipelines?") {
                XCTAssertTrue(p.contains("target.commit.hash=h1"))
                return self.page([["build_number": 317, "uuid": "{p-317}"], ["build_number": 318, "uuid": "{p-318}"]])
            }
            if p.hasPrefix("/repositories/acme/api/pipelines/%7Bp-318%7D/steps?") {
                return self.page([
                    ["uuid": "{s-1}", "name": "build", "state": ["result": ["name": "SUCCESSFUL"]]],
                    ["uuid": "{s-2}", "name": "test", "state": ["result": ["name": "FAILED"]]],
                ])
            }
            return nil
        }
        var logs: [String] = []
        bb.stepLog = { p in logs.append(p); return "FAIL x.test.ts\tExpected 1" }
        let i = bbItem(failed: [.init(name: "Pipeline #318", url: "https://bitbucket.org/acme/api/pipelines/results/318")])
        XCTAssertEqual(try bb.pipelineLog(i, i.failedCheckDetails[0]), "FAIL x.test.ts\tExpected 1")
        XCTAssertEqual(logs, ["/repositories/acme/api/pipelines/%7Bp-318%7D/steps/%7Bs-2%7D/log"])
        XCTAssertThrowsError(try bb.pipelineLog(i, .init(name: "Jenkins", url: "https://ci.example.com/job/7")))
        // A Pipelines log is plain lines: tabs stay.
        XCTAssertEqual(InboxCI.clean("a\tb\nError: c", fields: false), "a\tb\nError: c")
        XCTAssertEqual(InboxCI.collect(i, log: { _, _ in "" }, bitbucketLog: { bb2, c in try bb.pipelineLog(bb2, c) }).first?.text, "FAIL x.test.ts\tExpected 1")
    }

    func testCommentsGoThroughTheWriter() {
        let (store, _) = quietStore()
        var wrote: [String] = []
        store.commentWriter = { i, t in wrote.append("\(i.source.rawValue): \(t)") }
        let done = expectation(description: "posted")
        store.postComment(bbItem(), "Looks good") { err in XCTAssertNil(err); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(wrote, ["bitbucket: Looks good"])
    }

    // MARK: Detail polish

    func testHiddenReposAreNotScannedAndTheScanIsKept() throws {
        let (bb, _, f) = store()
        bb.skippedRepos = ["acme/web"]
        world(f, reviews: [:], repos: ["acme/api", "acme/web"])
        _ = try bb.fetch(review: true, mine: false)
        XCTAssertEqual(f.count("/repositories/acme/web/pullrequests?"), 0)
        XCTAssertEqual(bb.lastScan, ["acme/api"])
    }

    func testYourReviewAndWhoAsked() {
        let (store, _) = quietStore()
        var bbI = bbItem()
        XCTAssertEqual(store.yourReview(bbI), .none)
        bbI.youApproved = true
        XCTAssertEqual(store.yourReview(bbI), .approved)
        bbI.youRequestedChanges = true
        XCTAssertEqual(store.yourReview(bbI), .changes)
        let gh = InboxItem(id: "gh:o/r#1", source: .github, kind: .pr, key: "#1", place: "o/r", title: "t", author: "ann", assignee: nil,
                           status: "Open", statusTone: "done", reason: .review, updated: Date(), body: "", url: "", number: 1)
        store.loadActivity = { _ in InboxActivity(events: [
            InboxEvent(kind: .change, actor: "ann", date: Date(timeIntervalSince1970: 1), summary: "asked you for a review", field: "review request"),
            InboxEvent(kind: .review, actor: "You", date: Date(timeIntervalSince1970: 2), summary: "requested changes", field: "review"),
            InboxEvent(kind: .review, actor: "You", date: Date(timeIntervalSince1970: 3), summary: "approved", field: "review"),
        ]) }
        store.apply(.github, .success([gh]))
        let loaded = expectation(description: "activity")
        store.loadActivity(gh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(store.reviewAskedBy(gh), "ann")
        XCTAssertEqual(store.yourReview(gh), .approved)               // the newest one
    }

    func testJiraLookupForIssuesNotListed() {
        let (store, _) = quietStore()
        store.fixtureOn = [.jira]
        var asked: [String] = []
        store.jiraLookup = { k in asked.append(k); return ("Title of \(k)", "In Progress") }
        store.lookUpJira(["DC-1", "DC-2"])
        store.lookUpJira(["DC-1"])                                    // read once
        XCTAssertEqual(asked, ["DC-1", "DC-2"])
        XCTAssertEqual(store.jiraLookups["DC-2"]?.status, "In Progress")
        store.fixtureOn = []
        store.lookUpJira(["DC-9"])                                    // Jira not connected: nothing read
        XCTAssertEqual(asked.count, 2)
    }

    func testQuoteBlocksAndLongComments() {
        XCTAssertEqual(InboxMarkdown.quote("> ## Paused\n> wait"), "## Paused\nwait")
        XCTAssertEqual(InboxMarkdown.quote(">> nested"), "> nested")
        XCTAssertNil(InboxMarkdown.quote("> a\nb"))
        XCTAssertFalse(InboxActivityView.isLong("one\ntwo"))
        XCTAssertTrue(InboxActivityView.isLong((1...8).map(String.init).joined(separator: "\n")))
        XCTAssertTrue(InboxActivityView.isLong(String(repeating: "x", count: 800)))
    }

    // MARK: Tasks and reviewers

    func testReviewersAndTaskCount() {
        var p = pr(7, participants: [
            ["user": ["account_id": "acc-eli", "display_name": "Eli"], "role": "REVIEWER", "approved": false, "state": "changes_requested"],
            ["user": ["account_id": "acc-max", "display_name": "Max"], "role": "REVIEWER", "approved": true, "state": "approved"],
            ["user": ["account_id": "acc-bob", "display_name": "Bob"], "role": "PARTICIPANT", "approved": false],                 // only commented
            ["user": ["account_id": "acc-zoe", "display_name": "Zoe"], "role": "PARTICIPANT", "approved": true],                  // approved, not a reviewer
        ], reviewers: ["acc-me", "acc-eli", "acc-max"])
        p["reviewers"] = [["account_id": "acc-me", "display_name": "Me"], ["account_id": "acc-eli", "display_name": "Eli"], ["account_id": "acc-max", "display_name": "Max"]]
        p["task_count"] = 2
        let i = BitbucketClient.item(p, reason: .review, me: "acc-me")!
        XCTAssertEqual(i.openTasks, 2)
        XCTAssertEqual(i.reviewers.map(\.name), ["Me", "Eli", "Max", "Zoe"])
        XCTAssertEqual(i.reviewers.map(\.state), [.none, .changes, .approved, .approved])
        XCTAssertEqual(i.reviewers.first?.isMe, true)
        XCTAssertTrue(BitbucketClient.prFields.contains("%2Bvalues.task_count"))
    }

    func testTasks() {
        let t = BitbucketClient.tasks([
            ["id": 10, "state": "RESOLVED", "content": ["raw": "Rename"], "creator": ["account_id": "acc-eli", "display_name": "Eli"]],
            ["id": 12, "state": "UNRESOLVED", "content": ["raw": "Test three"], "creator": ["account_id": "acc-me", "display_name": "Me"]],
            ["id": 11, "state": "UNRESOLVED", "content": ["raw": "Remainder"], "creator": ["display_name": "Max"]],
            ["state": "UNRESOLVED"],
        ], me: "acc-me")
        XCTAssertEqual(t.map(\.id), [11, 12, 10])                         // open first
        XCTAssertEqual(t.map(\.creator), ["Max", "You", "Eli"])
        let (store, _) = quietStore()
        var asked: [String] = [], answer = false, wrote: [String] = []
        store.confirmChange = { title, _, _, done in asked.append(title); done(answer) }
        store.taskLoader = { _ in t }
        store.taskWriter = { i, id, r in wrote.append("\(id) \(r)") }
        let i = bbItem()
        store.loadTasks(i)
        XCTAssertEqual(store.prTasks[i.id]?.count, 3)
        store.setTask(i, t[0], resolved: true)
        XCTAssertEqual(wrote, [])                                            // said no
        answer = true
        store.setTask(i, t[0], resolved: true)
        XCTAssertEqual(wrote, ["11 true"])
        XCTAssertEqual(store.prTasks[i.id]?.first { $0.id == 11 }?.resolved, true)
        XCTAssertEqual(asked, ["Mark the task resolved?", "Mark the task resolved?"])
    }
}
