import AppKit
import WebKit

/// Runs the browser tools agents call through `octomux mcp` (see core/crates/octomux/src/mcp.rs for their schemas).
/// Results are MCP `CallToolResult`s: a text block in sections (### Page, ### Snapshot…) and, for screenshots,
/// an image block.
@MainActor
enum BrowserTools {
    struct Failure: Error { let message: String }

    /// Longest page snapshot returned (Claude Code warns at ~10k tokens and cuts at 25k).
    static let maxSnapshot = 40_000
    /// Time for the cursor to travel before an action lands, when someone is watching the page.
    static var cursorTravel = 0.35

    static func run(tool: String, args: [String: Any], session: String?) async -> [String: Any] {
        let session = session ?? "unknown"
        do {
            return try await perform(tool: tool, args: args, session: session).mcp
        } catch let f as Failure {
            return Result(text: ["### Error", f.message], isError: true).mcp
        } catch {
            return Result(text: ["### Error", jsMessage(error)], isError: true).mcp
        }
    }

    struct Result {
        var text: [String]
        var image: (data: Data, mime: String)?
        var isError = false
        var mcp: [String: Any] {
            var content: [[String: Any]] = [["type": "text", "text": text.joined(separator: "\n")]]
            if let image { content.append(["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mime]) }
            var r: [String: Any] = ["content": content]
            if isError { r["isError"] = true }
            return r
        }
    }

    private static var store: BrowserStore { .shared }

    private static func perform(tool: String, args: [String: Any], session: String) async throws -> Result {
        switch tool {
        case "browser_navigate":
            guard let raw = args["url"] as? String, let url = BrowserStore.normalize(raw) else {
                throw Failure(message: "Not a URL: \(args["url"] as? String ?? "(none)"). Pass a full URL like https://example.com or localhost:3000.")
            }
            let page = store.currentPage(of: session) ?? newPage(for: session)
            page.show(BrowserActivity(sessionId: session, label: "Opening \(url.host ?? url.absoluteString)"))
            defer { page.endActivity() }
            let ok = await page.load(url)
            if !ok, let e = page.lastError { throw Failure(message: "Couldn't open \(url.absoluteString): \(e)") }
            return try await afterAction(page, session: session, note: ok ? nil : "The page is still loading; the snapshot may be incomplete.")

        case "browser_navigate_back":
            let page = try await pageFor(session)
            guard page.web.canGoBack else { throw Failure(message: "This page has no earlier page to go back to.") }
            page.show(BrowserActivity(sessionId: session, label: "Going back"))
            defer { page.endActivity() }
            page.web.goBack()
            _ = await page.waitForNavigation(timeout: 15)
            return try await afterAction(page, session: session)

        case "browser_snapshot":
            let page = try await pageFor(session)
            page.show(BrowserActivity(sessionId: session, label: "Reading the page"))
            defer { page.endActivity(after: 0.8) }
            return try await afterAction(page, session: session, settle: false, depth: (args["depth"] as? Double).map(Int.init) ?? (args["depth"] as? Int))

        case "browser_click", "browser_hover", "browser_type", "browser_select_option":
            let page = try await pageFor(session)
            let ref = try string(args, "ref")
            let element = (args["element"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ref
            let label: String
            switch tool {
            case "browser_click": label = ((args["doubleClick"] as? Bool) == true ? "Double-clicking " : "Clicking ") + quoted(element)
            case "browser_hover": label = "Pointing at " + quoted(element)
            case "browser_type": label = "Typing " + quoted(short((args["text"] as? String) ?? "", 40))
            default: label = "Choosing " + quoted(((args["values"] as? [Any]) ?? []).map { "\($0)" }.joined(separator: ", "))
            }
            let loc = try await js(page, "return __octomux.locate(ref)", ["ref": ref]) as? [String: Any]
            let point = (loc?["center"] as? [String: Any]).flatMap(cgPoint)
            let box = (loc?["box"] as? [String: Any]).flatMap(cgRect)
            page.show(BrowserActivity(sessionId: session, label: label, point: point, box: box))
            defer { page.endActivity() }
            if page.web.window != nil { try? await Task.sleep(nanoseconds: UInt64(cursorTravel * 1e9)) }
            switch tool {
            case "browser_click":
                _ = try await js(page, "return __octomux.click(ref, opts)", ["ref": ref, "opts": ["doubleClick": args["doubleClick"] as? Bool ?? false, "button": args["button"] as? String ?? "left"]])
            case "browser_hover":
                _ = try await js(page, "return __octomux.hover(ref)", ["ref": ref])
            case "browser_type":
                let text = try string(args, "text", allowEmpty: true)
                _ = try await js(page, "return __octomux.type(ref, text, opts)", ["ref": ref, "text": text, "opts": ["submit": args["submit"] as? Bool ?? false, "slowly": args["slowly"] as? Bool ?? false]])
            default:
                let values = ((args["values"] as? [Any]) ?? []).map { "\($0)" }
                guard !values.isEmpty else { throw Failure(message: "Pass the option(s) to choose in values.") }
                _ = try await js(page, "return __octomux.selectOption(ref, values)", ["ref": ref, "values": values])
            }
            return try await afterAction(page, session: session)

        case "browser_press_key":
            let page = try await pageFor(session)
            let key = try string(args, "key")
            page.show(BrowserActivity(sessionId: session, label: "Pressing \(key)"))
            defer { page.endActivity() }
            _ = try await js(page, "return __octomux.press(key)", ["key": key])
            return try await afterAction(page, session: session)

        case "browser_take_screenshot":
            let page = try await pageFor(session)
            let ref = (args["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            page.show(BrowserActivity(sessionId: session, label: "Taking a screenshot"))
            defer { page.endActivity(after: 0.8) }
            let shot = try await screenshot(page, fullPage: args["fullPage"] as? Bool ?? false, ref: ref)
            var text = ["### Screenshot", "- \(shot.what) of page \(page.id) (\(Int(shot.size.width))×\(Int(shot.size.height)) px\(shot.note.map { ", \($0)" } ?? ""))"]
            text += pageLines(page, session: session)
            return Result(text: text, image: (shot.data, shot.mime))

        case "browser_wait_for":
            let page = try await pageFor(session)
            let text = args["text"] as? String, gone = args["textGone"] as? String
            let time = (args["time"] as? Double) ?? (args["time"] as? Int).map(Double.init)
            guard text != nil || gone != nil || time != nil else { throw Failure(message: "Pass text, textGone or time.") }
            page.show(BrowserActivity(sessionId: session, label: text.map { "Waiting for " + quoted(short($0, 40)) } ?? gone.map { "Waiting for " + quoted(short($0, 40)) + " to go" } ?? "Waiting"))
            defer { page.endActivity(after: 0.5) }
            var o: [String: Any] = [:]
            if let text { o["text"] = text }
            if let gone { o["textGone"] = gone }
            if let time { o["time"] = min(time, 30) }
            _ = try await js(page, "return await __octomux.waitFor(o)", ["o": o])
            return try await afterAction(page, session: session)

        case "browser_evaluate":
            let page = try await pageFor(session)
            let fn = try string(args, "function")
            page.show(BrowserActivity(sessionId: session, label: "Running a script"))
            defer { page.endActivity(after: 0.6) }
            var mark: String?
            if let ref = (args["ref"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                mark = try await js(page, "return __octomux.mark(ref)", ["ref": ref]) as? String
            }
            let body = """
            const __el = mark ? (() => { const q = '[data-octomux-eval="' + mark + '"]'; let e = document.querySelector(q);
              if (!e) for (const f of document.querySelectorAll('iframe')) { try { e = f.contentDocument.querySelector(q); if (e) break; } catch {} }
              if (e) e.removeAttribute('data-octomux-eval'); return e; })() : undefined;
            const __f = (\(fn));
            const __r = await (typeof __f === 'function' ? (__el ? __f(__el) : __f()) : __f);
            if (__r === undefined) return 'undefined';
            try { return JSON.stringify(__r, null, 2) ?? String(__r); } catch { return String(__r); }
            """
            let r = try await page.web.callAsyncJavaScript(body, arguments: ["mark": mark ?? NSNull()], in: nil, contentWorld: .page)
            var out = ["### Result", "```json", short("\(r ?? "undefined")", 20_000), "```"]
            out += pageLines(page, session: session)
            return Result(text: out)

        case "browser_console_messages":
            let page = try await pageFor(session)
            page.consoleSeen = page.console.count
            let lines = page.console.suffix(200).map { "- [\($0.level)] \(short($0.text, 1000))" }
            return Result(text: ["### Console messages of page \(page.id)"] + (lines.isEmpty ? ["(none since the page loaded)"] : lines))

        case "browser_tabs":
            let action = (args["action"] as? String) ?? "list"
            switch action {
            case "new":
                let page = newPage(for: session)
                if let raw = args["url"] as? String, !raw.isEmpty {
                    guard let url = BrowserStore.normalize(raw) else { throw Failure(message: "Not a URL: \(raw).") }
                    page.show(BrowserActivity(sessionId: session, label: "Opening \(url.host ?? url.absoluteString)"))
                    defer { page.endActivity() }
                    _ = await page.load(url)
                }
                return Result(text: tabsList(session: session))
            case "select":
                let id = try string(args, "page")
                guard let page = store.page(id) else { throw Failure(message: "No page \(id). " + tabsList(session: session).joined(separator: "\n")) }
                store.select(page.id, for: session)
                revealIfFocused(page, session: session)
                return Result(text: tabsList(session: session))
            case "close":
                let id = (args["page"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? store.current[session]
                guard let id, store.page(id) != nil else { throw Failure(message: "No page to close.") }
                store.close(id)
                return Result(text: tabsList(session: session))
            default:
                return Result(text: tabsList(session: session))
            }

        default:
            throw Failure(message: "Unknown tool \(tool).")
        }
    }

    // MARK: Pages

    private static func newPage(for session: String) -> BrowserPage {
        let page = store.newPage(owner: session)
        revealIfFocused(page, session: session)
        return page
    }

    /// The session's current page, or an error telling the agent to open one.
    private static func pageFor(_ session: String) async throws -> BrowserPage {
        guard let p = store.currentPage(of: session) else {
            throw Failure(message: "No page is open for this session. Open one with browser_navigate (or pick a page with browser_tabs).")
        }
        revealIfFocused(p, session: session)
        await p.loadPending()
        return p
    }

    /// The user is looking at this session: show the page it works on.
    private static func revealIfFocused(_ page: BrowserPage, session: String) {
        store.onAgentPage?(page, session)
    }

    // MARK: Results

    /// After an action: wait for a navigation it started and for the page to settle, then report it with a snapshot.
    private static func afterAction(_ page: BrowserPage, session: String, settle: Bool = true, note: String? = nil, depth: Int? = nil) async throws -> Result {
        if settle {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if page.web.isLoading { _ = await page.waitForNavigation(timeout: 10) }
            _ = try? await js(page, "return await __octomux.settle(120, 2000)", [:])
        }
        var text = pageLines(page, session: session)
        if let note { text.append("- Note: \(note)") }
        var opts: [String: Any] = [:]
        if let depth { opts["depth"] = depth }
        let snap = try await js(page, "return __octomux.snapshot(opts)", ["opts": opts]) as? [String: Any]
        var yaml = (snap?["yaml"] as? String) ?? ""
        if yaml.count > maxSnapshot {
            // Cut at a line end, so the last element stays whole.
            let head = yaml.prefix(maxSnapshot)
            yaml = String(head[..<(head.lastIndex(of: "\n") ?? head.endIndex)])
                + "\n# … the page is longer: snapshot cut at \(maxSnapshot / 1000)k characters. browser_snapshot with depth gives an overview; browser_evaluate reads one part."
        }
        text += ["### Snapshot", "```yaml", yaml, "```"]
        return Result(text: text)
    }

    /// The "### Page" section, plus what happened since the last call (dialogs, popups, console errors).
    static func pageLines(_ page: BrowserPage, session: String) -> [String] {
        var out = ["### Page", "- Page: \(page.id)" + (store.pages.count > 1 ? " (\(store.pages.count) pages open; browser_tabs lists them)" : ""),
                   "- URL: \(page.web.url?.absoluteString ?? page.url)", "- Title: \(page.web.title ?? page.title)"]
        let fresh = page.console.dropFirst(page.consoleSeen)
        let errors = fresh.filter { $0.level == "error" }.count, warnings = fresh.filter { $0.level == "warn" }.count
        if errors + warnings > 0 {
            let parts = [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil].compactMap { $0 }
            out.append("- Console: \(parts.joined(separator: ", ")) since the last look (browser_console_messages shows them)")
        }
        if !page.events.isEmpty {
            out.append("### Events")
            out += page.events.map { "- \($0)" }
            page.events.removeAll()
        }
        return out
    }

    private static func tabsList(session: String) -> [String] {
        let cur = store.current[session]
        var out = ["### Pages"]
        if store.pages.isEmpty { out.append("(no pages open)") }
        for p in store.pages {
            let who: String
            if p.owner == session { who = "opened by you" } else if p.owner == nil { who = "opened by the user" } else { who = "opened by another session (\(sessionName(p.owner)))" }
            let title = p.web.title.flatMap { $0.isEmpty ? nil : $0 } ?? "(untitled)"
            out.append("- \(p.id)\(p.id == cur ? " (current)" : ""): [\(title)](\(p.web.url?.absoluteString ?? "about:blank")) — \(who)")
        }
        return out
    }

    static var sessionName: (String?) -> String = { id in
        guard let s = AppModel.shared.session(id) else { return "a closed session" }
        return s.displayTitle
    }

    // MARK: Screenshot

    struct Shot { var data: Data; var mime: String; var size: CGSize; var what: String; var note: String? }

    /// Claude scales larger images down anyway; this keeps them readable and well under the API's size limit.
    static let maxWidth: CGFloat = 1568, maxHeight: CGFloat = 8000

    private static func screenshot(_ page: BrowserPage, fullPage: Bool, ref: String?) async throws -> Shot {
        let web = page.web
        let cfg = WKSnapshotConfiguration()
        var what = "Visible part"
        var note: String?
        var restore: NSSize?
        if let ref {
            let b = try await js(page, "return __octomux.box(ref)", ["ref": ref]) as? [String: Any]
            guard let r = b.flatMap(cgRect), r.width > 0, r.height > 0 else { throw Failure(message: "Element \(ref) has no size on screen.") }
            let visible = r.intersection(CGRect(origin: .zero, size: web.bounds.size))
            guard !visible.isNull, visible.width > 0 else { throw Failure(message: "Element \(ref) is outside the visible page.") }
            cfg.rect = visible
            what = "Element \(ref)"
        } else if fullPage {
            let m = try await js(page, "return __octomux.metrics()", [:]) as? [String: Any]
            let h = CGFloat((m?["height"] as? Double) ?? Double(web.bounds.height))
            what = "Whole page"
            if h > web.bounds.height + 1 {
                restore = web.frame.size
                let target = min(h, maxHeight)
                if h > maxHeight { note = "cut at \(Int(maxHeight)) px of \(Int(h))" }
                web.setFrameSize(NSSize(width: web.frame.width, height: target))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { if let restore { web.setFrameSize(restore) } }
        let image: NSImage = try await withCheckedThrowingContinuation { c in
            web.takeSnapshot(with: cfg) { img, err in
                if let img { c.resume(returning: img) } else { c.resume(throwing: Failure(message: "Couldn't take the screenshot: \(err?.localizedDescription ?? "unknown error")")) }
            }
        }
        guard let (data, mime, size) = encode(image) else { throw Failure(message: "Couldn't encode the screenshot.") }
        return Shot(data: data, mime: mime, size: size, what: what, note: note)
    }

    /// At 1 pixel per CSS pixel (at most `maxWidth` wide); PNG, or JPEG when that would be large.
    static func encode(_ image: NSImage) -> (Data, String, CGSize)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var size = image.size
        if size.width > maxWidth { size = CGSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded()) }
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        if let png = rep.representation(using: .png, properties: [:]), png.count < 900_000 { return (png, "image/png", CGSize(width: w, height: h)) }
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return (jpg, "image/jpeg", CGSize(width: w, height: h))
    }

    // MARK: JavaScript

    /// Runs `body` in the agent script's world of the page's main frame (injecting the script if the page
    /// hasn't got it yet, e.g. about:blank or a page still loading).
    static func js(_ page: BrowserPage, _ body: String, _ args: [String: Any]) async throws -> Any? {
        do {
            return try await page.web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: store.world)
        } catch {
            guard jsMessage(error).contains("__octomux"), let src = BrowserStore.agentScript else { throw Failure(message: jsMessage(error)) }
            _ = try? await page.web.evaluateJavaScript(src, in: nil, contentWorld: store.world)
            do { return try await page.web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: store.world) } catch { throw Failure(message: jsMessage(error)) }
        }
    }

    static func jsMessage(_ error: Error) -> String {
        if let f = error as? Failure { return f.message }
        let e = error as NSError
        if let m = e.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return m.hasPrefix("Error: ") ? String(m.dropFirst(7)) : m
        }
        return e.localizedDescription
    }

    // MARK: Helpers

    private static func string(_ args: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let v = args[key] as? String, allowEmpty || !v.isEmpty else { throw Failure(message: "Missing \(key).") }
        return v
    }

    static func short(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    static func quoted(_ s: String) -> String { "“\(s)”" }

    private static func cgPoint(_ d: [String: Any]) -> CGPoint? {
        guard let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func cgRect(_ d: [String: Any]) -> CGRect? {
        guard let x = d["x"] as? Double, let y = d["y"] as? Double, let w = d["width"] as? Double, let h = d["height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
