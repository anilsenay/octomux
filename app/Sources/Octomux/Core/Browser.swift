import AppKit
import Combine
import WebKit

/// What an agent is doing on a page right now, for the live view (cursor, label, highlight).
struct BrowserActivity: Equatable {
    var sessionId: String
    /// "Clicking “Sign in”", "Typing “hello”", "Reading the page"…
    var label: String
    /// Where the action lands, in the page's viewport points (nil: no pointer, e.g. a snapshot).
    var point: CGPoint?
    /// The element acted on, in viewport points.
    var box: CGRect?
    var at = Date()
    /// Bumped per action so the press ring replays on the same spot.
    var seq = 0
}

/// A screen size a page is laid out at (instead of the browser's own size), scaled down to fit when needed.
struct BrowserViewport: Equatable {
    var name: String
    var width: CGFloat
    var height: CGFloat
    /// The user agent sites see (phones and tablets get Safari's, so they serve their mobile pages).
    var userAgent: String?

    static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let presets: [BrowserViewport] = [
        BrowserViewport(name: "Mobile", width: 390, height: 844, userAgent: iPhoneUA),
        BrowserViewport(name: "Tablet", width: 820, height: 1180, userAgent: iPadUA),
        BrowserViewport(name: "Laptop", width: 1280, height: 800, userAgent: nil),
        BrowserViewport(name: "Desktop", width: 1920, height: 1080, userAgent: nil),
    ]
    static func preset(_ name: String) -> BrowserViewport? { presets.first { $0.name.lowercased() == name.lowercased() } }
    var label: String { "\(name) \(Int(width))×\(Int(height))" }
}

