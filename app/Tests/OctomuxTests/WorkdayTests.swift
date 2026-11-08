import XCTest
@testable import Octomux

final class WorkdayTests: XCTestCase {
    private func pr(_ n: Int, branch: String?, reason: InboxItem.Reason = .mine, checks: InboxItem.Checks? = nil, status: String = "Open") -> InboxItem {
        var i = InboxItem(id: "gh:o/r#\(n)", source: .github, kind: .pr, key: "#\(n)", place: "o/r", title: "PR \(n)", author: "You",
                          assignee: nil, status: status, statusTone: "done", reason: reason, updated: Date(timeIntervalSince1970: 1000),
                          body: "", url: "", number: n)
        i.branch = branch
        i.checks = checks
        return i
    }
    private func issue(_ key: String) -> InboxItem {
        InboxItem(id: "jira:\(key)", source: .jira, kind: .issue, key: key, place: "Shop", title: key, author: "ann",
                  assignee: nil, status: "To Do", statusTone: "todo", reason: .assigned, updated: Date(timeIntervalSince1970: 1000), body: "", url: "")
    }
    private func session(_ id: String, _ a: Activity, kind: SessionKind = .agent) -> Session {
        Session(id: id, projectId: "p", kind: kind, profileId: nil, title: id, customTitle: "", cwd: "/",
                state: .running, activity: a, unread: false, agentSessionId: nil, createdAt: 0, lastActivityAt: 0,
                exitCode: nil, placement: .tab, command: nil, worktree: nil, transcriptPath: nil, agentTitle: nil)
    }

    // MARK: Work links

    func testSessionLinksToItsItemsBranchPRAndIssueKey() {
        let items = [pr(1, branch: "shop-12-cart"), pr(2, branch: "other"), issue("SHOP-12"), issue("SHOP-123"), pr(3, branch: "x")]
        let got = WorkLinks.items(session: "s1", branch: "shop-12-cart", items: items, links: ["gh:o/r#3": "s1"])
        XCTAssertEqual(got.map(\.key), ["#3", "#1", "SHOP-12"])   // pull requests first; SHOP-123 is another key
    }

    func testSharedBranchesLinkOnlyThroughTheInbox() {
        let items = [pr(1, branch: "main"), issue("MAIN-1")]
        XCTAssertEqual(WorkLinks.items(session: "s", branch: "main", items: items, links: [:]).count, 0)
        XCTAssertEqual(WorkLinks.items(session: "s", branch: nil, items: items, links: ["jira:MAIN-1": "s"]).map(\.key), ["MAIN-1"])
    }

    func testKeyMatchesAsAWholeWord() {
        XCTAssertTrue(WorkLinks.containsKey("feature/shop-12-x", "shop-12"))
        XCTAssertTrue(WorkLinks.containsKey("shop-12", "shop-12"))
        XCTAssertFalse(WorkLinks.containsKey("shop-123", "shop-12"))
        XCTAssertFalse(WorkLinks.containsKey("workshop-12", "shop-12"))
        XCTAssertTrue(WorkLinks.containsKey("workshop-12-shop-12", "shop-12"))
    }

    // MARK: Next step

    func testNextStep() {
        XCTAssertEqual(PRNextStep.of(pr(1, branch: nil, checks: .failing)), .fixChecks)
        var changes = pr(2, branch: nil, checks: .passing); changes.changesRequested = 1
        XCTAssertEqual(PRNextStep.of(changes), .addressChanges)
        XCTAssertEqual(PRNextStep.of(pr(3, branch: nil, checks: .passing, status: "Draft")), .markReady)
        XCTAssertEqual(PRNextStep.of(pr(4, branch: nil, checks: .pending, status: "Draft")), .waitChecks)
        XCTAssertEqual(PRNextStep.of(pr(5, branch: nil, checks: .pending)), .waitChecks)
        var ok = pr(6, branch: nil, checks: .passing); ok.approvals = 1
        XCTAssertEqual(PRNextStep.of(ok), .merge)
        XCTAssertEqual(PRNextStep.of(pr(7, branch: nil, checks: .passing)), .waitReview)
        XCTAssertEqual(PRNextStep.of(issue("A-1")), .none)
        XCTAssertTrue(PRNextStep.merge.isAction)
        XCTAssertFalse(PRNextStep.waitReview.isAction)
    }

