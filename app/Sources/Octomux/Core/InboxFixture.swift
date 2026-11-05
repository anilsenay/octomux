import AppKit
import Foundation

/// Made-up Inbox items and history for the debug fixture (`ui_action inbox_fake`): no account is read or written.
enum InboxFixture {
    static var fixtureItems: [InboxItem] = []
    /// Commands the fixture's write actions would have run.
    static var ran: [String] = []

    /// A refresh that brings a new review request (#43) in.
    static func newPR() {
        let pr = InboxItem(id: "gh:octo/storefront#43", source: .github, kind: .pr, key: "#43", place: "octo/storefront",
                           title: "Cart: keep the coupon after login", author: "bob", assignee: nil, status: "Open", statusTone: "done",
                           reason: .review, updated: Date(), body: "Keeps the applied coupon when a guest signs in.",
                           url: "https://github.com/octo/storefront/pull/43", branch: "bob/coupon-login", number: 43, base: "main")
        fixtureItems.append(pr)
        InboxStore.shared.fixtureApply(.github, fixtureItems.filter { $0.source == .github })
    }

    /// A refresh in which the pull request is gone from the open searches because it was merged.
    static func mergePR() {
        let store = InboxStore.shared
        store.endedState = { list in
            Dictionary(uniqueKeysWithValues: list.filter { $0.kind == .pr }.map { ($0.id, InboxItem.Ended(label: "Merged", merged: true, at: Date())) })
        }
        store.fixtureApply(.github, fixtureItems.filter { $0.source == .github && $0.kind != .pr })
    }

    /// A Bitbucket refresh that brings a new review request (#8) in.
    static func newBitbucketPR() {
        var pr = InboxItem(id: "bb:acme/payments-api#8", source: .bitbucket, kind: .pr, key: "#8", place: "acme/payments-api",
                           title: "SHOP-7: round refunds per currency", author: "Eli", assignee: nil, status: "Open", statusTone: "done",
                           reason: .review, updated: Date(), body: "Rounds each item's refund in its currency.",
                           url: "https://bitbucket.org/acme/payments-api/pull-requests/8", branch: "eli/refund-rounding", number: 8, base: "develop")
        pr.head = "77aa88bb99cc"; pr.checks = .pending; pr.checkCounts = (0, 0, 1)
        fixtureItems.append(pr)
        InboxStore.shared.fixtureApply(.bitbucket, fixtureItems.filter { $0.source == .bitbucket })
    }