/// The element the user picked to send to an agent.
struct PickedElement {
    var info: [String: Any]
    var image: Data?
    var selector: String { info["selector"] as? String ?? "" }
    var box: CGRect? {
        guard let b = info["box"] as? [String: Any], let x = b["x"] as? Double, let y = b["y"] as? Double,
              let w = b["width"] as? Double, let h = b["height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct BrowserConsoleEntry {
    var level: String
    var text: String
    var at: Date
}

/// One browser page (a tab of the Browser panel). Agents act on it through `BrowserTools`; the user sees it live.
@MainActor
final class BrowserPage: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let web: BrowserWebView
    /// The session that opened it (nil: the user did).
    let owner: String?
    @Published var url = ""
    @Published var title = ""
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var activity: BrowserActivity?
    /// The session that acted on it last, and when (shown in the panel after the action).
    @Published var lastAgent: String?
    @Published var lastAgentAt: Date?
    /// A page brought back after a relaunch loads its address when first shown or used.
    var pendingURL: URL?
    /// Laid out at this size (nil: the browser's own size).
    @Published var viewport: BrowserViewport? { didSet { web.customUserAgent = viewport?.userAgent; BrowserStore.shared.relayout(self) } }
    @Published var zoom: Double = 1 { didSet { web.pageZoom = zoom } }
    @Published var findVisible = false
    @Published var findCount: Int?
    /// The page couldn't be loaded: shown over it with Try Again.
    @Published var loadError: (url: URL?, message: String)?
    /// The user is picking an element (hover highlights, a click picks).
    @Published var picking = false
    @Published var pickHover: (box: CGRect, label: String)?
    @Published var picked: PickedElement?
    /// Bumped to move the keyboard into the address bar (⌘L).
    @Published var addressFocusRequest = 0
    /// Each session's last snapshot of this page (for "only what changed").
    var lastSnapshot: [String: (url: String, yaml: String)] = [:]
    var console: [BrowserConsoleEntry] = []
    var consoleSeen = 0
    /// Console messages already reported to each session (each error is "new" once).
    var consoleReported: [String: Int] = [:]
    /// Things the agent should hear about with its next result (dialogs handled, pages opened…).
    var events: [String] = []
    private var navWaiters: [(Bool) -> Void] = []
    private var observers: [NSKeyValueObservation] = []
    private var activityClear: DispatchWorkItem?

    init(id: String, owner: String?, configuration: WKWebViewConfiguration) {
        self.id = id
        self.owner = owner
        web = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.isInspectable = true
        observers = [
            web.observe(\.url, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.url = w.url?.absoluteString ?? ""; BrowserStore.shared.save() } },
            web.observe(\.title, options: [.new]) { [weak self] w, _ in Task { @MainActor in
                self?.title = w.title ?? ""
                if let u = w.url, let t = w.title { BrowserHistory.shared.setTitle(t, for: u) }
            } },
            web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.isLoading = w.isLoading } },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
        ]
    }

    func close() {
        observers.removeAll()
        web.stopLoading()
        web.removeFromSuperview()
        finishNavigation(false)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let u = URL(string: url), let h = u.host { return h }
        return url.isEmpty ? "New page" : url
    }

    // MARK: Navigation

    /// Loads the address a restored page had (once).
    func loadPending() async {
        guard let u = pendingURL else { return }
        pendingURL = nil
        await load(u)
    }

    /// Opens `url` and waits (at most `timeout` s) for it to load. False: it failed or is still loading.
    @discardableResult
    func load(_ url: URL, timeout: Double = 20) async -> Bool {
        pendingURL = nil
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            web.load(URLRequest(url: url))
        }
        return await waitForNavigation(timeout: timeout)
    }

    /// Waits for the navigation in progress (if any) to finish.
    func waitForNavigation(timeout: Double) async -> Bool {
        if !web.isLoading && navWaiters.isEmpty { return true }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var done = false
            let finish: (Bool) -> Void = { ok in if !done { done = true; c.resume(returning: ok) } }
            navWaiters.append(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private func finishNavigation(_ ok: Bool) {
        let w = navWaiters
        navWaiters = []
        w.forEach { $0(ok) }
    }

    var lastError: String?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        loadError = nil
        console.removeAll()
        consoleSeen = 0
        consoleReported = [:]
        if picking { picking = false; pickHover = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadError = nil
        if let u = webView.url { BrowserHistory.shared.record(url: u, title: webView.title ?? "") }
        finishNavigation(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        // Cancelled (a newer navigation) and "frame load interrupted" (a download took over) aren't failures.
        if e.code != NSURLErrorCancelled && !(e.domain == "WebKitErrorDomain" && e.code == 102) {
            lastError = e.localizedDescription
            let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? (e.userInfo["NSErrorFailingURLKey"] as? URL)
            loadError = (failing ?? web.url, e.localizedDescription)
        }
        finishNavigation(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // What a page can't show (zip, dmg, a PDF sent as an attachment) is saved instead.
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download, page: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download, page: self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastError = "The page's web process stopped (it may have run out of memory)."
        finishNavigation(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Links to other apps (mailto:, slack:, …) open there when the user clicks; an agent's are refused.
        if let u = navigationAction.request.url, let scheme = u.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            if !agentDriving { NSWorkspace.shared.open(u) } else { events.append("A link to \(scheme): was not opened (\(u.absoluteString.prefix(120))).") }
            decisionHandler(.cancel)
            return
        }
        // Allowed sites (Settings) bind what an agent's actions open, in the page and its frames.
        if agentDriving, navigationAction.targetFrame?.isMainFrame != false, let u = navigationAction.request.url,
           !BrowserAccess.allows(u, patterns: BrowserAccess.allowedSites) {
            events.append("Blocked opening \(u.absoluteString.prefix(160)): \(u.host ?? "that address") isn't one of the sites allowed in Settings (\(BrowserAccess.allowedSites.joined(separator: ", "))).")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        decisionHandler(.allow)
    }

    // MARK: Windows and dialogs

    /// An agent acted in the last few seconds: dialogs are answered for it, and it hears about them.
    var agentDriving: Bool { (lastAgentAt.map { Date().timeIntervalSince($0) < 8 } ?? false) || activity != nil }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let page = BrowserStore.shared.adopt(configuration: configuration, owner: owner, opener: self)
        if let u = navigationAction.request.url { events.append("The page opened a new page \(page.id): \(u.absoluteString.prefix(200)) (use browser_tabs to switch to it).") }
        return page.web
    }

    func webViewDidClose(_ webView: WKWebView) { BrowserStore.shared.close(id) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        if agentDriving {
            events.append("The page showed an alert: “\(message.prefix(300))” (dismissed).")
            completionHandler()
            return
        }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        if agentDriving {
            events.append("The page asked to confirm: “\(message.prefix(300))” (accepted).")
            completionHandler(true)
            return
        }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        if agentDriving {
            events.append("The page asked for text: “\(prompt.prefix(300))” (answered with its default “\(defaultText ?? "")”).")
            completionHandler(defaultText ?? "")
            return
        }
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.begin { r in completionHandler(r == .OK ? p.urls : nil) }
    }

    // MARK: Console

    func log(level: String, text: String) {
        console.append(BrowserConsoleEntry(level: level, text: text, at: Date()))
        if console.count > 300 {
            console.removeFirst(console.count - 300)
            consoleSeen = max(0, consoleSeen - 1)
            for k in consoleReported.keys { consoleReported[k] = max(0, (consoleReported[k] ?? 0) - 1) }
        }
    }

    // MARK: Live view

    func show(_ a: BrowserActivity) {
        activityClear?.cancel()
        var a = a
        a.seq = (activity?.seq ?? 0) + 1
        activity = a
        lastAgent = a.sessionId
        lastAgentAt = Date()
    }

    /// The action is over: the cursor stays a moment, then the view goes back to normal.
    func endActivity(after: Double = 1.6) {
        lastAgentAt = Date()
        let w = DispatchWorkItem { [weak self] in self?.activity = nil }
        activityClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    // MARK: Picking an element for an agent

    func startPicking() {
        picked = nil
        picking = true
        Task { _ = try? await BrowserTools.js(self, "return __octomux.pickStart()", [:]) }
    }

    func stopPicking() {
        picking = false
        pickHover = nil
        Task { _ = try? await BrowserTools.js(self, "return __octomux.pickStop()", [:]) }
    }

    /// The picked element, with a crop of the page around it (what is on screen of it).
    func didPick(_ info: [String: Any]) async {
        picking = false
        pickHover = nil
        var info = info
        info["page"] = id
        var p = PickedElement(info: info)
        if let box = p.box {
            let visible = box.insetBy(dx: -8, dy: -8).intersection(CGRect(origin: .zero, size: web.bounds.size))
            if !visible.isNull, visible.width > 2, visible.height > 2 {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = visible
                if let img = try? await web.takeSnapshot(configuration: cfg) { p.image = BrowserTools.encode(img)?.0 }
            }
        }
        picked = p
    }

    // MARK: Find, zoom

    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { findCount = nil; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        web.find(text, configuration: cfg) { _ in }
        Task { findCount = (try? await BrowserTools.js(self, "return __octomux.countText(t)", ["t": text])) as? Int }
    }

    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    func zoomIn() { zoom = Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom }
    func zoomOut() { zoom = Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom }
}

/// The element picker's messages (hover, picked, cancel), from the agent script's world.
private final class BrowserPickRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        let web = message.webView
        MainActor.assumeIsolated {
            guard let page = BrowserStore.shared.pages.first(where: { $0.web === web }) else { return }
            switch type {
            case "hover":
                if let b = m["box"] as? [String: Any], let x = b["x"] as? Double, let y = b["y"] as? Double,
                   let w = b["width"] as? Double, let h = b["height"] as? Double {
                    page.pickHover = (CGRect(x: x, y: y, width: w, height: h), m["label"] as? String ?? "")
                }
            case "picked":
                if let info = m["info"] as? [String: Any] { Task { await page.didPick(info) } }
            default:
                page.picking = false
                page.pickHover = nil
            }
        }
    }
}

/// Console messages of every page arrive here (one content controller is shared by all pages, and by the pages
/// they open, which WebKit creates with their opener's configuration).
private final class BrowserConsoleRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let level = m["level"] as? String, let text = m["text"] as? String else { return }
        let web = message.webView
        MainActor.assumeIsolated {
            BrowserStore.shared.pages.first { $0.web === web }?.log(level: level, text: text)
        }
    }
}

