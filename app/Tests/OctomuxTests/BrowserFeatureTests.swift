import AppKit
import WebKit
import XCTest
@testable import Octomux

final class SnapshotDiffTests: XCTestCase {
    func testChangedLinesUnderTheirParents() throws {
        let old = """
        - main [ref=e1]:
          - heading "Sign up" [level=1] [ref=e2]
          - generic [ref=e3]:
            - textbox "Email" [ref=e4]
            - button "Go" [ref=e5]
          - paragraph [ref=e6]: Not submitted
        - contentinfo [ref=e9]: Footer
        """
        let new = old.replacingOccurrences(of: "paragraph [ref=e6]: Not submitted", with: "paragraph [ref=e6]: Submitted")
            .replacingOccurrences(of: "    - textbox \"Email\" [ref=e4]", with: "    - textbox \"Email\" [ref=e4]: a@b.co")
        let d = try XCTUnwrap(SnapshotDiff.diff(old: old, new: new))
        XCTAssertEqual(d.added, 2)
        XCTAssertEqual(d.removed, 2)
        XCTAssertTrue(d.text.contains("+   - paragraph [ref=e6]: Submitted"), d.text)
        XCTAssertTrue(d.text.contains("-   - paragraph [ref=e6]: Not submitted"), d.text)
        XCTAssertTrue(d.text.contains("  - main [ref=e1]:"), "parents give the place: \(d.text)")
        XCTAssertTrue(d.text.contains("    - generic [ref=e3]:"), d.text)
        XCTAssertFalse(d.text.contains("heading"), "unrelated lines stay out: \(d.text)")
        XCTAssertFalse(d.text.contains("Footer"), d.text)
        XCTAssertEqual(SnapshotDiff.diff(old: old, new: old)?.isEmpty, true)
        // A different page is no diff.
        let other = (1...50).map { "- listitem [ref=x\($0)]: \($0)" }.joined(separator: "\n")
        XCTAssertNil(SnapshotDiff.diff(old: old, new: other))
    }

    @MainActor
    func testWhenResultsCarryTheWholePage() {
        let big = (1...300).map { "- listitem [ref=e\($0)]: Item \($0) of the long list" }.joined(separator: "\n")
        let changed = "- listitem [ref=e0]: new one\n" + big
        XCTAssertGreaterThan(big.count, BrowserTools.smallSnapshot)
        func text(_ l: [String]) -> String { l.joined(separator: "\n") }
        // First look, a new address, or a small page: whole.
        XCTAssertEqual(BrowserTools.snapshotText(yaml: changed, previous: nil, mode: .auto, urlChanged: false).first, "### Snapshot")
        XCTAssertEqual(BrowserTools.snapshotText(yaml: changed, previous: big, mode: .auto, urlChanged: true).first, "### Snapshot")
        XCTAssertEqual(BrowserTools.snapshotText(yaml: "- button [ref=e1]", previous: "- link [ref=e2]", mode: .auto, urlChanged: false).first, "### Snapshot")
        // A large page that changed a little: only the change, and said so.
        let auto = text(BrowserTools.snapshotText(yaml: changed, previous: big, mode: .auto, urlChanged: false))
        XCTAssertTrue(auto.hasPrefix("### Snapshot (changes)"), auto)
        XCTAssertTrue(auto.contains("+ - listitem [ref=e0]: new one"), auto)
        XCTAssertLessThan(auto.count, 1000)
        // Asked for: a diff even on a small page; the whole page when there's nothing to compare with.
        let small = "- heading \"Hi\" [ref=e0]\n- paragraph [ref=e2]: text\n- button [ref=e1]: "
        XCTAssertTrue(text(BrowserTools.snapshotText(yaml: small + "B", previous: small + "A", mode: .diff, urlChanged: false)).contains("+ - button [ref=e1]: B"))
        XCTAssertTrue(text(BrowserTools.snapshotText(yaml: big, previous: nil, mode: .diff, urlChanged: false)).contains("no earlier snapshot"))
        XCTAssertTrue(text(BrowserTools.snapshotText(yaml: big, previous: big, mode: .diff, urlChanged: false)).contains("Nothing changed"))
        // A page just opened: whole when small, else its outline.
        XCTAssertEqual(BrowserTools.snapshotText(yaml: small, previous: nil, mode: .outline, urlChanged: true).first, "### Snapshot")
        XCTAssertEqual(BrowserTools.snapshotText(yaml: big, previous: nil, mode: .outline, urlChanged: true).first, "### Snapshot (outline)")
    }

