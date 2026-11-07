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
    var console: [BrowserConsoleEntry] = []
    var consoleSeen = 0
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
            web.observe(\.title, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? "" } },
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
        console.removeAll()
        consoleSeen = 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { lastError = error.localizedDescription }
        finishNavigation(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { lastError = error.localizedDescription }
        finishNavigation(false)
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
        if console.count > 300 { console.removeFirst(console.count - 300); consoleSeen = max(0, consoleSeen - 1) }
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
