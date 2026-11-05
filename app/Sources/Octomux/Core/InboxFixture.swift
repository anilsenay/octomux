import AppKit
import Foundation

/// Made-up Inbox items and history for the debug fixture (`ui_action inbox_fake`): no account is read or written.
enum InboxFixture {
    static var fixtureItems: [InboxItem] = []
    /// Commands the fixture's write actions would have run.
    static var ran: [String] = []

    /// A refresh in which the pull request is gone from the open searches because it was merged.
    static func mergePR() {
        let store = InboxStore.shared
        store.endedState = { list in
            Dictionary(uniqueKeysWithValues: list.filter { $0.kind == .pr }.map { ($0.id, InboxItem.Ended(label: "Merged", merged: true, at: Date())) })
        }
        store.fixtureApply(.github, fixtureItems.filter { $0.source == .github && $0.kind != .pr })
    }

    static func load(now: Date = Date()) {
        let t = now.timeIntervalSince1970
        func at(_ minutesAgo: Double) -> Date { Date(timeIntervalSince1970: t - minutesAgo * 60) }
        var pr = InboxItem(id: "gh:octo/storefront#42", source: .github, kind: .pr, key: "#42", place: "octo/storefront",
                           title: "Checkout: retry failed payments once", author: "ann", assignee: nil, status: "Open", statusTone: "done",
                           reason: .review, updated: at(5), body: "Retries a declined payment once when the gateway times out.\n\n- adds `RetryPolicy`\n- logs the second attempt\n\n![Retry flow](https://user-images.githubusercontent.com/1/retry-flow.png)\n\n<img src=\"https://tracker.example.com/pixel.gif\" width=\"1\">",
                           url: "https://github.com/octo/storefront/pull/42", branch: "ann/payment-retry", number: 42, base: "main")
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
                              body: "When the currency is EUR the filter still compares USD prices.\n\n![eur-filter.png](jira-attachment:eur-filter.png)", url: "https://example.atlassian.net/browse/SHOP-7")
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
        fixtureItems = [pr, issue, quiet]
        // Writes go nowhere: the commands are only recorded.
        ran = []
        InboxActions.shared.run = { args in ran.append(args.joined(separator: " ")); return "" }
        let jira = InboxJiraActions.shared
        jira.loadTransitions = { _ in [
            .init(id: "21", name: "Back to work", to: "In Progress", category: "indeterminate"),
            .init(id: "31", name: "Approve", to: "Done", category: "done"),
        ] }
        jira.doTransition = { k, id in ran.append("jira move \(k) \(id)") }
        jira.doAssign = { k in ran.append("jira assign \(k)") }
        jira.loadTypes = { _ in [.init(id: "10001", name: "Task"), .init(id: "10002", name: "Bug")] }
        jira.doCreate = { p, t, s, _, mine in ran.append("jira create \(p) \(t) \(s) mine=\(mine)"); return "\(p)-100" }
        jira.loadFilters = { [.init(id: "1", name: "Shop bugs", jql: "project = SHOP AND type = Bug ORDER BY priority"),
                              .init(id: "2", name: "Waiting for me", jql: "assignee = currentUser() AND status = \"In Review\"")] }
        InboxStore.shared.jiraProjects = [(id: "1", key: "SHOP", name: "Shop")]
        InboxStore.shared.loadDiff = { _ in
            """
            diff --git a/src/checkout/retry.ts b/src/checkout/retry.ts
            new file mode 100644
            index 0000000..3b18e51
            --- /dev/null
            +++ b/src/checkout/retry.ts
            @@ -0,0 +1,9 @@
            +export class RetryPolicy {
            +  constructor(private readonly max = 1) {}
            +
            +  shouldRetry(attempt: number, error: PaymentError): boolean {
            +    if (attempt > this.max) return false;
            +    return error.code === "gateway_timeout";
            +  }
            +}
            +
            diff --git a/src/checkout/pay.ts b/src/checkout/pay.ts
            index 7a1c2d0..9e4f5b1 100644
            --- a/src/checkout/pay.ts
            +++ b/src/checkout/pay.ts
            @@ -12,7 +12,12 @@ export async function pay(order: Order) {
               const gateway = gatewayFor(order.currency);
            -  return gateway.charge(order.total);
            +  const policy = new RetryPolicy(config.payments.maxRetries);
            +  for (let attempt = 1; ; attempt++) {
            +    try { return await gateway.charge(order.total); }
            +    catch (e) { if (!policy.shouldRetry(attempt, e)) throw e; log.warn("retrying payment", { attempt }); }
            +  }
             }
             
             export function refund(order: Order) {
            diff --git a/assets/logo.png b/assets/logo.png
            index 1111111..2222222 100644
            Binary files a/assets/logo.png and b/assets/logo.png differ
            """
        }
        // Made-up images: a drawn picture for allowed places (nothing is downloaded).
        InboxImages.shared.forget()
        InboxImages.shared.fetch = { origin, _ in
            let label: String
            switch origin {
            case .github: label = "GitHub image"
            case .jira(let n): label = "Jira attachment " + n
            case .blocked: throw InboxError("blocked")
            }
            let img = NSImage(size: NSSize(width: 520, height: 180), flipped: false) { r in
                NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.55, alpha: 1).setFill(); r.fill()
                (label as NSString).draw(at: NSPoint(x: 24, y: 78), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
                return true
            }
            return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }
        // Read up to an hour ago on the PR and the issue, so both have something new.
        InboxStore.shared.loadFixture([pr, issue, quiet], seen: [pr.id: t - 3600, issue.id: t - 3600, quiet.id: t], activity: history)
    }
}
