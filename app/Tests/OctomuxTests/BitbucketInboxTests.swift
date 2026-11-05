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
        XCTAssertEqual(ev.first { $0.kind == .comment }?.detail, "On `src/a.ts:42`:\n\nWhy?")
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
}