    func testOutlineKeepsLandmarksAndControls() {
        let yaml = """
        - generic [ref=e2]:
          - banner [ref=e4]:
            - generic [ref=e6]:
              - link "Home" [ref=e8] [cursor=pointer]:
                - /url: /
                - img "Logo" [ref=e9]
            - search [ref=e17]:
              - button "Search everything" [ref=e18] [cursor=pointer]:
                - generic [ref=e21]: icon
          - main [ref=e37]:
            - heading "Deals" [level=2] [ref=e53]
            - paragraph [ref=e55]: A long paragraph nobody acts on.
            - generic [ref=e56]:
              - link [ref=e99] [cursor=pointer]:
                - /url: /product/1
                - img [ref=e100]
              - textbox "Email" [ref=e60]: a@b.co
        """
        XCTAssertEqual(SnapshotOutline.outline(yaml), """
        - banner [ref=e4]:
          - link "Home" [ref=e8]
          - search [ref=e17]:
            - button "Search everything" [ref=e18]
        - main [ref=e37]:
          - heading "Deals" [level=2] [ref=e53]
          - link [ref=e99] → /product/1
          - textbox "Email" [ref=e60]: a@b.co
        """)
        // Long names are cut; a huge page stops with a note.
        let long = "- link \"\(String(repeating: "x", count: 200))\" [ref=e1]"
        XCTAssertEqual(SnapshotOutline.outline(long), "- link \"\(String(repeating: "x", count: SnapshotOutline.maxName - 1))…\" [ref=e1]")
        let many = (1...2000).map { "- button \"Button \($0)\" [ref=e\($0)]" }.joined(separator: "\n")
        let o = SnapshotOutline.outline(many)
        XCTAssertLessThanOrEqual(o.count, SnapshotOutline.maxLength + 100)
        XCTAssertTrue(o.hasSuffix("browser_snapshot reads the whole page."), String(o.suffix(80)))
    }
}

final class BrowserAccessTests: XCTestCase {
    func testAllowedSites() {
        func ok(_ u: String, _ p: [String]) -> Bool { BrowserAccess.allows(URL(string: u)!, patterns: p) }
        XCTAssertTrue(ok("https://anything.com", []), "an empty list allows everything")
        XCTAssertTrue(ok("https://example.com/a", ["example.com"]))
        XCTAssertFalse(ok("https://www.example.com/a", ["example.com"]))
        XCTAssertTrue(ok("https://www.example.com/a", ["*.example.com"]))
        XCTAssertTrue(ok("https://example.com", ["*.example.com"]))
        XCTAssertFalse(ok("https://badexample.com", ["*.example.com"]))
        XCTAssertTrue(ok("http://localhost:3000/x", ["localhost:3000"]))
        XCTAssertFalse(ok("http://localhost:4000/x", ["localhost:3000"]))
        XCTAssertTrue(ok("http://localhost:4000/x", ["localhost"]))
        XCTAssertTrue(ok("https://EXAMPLE.com", ["https://Example.com/path"]), "scheme, path and case don't matter")
        XCTAssertTrue(ok("about:blank", ["example.com"]))
        XCTAssertFalse(ok("file:///tmp/a.html", ["example.com"]))
        XCTAssertTrue(ok("file:///tmp/a.html", ["file://"]))
        XCTAssertTrue(ok("https://x.org", ["*"]))
    }