final class BrowserWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// All browser pages, which one the panel shows, and which page each session works in.
@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()
    @Published private(set) var pages: [BrowserPage] = []
    /// The browser beside a tab's terminals: tab id → the page it shows ("" = open, no page yet). No entry: closed.
    @Published private(set) var splits: [String: String] = [:]
    /// The page last shown anywhere (what the browser shows when opened on a tab that had none).
    private(set) var lastShownId: String?
    /// Each session's current page (the one its tools act on).
    private(set) var current: [String: String] = [:]
    private var nextId = 1
    /// Cookies and storage of the Octomux browser: its own, kept between launches, apart from the app's other web views.
    static let dataStoreId = UUID(uuidString: "6F63746F-6D75-7842-726F-777365720001")!
    let dataStore = WKWebsiteDataStore(forIdentifier: BrowserStore.dataStoreId)
    let world = WKContentWorld.world(name: "octomux")
    /// Called when an agent starts using a page in the focused session (the app shows the panel).
    var onAgentPage: ((BrowserPage, String) -> Void)?

    func splitPage(tab: String?) -> BrowserPage? { tab.flatMap { splits[$0] }.flatMap(page) }
    func splitOpen(tab: String?) -> Bool { tab.map { splits[$0] != nil } ?? false }

    /// Shows `page` beside the tab's terminals (opening the browser there).
    func show(_ page: BrowserPage, in tab: String) {
        guard splits[tab] != page.id else { return }
        splits[tab] = page.id
        lastShownId = page.id
        save()
    }

    /// Opens the browser on a tab: the page it showed last, or an empty browser.
    func openSplit(tab: String) {
        guard splits[tab] == nil else { return }
        splits[tab] = page(lastShownId)?.id ?? pages.last?.id ?? ""
        save()
    }

    func closeSplit(tab: String) {
        guard splits[tab] != nil else { return }
        splits[tab] = nil
        save()
    }
    func page(_ id: String?) -> BrowserPage? { pages.first { $0.id == id } }
    func currentPage(of session: String) -> BrowserPage? { page(current[session]) }

    private lazy var contentController: WKUserContentController = {
        let uc = WKUserContentController()
        Self.addScripts(to: uc, world: world)
        uc.add(BrowserConsoleRouter(), contentWorld: .page, name: "octomuxConsole")
        uc.add(BrowserPickRouter(), contentWorld: world, name: "octomuxPick")
        return uc
    }()

    func makeConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = contentController
        cfg.websiteDataStore = dataStore
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        return cfg
    }

    static func addScripts(to uc: WKUserContentController, world: WKContentWorld) {
        if let src = agentScript {
            uc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        }
        uc.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    static let agentScript: String? = try? String(contentsOf: EditorAssets.dir.appendingPathComponent("browser.js"), encoding: .utf8)

    /// Passes the page's console and uncaught errors to the app (browser_console_messages).
    static let consoleScript = """
    (() => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.octomuxConsole;
      if (!h) return;
      const str = (a) => { try { return typeof a === 'string' ? a : a instanceof Error ? (a.stack || String(a)) : JSON.stringify(a); } catch { return String(a); } };
      const post = (level, args) => { try { h.postMessage({ level, text: args.map(str).join(' ').slice(0, 2000) }); } catch {} };
      for (const l of ['log', 'info', 'warn', 'error', 'debug']) {
        const o = console[l];
        console[l] = function (...a) { post(l, a); return o.apply(this, a); };
      }
      addEventListener('error', e => post('error', [e.message + (e.filename ? ` (${e.filename}:${e.lineno})` : '')]));
      addEventListener('unhandledrejection', e => post('error', ['Unhandled rejection: ' + str(e.reason)]));
    })();
    """

    @discardableResult
    func newPage(owner: String?, showIn tab: String? = nil) -> BrowserPage {
        let p = BrowserPage(id: "p\(nextId)", owner: owner, configuration: makeConfiguration())
        nextId += 1
        pages.append(p)
        if let owner { current[owner] = p.id }
        if let tab { splits[tab] = p.id; lastShownId = p.id }
        save()
        return p
    }

    // MARK: Kept across launches

    private static let savedKey = "octomux.browserPages"
    private struct Saved: Codable { var id: String; var owner: String?; var url: String; var current: [String]? }
    private struct SavedState: Codable { var pages: [Saved]; var splits: [String: String]; var last: String? }

    /// Pages, their owners and which sessions work in them, so agents (and the user) find them after a relaunch
    /// or an update. Their addresses load when first shown or used.
    func save() {
        let v = pages.map { p in Saved(id: p.id, owner: p.owner, url: p.web.url?.absoluteString ?? p.pendingURL?.absoluteString ?? p.url,
                                       current: current.filter { $0.value == p.id }.map(\.key)) }
        if let d = try? JSONEncoder().encode(SavedState(pages: v, splits: splits, last: lastShownId)) { UserDefaults.standard.set(d, forKey: Self.savedKey) }
    }

    func restore() {
        guard pages.isEmpty, let d = UserDefaults.standard.data(forKey: Self.savedKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: d) else { return }
        for s in state.pages.prefix(20) {
            let p = BrowserPage(id: s.id, owner: s.owner, configuration: makeConfiguration())
            p.pendingURL = URL(string: s.url).flatMap { $0.scheme == nil || $0.absoluteString == "about:blank" ? nil : $0 }
            p.url = s.url
            p.events.append("Octomux was restarted: this page loaded again; anything typed into it before is gone.")
            pages.append(p)
            for sid in s.current ?? [] { current[sid] = p.id }
            if let n = Int(s.id.dropFirst()), n >= nextId { nextId = n + 1 }
        }
        splits = state.splits.filter { $0.value.isEmpty || page($0.value) != nil }
        lastShownId = page(state.last)?.id
    }

    /// A page the web content opened (window.open, target=_blank), with the configuration WebKit gives.
    func adopt(configuration: WKWebViewConfiguration, owner: String?, opener: BrowserPage) -> BrowserPage {
        let p = BrowserPage(id: "p\(nextId)", owner: owner, configuration: configuration)
        nextId += 1
        if let i = pages.firstIndex(where: { $0 === opener }) { pages.insert(p, at: i + 1) } else { pages.append(p) }
        // The user clicked it: show it, as a browser would. An agent's popup waits until it switches to it.
        if !opener.agentDriving {
            for (tab, pid) in splits where pid == opener.id { splits[tab] = p.id }
            lastShownId = p.id
        }
        save()
        return p
    }

    func select(_ id: String, for session: String) { current[session] = id; save() }

    /// Gives a page with a viewport preset that size when it isn't on screen (on screen, its host sizes it).
    func relayout(_ page: BrowserPage) {
        if let v = page.viewport, page.web.superview == nil { page.web.frame = NSRect(x: 0, y: 0, width: v.width, height: v.height) }
        page.web.superview?.needsLayout = true
    }

    func close(_ id: String) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let p = pages.remove(at: i)
        p.close()
        for (s, pid) in current where pid == id { current[s] = nil }
        // A browser that showed it moves to a neighbor page, or stays open empty.
        let next = pages.indices.contains(i) ? pages[i].id : pages.last?.id
        for (tab, pid) in splits where pid == id { splits[tab] = next ?? "" }
        if lastShownId == id { lastShownId = next }
        save()
    }

    /// The pages a session should see first in lists: its own, then the user's, then other sessions'.
    func sessionsUsing(_ page: BrowserPage) -> [String] { current.filter { $0.value == page.id }.map(\.key) }

    /// Clears cookies, storage and cache of the Octomux browser.
    func clearData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Turns what someone typed in the address bar (or an agent passed) into a URL.
    nonisolated static func normalize(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("/") || s.hasPrefix("~/") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) { return u }
        if s.contains(" ") { return nil }
        // localhost:3000, 127.0.0.1:8080/x, example.com/path
        let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." } && host.contains(".")
        guard local || host.contains(".") else { return nil }
        return URL(string: (local ? "http://" : "https://") + s)
    }

    /// For the address bar: a URL, or a web search for anything else.
    nonisolated static func addressBarURL(_ raw: String) -> URL? {
        if let u = normalize(raw) { return u }
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, var c = URLComponents(string: "https://duckduckgo.com/") else { return nil }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}

