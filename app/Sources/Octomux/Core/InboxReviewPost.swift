import Foundation

/// Posting an agent review's findings to the pull request: each picked finding as a comment on its line, what can't
/// sit on a line (outside the change) in the review's text, and your verdict. Only ever after you confirm it.
enum InboxReviewPost {
    enum Verdict: String, CaseIterable, Identifiable {
        case comment, approve, requestChanges
        var id: String { rawValue }
        var title: String {
            switch self {
            case .comment: return "Comment only"
            case .approve: return "Approve"
            case .requestChanges: return "Request changes"
            }
        }
    }

    /// One comment as it will be posted.
    struct Comment: Equatable {
        var findingId: String
        var path: String
        var line: Int?
        var body: String
        /// On its line (the line is in the change); otherwise it goes in the review's text.
        var inline: Bool
    }

    struct Plan: Equatable {
        var comments: [Comment]
        var summary: String?
        var verdict: Verdict
        /// The commit the review read (GitHub anchors the comments there).
        var commit: String
    }

    /// Findings picked when the preview opens: the ones a reviewer would post (questions and nits wait for you).
    static func picked(_ f: InboxReviewResult.Finding) -> Bool { f.severity == "issue" || f.severity == "suggestion" }

    static func body(_ f: InboxReviewResult.Finding) -> String {
        let d = f.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return "**\(f.title)**" + (d.isEmpty ? "" : "\n\n" + d)
    }

    /// The lines of the new version each file's diff shows (added and context lines): the ones a comment can sit on.
    static func commentable(diff: String) -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        var file: String?
        var line = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if l.hasPrefix("diff --git ") { file = nil; continue }
            if l.hasPrefix("+++ ") {
                let p = String(l.dropFirst(4))
                file = p == "/dev/null" ? nil : (p.hasPrefix("b/") ? String(p.dropFirst(2)) : p)
                continue
            }
            if l.hasPrefix("--- ") { continue }
            if l.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                if let plus = l.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    line = Int(plus.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                continue
            }
            guard let f = file, line > 0 else { continue }
            if l.hasPrefix("+") || l.hasPrefix(" ") { out[f, default: []].insert(line); line += 1 }
            else if l.hasPrefix("-") || l.hasPrefix("\\") { continue }
        }
        return out
    }

    /// The comments for the picked findings, each on its line when the change shows that line.
    static func comments(_ findings: [InboxReviewResult.Finding], lines: [String: Set<Int>]?) -> [Comment] {
        findings.map { f in
            let inline = !f.file.isEmpty && f.line.map { lines?[f.file]?.contains($0) ?? false } == true
            return Comment(findingId: f.id, path: f.file, line: f.line, body: body(f), inline: inline)
        }
    }

    /// The review's own text: the summary when asked for, then the findings that couldn't go on a line.
    static func text(_ plan: Plan) -> String {
        var parts: [String] = []
        if let s = plan.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { parts.append(s) }
        for c in plan.comments where !c.inline {
            let place = c.path.isEmpty ? "" : "`\(c.path)\(c.line.map { ":\($0)" } ?? "")`: "
            parts.append(place + c.body)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: GitHub: one review with every comment and the verdict

    static func githubReview(_ plan: Plan) -> [String: Any] {
        var r: [String: Any] = [
            "commit_id": plan.commit,
            "event": plan.verdict == .approve ? "APPROVE" : plan.verdict == .requestChanges ? "REQUEST_CHANGES" : "COMMENT",
            "comments": plan.comments.filter(\.inline).map { ["path": $0.path, "line": $0.line ?? 0, "side": "RIGHT", "body": $0.body] as [String: Any] },
        ]
        let body = text(plan)
        if !body.isEmpty { r["body"] = body }
        return r
    }

    /// Posts it with gh; returns the review's link for every comment in it.
    static func postGitHub(_ i: InboxItem, _ plan: Plan) throws -> [String: String] {
        guard let repo = i.repo, let n = i.number else { throw InboxError("Not a GitHub pull request.") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: githubReview(plan)), as: UTF8.self)
        let out = try InboxShell.run(["gh", "api", "--method", "POST", "repos/\(repo)/pulls/\(n)/reviews", "--input", "-"], input: json)
        let url = ((try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any])?["html_url"] as? String ?? i.url
        return Dictionary(uniqueKeysWithValues: plan.comments.map { ($0.findingId, url) })
    }

    // MARK: Bitbucket: a comment each (no review to hold them), the text as one more, then the verdict

    static func bitbucketComment(_ c: Comment) -> [String: Any] {
        var b: [String: Any] = ["content": ["raw": c.body]]
        if c.inline, let line = c.line { b["inline"] = ["path": c.path, "to": line] }
        return b
    }

    /// Posts them one by one; on a failure it stops and says how far it got (what went stays marked as posted).
    static func postBitbucket(_ i: InboxItem, _ plan: Plan, request: (String, String, Any?) throws -> Data = { try BitbucketClient.request($0, method: $1, body: $2) },
                              posted: (String, String) -> Void) throws {
        func send(_ method: String, _ tail: String, _ body: Any?) throws -> Data {
            do { return try request(BitbucketWrites.path(i, tail), method, body) }
            catch let e as BitbucketHTTPError where e.code == 403 { throw BitbucketWrites.writeRefused(e) }
        }
        func link(_ d: Data) -> String {
            (((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["links"] as? [String: Any]).flatMap { ($0["html"] as? [String: Any])?["href"] as? String } ?? i.url
        }
        let inline = plan.comments.filter(\.inline)
        for (k, c) in inline.enumerated() {
            do { posted(c.findingId, link(try send("POST", "comments", bitbucketComment(c)))) }
            catch { throw InboxError("Posted \(k) of \(inline.count) comments, then: \(error)") }
        }
        let body = text(plan)
        if !body.isEmpty {
            let d = try send("POST", "comments", ["content": ["raw": body]])
            for c in plan.comments where !c.inline { posted(c.findingId, link(d)) }
        }
        switch plan.verdict {
        case .approve: _ = try send("POST", "approve", nil)
        case .requestChanges: _ = try send("POST", "request-changes", nil)
        case .comment: break
        }
    }
}
