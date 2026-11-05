import Foundation

/// Made-up Inbox items and history for the debug fixture (`ui_action inbox_fake`): no account is read or written.
enum InboxFixture {
    static func load(now: Date = Date()) {
        let t = now.timeIntervalSince1970
        func at(_ minutesAgo: Double) -> Date { Date(timeIntervalSince1970: t - minutesAgo * 60) }
        var pr = InboxItem(id: "gh:octo/storefront#42", source: .github, kind: .pr, key: "#42", place: "octo/storefront",
                           title: "Checkout: retry failed payments once", author: "ann", assignee: nil, status: "Open", statusTone: "done",
                           reason: .review, updated: at(5), body: "Retries a declined payment once when the gateway times out.\n\n- adds `RetryPolicy`\n- logs the second attempt",
                           url: "https://github.com/octo/storefront/pull/42", branch: "ann/payment-retry", number: 42)
        pr.checks = .failing; pr.checkCounts = (5, 2, 0); pr.failedChecks = ["test (ubuntu-latest)", "Vercel"]
        pr.failedCheckDetails = [
            .init(name: "test (ubuntu-latest)", url: "https://github.com/octo/storefront/actions/runs/111/job/222", title: "Process completed with exit code 1"),
            .init(name: "Vercel", url: "https://vercel.example/octo/storefront/abc", title: "Deployment failed", summary: "Build step: `next build` exited with 1"),
        ]
        InboxStore.shared.ciLog = { _, job in
            guard job == "222" else { throw InboxError("no such job") }
            return """
            test\tRun tests\t2026-11-05T09:00:00.0000000Z ##[group]Run npm test
            test\tRun tests\t2026-11-05T09:00:01.0000000Z > storefront@1.0.0 test
            test\tRun tests\t2026-11-05T09:00:05.0000000Z FAIL src/checkout/retry.test.ts
            test\tRun tests\t2026-11-05T09:00:05.1000000Z   ● RetryPolicy › retries a timed-out payment once
            test\tRun tests\t2026-11-05T09:00:05.2000000Z     expect(received).toBe(expected)
            test\tRun tests\t2026-11-05T09:00:05.3000000Z     Expected: 1
            test\tRun tests\t2026-11-05T09:00:05.4000000Z     Received: 2
            test\tRun tests\t2026-11-05T09:00:06.0000000Z ##[error]Process completed with exit code 1.
            """
        }
        let issue = InboxItem(id: "jira:SHOP-7", source: .jira, kind: .issue, key: "SHOP-7", place: "Shop", title: "Price filter ignores the currency",
                              author: "Cem", assignee: "You", status: "Code Review", statusTone: "progress", reason: .assigned, updated: at(12),
                              body: "When the currency is EUR the filter still compares USD prices.", url: "https://example.atlassian.net/browse/SHOP-7")
        let quiet = InboxItem(id: "jira:SHOP-3", source: .jira, kind: .issue, key: "SHOP-3", place: "Shop", title: "Update the size guide",
                              author: "Bob", assignee: "Bob", status: "To Do", statusTone: "todo", reason: .project, updated: at(300),
                              body: "", url: "https://example.atlassian.net/browse/SHOP-3")
        let history: [String: InboxActivity] = [
            pr.id: InboxActivity(events: [
                InboxEvent(kind: .commits, actor: "ann", date: at(180), summary: "pushed a commit", detail: "Add RetryPolicy"),
                InboxEvent(kind: .commits, actor: "ann", date: at(175), summary: "pushed a commit", detail: "Log the second attempt"),
                InboxEvent(kind: .change, actor: "ann", date: at(170), summary: "asked you for a review", field: "review request"),
                InboxEvent(kind: .comment, actor: "bob", date: at(90), summary: "commented", detail: "Should the retry wait a bit first?"),
                InboxEvent(kind: .review, actor: "cem", date: at(30), summary: "requested changes", detail: "Please cap the retries at one in the config too.", field: "review"),
                InboxEvent(kind: .commits, actor: "ann", date: at(8), summary: "pushed a commit", detail: "Cap retries in config"),
                InboxEvent(kind: .change, actor: "ann", date: at(5), summary: "added the label payments", field: "labels"),
            ]),
            issue.id: InboxActivity(events: [
                InboxEvent(kind: .change, actor: "Cem", date: at(2000), summary: "assigned it to You", field: "assignee"),
                InboxEvent(kind: .change, actor: "You", date: at(600), summary: "moved it to In Progress", field: "status"),
                InboxEvent(kind: .comment, actor: "Bob", date: at(40), summary: "commented", detail: "Repro: switch to EUR, set max 50."),
                InboxEvent(kind: .change, actor: "Ann", date: at(12), summary: "moved it to Code Review", field: "status"),
            ]),
            quiet.id: InboxActivity(events: [
                InboxEvent(kind: .comment, actor: "Bob", date: at(300), summary: "commented", detail: "Waiting for the new measurements."),
            ], note: "The history isn't available (Jira answered 403). Showing comments only."),
        ]
        // Read up to an hour ago on the PR and the issue, so both have something new.
        InboxStore.shared.loadFixture([pr, issue, quiet], seen: [pr.id: t - 3600, issue.id: t - 3600, quiet.id: t], activity: history)
    }
}