/// Files the browser's pages save (links to downloads, files sites send as attachments): into ~/Downloads.
@MainActor
final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var source: String
        var file: URL?
        var pageId: String?
        var done = false
        var error: String?
        var bytes: Int64 = 0
        var at = Date()
    }

    @Published private(set) var items: [Item] = []
    private var byDownload: [ObjectIdentifier: UUID] = [:]
    private var pages: [ObjectIdentifier: String] = [:]
    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

    func track(_ d: WKDownload, page: BrowserPage) {
        d.delegate = self
        let item = Item(name: d.originalRequest?.url?.lastPathComponent ?? "download", source: d.originalRequest?.url?.absoluteString ?? "", pageId: page.id)
        items.insert(item, at: 0)
        if items.count > 30 { items.removeLast(items.count - 30) }
        byDownload[ObjectIdentifier(d)] = item.id
        pages[ObjectIdentifier(d)] = page.id
    }

    private func update(_ d: WKDownload, _ f: (inout Item) -> Void) {
        guard let id = byDownload[ObjectIdentifier(d)], let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    /// A free name in the folder: "report.pdf", then "report 2.pdf"…
    static func unique(_ name: String, in folder: URL) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var url = folder.appendingPathComponent(clean.isEmpty ? "download" : clean)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let url = Self.unique(suggestedFilename, in: folder)
        update(download) { $0.name = url.lastPathComponent; $0.file = url; $0.bytes = max(0, response.expectedContentLength) }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        update(download) { item in
            item.done = true
            if let f = item.file, let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int64 { item.bytes = size }
        }
        report(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        update(download) { $0.error = error.localizedDescription; $0.done = true }
        report(download)
    }

    /// The page's agent hears about it with its next result.
    private func report(_ d: WKDownload) {
        guard let id = byDownload[ObjectIdentifier(d)], let item = items.first(where: { $0.id == id }),
              let page = BrowserStore.shared.page(pages[ObjectIdentifier(d)]) else { return }
        if let e = item.error {
            page.events.append("Download of \(item.name) failed: \(e)")
        } else if let f = item.file {
            page.events.append("Downloaded \(item.name) (\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))) to \(f.path)")
        }
    }
}
