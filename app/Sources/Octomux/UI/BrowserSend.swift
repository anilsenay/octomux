import AppKit
import SwiftUI

/// Sending a picked element to an agent: what the message says, and where it goes.
enum BrowserSend {
    /// The message: the user's note, then the element (where, what, how it looks) and the crop of it.
    static func message(note: String, info: [String: Any], image: URL?, kind: AgentKind) -> String {
        var lines: [String] = []
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lines += [n, ""] }
        let url = info["url"] as? String ?? ""
        let title = (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // The page id lets the agent act on that very page (browser_tabs select).
        let page = (info["page"] as? String).map { " (page \($0))" } ?? ""
        lines.append("Element I picked in the Octomux browser\(page), on \(url)\(title.map { " (“\($0)”)" } ?? ""):")
        if let s = info["selector"] as? String, !s.isEmpty { lines.append("- selector: \(s)") }
        let role = info["role"] as? String ?? "", name = info["name"] as? String ?? ""
        if !role.isEmpty || !name.isEmpty { lines.append("- role: \(role.isEmpty ? (info["tag"] as? String ?? "") : role)\(name.isEmpty ? "" : " “\(name)”")") }
        if let t = info["text"] as? String, !t.isEmpty, t != name { lines.append("- text: \(t.count > 300 ? String(t.prefix(299)) + "…" : t)") }
        if let b = info["box"] as? [String: Any], let w = b["width"] as? Double, let h = b["height"] as? Double {
            lines.append("- size: \(Int(w))×\(Int(h)) px")
        }
        if let styles = info["styles"] as? [String: Any], !styles.isEmpty {
            let order = ["color", "background-color", "font-family", "font-size", "font-weight", "line-height", "display", "position", "width", "height",
                         "margin", "padding", "border", "border-radius", "box-shadow", "opacity", "gap", "flex-direction", "justify-content", "align-items"]
            let s = order.compactMap { k in (styles[k] as? String).map { "\(k): \($0)" } }
            lines.append("- styles: \(s.joined(separator: "; "))")
        }
        if let html = info["html"] as? String, !html.isEmpty {
            lines.append("- html: \(html.replacingOccurrences(of: "\n", with: " ").prefix(500))")
        }
        if let image {
            // Claude reads @path references (images too); other agents get the path.
            let p = image.path.contains(" ") ? "\"\(image.path)\"" : image.path
            lines.append("- screenshot of it: \(kind == .claude ? "@" + p : p)")
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the crop where pasted screenshots go.
    static func saveImage(_ data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("element-\(f.string(from: Date())).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Agents that can take it: the tab's first (its focused one first), then the others still running.
    @MainActor static func targets(tab: String) -> [Session] {
        let m = AppModel.shared
        let agents = m.state.sessions.filter { $0.isAgent && $0.state == .running }
        let t = m.state.tabs.first { $0.id == tab }
        let inTab = t?.layout.sessions ?? []
        return agents.sorted { a, b in
            let ra = a.id == t?.activeSessionId ? 0 : inTab.contains(a.id) ? 1 : 2
            let rb = b.id == t?.activeSessionId ? 0 : inTab.contains(b.id) ? 1 : 2
            return ra != rb ? ra < rb : a.lastActivityAt > b.lastActivityAt
        }
    }

    /// Texts for chat composers that weren't on screen when sent (taken by the chat view when it appears).
    @MainActor static var pendingChat: [String: [String]] = [:]
    @MainActor static func takePending(_ session: String) -> [String] { pendingChat.removeValue(forKey: session) ?? [] }

    /// Puts the message where the user writes to that agent, without sending it: the chat composer, or the
    /// agent's own prompt in its terminal (pasted). The session comes to the front so they can read it and send.
    @MainActor static func deliver(_ text: String, to session: String) {
        let m = AppModel.shared
        m.selectSession(session)
        if m.isChat(session) {
            // The chat view may not be on screen yet (another tab): it picks the text up when it appears.
            pendingChat[session, default: []].append(text)
            NotificationCenter.default.post(name: .octomuxComposerAppend, object: session, userInfo: ["text": text])
        } else {
            m.sendToSession(session, text: text, submit: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { TerminalHost.shared.focusCurrent() }
        }
    }
}

extension Notification.Name {
    /// Text for a chat composer (object: session id, userInfo["text"]).
    static let octomuxComposerAppend = Notification.Name("octomux.composerAppend")
}

/// After picking: the note, the agent, and exactly what will be sent.
struct SendElementPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var page: BrowserPage
    let tab: String
    @State private var note = ""
    @State private var target: String?
    @State private var showDetails = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        let picked = page.picked
        let targets = BrowserSend.targets(tab: tab)
        let chosen = target ?? targets.first?.id
        let kind = model.profile(model.session(chosen)?.profileId)?.kind ?? .claude
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(T.accent)
                Text("Send to agent").font(T.headline)
                if let info = picked?.info {
                    Text(((info["role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? info["tag"] as? String ?? "") + ((info["name"] as? String).flatMap { $0.isEmpty ? nil : " “\($0.prefix(40))”" } ?? ""))
                        .font(T.caption).foregroundStyle(T.text2).lineLimit(1)
                }
                Spacer()
                Button { page.picked = nil; page.startPicking() } label: { Text("Pick Again") }.buttonStyle(ChromeButtonStyle(size: 22)).font(T.caption)
            }
            HStack(alignment: .top, spacing: 10) {
                if let d = picked?.image, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(T.border))
                }
                TextField("What should the agent do with it? (e.g. make this button full width)", text: $note, axis: .vertical)
                    .textFieldStyle(.plain).font(T.body).lineLimit(2...5).focused($noteFocused)
                    .padding(8).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
            }
            DisclosureGroup(isExpanded: $showDetails) {
                ScrollView {
                    Text(preview(kind: kind)).font(T.mono(10.5)).foregroundStyle(T.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } label: { Text("What will be sent").font(T.caption).foregroundStyle(T.text2) }
            HStack(spacing: 8) {
                if targets.isEmpty {
                    Text("No agent is running. Start one, then send.").font(T.caption).foregroundStyle(T.text3)
                } else {
                    Picker("To", selection: Binding(get: { chosen ?? "" }, set: { target = $0 })) {
                        ForEach(targets) { s in Text(BrowserUI.agentLabel(s.id)).tag(s.id) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { page.picked = nil }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Send") { send(to: chosen, kind: kind) }.buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command).disabled(chosen == nil)
                    .help("Puts it in the agent's message box; you send it from there (⌘↩)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.raised).shadow(color: .black.opacity(0.25), radius: 10, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border))
        .padding(10)
        .onAppear { noteFocused = true }
    }

    private func preview(kind: AgentKind) -> String {
        guard let p = page.picked else { return "" }
        let img = p.image.map { _ in URL(fileURLWithPath: NSTemporaryDirectory() + "octomux-attachments/element-….png") }
        return BrowserSend.message(note: note, info: p.info, image: img, kind: kind)
    }

    private func send(to session: String?, kind: AgentKind) {
        guard let session, let p = page.picked else { return }
        let image = p.image.flatMap(BrowserSend.saveImage)
        let text = BrowserSend.message(note: note, info: p.info, image: image, kind: kind)
        page.picked = nil
        BrowserSend.deliver(text, to: session)
    }
}

/// Links clicked in terminals (and the chat view): which open in the Octomux browser, beside the session's tab.
/// Settings → MCP → Octomux browser picks; ⇧ while clicking does the other thing for that click.
enum BrowserLinks {
    enum Mode: String, CaseIterable {
        case local, all, never
        var title: String {
            switch self {
            case .local: return "Local addresses (localhost…)"
            case .all: return "All web links"
            case .never: return "None (default browser)"
            }
        }
    }
    static let key = "octomux.browserLinks"
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .local }

    /// localhost, *.localhost, 127.x, 0.0.0.0, [::1], *.local, and private network addresses (a dev server on the LAN).
    static func isLocal(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "0.0.0.0" || h == "::1" || h == "[::1]" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    static func opensInApp(_ url: URL, mode: Mode, flipped: Bool) -> Bool {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        let inApp: Bool
        switch mode {
        case .local: inApp = isLocal(url)
        case .all: inApp = true
        case .never: inApp = false
        }
        return inApp != flipped
    }

    /// Same page for "bring it forward": scheme, host, port, path (without a trailing /) and query; not the #fragment.
    static func samePage(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        func key(_ u: URL) -> String {
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            if var p = c?.path, p.hasSuffix("/") { p.removeLast(); c?.path = p }
            return c?.string?.lowercased() ?? u.absoluteString.lowercased()
        }
        return key(a) == key(b)
    }

    /// Opens in the Octomux browser when the setting says so (true), else leaves it to the caller (false).
    @MainActor static func open(_ url: URL, session: String?, flipped: Bool = NSEvent.modifierFlags.contains(.shift)) -> Bool {
        guard opensInApp(url, mode: mode, flipped: flipped) else { return false }
        let m = AppModel.shared
        let tab = session.flatMap { sid in m.state.tabs.first { $0.layout.sessions.contains(sid) }?.id } ?? m.activeTabId
        guard let tab else { return false }
        let store = BrowserStore.shared
        if let existing = store.pages.first(where: { samePage($0.web.url ?? URL(string: $0.url), url) }) {
            store.show(existing, in: tab)
        } else {
            let p = store.newPage(owner: nil, showIn: tab)
            Task { await p.load(url) }
        }
        return true
    }
}
