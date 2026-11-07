import AppKit

/// Who may use the Octomux browser's agent tools, and where (Settings → MCP → Octomux browser):
/// Off / Ask (each session asks once) / On, and an optional list of allowed sites.
@MainActor
enum BrowserAccess {
    enum Mode: String, CaseIterable { case off, ask, on
        var title: String { switch self { case .off: return "Off"; case .ask: return "Ask"; case .on: return "On" } }
    }

    static var mode: Mode {
        if case .string(let s)? = AppModel.shared.setting("browser.access"), let m = Mode(rawValue: s) { return m }
        // Before Ask existed: a plain switch.
        if AppModel.shared.setting("browser.agent_tools")?.bool == false { return .off }
        return .on
    }

    static var allowedSites: [String] {
        guard case .array(let a)? = AppModel.shared.setting("browser.allowed_sites") else { return [] }
        return a.compactMap { if case .string(let s) = $0 { return s.trimmingCharacters(in: .whitespaces) }; return nil }.filter { !$0.isEmpty }
    }

    /// Does `url` match one of `patterns`? Patterns: `example.com` (that host), `*.example.com` (it and its
    /// subdomains), `localhost:3000` (host and port), `*` (anything). about: pages always pass; file: pages only
    /// with a `file://` pattern. An empty list allows everything.
    nonisolated static func allows(_ url: URL, patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return true }
        if scheme == "file" { return patterns.contains { $0.lowercased().hasPrefix("file://") || $0 == "*" } }
        guard let host = url.host?.lowercased() else { return false }
        let port = url.port
        for raw in patterns {
            var p = raw.lowercased()
            if p == "*" { return true }
            if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
            if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
            var pPort: Int?
            if let colon = p.lastIndex(of: ":"), let n = Int(p[p.index(after: colon)...]) { pPort = n; p = String(p[..<colon]) }
            if let pPort, pPort != port { continue }
            if p.hasPrefix("*.") {
                let base = String(p.dropFirst(2))
                if host == base || host.hasSuffix("." + base) { return true }
            } else if host == p {
                return true
            }
        }
        return false
    }

    // MARK: Ask: one decision per session, kept until revoked in Settings

    private static let key = "octomux.browserApprovals"
    static var decisions: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key); NotificationCenter.default.post(name: .octomuxBrowserAccess, object: nil) }
    }
    static func forget(_ session: String) { var d = decisions; d[session] = nil; decisions = d }

    private static var pending: [String: Task<Bool, Never>] = [:]
    /// Answers the prompt in tests and automation (nil: ask the user).
    static var autoAnswer: ((String) -> Bool)?

    /// Nil when the session may use the browser; else the message the agent gets.
    static func check(session: String) async -> String? {
        switch mode {
        case .off:
            return "The user turned the Octomux browser off for agents (Settings → MCP → Octomux browser). Don't retry; ask the user if you need it."
        case .on:
            return nil
        case .ask:
            if let d = decisions[session] { return d ? nil : denied }
            let t = pending[session] ?? Task { await ask(session) }
            pending[session] = t
            let ok = await t.value
            pending[session] = nil
            var d = decisions; d[session] = ok; decisions = d
            return ok ? nil : denied
        }
    }

    private static let denied = "The user didn't allow this session to use the Octomux browser. Don't retry; ask the user if you need it."

    private static func ask(_ session: String) async -> Bool {
        if let a = autoAnswer { return a(session) }
        let a = NSAlert()
        a.messageText = "Let “\(BrowserUI.agentLabel(session))” use the browser?"
        a.informativeText = "It can open pages, read them, click and type in them, with the cookies of the Octomux browser. You'll see what it does beside its tab. Settings → MCP → Octomux browser can change this later."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don't Allow")
        a.icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        NSApp.requestUserAttention(.informationalRequest)
        guard let win = (NSApp.delegate as? AppDelegate)?.mainWindow ?? NSApp.mainWindow, win.attachedSheet == nil else {
            return a.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { c in
            a.beginSheetModal(for: win) { r in c.resume(returning: r == .alertFirstButtonReturn) }
        }
    }
}

extension Notification.Name {
    static let octomuxBrowserAccess = Notification.Name("octomux.browserAccess")
}