    func testModeAsksUnlessChosen() {
        XCTAssertEqual(BrowserAccess.mode(access: nil, legacySwitch: nil), .ask)
        XCTAssertEqual(BrowserAccess.mode(access: nil, legacySwitch: true), .on, "a choice made with the old switch holds")
        XCTAssertEqual(BrowserAccess.mode(access: nil, legacySwitch: false), .off)
        XCTAssertEqual(BrowserAccess.mode(access: "on", legacySwitch: false), .on)
    }
}

final class BrowserLinkTests: XCTestCase {
    func testWhichLinksOpenInTheBrowser() {
        let local = URL(string: "http://localhost:5173/")!, lan = URL(string: "http://192.168.1.20:8080")!
        let web = URL(string: "https://github.com/x")!, mail = URL(string: "mailto:a@b.c")!
        XCTAssertTrue(BrowserLinks.isLocal(local))
        XCTAssertTrue(BrowserLinks.isLocal(lan))
        XCTAssertTrue(BrowserLinks.isLocal(URL(string: "http://app.localhost")!))
        XCTAssertFalse(BrowserLinks.isLocal(web))
        XCTAssertFalse(BrowserLinks.isLocal(URL(string: "http://172.40.0.1")!))
        XCTAssertTrue(BrowserLinks.opensInApp(local, mode: .local, flipped: false))
        XCTAssertFalse(BrowserLinks.opensInApp(web, mode: .local, flipped: false))
        XCTAssertTrue(BrowserLinks.opensInApp(web, mode: .local, flipped: true), "⇧ does the other thing")
        XCTAssertFalse(BrowserLinks.opensInApp(local, mode: .local, flipped: true))
        XCTAssertTrue(BrowserLinks.opensInApp(web, mode: .all, flipped: false))
        XCTAssertFalse(BrowserLinks.opensInApp(local, mode: .never, flipped: false))
        XCTAssertFalse(BrowserLinks.opensInApp(mail, mode: .all, flipped: false), "only web links")
        XCTAssertTrue(BrowserLinks.samePage(URL(string: "http://localhost:5173/#top"), local))
        XCTAssertTrue(BrowserLinks.samePage(URL(string: "http://localhost:5173"), local))
        XCTAssertFalse(BrowserLinks.samePage(URL(string: "http://localhost:5173/about"), local))
    }

    func testShortcutsAndGeometry() {
        XCTAssertEqual(BrowserKeys.action(chars: "f", command: true), .find)
        XCTAssertEqual(BrowserKeys.action(chars: "L", command: true), .address)
        XCTAssertEqual(BrowserKeys.action(chars: "[", command: true), .back)
        XCTAssertEqual(BrowserKeys.action(chars: "=", command: true), .zoomIn)
        XCTAssertNil(BrowserKeys.action(chars: "f", command: false))
        XCTAssertNil(BrowserKeys.action(chars: "f", command: true, others: .option))
        XCTAssertNil(BrowserKeys.action(chars: "k", command: true))
        // A phone in a 600×600 browser: scaled to fit, centered; CSS pixels map through scale and zoom.
        let g = BrowserGeometry(host: CGSize(width: 600, height: 600), viewport: BrowserViewport.preset("mobile"), zoom: 1)
        XCTAssertEqual(g.scale, 600 / 844, accuracy: 0.001)
        XCTAssertEqual(g.originX, (600 - 390 * g.scale) / 2, accuracy: 0.01)
        XCTAssertEqual(g.point(CGPoint(x: 100, y: 100)).y, 100 * g.scale, accuracy: 0.01)
        let fit = BrowserGeometry(host: CGSize(width: 600, height: 600), viewport: nil, zoom: 1.5)
        XCTAssertEqual(fit.point(CGPoint(x: 10, y: 20)), CGPoint(x: 15, y: 30))
    }

