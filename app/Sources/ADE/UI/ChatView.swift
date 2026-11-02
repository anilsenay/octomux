import AppKit
import SwiftUI

// Chat view of a running Claude session (DECISIONS D13): renders the session's own transcript
// and types into the same PTY. It never runs Claude itself and never touches credentials.

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tool, thinking, note }
    let id: String
    var kind: Kind
    var text: String
    var tool: String = ""
    var detail: String = ""
    var result: String?
    var failed = false
}

final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var path: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var toolIndex: [String: Int] = [:]
    private var timer: Timer?
    private var seq = 0

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        items = []
        offset = 0
        partial = Data()
        toolIndex = [:]
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Reads whatever was appended since the last poll.
    func poll() {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; items = []; toolIndex = [:] }   // rewritten
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset += UInt64(data.count)
        partial.append(data)
        var lines: [Data] = []
        while let nl = partial.firstIndex(of: 0x0A) {
            lines.append(partial.subdata(in: partial.startIndex..<nl))
            partial.removeSubrange(partial.startIndex...nl)
        }
        var next = items
        for l in lines { ingest(l, into: &next) }
        if next != items { items = next }
    }

    private func newId() -> String { seq += 1; return "c\(seq)" }

    private func ingest(_ line: Data, into out: inout [ChatItem]) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
        if (o["isMeta"] as? Bool) == true || (o["isSidechain"] as? Bool) == true { return }
        guard let msg = o["message"] as? [String: Any] else { return }
        switch type {
        case "user":
            if let s = msg["content"] as? String {
                appendUser(s, &out)
            } else if let parts = msg["content"] as? [[String: Any]] {
                for p in parts {
                    switch p["type"] as? String {
                    case "text": appendUser(p["text"] as? String ?? "", &out)
                    case "tool_result":
                        let id = p["tool_use_id"] as? String ?? ""
                        let text = Self.flatten(p["content"])
                        if let i = toolIndex[id], i < out.count {
                            out[i].result = text
                            out[i].failed = (p["is_error"] as? Bool) ?? false
                        }
                    default: break
                    }
                }
            }
        case "assistant":
            for p in (msg["content"] as? [[String: Any]]) ?? [] {
                switch p["type"] as? String {
                case "text":
                    let t = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(ChatItem(id: newId(), kind: .assistant, text: t)) }
                case "thinking":
                    let t = (p["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(ChatItem(id: newId(), kind: .thinking, text: t)) }
                case "tool_use":
                    let name = p["name"] as? String ?? "Tool"
                    let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, p["input"] as? [String: Any] ?? [:]))
                    toolIndex[p["id"] as? String ?? item.id] = out.count
                    out.append(item)
                default: break
                }
            }
        default: break
        }
    }

    private func appendUser(_ raw: String, _ out: inout [ChatItem]) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Slash commands and local command output show up as tagged text; keep them small.
        if t.hasPrefix("<command-name>") || t.hasPrefix("<local-command") || t.hasPrefix("<command-message>") {
            let name = t.components(separatedBy: "<command-name>").dropFirst().first?.components(separatedBy: "</command-name>").first ?? "command"
            out.append(ChatItem(id: newId(), kind: .note, text: name))
            return
        }
        if t.hasPrefix("[Request interrupted") { out.append(ChatItem(id: newId(), kind: .note, text: "Interrupted")); return }
        out.append(ChatItem(id: newId(), kind: .user, text: t))
    }

    static func flatten(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let a = v as? [[String: Any]] { return a.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    /// One line describing a tool call: the file, command, pattern or URL it works on.
    static func summary(_ name: String, _ input: [String: Any]) -> String {
        for k in ["file_path", "command", "pattern", "url", "path", "query", "description", "prompt"] {
            if let v = input[k] as? String, !v.isEmpty {
                let one = v.split(separator: "\n").first.map(String.init) ?? v
                return one.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
        }
        return ""
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    @StateObject private var chat = ChatModel()
    @State private var draft = ""
    @State private var expanded: Set<String> = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        let s = model.session(sessionId)
        VStack(spacing: 0) {
            header(s)
            Hairline()
            if chat.path == nil {
                PanelEmpty(icon: "text.bubble", text: "No transcript yet — it appears after the first message.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(chat.items) { item in row(item).id(item.id) }
                            if s?.activity == .working {
                                HStack(spacing: 8) { WorkingRing(); Text("Working…").font(T.body).foregroundStyle(T.text2) }
                                    .padding(.leading, 4).id("working")
                            }
                        }
                        .padding(.horizontal, 22).padding(.vertical, 16)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: chat.items.count) { _, _ in
                        if let last = chat.items.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear { if let last = chat.items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if s?.activity == .needsInput {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(T.amber)
                    Text("Claude is waiting for your answer (permission or question).").font(T.body).foregroundStyle(T.text)
                    Spacer()
                    Button("Answer in Terminal") { model.toggleChat(sessionId) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(T.amber.opacity(0.12))
            }
            composer(s)
        }
        .background(T.surface)
        .onAppear { chat.attach(resolvePath(s)) }
        .onDisappear { chat.stop() }
        .onChange(of: s?.transcriptPath) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
        .onChange(of: s?.agentSessionId) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
    }

    private func resolvePath(_ s: Session?) -> String? {
        guard let s else { return nil }
        if let p = s.transcriptPath, FileManager.default.fileExists(atPath: p) { return p }
        return TranscriptLocator.path(for: s, model: model)
    }

    private func header(_ s: Session?) -> some View {
        HStack(spacing: 8) {
            AgentIcon(icon: "claude", size: 12)
            Text(s?.displayTitle ?? "Chat").font(T.headline).foregroundStyle(T.text).lineLimit(1)
            Text("chat view").font(T.caption).foregroundStyle(T.text3)
            Spacer()
            Button { model.toggleChat(sessionId) } label: {
                HStack(spacing: 5) { Image(systemName: "terminal").font(.system(size: 10.5)); Text("Terminal") }
            }
            .buttonStyle(ChromeButtonStyle()).help("Back to the terminal (⌘⇧C)")
        }
        .padding(.horizontal, 14).frame(height: 38)
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text).font(T.body).foregroundStyle(T.text).textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.selection))
            }
        case .assistant:
            Text(markdown(item.text)).font(.system(size: 13.5)).foregroundStyle(T.text).textSelection(.enabled)
                .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text(item.text).font(.system(size: 12).italic()).foregroundStyle(T.text3).lineLimit(expanded.contains(item.id) ? nil : 2)
                .onTapGesture { toggle(item.id) }
        case .note:
            Text(item.text).font(T.mono(11)).foregroundStyle(T.text3)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(item.result == nil ? T.accent : item.failed ? T.red : T.green).frame(width: 7, height: 7)
                    Text(item.tool).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.text)
                    Text(relative(item.detail)).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.result != nil {
                        Image(systemName: expanded.contains(item.id) ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
                    }
                }
                if let r = item.result, expanded.contains(item.id) {
                    Text(r.count > 4000 ? String(r.prefix(4000)) + "\n…" : r).font(T.mono(11)).foregroundStyle(T.text2).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.frame.opacity(0.6)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border))
            .contentShape(Rectangle())
            .onTapGesture { toggle(item.id) }
        }
    }

    private func composer(_ s: Session?) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude — goes to the same session", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(T.body).lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.frame.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(composerFocused ? T.accent.opacity(0.6) : T.border))
            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30) }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(Circle().fill(draft.isEmpty ? T.text3 : T.accent))
                .disabled(draft.isEmpty || s?.state != .running)
                .help("Send (↩)")
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.sendToSession(sessionId, text: text)
    }

    /// Paths inside the session's folder are shown relative to it.
    private func relative(_ s: String) -> String {
        guard let cwd = model.session(sessionId)?.cwd else { return s }
        var out = s
        for base in [cwd, "/private" + cwd, cwd.replacingOccurrences(of: "/private/", with: "/")] {
            out = out.replacingOccurrences(of: base + "/", with: "")
        }
        return out
    }

    private func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

extension AppModel {
    func isChat(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "ade.chat") ?? []).contains(id) }

    func canChat(_ s: Session?) -> Bool {
        guard let s, s.kind == .agent, (setting("features.chat")?.bool ?? true) else { return false }
        return profile(s.profileId)?.kind == .claude || profile(s.profileId)?.icon == "claude"
    }

    func toggleChat(_ id: String? = nil) {
        guard let id = id ?? focusedSessionId, canChat(session(id)) else { return }
        var set = UserDefaults.standard.stringArray(forKey: "ade.chat") ?? []
        if let i = set.firstIndex(of: id) { set.remove(at: i) } else { set.append(id) }
        UserDefaults.standard.set(set, forKey: "ade.chat")
        objectWillChange.send()
        TerminalHost.shared.render(force: true)
        if !set.contains(id) { DispatchQueue.main.async { TerminalHost.shared.focusCurrent() } }
    }

    /// Types `text` into the session like a paste followed by Enter.
    func sendToSession(_ id: String, text: String) {
        client.call("session.input", ["id": id, "data": "\u{1b}[200~" + text + "\u{1b}[201~"]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.client.call("session.input", ["id": id, "data": "\r"], completion: self?.report)
            }
        }
    }
}
