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
    /// The tool call's input as JSON (edit snippets, todo lists, questions…), long strings cut.
    var input = ""
    /// When the transcript wrote it (ISO 8601), for turn durations and times.
    var ts = ""
}

/// How full the agent's context is, from its transcript (tokens of the last main-thread reply; Codex also
/// reports its window). Claude's own reading (status line) is preferred when the app has it.
struct ChatContext: Equatable {
    var used = 0
    var window: Int?
    var model = ""
}

final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var context = ChatContext()
    @Published var path: String?
    /// Client of the session's host when it is remote (transcripts live there).
    var remoteClient: DaemonClient?
    var remoteHint: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var toolIndex: [String: Int] = [:]
    private var timer: Timer?
    private var seq = 0
    /// Timestamp of the line being ingested.
    private var lineTs = ""
    /// Context readings while lines are ingested; published once per poll.
    private var pendingContext = ChatContext()

    static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? (v as? Int) ?? 0 }

    func attach(_ p: String?) {
        guard p != path else { return }
        path = p
        items = []
        offset = 0
        partial = Data()
        toolIndex = [:]
        pendingContext = ChatContext()
        context = ChatContext()
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
        if pendingContext != context { context = pendingContext }
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
        if pendingContext != context { context = pendingContext }
    }

    private func newId() -> String { seq += 1; return "c\(seq)" }

    /// Gives the items `ingest` just added the line's timestamp.
    private func stamp(_ out: inout [ChatItem], from start: Int) {
        guard !lineTs.isEmpty, start < out.count else { return }
        for i in start..<out.count where out[i].ts.isEmpty { out[i].ts = lineTs }
    }

    private func ingest(_ line: Data, into out: inout [ChatItem]) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
        lineTs = o["timestamp"] as? String ?? ""
        let start = out.count
        defer { stamp(&out, from: start) }
        if type == "response_item", let p = o["payload"] as? [String: Any] { ingestCodex(p, into: &out); return }
        if type == "event_msg", let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count",
           let info = p["info"] as? [String: Any] {
            let last = info["last_token_usage"] as? [String: Any] ?? [:]
            let used = Self.int(last["input_tokens"]) + Self.int(last["output_tokens"])
            if used > 0 { pendingContext.used = used }
            if let w = info["model_context_window"] { pendingContext.window = Self.int(w) }
            return
        }
        if type == "turn_context", let p = o["payload"] as? [String: Any], let m = p["model"] as? String { pendingContext.model = m; return }
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
            if let m = msg["model"] as? String, !m.hasPrefix("<") { pendingContext.model = m }
            if let u = msg["usage"] as? [String: Any] {
                let used = Self.int(u["input_tokens"]) + Self.int(u["cache_creation_input_tokens"]) + Self.int(u["cache_read_input_tokens"])
                if used > 0 { pendingContext.used = used }
            }
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
                    let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, p["input"] as? [String: Any] ?? [:]),
                                        input: Self.inputJSON(p["input"]))
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
            let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, input), input: Self.inputJSON(input))
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
            var (name, input) = Self.codeModeCall(script, fallback: p["name"] as? String ?? "tool")
            if (p["name"] as? String) == "apply_patch" || script.hasPrefix("*** Begin Patch") { name = "apply_patch"; input = ["patch": script] }
            let item = ChatItem(id: newId(), kind: .tool, text: name, tool: name, detail: Self.summary(name, input), input: Self.inputJSON(input))
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

    /// A tool input as JSON for the chat page; strings longer than 40k characters are cut.
    static func inputJSON(_ v: Any?) -> String {
        func cut(_ x: Any) -> Any {
            if let s = x as? String { return s.count > 40_000 ? String(s.prefix(40_000)) + "\n…" : s }
            if let d = x as? [String: Any] { return d.mapValues(cut) }
            if let a = x as? [Any] { return a.map(cut) }
            return x
        }
        guard let v, JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: cut(v), options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
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
    @State private var composerFocused = false
    /// Claude's own context reading (its status line writes `run/<session>.context`).
    @State private var statusContext: ContextReading?
    @StateObject private var completion = ComposerCompletion()
    @State private var queued: [String] = []

    var body: some View {
        let s = model.session(sessionId)
        // The pane's header names the session and switches back to the terminal.
        VStack(spacing: 0) {
            if chat.path == nil || chat.items.isEmpty {
                starting(s)
            } else {
                ChatTranscriptView(sessionId: sessionId, items: chat.items, working: s?.activity == .working,
                                   needsInput: s?.activity == .needsInput,
                                   cwd: s?.cwd ?? "", agent: model.profile(s?.profileId)?.name ?? "Agent")
            }
            if s?.activity == .needsInput {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(T.amber)
                    Text("\(model.profile(s?.profileId)?.name ?? "The agent") is waiting for you: answer above, or in the terminal.").font(T.body).foregroundStyle(T.text)
                    Spacer()
                    Button("Answer in Terminal") { model.toggleChat(sessionId) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(T.amber.opacity(0.12))
            }
            queuedList
            composer(s)
        }
        .background(CanvasBackground())
        .onAppear {
            if let s, model.host(for: s.id).isRemote { chat.remoteClient = model.client(for: s.id) }
            chat.attach(resolvePath(s))
            readStatusContext()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if chat.path == nil { chat.attach(resolvePath(model.session(sessionId))) }   // transcript appears after the first turn
            readStatusContext()
        }
        .onDisappear { chat.stop() }
        .onChange(of: chat.items.count) { _, _ in
            guard !queued.isEmpty else { return }
            let users = chat.items.suffix(40).filter { $0.kind == .user }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            queued.removeAll { q in users.contains { $0 == q || $0.hasPrefix(q) || q.hasPrefix($0) } }
        }
        .onChange(of: model.session(sessionId)?.activity) { _, a in if a == .idle || a == .done { DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if model.session(sessionId)?.activity != .working { queued.removeAll() } } } }
        .onChange(of: s?.transcriptPath) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
        .onChange(of: s?.agentSessionId) { _, _ in chat.attach(resolvePath(model.session(sessionId))) }
        // Something to send from elsewhere (an element picked in the browser): added to the draft, not sent.
        .onReceive(NotificationCenter.default.publisher(for: .octomuxComposerAppend)) { n in
            guard (n.object as? String) == sessionId else { return }
            takeSent()
        }
        .onAppear { takeSent() }
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
        .frame(maxWidth: NewChatView.column + 44, alignment: .leading)
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

    private func composer(_ s: Session?) -> some View {
        let p = model.profile(s?.profileId)
        return VStack(alignment: .leading, spacing: 12) {
            ComposerField(text: $draft, placeholder: "Message \(p?.name ?? "the agent") — goes to the same session (⇧↩ new line)",
                          minLines: 2, maxLines: 14, focused: $composerFocused, onSubmit: send,
                          onPasteFiles: {
                              let kind = model.profile(s?.profileId)?.kind ?? .claude
                              let refs = AttachmentChips.pasted().map { kind == .claude ? "@" + $0.path : $0.path }
                              if !refs.isEmpty { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + refs.joined(separator: " ") + " " }
                              return !refs.isEmpty
                          }, completion: completion)
            HStack(spacing: 6) {
                if let p { AgentIcon(icon: p.icon, size: 11) }
                Text(p?.name ?? "Agent").font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text2)
                modelChip(s, kind: p?.kind)
                if let b = s.flatMap({ GitInfo.shared.branch(for: $0.worktree ?? model.project($0.projectId)?.path ?? $0.cwd) }) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: T.k * 10)).foregroundStyle(T.text3).padding(.leading, 6)
                    Text(b).font(T.mono(12)).foregroundStyle(T.text3)
                }
                Spacer()
                Button {
                    let kind = model.profile(s?.profileId)?.kind ?? .claude
                    let refs = AttachmentChips.pick().map { kind == .claude ? "@" + $0.path : $0.path }
                    if !refs.isEmpty { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + refs.joined(separator: " ") + " " }
                } label: { Image(systemName: "paperclip").font(.system(size: T.k * 13)).foregroundStyle(T.text2) }
                .buttonStyle(IconButtonStyle(size: 26)).help("Attach files (added to the message as paths)")
                ContextRing(reading: contextReading)
                if s?.activity == .working && draft.isEmpty {
                    StopButton { model.interruptSession(sessionId) }
                } else {
                    SendButton(enabled: !draft.isEmpty && s?.state == .running,
                               help: s?.activity == .working ? "Send (↩); the agent reads it when it finishes this step" : "Send (↩)", action: send)
                }
            }
        }
        .composerCard(focused: composerFocused)
        .overlay(alignment: .top) { CompletionMenu(completion: completion).alignmentGuide(.top) { $0[.bottom] + 8 } }
        .onAppear {
            completion.configure(kind: { [model, sessionId] in model.profile(model.session(sessionId)?.profileId)?.kind },
                                 configDir: { [model, sessionId] in ChatAgentDirs.config(model.profile(model.session(sessionId)?.profileId)) },
                                 folder: { [model, sessionId] in model.session(sessionId).map { $0.worktree ?? model.project($0.projectId)?.path ?? $0.cwd } })
        }
        // The same column as the start screen and the messages (the composer doesn't move or resize when a
        // new chat starts).
        .frame(maxWidth: NewChatView.column)
        .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    /// The model the session runs, from its transcript; for Claude a menu that switches it with `/model`.
    @ViewBuilder private func modelChip(_ s: Session?, kind: AgentKind?) -> some View {
        let name = ChatModels.pretty(statusContext?.model ?? chat.context.model)
        if !name.isEmpty || kind == .claude {
            Rectangle().fill(T.border).frame(width: 1, height: 12).padding(.horizontal, 3)
            if kind == .claude {
                Menu {
                    ForEach(ChatModels.claude, id: \.alias) { m in
                        Button(m.title) { model.sendToSession(sessionId, text: "/model " + m.alias) }
                    }
                } label: {
                    Text(name.isEmpty ? "Model" : name).font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .disabled(s?.activity == .working || s?.state != .running)
                .help("Switch the model for the rest of this session (sends /model)")
            } else {
                Text(name).font(.system(size: T.k * 12)).foregroundStyle(T.text2)
            }
        }
    }

    private var contextReading: ContextReading? {
        if let r = statusContext { return r }
        let c = chat.context
        guard c.used > 0 else { return nil }
        return ContextReading(percent: c.window.map { Double(c.used) / Double(max($0, 1)) * 100 }, used: c.used, size: c.window, model: c.model)
    }

    private func readStatusContext() {
        guard let s = model.session(sessionId), !model.host(for: s.id).isRemote,
              let data = try? Data(contentsOf: Paths.home.appendingPathComponent("run/\(s.id).context")),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let r = ContextReading(statusLine: o)
        if r != statusContext { statusContext = r }
    }

    /// Text sent here from elsewhere (an element picked in the browser): added to the draft, not sent.
    private func takeSent() {
        for t in BrowserSend.takePending(sessionId) {
            draft += (draft.isEmpty ? "" : draft.hasSuffix("\n") ? "\n" : "\n\n") + t
            composerFocused = true
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // Typed while the agent works: it reads it after this step; shown here until the transcript has it.
        if model.session(sessionId)?.activity == .working, !text.hasPrefix("/") { queued.append(text) }
        model.sendToSession(sessionId, text: text)
    }

    /// Messages sent while the agent was working that its transcript does not have yet.
    @ViewBuilder private var queuedList: some View {
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(queued.enumerated()), id: \.offset) { _, q in
                    HStack(spacing: 7) {
                        Image(systemName: "clock").font(.system(size: T.k * 10)).foregroundStyle(T.text3)
                        Text(q).font(.system(size: T.k * 12)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text("queued").font(.system(size: T.k * 11)).foregroundStyle(T.text3)
                    }
                    .help("Sent while the agent works; it reads it when this step ends")
                }
            }
            .frame(maxWidth: NewChatView.column - 20)
            .padding(.horizontal, 38).padding(.top, 4)
            .frame(maxWidth: .infinity)
        }
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

    /// Types `text` into the session like a paste followed by Enter (or just the paste, to read it over first).
    func sendToSession(_ id: String, text: String, submit: Bool = true) {
        let c = client(for: id)
        c.call("session.input", ["id": id, "data": "\u{1b}[200~" + text + "\u{1b}[201~"]) { [weak self] _ in
            guard submit else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                c.call("session.input", ["id": id, "data": "\r"], completion: self?.report)
            }
        }
    }
}
