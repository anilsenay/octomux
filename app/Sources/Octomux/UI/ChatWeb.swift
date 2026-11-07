import AppKit
import SwiftUI
import WebKit

/// The chat view's transcript, drawn by `Resources/editor/chat.html` (markdown, tool runs, edit diffs, todos).
/// One page per session, kept while the app runs so switching back is instant and keeps what was expanded.
final class ChatWebHost {
    static let shared = ChatWebHost()
    private var controllers: [String: ChatWebController] = [:]
    private var recent: [String] = []

    func controller(for sessionId: String) -> ChatWebController {
        recent.removeAll { $0 == sessionId }
        recent.append(sessionId)
        if let c = controllers[sessionId] { return c }
        let c = ChatWebController(sessionId: sessionId)
        controllers[sessionId] = c
        // A few pages at most; the oldest one is rebuilt when it is opened again.
        while recent.count > 6, let old = recent.first {
            recent.removeFirst()
            controllers.removeValue(forKey: old)?.close()
        }
        return c
    }

    var any: ChatWebController? { recent.last.flatMap { controllers[$0] } }
    func refreshTheme() { controllers.values.forEach { $0.applyTheme() } }
}

final class ChatWebController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let sessionId: String
    let web: CodeWebView
    private var ready = false
    private var queue: [String] = []
    /// What the page has, by item id (to send only what changed).
    private var sent: [String: ChatItem] = [:]
    private var sentOrder: [String] = []
    private var sentMeta: [String: String] = [:]
    private var last: (items: [ChatItem], working: Bool, needsInput: Bool, cwd: String, agent: String)?

    init(sessionId: String) {
        self.sessionId = sessionId
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = CodeWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(ChatWeakHandler(self), name: "octomux")
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.allowsMagnification = false
        web.loadFileURL(EditorAssets.dir.appendingPathComponent("chat.html"), allowingReadAccessTo: EditorAssets.dir)
        applyTheme()
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "octomux")
        web.removeFromSuperview()
    }

    /// Sends the items that are new or changed since the last update, and the order of all of them.
    func update(items: [ChatItem], working: Bool, needsInput: Bool, cwd: String, agent: String) {
        last = (items, working, needsInput, cwd, agent)
        let meta = ["working": working ? "1" : "0", "input": needsInput ? "1" : "0", "cwd": cwd, "agent": agent]
        let order = items.map(\.id)
        let changed = items.filter { sent[$0.id] != $0 }
        guard !changed.isEmpty || order != sentOrder || meta != sentMeta else { return }
        // A transcript that was rewritten (new ids from the start) is sent from scratch.
        let reset = !sentOrder.isEmpty && (order.first != sentOrder.first || order.count < sentOrder.count && !sentOrder.starts(with: order))
        let payloadItems = reset ? items : changed
        var p: [String: Any] = [
            "items": payloadItems.map(Self.json), "working": working, "needsInput": needsInput, "cwd": cwd, "agent": agent,
            "home": NSHomeDirectory(),
        ]
        if reset { p["reset"] = true }
        if order != sentOrder || reset { p["order"] = order }
        call("chatUpdate", p)
        if reset { sent = [:] }
        for it in payloadItems { sent[it.id] = it }
        if order.count < sent.count { let ids = Set(order); sent = sent.filter { ids.contains($0.key) } }
        sentOrder = order
        sentMeta = meta
    }

    static func json(_ it: ChatItem) -> [String: Any] {
        var d: [String: Any] = ["id": it.id, "kind": "\(it.kind)", "text": it.text, "failed": it.failed, "ts": it.ts]
        if it.kind == .tool {
            d["tool"] = it.tool
            d["detail"] = it.detail
            if let r = it.result { d["result"] = r.count > 60_000 ? String(r.prefix(60_000)) + "\n…" : r }
            if !it.input.isEmpty, let data = it.input.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) { d["input"] = o }
        }
        return d
    }

    // MARK: JS bridge

    private func call(_ fn: String, _ arg: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]), let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.octomux && window.octomux.\(fn)(\(json))"
        if ready { web.evaluateJavaScript(js) } else { queue.append(js) }
    }

    func eval(_ js: String, done: @escaping (String) -> Void) {
        web.evaluateJavaScript(js) { r, e in done(e.map { "error: \($0)" } ?? "\(r ?? "nil")") }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            // A reloaded page (or a restarted web process) starts empty: send everything again.
            let reloaded = ready
            ready = true
            queue.forEach { web.evaluateJavaScript($0) }
            queue.removeAll()
            if reloaded {
                sent = [:]; sentOrder = []; sentMeta = [:]
                applyTheme()
                if let l = last { update(items: l.items, working: l.working, needsInput: l.needsInput, cwd: l.cwd, agent: l.agent) }
            }
        case "copy":
            if let t = m["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "link":
            if let href = m["href"] as? String, let u = URL(string: href), let s = u.scheme?.lowercased(), ["http", "https", "mailto"].contains(s) {
                if !BrowserLinks.open(u, session: sessionId) { NSWorkspace.shared.open(u) }
            }
        case "open":
            if let p = m["path"] as? String { open(path: p) }
        case "diff":
            showChanges(path: m["path"] as? String ?? "")
        case "choose":
            if let id = m["id"] as? String, let i = (m["index"] as? NSNumber)?.intValue, i >= 0, i < 20, waitingOn(id) {
                // The question's list starts on its first option: move down to the pick, then return.
                keys(Array(repeating: "\u{1b}[B", count: i) + ["\r"])
            }
        case "permit":
            if let id = m["id"] as? String, waitingOn(id) {
                keys([(m["allow"] as? Bool) == true ? "\r" : "\u{1b}"])   // first option is Yes; esc says no
            }
        default: break
        }
    }

    /// The Changes view of the session's folder, scrolled to `path` when given (as a working-tree change,
    /// or against the compare branch when one is set).
    private func showChanges(path: String) {
        let model = AppModel.shared
        guard let s = model.session(sessionId) else { return }
        let base = s.worktree ?? model.project(s.projectId)?.path ?? s.cwd
        if model.selectedProjectId != s.projectId { model.selectedProjectId = s.projectId }
        var key: String?
        let full = (path as NSString).standardizingPath
        if !path.isEmpty, full.hasPrefix(base + "/") {
            let rel = String(full.dropFirst(base.count + 1))
            key = (GitInfo.compareBase(for: base) != nil ? "b:" : "u:") + rel
        }
        model.openDoc(.changes, workPath: base, scrollTo: key)
    }

    /// True when the session waits for input and `id` is its newest tool call without a result
    /// (what the page shows as answerable), so a late click never lands on another prompt.
    private func waitingOn(_ id: String) -> Bool {
        guard AppModel.shared.session(sessionId)?.activity == .needsInput,
              let l = last, let tool = l.items.last(where: { $0.kind == .tool }) else { return false }
        return tool.id == id && tool.result == nil
    }

    /// Keystrokes to the session's terminal, one by one (a TUI reads each as its own key).
    private func keys(_ seq: [String]) {
        let c = AppModel.shared.client(for: sessionId)
        for (i, k) in seq.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) { [sessionId] in
                c.call("session.input", ["id": sessionId, "data": k], completion: AppModel.shared.report)
            }
        }
    }

    /// A file the agent read or edited: opens it as a tab when it is inside the session's folder.
    private func open(path: String) {
        let model = AppModel.shared
        guard let s = model.session(sessionId) else { return }
        let base = s.worktree ?? model.project(s.projectId)?.path ?? s.cwd
        let full = (path as NSString).standardizingPath
        for root in [base, s.cwd] where full.hasPrefix(root + "/") {
            model.openDoc(.file(String(full.dropFirst(root.count + 1))), workPath: root)
            return
        }
        if FileManager.default.fileExists(atPath: full) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
    }

    // MARK: Theme

    func applyTheme() {
        let dark = ThemeStore.shared.isDark
        let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var vars: [String: String] = [:]
        ap.performAsCurrentDrawingAppearance {
            func css(_ c: NSColor, _ alpha: CGFloat? = nil) -> String {
                let x = c.usingColorSpace(.sRGB) ?? c
                return String(format: "rgba(%d,%d,%d,%.3f)", Int(round(x.redComponent * 255)), Int(round(x.greenComponent * 255)),
                              Int(round(x.blueComponent * 255)), alpha ?? x.alphaComponent)
            }
            let green = T.diffAddNS, red = T.diffDelNS
            vars = [
                "bg": css(WorkspaceTint.canvas(dark: dark)),
                "raised": css(T.ns(\.raised)),
                "text": css(T.ns(\.text)), "text2": css(T.ns(\.text2)), "text3": css(T.ns(\.text3)),
                "border": css(T.ns(\.border)), "hover": css(T.ns(\.hover)),
                "hover2": dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.07)",
                // The user's messages: a neutral raised bubble (the accent stays for state, not decoration).
                "bubble": dark ? "rgba(255,255,255,0.075)" : "rgba(0,0,0,0.05)",
                "selection": css(T.ns(\.accent), 0.28),
                "accent": css(T.ns(\.accent)), "green": css(green), "red": css(red), "blue": css(T.ns(\.blue)), "amber": css(T.ns(\.amber)),
                "add-bg": css(green, dark ? 0.12 : 0.13), "del-bg": css(red, dark ? 0.12 : 0.11),
                "mono": "\"\(T.monoName ?? "SF Mono")\", \"SF Mono\", ui-monospace, Menlo, monospace",
                "chat-size": String(format: "%.1fpx", 13.5 * T.k),
            ]
        }
        call("setTheme", ["dark": dark, "vars": vars])
    }
}

private final class ChatWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: ChatWebController?
    init(_ t: ChatWebController) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(uc, didReceive: m) }
}

/// Hosts the session's chat page in SwiftUI and keeps it up to date with the parsed transcript.
struct ChatTranscriptView: NSViewRepresentable {
    let sessionId: String
    let items: [ChatItem]
    let working: Bool
    var needsInput = false
    let cwd: String
    let agent: String

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(to: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        attach(to: box)
        ChatWebHost.shared.controller(for: sessionId).update(items: items, working: working, needsInput: needsInput, cwd: cwd, agent: agent)
    }

    private func attach(to box: NSView) {
        let web = ChatWebHost.shared.controller(for: sessionId).web
        guard web.superview !== box else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: box.leadingAnchor), web.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            web.topAnchor.constraint(equalTo: box.topAnchor), web.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}
