import AppKit
import WebKit
import XCTest
@testable import Octomux

struct Failure: Error {}

final class BrowserAddressTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(BrowserStore.normalize("https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(BrowserStore.normalize("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserStore.normalize("127.0.0.1:8080/x")?.absoluteString, "http://127.0.0.1:8080/x")
        XCTAssertEqual(BrowserStore.normalize("app.localhost")?.absoluteString, "http://app.localhost")
        XCTAssertEqual(BrowserStore.normalize("example.com/docs")?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(BrowserStore.normalize("/tmp/a.html")?.absoluteString, "file:///tmp/a.html")
        XCTAssertNil(BrowserStore.normalize("how do i"))
        XCTAssertNil(BrowserStore.normalize("word"))
        XCTAssertNil(BrowserStore.normalize(""))
        // The address bar searches for anything that isn't an address.
        XCTAssertEqual(BrowserStore.addressBarURL("swift async")?.host, "duckduckgo.com")
        XCTAssertEqual(BrowserStore.addressBarURL("localhost:5173")?.absoluteString, "http://localhost:5173")
    }

    @MainActor
    func testScreenshotEncoding() {
        let img = NSImage(size: NSSize(width: 2000, height: 1000), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        let (data, mime, size) = BrowserTools.encode(img)!
        XCTAssertEqual(size.width, BrowserTools.maxWidth)
        XCTAssertEqual(size.height, 784)
        XCTAssertEqual(mime, "image/png")
        XCTAssertNotNil(NSBitmapImageRep(data: data))
    }
}

/// The tools against a real WKWebView (no window): the same calls an agent makes through `octomux mcp`.
@MainActor
final class BrowserToolsTests: XCTestCase {
    static let testPage = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/browser-test-page.html")

    override func setUp() async throws {
        BrowserTools.sessionName = { _ in "another agent" }
        for p in BrowserStore.shared.pages { BrowserStore.shared.close(p.id) }
        AppModel.shared.setSettingLocally("browser.access", .string("on"), scope: "global")
    }

    private func call(_ tool: String, _ args: [String: Any] = [:], session: String = "s1") async -> (text: String, result: [String: Any]) {
        let r = await BrowserTools.run(tool: tool, args: args, session: session)
        let content = r["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), r)
    }

    private func ref(_ snapshot: String, _ pattern: String) throws -> String {
        let re = try NSRegularExpression(pattern: pattern + #"[^\n]*?\[ref=(\w+)\]"#)
        guard let m = re.firstMatch(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)),
              let r = Range(m.range(at: 1), in: snapshot) else { XCTFail("no \(pattern) in snapshot:\n\(snapshot)"); throw Failure() }
        return String(snapshot[r])
    }

    func testNavigateSnapshotTypeClickScreenshot() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.testPage.path))
        var (text, r) = await call("browser_snapshot")
        XCTAssertEqual(r["isError"] as? Bool, true, "no page yet")
        XCTAssertTrue(text.contains("browser_navigate"))

        (text, r) = await call("browser_navigate", ["url": Self.testPage.path])
        XCTAssertNil(r["isError"], text)
        XCTAssertTrue(text.contains("- Title: Octomux browser test"), text)
        XCTAssertTrue(text.contains(#"heading "Sign up" [level=1]"#), text)
        let page = try XCTUnwrap(BrowserStore.shared.currentPage(of: "s1"))
        XCTAssertEqual(page.owner, "s1")

        let email = try ref(text, #"textbox "Email""#)
        (text, r) = await call("browser_type", ["ref": email, "element": "Email", "text": "a@b.co"])
        XCTAssertNil(r["isError"], text)
        XCTAssertTrue(text.contains("text: a@b.co"), text)

        let full = (await call("browser_snapshot")).text
        let agree = try ref(full, #"checkbox "I agree to the terms""#)
        (text, _) = await call("browser_click", ["ref": agree, "element": "I agree"])
        XCTAssertTrue(text.contains(#"checkbox "I agree to the terms" [checked]"#), text)

        let plan = try ref(full, #"combobox "Plan""#)
        (text, _) = await call("browser_select_option", ["ref": plan, "element": "Plan", "values": ["Pro"]])
        XCTAssertTrue(text.contains(#"option "Pro" [selected]"#), text)

        let create = try ref(full, #"button "Create account""#)
        (text, _) = await call("browser_click", ["ref": create, "element": "Create account"])
        XCTAssertTrue(text.contains("Submitted: a@b.co / pro / true"), text)
        XCTAssertTrue(text.contains("1 new console warning"), "the page's console.warn is reported: \(text)")

        (text, _) = await call("browser_console_messages")
        XCTAssertTrue(text.contains("[warn] form submitted"), text)

        (text, r) = await call("browser_take_screenshot")
        let image = (r["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" }
        let data = try XCTUnwrap((image?["data"] as? String).flatMap { Data(base64Encoded: $0) })
        XCTAssertNotNil(NSBitmapImageRep(data: data))
        XCTAssertTrue(text.contains("Visible part of page \(page.id)"), text)

        (text, _) = await call("browser_evaluate", ["function": "() => document.querySelector('#out').textContent"])
        XCTAssertTrue(text.contains("Submitted: a@b.co"), text)
        (text, _) = await call("browser_evaluate", ["function": "(el) => el.value", "ref": email])
        XCTAssertTrue(text.contains("a@b.co"), text)

        // A ref from before the page changed is refused with a hint.
        page.web.reload()
        _ = await page.waitForNavigation(timeout: 10)
        (text, r) = await call("browser_click", ["ref": create, "element": "Create account"])
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("Take a new snapshot"), text)
    }

    func testPagesPerSession() async throws {
        _ = await call("browser_navigate", ["url": Self.testPage.path], session: "a")
        _ = await call("browser_navigate", ["url": Self.testPage.path + "#two"], session: "b")
        let pa = try XCTUnwrap(BrowserStore.shared.currentPage(of: "a")), pb = try XCTUnwrap(BrowserStore.shared.currentPage(of: "b"))
        XCTAssertNotEqual(pa.id, pb.id, "each session gets its own page")
        var (text, _) = await call("browser_tabs", ["action": "list"], session: "a")
        XCTAssertTrue(text.contains("- \(pa.id) (current)"), text)
        XCTAssertTrue(text.contains("\(pb.id): ") && text.contains("opened by another session (another agent)"), text)
        // A session may switch to another page (e.g. one the user opened), then close its own.
        (text, _) = await call("browser_tabs", ["action": "select", "page": pb.id], session: "a")
        XCTAssertEqual(BrowserStore.shared.currentPage(of: "a")?.id, pb.id)
        (text, _) = await call("browser_tabs", ["action": "close", "page": pa.id], session: "a")
        XCTAssertNil(BrowserStore.shared.page(pa.id))
        (text, _) = await call("browser_tabs", ["action": "new"], session: "a")
        XCTAssertEqual(BrowserStore.shared.pages.count, 2, text)
        let (bad, r) = await call("browser_navigate", ["url": "not a url"], session: "a")
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(bad.contains("Not a URL"), bad)
    }

    func testPagesComeBackAfterRelaunch() async throws {
        _ = await call("browser_navigate", ["url": Self.testPage.path], session: "keep")
        let before = try XCTUnwrap(BrowserStore.shared.currentPage(of: "keep"))
        BrowserStore.shared.save()
        let fresh = BrowserStore()
        fresh.restore()
        let after = try XCTUnwrap(fresh.currentPage(of: "keep"), "the session finds its page again")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.owner, "keep")
        XCTAssertEqual(after.pendingURL?.path, Self.testPage.path, "loads when first used, not at launch")
        XCTAssertNil(after.web.url)
        XCTAssertEqual(fresh.newPage(owner: nil).id, "p\((Int(before.id.dropFirst()) ?? 0) + 1)", "ids go on after the restored ones")
        for p in fresh.pages { fresh.close(p.id) }
    }

    func testBrowserBesideTabs() throws {
        let store = BrowserStore()
        XCTAssertFalse(store.splitOpen(tab: "t1"))
        store.openSplit(tab: "t1")
        XCTAssertTrue(store.splitOpen(tab: "t1"), "opens empty when there is no page yet")
        XCTAssertNil(store.splitPage(tab: "t1"))
        let a = store.newPage(owner: nil, showIn: "t1"), b = store.newPage(owner: "s1")
        XCTAssertEqual(store.splitPage(tab: "t1")?.id, a.id)
        XCTAssertFalse(store.splitOpen(tab: "t2"), "each tab has its own")
        store.show(b, in: "t2")
        store.closeSplit(tab: "t2")
        store.openSplit(tab: "t2")
        XCTAssertEqual(store.splitPage(tab: "t2")?.id, b.id, "reopens on the page shown last")
        store.close(a.id)
        XCTAssertEqual(store.splitPage(tab: "t1")?.id, b.id, "a closed page's browser moves to a neighbor")
        store.close(b.id)
        XCTAssertTrue(store.splitOpen(tab: "t1"))
        XCTAssertNil(store.splitPage(tab: "t1"))
    }

    func testWaitAndKeys() async throws {
        var (text, _) = await call("browser_navigate", ["url": Self.testPage.path])
        let link = try ref(text, #"link "Show details""#)
        let clicked = await call("browser_click", ["ref": link, "element": "Show details"]).text
        (text, _) = await call("browser_wait_for", ["text": "Hidden until the link is clicked."])
        // The click's result already shows it (the wait's then says nothing changed since).
        XCTAssertTrue((clicked + text).contains(#"heading "Details""#), clicked + text)
        let (gone, r) = await call("browser_wait_for", ["text": "never there", "time": 1])
        XCTAssertEqual(r["isError"] as? Bool, true, gone)

        let email = try ref((await call("browser_snapshot")).text, #"textbox "Email""#)
        _ = await call("browser_type", ["ref": email, "element": "Email", "text": "k@x.io", "submit": true])
        (text, _) = await call("browser_snapshot")
        XCTAssertTrue(text.contains("Submitted: k@x.io"), "Enter submits the form: \(text)")
    }
}