    @MainActor
    func testHistorySuggestions() {
        let h = BrowserHistory(file: nil)
        h.record(url: URL(string: "http://localhost:3000/dashboard")!, title: "Dashboard")
        h.record(url: URL(string: "https://github.com/anilsenay/octomux")!, title: "octomux")
        h.record(url: URL(string: "https://github.com/anilsenay/octomux")!, title: "octomux")
        h.record(url: URL(string: "https://docs.github.com/en")!, title: "GitHub Docs")
        h.record(url: URL(string: "about:blank")!, title: "")
        XCTAssertEqual(h.entries.count, 3, "about: pages aren't kept")
        XCTAssertEqual(h.suggestions("github").first?.url, "https://github.com/anilsenay/octomux", "prefix and visits first")
        XCTAssertEqual(h.suggestions("dash").map(\.title), ["Dashboard"])
        XCTAssertEqual(h.suggestions("github docs").map(\.title), ["GitHub Docs"], "every word must match")
        XCTAssertTrue(h.suggestions("").isEmpty)
    }

    func testElementMessage() {
        let info: [String: Any] = ["url": "http://localhost:3000/signup", "title": "Sign up", "selector": "#f > button", "role": "button",
                                   "name": "Create account", "text": "Create account", "tag": "button",
                                   "box": ["x": 10.0, "y": 20.0, "width": 120.0, "height": 36.0],
                                   "styles": ["color": "rgb(255, 255, 255)", "background-color": "rgb(91, 91, 214)"], "html": "<button>Create account</button>"]
        let img = URL(fileURLWithPath: "/tmp/octomux-attachments/element-1.png")
        let m = BrowserSend.message(note: "Make it full width", info: info, image: img, kind: .claude)
        XCTAssertTrue(m.hasPrefix("Make it full width\n\nElement I picked in the Octomux browser, on http://localhost:3000/signup (“Sign up”):"), m)
        XCTAssertTrue(m.contains("- selector: #f > button"))
        XCTAssertTrue(m.contains("- role: button “Create account”"))
        XCTAssertFalse(m.contains("- text:"), "text that repeats the name is left out")
        XCTAssertTrue(m.contains("- size: 120×36 px"))
        XCTAssertTrue(m.contains("- styles: color: rgb(255, 255, 255); background-color: rgb(91, 91, 214)"))
        XCTAssertTrue(m.contains("- screenshot of it: @/tmp/octomux-attachments/element-1.png"), "Claude reads @paths")
        XCTAssertTrue(BrowserSend.message(note: "", info: info, image: img, kind: .codex).contains("- screenshot of it: /tmp/octomux-attachments/element-1.png"))
        XCTAssertTrue(BrowserSend.message(note: "", info: info, image: nil, kind: .claude).hasPrefix("Element I picked"))
        var onPage = info; onPage["page"] = "p3"
        XCTAssertTrue(BrowserSend.message(note: "", info: onPage, image: nil, kind: .claude).hasPrefix("Element I picked in the Octomux browser (page p3), on http://localhost:3000/signup"))
    }
}

/// Agent-facing behavior against a real WKWebView: reports, diffs, sizes, access.
@MainActor
final class BrowserAgentReportTests: XCTestCase {
    static let page = BrowserToolsTests.testPage

    override func setUp() async throws {
        BrowserTools.sessionName = { _ in "another agent" }
        for p in BrowserStore.shared.pages { BrowserStore.shared.close(p.id) }
        AppModel.shared.setSettingLocally("browser.access", .string("on"), scope: "global")
        AppModel.shared.setSettingLocally("browser.allowed_sites", nil, scope: "global")
        BrowserAccess.autoAnswer = nil
        BrowserAccess.decisions = [:]
    }

