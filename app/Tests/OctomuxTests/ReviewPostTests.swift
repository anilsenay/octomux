import XCTest
@testable import Octomux

final class ReviewPostTests: XCTestCase {
    private let diff = """
    diff --git a/src/pay.ts b/src/pay.ts
    index 1..2 100644
    --- a/src/pay.ts
    +++ b/src/pay.ts
    @@ -10,4 +10,5 @@ export function pay() {
     const a = 1
    -const b = 2
    +const b = 3
    +const c = 4
     return a
    \\ No newline at end of file
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    """

    private func f(_ file: String, _ line: Int?, _ sev: String, _ title: String) -> InboxReviewResult.Finding {
        .init(file: file, line: line, severity: sev, title: title, detail: "Do it.")
    }

    private func item(_ source: InboxSource, author: String = "ann") -> InboxItem {
        InboxItem(id: source == .github ? "gh:o/r#5" : "bb:acme/api#5", source: source, kind: .pr, key: "#5", place: source == .github ? "o/r" : "acme/api",
                  title: "t", author: author, assignee: nil, status: "Open", statusTone: "done", reason: .review, updated: Date(), body: "", url: "https://x/5", number: 5)
    }

    func testCommentableLinesAreTheNewSidesHunkLines() {
        let lines = InboxReviewPost.commentable(diff: diff)
        XCTAssertEqual(lines["src/pay.ts"], [10, 11, 12, 13])   // context, the two added, context
        XCTAssertNil(lines["old.txt"])
    }

    func testFindingsOnLinesOutsideTheChangeGoInTheText() {
        let lines = InboxReviewPost.commentable(diff: diff)
        let cs = InboxReviewPost.comments([f("src/pay.ts", 11, "issue", "B"), f("src/pay.ts", 40, "suggestion", "Far"), f("", nil, "issue", "Whole")], lines: lines)
        XCTAssertEqual(cs.map(\.inline), [true, false, false])
        XCTAssertEqual(cs[0].body, "**B**\n\nDo it.")
        // No diff to go by (the worktree is gone): nothing is put on a line it might not be in.
        XCTAssertEqual(InboxReviewPost.comments([f("src/pay.ts", 11, "issue", "B")], lines: nil).map(\.inline), [false])
        // The default pick: issues and suggestions.
        XCTAssertEqual(["issue", "suggestion", "question", "nit"].map { InboxReviewPost.picked(f("a", 1, $0, "x")) }, [true, true, false, false])
    }

    func testGitHubIsOneReviewAnchoredToTheReviewedCommit() {
        let lines = InboxReviewPost.commentable(diff: diff)
        let cs = InboxReviewPost.comments([f("src/pay.ts", 11, "issue", "B"), f("src/pay.ts", 40, "suggestion", "Far")], lines: lines)
        let r = InboxReviewPost.githubReview(.init(comments: cs, summary: "Looks close.", verdict: .requestChanges, commit: "abc123"))
        XCTAssertEqual(r["commit_id"] as? String, "abc123")
        XCTAssertEqual(r["event"] as? String, "REQUEST_CHANGES")
        let inline = r["comments"] as! [[String: Any]]
        XCTAssertEqual(inline.count, 1)
        XCTAssertEqual(inline[0]["path"] as? String, "src/pay.ts"); XCTAssertEqual(inline[0]["line"] as? Int, 11); XCTAssertEqual(inline[0]["side"] as? String, "RIGHT")
        XCTAssertEqual(r["body"] as? String, "Looks close.\n\n`src/pay.ts:40`: **Far**\n\nDo it.")
        // No summary, nothing outside: no body at all (GitHub takes a COMMENT review with comments alone).
        let bare = InboxReviewPost.githubReview(.init(comments: [cs[0]], summary: nil, verdict: .comment, commit: "abc"))
        XCTAssertNil(bare["body"]); XCTAssertEqual(bare["event"] as? String, "COMMENT")
    }

