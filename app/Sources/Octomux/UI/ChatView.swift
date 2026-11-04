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
    /// Client of the session's host when it is remote (transcripts live there).
    var remoteClient: DaemonClient?
    var remoteHint: String?
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

    /// Reads whatever was appended since the last poll (local file, or `fs.read` on a remote host).
    func poll() {
        guard let path else { return }
        var data = Data()
        let (h, c) = AppModel.shared.host(forPath: path.hasPrefix("/") ? (remoteHint ?? path) : path)
        if h.isRemote || remoteClient != nil {
            let off = offset
            guard let r = try? (remoteClient ?? c).callSync("fs.read", ["path": path, "offset": off, "max": 2_000_000]) as? [String: Any] else { return }
            let size = (r["size"] as? NSNumber)?.uint64Value ?? 0
            if size < off { offset = 0; items = []; toolIndex = [:]; return }
            data = (r["text"] as? String ?? "").data(using: .utf8) ?? Data()
            offset = (r["next_offset"] as? NSNumber)?.uint64Value ?? off
        } else {
            guard let h = FileHandle(forReadingAtPath: path) else { return }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size < offset { offset = 0; items = []; toolIndex = [:] }   // rewritten
            guard size > offset else { return }
            try? h.seek(toOffset: offset)
            data = h.readDataToEndOfFile()
            offset += UInt64(data.count)
        }
        guard !data.isEmpty else { return }
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

    /// Parses complete JSONL lines (used by `poll`; exposed for tests).
    func feed(_ data: Data) {
        partial.append(data)
        var next = items
        while let nl = partial.firstIndex(of: 0x0A) {
            ingest(partial.subdata(in: partial.startIndex..<nl), into: &next)
            partial.removeSubrange(partial.startIndex...nl)
        }
        if next != items { items = next }
    }

    private func newId() -> String { seq += 1; return "c\(seq)" }

    private func ingest(_ line: Data, into out: inout [ChatItem]) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
        if type == "response_item", let p = o["payload"] as? [String: Any] { ingestCodex(p, into: &out); return }
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

    /// Codex rollout `response_item`s: messages, function calls and their outputs, reasoning summaries.
    private func ingestCodex(_ p: [String: Any], into out: inout [ChatItem]) {
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String ?? ""
            var parts = (p["content"] as? [[String: Any]]) ?? []
            // Codex injects context (AGENTS.md, environment) as user messages. Newer ones say where each part
            // came from: keep only what you typed. Older ones: their context blocks start with a tag.
            let meta = (p["internal_chat_message_metadata_passthrough"] as? [String: Any])?["content_item_metadata"] as? [[String: Any]]
            if role == "user", let meta, meta.count == parts.count {
                parts = zip(parts, meta).filter { (($0.1["provenance"] as? [String: Any])?["type"] as? String) == "user" }.map(\.0)
            }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if role == "user" {
                if text.hasPrefix("<") || text.hasPrefix("# AGENTS.md instructions") { return }
                out.append(ChatItem(id: newId(), kind: .user, text: text))
            } else if role == "assistant" {
                out.append(ChatItem(id: newId(), kind: .assistant, text: text))
            }
        case "function_call":
            let name = p["name"] as? String ?? "tool"
            var input: [String: Any] = [:]
            if let a = p["arguments"] as? String, let d = a.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { input = o }
            if let cmd = input["command"] as? [String] { input["command"] = cmd.joined(separator: " ") }
            if let cmd = input["cmd"] as? String { input["command"] = cmd }
            let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, input))
            toolIndex[p["call_id"] as? String ?? item.id] = out.count
            out.append(item)
        case "function_call_output":
            let id = p["call_id"] as? String ?? ""
            var text = ""
            if let s = p["output"] as? String {
                if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let inner = o["output"] as? String { text = inner } else { text = s }
            }
            if let i = toolIndex[id], i < out.count { out[i].result = text }
        case "custom_tool_call":
            // Codex's code mode: the call is a script (`await tools.exec_command({ cmd: "…" })`).
            let script = p["input"] as? String ?? ""
            let (name, input) = Self.codeModeCall(script, fallback: p["name"] as? String ?? "tool")
            let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, input))
            toolIndex[p["call_id"] as? String ?? item.id] = out.count
            out.append(item)
        case "custom_tool_call_output":
            let id = p["call_id"] as? String ?? ""
            if let i = toolIndex[id], i < out.count { out[i].result = p["output"] as? String ?? Self.flatten(p["output"]) }
        case "reasoning":
            let t = ((p["summary"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !t.isEmpty { out.append(ChatItem(id: newId(), kind: .thinking, text: t)) }
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

    /// The tool a Codex code-mode script calls first and its string arguments (`cmd`, `path`, …), read from
    /// the script text; the first line of the script when it calls none.
    static func codeModeCall(_ script: String, fallback: String) -> (String, [String: Any]) {
        let ns = script as NSString
        var name = fallback
        if let m = try? NSRegularExpression(pattern: #"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#).firstMatch(in: script, range: NSRange(location: 0, length: ns.length)) {
            name = ns.substring(with: m.range(at: 1))
        }
        var input: [String: Any] = [:]
        let arg = try? NSRegularExpression(pattern: #"\b(cmd|command|file_path|path|pattern|query|url)\s*:\s*"((?:[^"\\]|\\.)*)""#)
        for m in arg?.matches(in: script, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let key = ns.substring(with: m.range(at: 1)) == "cmd" ? "command" : ns.substring(with: m.range(at: 1))
            guard input[key] == nil else { continue }
            let raw = "\"" + ns.substring(with: m.range(at: 2)) + "\""
            input[key] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String) ?? ns.substring(with: m.range(at: 2))
        }
        if input.isEmpty, let line = script.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            input["command"] = String(line).trimmingCharacters(in: .whitespaces)
        }
        return (name, input)
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
            if chat.path == nil || chat.items.isEmpty {
                starting(s)
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
                    Text("\(model.profile(s?.profileId)?.name ?? "The agent") is waiting for your answer (permission or question).").font(T.body).foregroundStyle(T.text)
                    Spacer()
                    Button("Answer in Terminal") { model.toggleChat(sessionId) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(T.amber.opacity(0.12))
            }
            composer(s)
        }
        .background(CanvasBackground())
        .onAppear {
            if let s, model.host(for: s.id).isRemote { chat.remoteClient = model.client(for: s.id) }
            chat.attach(resolvePath(s))
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if chat.path == nil { chat.attach(resolvePath(model.session(sessionId))) }   // transcript appears after the first turn
        }
        .onDisappear { chat.stop() }
        .onChange(of: s?.transcriptPath) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
        .onChange(of: s?.agentSessionId) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
    }

    /// Before the transcript has anything: the first message (started from the chat screen) and a spinner,
    /// or a hint when the session was opened without one.
    @ViewBuilder private func starting(_ s: Session?) -> some View {
        let agent = model.profile(s?.profileId)?.name ?? "The agent"
        let first = s.flatMap { ChatFirstMessage.get($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            if let first {
                HStack {
                    Spacer(minLength: 80)
                    Text(first).font(T.body).foregroundStyle(T.text)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.selection))
                }
            }
            if first == nil, s?.state == .running {
                Text("\(agent) is ready. Write below; it goes to the same session as the terminal.").font(T.body).foregroundStyle(T.text2)
            } else if s?.state == .running || s?.state == .interrupted {
                HStack(spacing: 8) { WorkingRing(); Text("Starting \(agent)…").font(T.body).foregroundStyle(T.text2) }
            } else {
                Text("\(agent) is not running.").font(T.body).foregroundStyle(T.text2)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolvePath(_ s: Session?) -> String? {
        guard let s else { return nil }
        let prof = model.profile(s.profileId)
        let remote = model.host(for: s.id).isRemote
        // The daemon knows the running agent's transcript (Claude hooks; the rollout a Codex keeps open).
        if let p = s.transcriptPath, remote || FileManager.default.fileExists(atPath: p) { return p }
        if prof?.kind == .codex || prof?.icon == "codex" {
            var params: [String: Any] = ["id": s.agentSessionId ?? "", "cwd": s.cwd, "since": s.createdAt]
            if let ch = prof?.env["CODEX_HOME"] { params["codex_home"] = ch }
            return (try? model.client(for: s.id).callSync("fs.find_rollout", params) as? [String: Any])?["path"] as? String
        }
        return remote ? nil : TranscriptLocator.path(for: s, model: model)
    }

    private func header(_ s: Session?) -> some View {
        HStack(spacing: 8) {
            AgentIcon(icon: model.profile(s?.profileId)?.icon ?? "claude", size: 12)
            Text(s?.displayTitle ?? "Chat").font(T.headline).foregroundStyle(T.text).lineLimit(1)
            Text("chat view").font(T.caption).foregroundStyle(T.text3)
            Spacer()
            Button { model.toggleChat(sessionId) } label: {
                HStack(spacing: 5) { Image(systemName: "terminal").font(.system(size: T.k * 10.5)); Text("Terminal") }
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
            Text(markdown(item.text)).font(.system(size: T.k * 13.5)).foregroundStyle(T.text).textSelection(.enabled)
                .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text(item.text).font(.system(size: T.k * 12).italic()).foregroundStyle(T.text3).lineLimit(expanded.contains(item.id) ? nil : 2)
                .onTapGesture { toggle(item.id) }
        case .note:
            Text(item.text).font(T.mono(11)).foregroundStyle(T.text3)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(item.result == nil ? T.accent : item.failed ? T.red : T.green).frame(width: 7, height: 7)
                    Text(item.tool).font(.system(size: T.k * 12.5, weight: .semibold)).foregroundStyle(T.text)
                    Text(relative(item.detail)).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.result != nil {
                        Image(systemName: expanded.contains(item.id) ? "chevron.up" : "chevron.down").font(.system(size: T.k * 9, weight: .semibold)).foregroundStyle(T.text3)
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
        let p = model.profile(s?.profileId)
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Message \(p?.name ?? "the agent") — goes to the same session", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: T.k * 14)).lineLimit(2...10)
                .frame(minHeight: 40, alignment: .topLeading)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 6) {
                if let p { AgentIcon(icon: p.icon, size: 11) }
                Text(p?.name ?? "Agent").font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text2)
                if let b = s.flatMap({ GitInfo.shared.branch(for: $0.worktree ?? model.project($0.projectId)?.path ?? $0.cwd) }) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10)).foregroundStyle(T.text3).padding(.leading, 6)
                    Text(b).font(T.mono(11.5)).foregroundStyle(T.text3)
                }
                Spacer()
                Button {
                    let kind = model.profile(s?.profileId)?.kind ?? .claude
                    let refs = AttachmentChips.pick().map { kind == .claude ? "@" + $0.path : $0.path }
                    if !refs.isEmpty { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + refs.joined(separator: " ") + " " }
                } label: { Image(systemName: "paperclip").font(.system(size: T.k * 12.5)).foregroundStyle(T.text2) }
                .buttonStyle(IconButtonStyle(size: 26)).help("Attach files (added to the message as paths)")
                SendButton(enabled: !draft.isEmpty && s?.state == .running, action: send)
            }
        }
        .composerCard(focused: composerFocused)
        .frame(maxWidth: 780)
        .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
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

/// The message a chat session was started with (shown until the transcript has it). App-side only.
enum ChatFirstMessage {
    static func get(_ id: String) -> String? { (UserDefaults.standard.dictionary(forKey: "octomux.chatFirst") as? [String: String])?[id] }
    static func set(_ id: String, _ text: String) {
        var d = UserDefaults.standard.dictionary(forKey: "octomux.chatFirst") as? [String: String] ?? [:]
        d[id] = text
        if d.count > 50 { d = Dictionary(uniqueKeysWithValues: d.suffix(50).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: "octomux.chatFirst")
    }
}

extension AppModel {
    /// Agents a chat session can use (the chat view reads Claude and Codex transcripts).
    var chatProfiles: [Profile] {
        state.profiles.filter { $0.enabled && ($0.kind == .claude || $0.kind == .codex || $0.icon == "claude" || $0.icon == "codex") }
            .sorted { $0.sort < $1.sort }
    }

    /// The workspace's default agent for new chats (Settings → Workspaces), if set and still there.
    func defaultChatProfile(workspace id: String?) -> Profile? {
        guard let id, case .string(let pid)? = settingValue("chat.default_profile", scope: "workspace:\(id)") else { return nil }
        return profile(pid)
    }

    func setDefaultChatProfile(_ profileId: String?, workspace id: String) {
        setSetting("chat.default_profile", profileId, scope: "workspace:\(id)")
    }

    func isChat(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "octomux.chat") ?? []).contains(id) }

    func canChat(_ s: Session?) -> Bool {
        guard let s, s.kind == .agent, (setting("features.chat")?.bool ?? true) else { return false }
        let p = profile(s.profileId)
        return p?.kind == .claude || p?.kind == .codex || p?.icon == "claude" || p?.icon == "codex"
    }

    func toggleChat(_ id: String? = nil) {
        guard let id = id ?? focusedSessionId, canChat(session(id)) else { return }
        var set = UserDefaults.standard.stringArray(forKey: "octomux.chat") ?? []
        if let i = set.firstIndex(of: id) { set.remove(at: i) } else { set.append(id) }
        UserDefaults.standard.set(set, forKey: "octomux.chat")
        objectWillChange.send()
        TerminalHost.shared.render(force: true)
        if !set.contains(id) { DispatchQueue.main.async { TerminalHost.shared.focusCurrent() } }
    }

    /// Types `text` into the session like a paste followed by Enter.
    func sendToSession(_ id: String, text: String) {
        let c = client(for: id)
        c.call("session.input", ["id": id, "data": "\u{1b}[200~" + text + "\u{1b}[201~"]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                c.call("session.input", ["id": id, "data": "\r"], completion: self?.report)
            }
        }
    }
}