    // MARK: Activity log

    func testTransitionsRecordFinishedWaitingAndErrors() {
        let old = [session("a", .working), session("b", .working), session("c", .working), session("d", .idle), session("t", .working, kind: .terminal)]
        let new = [session("a", .done), session("b", .needsInput), session("c", .error), session("d", .working), session("t", .done, kind: .terminal), session("e", .done)]
        let ev = ActivityLog.transitions(old: old, new: new) { $0.id }
        XCTAssertEqual(ev.map(\.kind), [.finished, .waiting, .error])
        XCTAssertEqual(ev.map(\.sessionId), ["a", "b", "c"])   // a new session or a terminal is no news
    }

    func testAwayIsSinceYouLeftNewestFirstAndKept() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = ActivityLog(file: file)
        let t0 = Date()
        log.now = { t0.addingTimeInterval(-9 * 3600) }
        log.record(.finished, "old")
        log.now = { t0.addingTimeInterval(-60) }
        log.record(.automation, "rule ran")
        log.now = { t0 }
        log.record(.finished, "new")
        XCTAssertEqual(log.away().map(\.title), ["new", "rule ran"])   // no "left" yet: the last 8 hours
        let again = ActivityLog(file: file)
        XCTAssertEqual(again.events.map(\.title), ["old", "rule ran", "new"])
        for i in 0..<(ActivityLog.keep + 5) { log.record(.finished, "\(i)") }
        XCTAssertEqual(log.events.count, ActivityLog.keep)
    }

    func testStatusLine() {
        XCTAssertEqual(HomeToday.statusLine(needs: 0, reviews: 0, steps: 0), "Nothing needs you right now.")
        XCTAssertEqual(HomeToday.statusLine(needs: 2, reviews: 1, steps: 0), "2 agents need you · 1 review for you")
        XCTAssertEqual(HomeToday.statusLine(needs: 1, reviews: 0, steps: 3), "1 agent needs you · 3 pull requests need a step")
    }

    // MARK: Since you looked

    private func git(_ args: [String], _ dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }

    func testSinceLookedSeesNewEditedAndUntrackedFilesWithoutTouchingTheIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-since-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        git(["init", "-q"], dir)
        try "a\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git(["add", "."], dir); git(["commit", "-qm", "i"], dir)
        try "a\nb\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)   // uncommitted when you look
        let before = SinceLooked.run(["status", "--porcelain"], in: dir)
        let t1 = try XCTUnwrap(SinceLooked.tree(of: dir))
        XCTAssertEqual(SinceLooked.run(["status", "--porcelain"], in: dir), before)        // the real index is untouched
        XCTAssertEqual(SinceLooked.tree(of: dir), t1)                                      // nothing changed: same tree
        try "a\nb\nc\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "n\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        let t2 = try XCTUnwrap(SinceLooked.tree(of: dir))
        XCTAssertEqual(SinceLooked.files(from: t1, to: t2, in: dir).sorted(), ["a.txt", "new.txt"])
    }

    func testSinceLookedStore() {
        let d = UserDefaults(suiteName: "octomux-since-\(UUID().uuidString)")!
        let s = SinceLooked(defaults: d)
        s.background = { $0() }; s.onMain = { $0() }
        var tree = "t1"
        s.snapshot = { _ in tree }
        s.diff = { a, b, _ in ["\(a)>\(b)"] }
        XCTAssertNil(s.files("x"))                 // never looked
        s.seen("x", path: "/p")
        XCTAssertNotNil(s.lookedAt("x"))
        XCTAssertEqual(s.files("x", every: 0), [])
        tree = "t2"
        _ = s.files("x", every: 0)
        XCTAssertEqual(s.changed["x"], ["t1>t2"])
        XCTAssertEqual(SinceLooked(defaults: d).tree(for: "x"), "t1")   // kept across launches
        s.forget("x")
        XCTAssertNil(s.files("x"))
    }
}