    /// A refresh in which the Bitbucket review request is gone because it was declined.
    static func declineBitbucket() {
        let store = InboxStore.shared
        store.endedState = { list in
            Dictionary(uniqueKeysWithValues: list.filter { $0.source == .bitbucket }.map { ($0.id, InboxItem.Ended(label: "Declined", at: Date())) })
        }
        store.fixtureApply(.bitbucket, fixtureItems.filter { $0.source == .bitbucket && $0.reason != .review })
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
        // Bitbucket: a review request with a failed build, and your own draft with a passing one.
        var bbReview = InboxItem(id: "bb:acme/payments-api#7", source: .bitbucket, kind: .pr, key: "#7", place: "acme/payments-api",
                                 title: "Refunds: split partial refunds per item", author: "Dana", assignee: nil, status: "Open", statusTone: "done",
                                 reason: .review, updated: at(3), body: "[bot-note-0]: https://bot.example.com/#hidden-note-AAAA\n\nSplits a partial refund across the order's items.\n\n- adds `RefundSplitter`\n- SHOP-7 follow-up\n\n> ## Reviews paused\n> The bot waits for the branch to settle.",
                                 url: "https://bitbucket.org/acme/payments-api/pull-requests/7", branch: "feature/SHOP-7-refund-split", number: 7, base: "develop")
        bbReview.head = "a1b2c3d4e5f6"; bbReview.approvals = 1; bbReview.changesRequested = 1; bbReview.commentCount = 18
        bbReview.checks = .failing; bbReview.checkCounts = (1, 1, 0); bbReview.failedChecks = ["Pipeline #318"]
        bbReview.failedCheckDetails = [.init(name: "Pipeline #318", url: "https://bitbucket.org/acme/payments-api/pipelines/results/318", title: "Tests failed in step test")]
        var bbMine = InboxItem(id: "bb:acme/web-shop#21", source: .bitbucket, kind: .pr, key: "#21", place: "acme/web-shop",
                               title: "Basket: show the delivery estimate", author: "You", assignee: nil, status: "Draft", statusTone: "todo",
                               reason: .mine, updated: at(45), body: "Shows the estimate under the basket total.",
                               url: "https://bitbucket.org/acme/web-shop/pull-requests/21", branch: "feature/SHOP-9-basket-estimate", number: 21, base: "main")
        bbMine.head = "0f9e8d7c6b5a"; bbMine.approvals = 2; bbMine.commentCount = 1; bbMine.checks = .passing; bbMine.checkCounts = (2, 0, 0)
        let history: [String: InboxActivity] = [
            bbReview.id: InboxActivity(events: [
                InboxEvent(kind: .change, actor: "Dana", date: at(240), summary: "opened it", field: "opened"),
                { var e = InboxEvent(kind: .comment, actor: "Acme CodeRabbit", date: at(235), summary: "commented",
                                     detail: "[bot-note-1]: https://bot.example.com/#note\n\n**Summary by the review bot**\n\n" + (1...14).map { "- Change \($0): refunds are now split per item and rounded" }.joined(separator: "\n"))
                  e.bot = true; return e }(),
                InboxEvent(kind: .comment, actor: "Max", date: at(200), summary: "commented",
                           detail: "A few thoughts before this goes in:\n\n1. The splitter should not know about currencies.\n2. Rounding belongs to the money type.\n3. The tests cover two items only.\n4. Partial refunds of shipping are missing.\n5. The log line repeats the order id.\n6. The config default should stay at one.\n7. Docs need a line about the remainder.\n\n> Does anyone remember why we round down?\n\nThanks!"),
                { var e = InboxEvent(kind: .comment, actor: "Eli", date: at(120), summary: "commented", detail: "Rounding: should the last item take the remainder?")
                  e.path = "src/checkout/pay.ts"; e.line = 14; return e }(),
                InboxEvent(kind: .review, actor: "Eli", date: at(110), summary: "requested changes", field: "review"),
                InboxEvent(kind: .commits, actor: "Dana", date: at(20), summary: "pushed new commits", detail: "a1b2c3d"),
                InboxEvent(kind: .review, actor: "Max", date: at(3), summary: "approved", field: "review"),
            ]),
            bbMine.id: InboxActivity(events: [
                InboxEvent(kind: .change, actor: "You", date: at(300), summary: "opened it", field: "opened"),
                InboxEvent(kind: .review, actor: "Dana", date: at(60), summary: "approved", field: "review"),
                InboxEvent(kind: .review, actor: "Eli", date: at(45), summary: "approved", field: "review"),
            ]),
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
        fixtureItems = [pr, bbReview, bbMine, issue, quiet]
        InboxStore.shared.fixtureOn = Set(InboxSource.allCases)
        // Writes go nowhere: the commands are only recorded.
        ran = []
        InboxActions.shared.run = { args in ran.append(args.joined(separator: " ")); return "" }
        InboxActions.shared.bitbucket = { a, i in
            let r = BitbucketWrites.request(a, i)
            ran.append("bitbucket \(r?.method ?? "?") \(r?.path ?? a.rawValue)" + ((r?.body?["merge_strategy"] as? String).map { " " + $0 } ?? ""))
            return ""
        }
        InboxStore.shared.commentWriter = { i, text in ran.append("comment \(i.id) \(text)") }
        InboxStore.shared.bitbucketLog = { _, c in
            guard c.name == "Pipeline #318" else { throw InboxError("no such build") }
            return """
            + npm test
            > payments-api@2.1.0 test
            FAIL src/refunds/split.test.ts
              ● RefundSplitter › gives the last item the remainder
                expect(received).toBe(expected)
                Expected: 3.34
                Received: 3.33
            Tests: 1 failed, 41 passed, 42 total
            """
        }
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
        InboxStore.shared.jiraLookup = { k in k == "SHOP-9" ? ("Show the delivery estimate in the basket", "To Do") : (k, "") }
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
        InboxStore.shared.loadFixture([pr, bbReview, bbMine, issue, quiet],
                                      seen: [pr.id: t - 3600, bbReview.id: t - 3600, bbMine.id: t, issue.id: t - 3600, quiet.id: t], activity: history)
    }
}