    func testBitbucketPostsOneByOneThenTheVerdict() throws {
        let lines = InboxReviewPost.commentable(diff: diff)
        let cs = InboxReviewPost.comments([f("src/pay.ts", 11, "issue", "B"), f("src/pay.ts", 12, "issue", "C"), f("x.ts", 3, "nit", "Far")], lines: lines)
        var sent: [String] = [], marked: [String: String] = [:]
        try InboxReviewPost.postBitbucket(item(.bitbucket), .init(comments: cs, summary: nil, verdict: .approve, commit: "h"), request: { path, method, body in
            let b = body.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) } ?? "-"
            sent.append("\(method) \(path) \(b)")
            return Data(#"{"links": {"html": {"href": "https://bb/c\#(sent.count)"}}}"#.utf8)
        }, posted: { marked[$0] = $1 })
        XCTAssertEqual(sent, [
            #"POST /repositories/acme/api/pullrequests/5/comments {"content":{"raw":"**B**\n\nDo it."},"inline":{"path":"src\/pay.ts","to":11}}"#,
            #"POST /repositories/acme/api/pullrequests/5/comments {"content":{"raw":"**C**\n\nDo it."},"inline":{"path":"src\/pay.ts","to":12}}"#,
            #"POST /repositories/acme/api/pullrequests/5/comments {"content":{"raw":"`x.ts:3`: **Far**\n\nDo it."}}"#,
            "POST /repositories/acme/api/pullrequests/5/approve -",
        ])
        XCTAssertEqual(marked[cs[0].findingId], "https://bb/c1")
        XCTAssertEqual(marked[cs[2].findingId], "https://bb/c3")

        // A failure halfway: what went is marked, and the error says how far it got.
        var calls = 0; var half: [String: String] = [:]
        XCTAssertThrowsError(try InboxReviewPost.postBitbucket(item(.bitbucket), .init(comments: cs, summary: nil, verdict: .comment, commit: "h"), request: { _, _, _ in
            calls += 1
            if calls == 2 { throw BitbucketHTTPError(code: 500, message: "boom") }
            return Data("{}".utf8)
        }, posted: { half[$0] = $1 })) { XCTAssertTrue("\($0)".hasPrefix("Posted 1 of 2 comments")) }
        XCTAssertEqual(Array(half.keys), [cs[0].findingId])
    }

    func testPostingMarksFindingsAndTheyAreNotOfferedAgain() {
        let d = scratchDefaults("review-post-\(UUID())")
        let m = InboxReviews(defaults: d)
        m.background = { $0() }; m.onMain = { $0() }
        m.notify = { _, _ in }
        let i = item(.github)
        m.item = { _ in i }
        let p = Project(id: "p1", workspaceId: "w", name: "r", path: "/tmp/r", color: "#fff", icon: ProjectIcon(kind: "folder"), sort: 0, archived: false)
        m.project = { _ in p }
        m.prepare = { _, _, _, _ in .init(path: "/tmp/r.worktrees/x", head: "h1", base: "origin/main", lines: 3) }
        m.launch = { r, _, _, done in done("s1") }
        let res = InboxReviewResult(summary: "S", risk: "low", findings: [f("src/pay.ts", 11, "issue", "B"), f("src/pay.ts", 12, "nit", "N")])
        m.read = { _ in (res, false, false) }
        m.diffFor = { _ in self.diff }
        m.start(i, in: p, profileId: nil, auto: false)
        m.check()
        XCTAssertEqual(m.run(i.id)?.state, .done)
        var plans: [InboxReviewPost.Plan] = []
        m.poster = { _, plan, posted in plans.append(plan); for c in plan.comments { posted(c.findingId, "https://x/r1") } }
        let cs = m.comments(i.id, picked: [res.findings[0].id])
        XCTAssertEqual(cs.map(\.inline), [true])
        var err: String? = "unset"
        m.post(i, .init(comments: cs, summary: nil, verdict: .comment, commit: "h1")) { err = $0 }
        XCTAssertNil(err)
        XCTAssertEqual(m.run(i.id)?.posted?[res.findings[0].id], "https://x/r1")
        XCTAssertTrue(m.comments(i.id, picked: Set(res.findings.map(\.id))).map(\.findingId) == [res.findings[1].id])   // the posted one isn't offered
    }
}