    private func call(_ tool: String, _ args: [String: Any] = [:], session: String = "r1") async -> (text: String, result: [String: Any]) {
        let r = await BrowserTools.run(tool: tool, args: args, session: session)
        let content = r["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), r)
    }

    private func ref(_ snapshot: String, _ pattern: String) throws -> String {
        let re = try NSRegularExpression(pattern: pattern + #"[^\n]*?\[ref=(\w+)\]"#)
        let m = try XCTUnwrap(re.firstMatch(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)), "no \(pattern) in:\n\(snapshot)")
        return String(snapshot[Range(m.range(at: 1), in: snapshot)!])
    }

    func testActionsReportWhatChanged() async throws {
        var (text, _) = await call("browser_navigate", ["url": Self.page.path])
        XCTAssertTrue(text.contains("### Snapshot (outline)"), "a long page just opened: its outline\n\(text)")
        let whole = (await call("browser_snapshot")).text
        XCTAssertLessThan(text.count * 2, whole.count, "the outline is much shorter than the page")
        let add = try ref(text, #"button "Add an item""#)
        (text, _) = await call("browser_click", ["ref": add, "element": "Add an item"])
        XCTAssertTrue(text.contains("### Snapshot (changes)"), "a long page that changed a little: only the change\n\(text)")
        XCTAssertTrue(text.contains("+ ") && text.contains("A new item, added by the button"), text)
        XCTAssertLessThan(text.count, 3000)

        let error = try ref(text + (await call("browser_snapshot")).text, #"button "Log an error""#)
        (text, _) = await call("browser_click", ["ref": error, "element": "Log an error"])
        XCTAssertTrue(text.contains("- New console error: Something broke on purpose"), text)

        (text, _) = await call("browser_snapshot", ["diff": true])
        XCTAssertTrue(text.contains("Nothing changed since your last snapshot"), text)
        XCTAssertFalse(text.contains("New console error"), "an error is new once\n\(text)")

        let popup = try ref((await call("browser_snapshot")).text, #"link "Open in a new page""#)
        (text, _) = await call("browser_click", ["ref": popup, "element": "Open in a new page"])
        XCTAssertTrue(text.contains("### Changes") && text.contains("New page p"), "pages it opens are reported\n\(text)")

        let link = try ref((await call("browser_snapshot")).text, #"link "Show details""#)
        (text, _) = await call("browser_click", ["ref": link, "element": "Show details"])
        XCTAssertTrue(text.contains("URL changed: file://") && text.contains("#details"), text)
    }

    func testDownloadsAreReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = BrowserDownloads.shared.folder
        BrowserDownloads.shared.folder = dir
        defer { BrowserDownloads.shared.folder = saved; try? FileManager.default.removeItem(at: dir) }
        let (nav, _) = await call("browser_navigate", ["url": Self.page.path])
        let dl = try ref(nav, #"link "Download a file""#)
        let (clicked, _) = await call("browser_click", ["ref": dl, "element": "Download a file"])
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("octomux-test.txt").path) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("octomux-test.txt"), encoding: .utf8), "Hello from the Octomux browser test")
        // Reported with the click when it finished meanwhile, else with the next result.
        let text = clicked + (await call("browser_snapshot")).text
        XCTAssertTrue(text.contains("Downloaded octomux-test.txt") && text.contains(dir.path), text)
    }

    func testResize() async throws {
        _ = await call("browser_navigate", ["url": Self.page.path])
        var (text, r) = await call("browser_resize", ["preset": "mobile"])
        XCTAssertNil(r["isError"], text)
        XCTAssertTrue(text.contains("Mobile 390×844 (the page sees 390×844)"), text)
        let page = try XCTUnwrap(BrowserStore.shared.currentPage(of: "r1"))
        XCTAssertEqual(page.web.customUserAgent, BrowserViewport.iPhoneUA)
        let ua = try await page.web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertTrue(ua?.contains("iPhone") == true, "the site sees a phone")
        let w = try await page.web.evaluateJavaScript("innerWidth") as? Int
        XCTAssertEqual(w, 390)
        (text, _) = await call("browser_resize", ["width": 1000, "height": 700])
        XCTAssertTrue(text.contains("Custom 1000×700"), text)
        (text, r) = await call("browser_resize", ["preset": "watch"])
        XCTAssertEqual(r["isError"] as? Bool, true)
        (text, _) = await call("browser_resize", ["preset": "fit"])
        XCTAssertNil(page.viewport)
        XCTAssertEqual(page.web.customUserAgent ?? "", "")
    }

    func testAccessAndAllowedSites() async throws {
        let m = AppModel.shared
        m.setSettingLocally("browser.access", .string("off"), scope: "global")
        var (text, r) = await call("browser_snapshot")
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("turned the Octomux browser off"), text)

        m.setSettingLocally("browser.access", .string("ask"), scope: "global")
        var asked: [String] = []
        BrowserAccess.autoAnswer = { s in asked.append(s); return s == "yes" }
        (text, r) = await call("browser_navigate", ["url": Self.page.path], session: "no")
        XCTAssertTrue(text.contains("didn't allow this session"), text)
        (text, r) = await call("browser_navigate", ["url": Self.page.path], session: "yes")
        XCTAssertNil(r["isError"], text)
        _ = await call("browser_snapshot", session: "yes")
        _ = await call("browser_snapshot", session: "no")
        XCTAssertEqual(asked, ["no", "yes"], "asked once per session, the answer is kept")
        BrowserAccess.forget("no")
        _ = await call("browser_snapshot", session: "no")
        XCTAssertEqual(asked.count, 3, "forgotten: asks again")

        m.setSettingLocally("browser.access", .string("on"), scope: "global")
        m.setSettingLocally("browser.allowed_sites", .array([.string("localhost:3000"), .string("*.example.com")]), scope: "global")
        (text, r) = await call("browser_navigate", ["url": "https://example.org/"], session: "yes")
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("example.org isn't one of the sites") && text.contains("localhost:3000, *.example.com"), text)
        (text, r) = await call("browser_tabs", ["action": "new", "url": "/tmp/x.html"], session: "yes")
        XCTAssertEqual(r["isError"] as? Bool, true, "files need file:// in the list")
        // A link the agent follows to another site is blocked too.
        m.setSettingLocally("browser.allowed_sites", .array([.string("file://")]), scope: "global")
        (text, _) = await call("browser_navigate", ["url": Self.page.path], session: "yes")
        let ex = try ref(text, #"link "Example.org""#)
        (text, _) = await call("browser_click", ["ref": ex, "element": "Example.org"], session: "yes")
        XCTAssertTrue(text.contains("Blocked opening https://example.org/"), text)
        XCTAssertTrue(text.contains("- URL: file://"), "stayed on the page\n\(text)")
    }
}

/// The chat composer's height: measured without touching the field (doing so looped forever on long text).
@MainActor
final class ComposerMeasureTests: XCTestCase {
    func testMeasuringLeavesTheFieldAlone() {
        let sv = ComposerScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        let tv = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        sv.textView = tv
        sv.maxHeight = 2000
        tv.string = String(repeating: "a long line of words that wraps ", count: 40)
        let before = tv.textContainer?.containerSize
        let narrow = sv.measure(width: 200), wide = sv.measure(width: 800)
        XCTAssertGreaterThan(narrow, wide, "narrower wraps into more lines")
        XCTAssertEqual(sv.measure(width: 200), narrow, "same answer for the same text and width")
        XCTAssertEqual(tv.textContainer?.containerSize, before, "the field's own text container is never changed")
        sv.maxHeight = 220
        tv.string = String(repeating: "x\n", count: 100)
        XCTAssertEqual(sv.measure(width: 300), 220, "clamped: it scrolls past the maximum")
        tv.string = ""
        XCTAssertEqual(sv.measure(width: 300), sv.minHeight)
    }
}
