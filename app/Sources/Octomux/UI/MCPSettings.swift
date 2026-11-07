import SwiftUI

/// Settings → MCP: the MCP servers each agent's config gives it, per config file (agents that share a config
/// share a group). Read only.
struct MCPSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var groups: [Group] = []
    /// `claude mcp list` results per config file: server name → status.
    @State private var status: [String: [String: String]] = [:]
    /// Servers the check found that the config files don't list (claude.ai connectors, plugins), per file.
    @State private var others: [String: [(name: String, target: String, status: String)]] = [:]
    @State private var checking: Set<String> = []
    @State private var message = ""
    /// The group whose Add Server form is open.
    @State private var adding: Group?

    struct Group: Identifiable {
        var id: String { file }
        let kind: AgentKind
        let agents: [String]
        let profile: Profile?
        let file: String
        let exists: Bool
        let servers: [MCPServer]
    }

    var body: some View {
        if model.host.isRemote {
            Text("This window shows \(model.host.name). The MCP servers listed are this Mac's agents'.")
                .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
        }
        BrowserToolsSettings()
        ForEach(groups) { g in
            SettingsGroup("\(g.kind == .codex ? "Codex" : "Claude Code") · \(g.agents.joined(separator: ", "))",
                          desc: (g.file as NSString).abbreviatingWithTildeInPath + (g.exists ? "" : " (not there yet)"),
                          trailing: {
                if g.kind == .claude, g.profile != nil {
                    Button(checking.contains(g.file) ? "Checking…" : "Check") { check(g) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(checking.contains(g.file))
                        .help("Starts each server the way Claude Code does (claude mcp list) and shows whether it connects")
                }
                if g.profile != nil {
                    Button("Add Server…") { adding = g }.buttonStyle(SecondaryButtonStyle())
                        .help("Adds a server with \(g.kind == .codex ? "codex" : "claude") mcp add")
                }
                if g.exists {
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.file)]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }) {
                if g.servers.isEmpty {
                    Text("No MCP servers.").font(.system(size: T.k * 13)).foregroundStyle(T.text2).padding(14)
                }
                ForEach(g.servers) { s in row(s, g) }
                if let extra = others[g.file], !extra.isEmpty {
                    Text("Also available to Claude Code (your claude.ai connectors and plugins; manage them there)")
                        .font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text2)
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                    ForEach(extra, id: \.name) { e in otherRow(e) }
                }
            }
        }
        if !message.isEmpty { Text(message).font(.system(size: T.k * 12)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true) }
        SettingsFootnote("Read from the agents' own config files when this page opens. Add Server, Remove and Check run the agents' own commands (`claude mcp add`, `codex mcp add`…). Turning a server off is done in the agent (Claude: /mcp). Values of environment variables and headers are not shown.")
        HStack {
            Spacer()
            Button("Reload") { load() }.buttonStyle(SecondaryButtonStyle())
        }
        Color.clear.frame(height: 0).onAppear(perform: load)
            .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
                if let k = n.userInfo?["mcpAdd"] as? String { adding = groups.first { $0.profile != nil && ($0.kind == .codex) == (k == "codex") } }
            }
            .sheet(item: $adding) { g in
                if let profile = g.profile {
                    MCPAddSheet(kind: g.kind, profile: profile, agents: g.agents) { added in
                        adding = nil
                        if added { load() }
                    }
                    .environmentObject(model)
                }
            }
    }

    private func row(_ s: MCPServer, _ g: Group) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.url != nil ? "globe" : "terminal").font(.system(size: T.k * 12)).foregroundStyle(T.text3).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name).font(.system(size: T.k * 13, weight: .medium))
                    pill(scopeLabel(s.scope), color: T.text2)
                    if s.enabled == false { pill("Off", color: T.text3) }
                    if s.enabled == nil, case .project = s.scope { pill("Not approved yet", color: T.amber) }
                    if let st = status[g.file]?[s.name] {
                        let short = st.components(separatedBy: " — ").first ?? st
                        pill(short, color: st.hasPrefix("✔") || st.hasPrefix("✓") ? T.green : st.hasPrefix("!") || st.hasPrefix("⚠") ? T.amber : T.red)
                            .help(st)
                    }
                }
                Text("\(s.transport) · \(s.target)").font(T.mono(11)).foregroundStyle(T.text2)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if !s.envNames.isEmpty {
                    Text("Uses " + s.envNames.joined(separator: ", ")).font(.system(size: T.k * 11)).foregroundStyle(T.text3).lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Button { copy(s.target) } label: { Image(systemName: "doc.on.doc").font(.system(size: T.k * 11)) }
                .buttonStyle(ChromeButtonStyle()).help(s.url != nil ? "Copy URL" : "Copy command")
            if let profile = g.profile {
                Button { remove(s, g, profile) } label: { Image(systemName: "trash").font(.system(size: T.k * 11)) }
                    .buttonStyle(ChromeButtonStyle()).help("Remove with \(g.kind == .codex ? "codex" : "claude") mcp remove")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(s.enabled == false ? 0.6 : 1)
    }

    private func otherRow(_ e: (name: String, target: String, status: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.name.hasPrefix("claude.ai") ? "person.crop.circle" : "puzzlepiece.extension")
                .font(.system(size: T.k * 12)).foregroundStyle(T.text3).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.name.hasPrefix("claude.ai ") ? String(e.name.dropFirst(10)) : e.name).font(.system(size: T.k * 13, weight: .medium))
                    pill(e.name.hasPrefix("claude.ai") ? "claude.ai" : "Not in a config file", color: T.text2)
                    let short = e.status.components(separatedBy: " — ").first ?? e.status
                    pill(short, color: e.status.hasPrefix("✔") || e.status.hasPrefix("✓") ? T.green : e.status.hasPrefix("!") || e.status.hasPrefix("⚠") ? T.amber : T.red)
                        .help(e.status)
                }
                Text(e.target).font(T.mono(11)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func pill(_ t: String, color: Color) -> some View {
        Text(t).font(.system(size: T.k * 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(T.hover))
    }

    private func scopeLabel(_ s: MCPServer.Scope) -> String {
        func name(_ path: String) -> String { model.state.projects.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent }
        switch s {
        case .user: return "All projects"
        case .local(let p): return "Only \(name(p))"
        case .project(let p): return "\(name(p)) · .mcp.json"
        }
    }

    private func check(_ g: Group) {
        guard let profile = g.profile else { return }
        checking.insert(g.file)
        let cwd = model.currentProject?.path
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out, err) = MCPConfig.runCLI(profile, ["mcp", "list"], cwd: cwd, timeout: 90)
            DispatchQueue.main.async {
                checking.remove(g.file)
                if code == 0 {
                    let entries = MCPConfig.parseClaudeListEntries(out)
                    status[g.file] = MCPConfig.parseClaudeList(out)
                    let known = Set(g.servers.map(\.name))
                    others[g.file] = entries.filter { !known.contains($0.name) }
                    message = ""
                }
                else { message = "claude mcp list failed: " + (err.isEmpty ? "exit \(code)" : String(err.suffix(300))) }
            }
        }
    }

    private func remove(_ s: MCPServer, _ g: Group, _ profile: Profile) {
        let (args, cwd) = MCPConfig.removeCommand(s, kind: g.kind)
        let a = NSAlert()
        a.messageText = "Remove “\(s.name)”?"
        a.informativeText = "Runs `\(profile.command) \(args.joined(separator: " "))`" + (cwd.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "")
            + ". The server is gone for \(g.agents.joined(separator: ", ")); add it again with mcp add."
        a.addButton(withTitle: "Remove").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, _, err) = MCPConfig.runCLI(profile, args, cwd: cwd)
            DispatchQueue.main.async {
                message = code == 0 ? "" : "Removing \(s.name) failed: " + (err.isEmpty ? "exit \(code)" : String(err.suffix(300)))
                load()
            }
        }
    }

    private func load() {
        let profiles = model.state.profiles.filter { $0.enabled && ($0.kind == .claude || $0.kind == .codex) }
        let projects = model.host.isRemote ? [] : model.state.projects.filter { !$0.archived }.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Self.groups(profiles: profiles, projects: projects)
            DispatchQueue.main.async { groups = out }
        }
    }

    /// One group per config file; agents without a profile here still show their default file.
    static func groups(profiles: [Profile], projects: [String]) -> [Group] {
        var byFile: [(kind: AgentKind, file: String, agents: [String], profile: Profile?)] = []
        func add(_ kind: AgentKind, _ file: String, _ agent: String, _ p: Profile?) {
            if let i = byFile.firstIndex(where: { $0.file == file }) { byFile[i].agents.append(agent) } else { byFile.append((kind, file, [agent], p)) }
        }
        for p in profiles {
            if p.kind == .claude { add(.claude, MCPConfig.claudeFile(configDir: p.env["CLAUDE_CONFIG_DIR"]), p.name, p) }
            else { add(.codex, MCPConfig.codexFile(home: p.env["CODEX_HOME"]), p.name, p) }
        }
        if !byFile.contains(where: { $0.kind == .claude }) { add(.claude, MCPConfig.claudeFile(configDir: nil), "claude", nil) }
        if !byFile.contains(where: { $0.kind == .codex }) { add(.codex, MCPConfig.codexFile(home: nil), "codex", nil) }
        return byFile.map { g in
            let exists = FileManager.default.fileExists(atPath: g.file)
            let servers: [MCPServer]
            if g.kind == .claude {
                servers = MCPConfig.claude(json: MCPConfig.readJSON(g.file) ?? [:], file: g.file, projects: projects) {
                    MCPConfig.readJSON(($0 as NSString).appendingPathComponent(".mcp.json"))
                }
            } else {
                servers = MCPConfig.codex(toml: (try? String(contentsOfFile: g.file, encoding: .utf8)) ?? "", file: g.file)
            }
            return Group(kind: g.kind, agents: g.agents, profile: g.profile, file: g.file, exists: exists, servers: servers)
        }
    }
}

/// Settings → MCP → Add Server…: a server for one agent's config, added with its own `mcp add`.
struct MCPAddSheet: View {
    @EnvironmentObject var model: AppModel
    let kind: AgentKind
    let profile: Profile
    let agents: [String]
    let done: (Bool) -> Void
    @State private var s = MCPConfig.NewServer()
    @State private var scopeKind = "user"
    @State private var project = ""
    @State private var running = false
    @State private var error = ""

    private var projects: [Project] { model.state.projects.filter { !$0.archived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an MCP server").font(.title2.weight(.semibold))
            Text("For \(kind == .codex ? "Codex" : "Claude Code") · \(agents.joined(separator: ", ")). It starts with the agent's next session.")
                .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
            Form {
                TextField("Name", text: $s.name, prompt: Text("github"))
                Picker("Type", selection: $s.transport) {
                    Text("Command (stdio)").tag(MCPConfig.NewServer.Transport.stdio)
                    Text("HTTP").tag(MCPConfig.NewServer.Transport.http)
                    if kind == .claude { Text("SSE").tag(MCPConfig.NewServer.Transport.sse) }
                }
                TextField(s.transport == .stdio ? "Command" : "URL", text: $s.target,
                          prompt: Text(s.transport == .stdio ? "npx -y @modelcontextprotocol/server-github" : "https://mcp.example.com/mcp"))
                    .font(.system(.body, design: .monospaced))
                if s.transport == .stdio {
                    LabeledContent("Environment") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextEditor(text: $s.env).font(.system(.body, design: .monospaced)).frame(height: 54)
                            Text("KEY=value, one per line").font(.caption).foregroundStyle(T.text3)
                        }
                    }
                } else if kind == .claude {
                    LabeledContent("Headers") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextEditor(text: $s.headers).font(.system(.body, design: .monospaced)).frame(height: 54)
                            Text("Name: value, one per line").font(.caption).foregroundStyle(T.text3)
                        }
                    }
                } else {
                    TextField("Bearer token from variable", text: $s.bearerEnv, prompt: Text("optional, e.g. GITHUB_TOKEN"))
                        .font(.system(.body, design: .monospaced))
                }
                if kind == .claude {
                    Picker("Available in", selection: $scopeKind) {
                        Text("All projects").tag("user")
                        Text("One project, only for you").tag("local")
                        Text("One project, shared in its .mcp.json").tag("project")
                    }
                    if scopeKind != "user" {
                        Picker("Project", selection: $project) {
                            ForEach(projects) { p in Text(p.name).tag(p.path) }
                        }
                    }
                }
            }
            if !error.isEmpty {
                Text(error).font(.system(size: T.k * 12)).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let p = current.problem(kind: kind), !s.name.isEmpty || !s.target.isEmpty {
                Text(p).font(.system(size: T.k * 12)).foregroundStyle(T.text2)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(running ? "Adding…" : "Add") { add() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(running || current.problem(kind: kind) != nil || (scopeKind != "user" && project.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { project = model.currentProject?.path ?? projects.first?.path ?? "" }
    }

    private var current: MCPConfig.NewServer {
        var c = s
        c.scope = kind == .codex || scopeKind == "user" ? .user : scopeKind == "local" ? .local(project) : .project(project)
        return c
    }

    private func add() {
        let (args, cwd) = MCPConfig.addCommand(current, kind: kind)
        running = true
        error = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out, err) = MCPConfig.runCLI(profile, args, cwd: cwd)
            DispatchQueue.main.async {
                running = false
                if code == 0 { done(true) } else {
                    let text = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
                    error = "\(kind == .codex ? "codex" : "claude") mcp add failed: " + (text.isEmpty ? "exit \(code)" : String(text.suffix(400)))
                }
            }
        }
    }
}

/// The browser tools Octomux gives Claude and Codex sessions (its own MCP server, added per launch), who may use
/// them and where, and which links open in the browser.
struct BrowserToolsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var cleared = false
    @State private var sites = ""
    @State private var decisions = BrowserAccess.decisions
    @AppStorage(BrowserLinks.key) private var links = BrowserLinks.Mode.local.rawValue

    var body: some View {
        SettingsGroup("Octomux browser", desc: "Claude and Codex sessions started in Octomux get browser tools (open a page, read it, click, type, take screenshots) that drive the browser beside their tab, where you watch them work. Added to each session as it starts; your own MCP settings stay as they are.") {
            SettingRow("Agents can use it", desc: accessDesc) {
                Picker("", selection: Binding(get: { BrowserAccess.mode.rawValue },
                                              set: { v in model.setSettingLocally("browser.access", .string(v), scope: "global"); model.setSetting("browser.access", v) })) {
                    ForEach(BrowserAccess.Mode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingRow("Allowed sites", desc: "Agents can open only these (one per line or comma separated): example.com, *.example.com (and its subdomains), localhost:3000, file:// for local files. Empty: any site. Links they follow elsewhere are blocked too.") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Any site", text: $sites, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(T.mono(12)).lineLimit(1...5).frame(width: 260)
                        .onSubmit(saveSites)
                    if sites != BrowserAccess.allowedSites.joined(separator: ", ") {
                        Button("Save", action: saveSites).buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    }
                }
            }
            if !decisions.isEmpty {
                SettingRow("Asked sessions", desc: "What you answered when a session first wanted the browser. Forget one and it asks again.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(decisions.keys.sorted(), id: \.self) { sid in
                            HStack(spacing: 8) {
                                Text(BrowserUI.agentLabel(sid)).font(.system(size: T.k * 12)).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
                                Text(decisions[sid] == true ? "Allowed" : "Not allowed").font(T.caption).foregroundStyle(decisions[sid] == true ? T.green : T.text3)
                                Button("Forget") { BrowserAccess.forget(sid) }.buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            }
                        }
                    }
                }
            }
            SettingRow("Links that open in it", desc: "Clicking a link in a terminal or the chat view opens it beside the tab instead of in your default browser. Hold ⇧ while clicking to do the other.") {
                Picker("", selection: $links) {
                    ForEach(BrowserLinks.Mode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow("Browsing data", desc: "Pages keep cookies and logins between launches, apart from your other browsers.") {
                Button(cleared ? "Cleared" : "Clear Browsing Data…") {
                    let a = NSAlert()
                    a.messageText = "Clear the Octomux browser's cookies, logins and cache?"
                    a.informativeText = "Sites you signed in to in the Octomux browser will ask you to sign in again."
                    a.addButton(withTitle: "Clear")
                    a.addButton(withTitle: "Cancel")
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                    Task { await BrowserStore.shared.clearData(); cleared = true }
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(cleared)
            }
        }
        .onAppear { sites = BrowserAccess.allowedSites.joined(separator: ", ") }
        .onReceive(NotificationCenter.default.publisher(for: .octomuxBrowserAccess)) { _ in decisions = BrowserAccess.decisions }
    }

    private var accessDesc: String {
        switch BrowserAccess.mode {
        case .off: return "Sessions don't get the browser tools (from the next session on)."
        case .ask: return "A session asks you the first time it wants the browser; your answer holds for that session."
        case .on: return "Every Claude and Codex session can use it."
        }
    }

    private func saveSites() {
        let list = sites.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.setSettingLocally("browser.allowed_sites", .array(list.map { .string($0) }), scope: "global")
        model.setSetting("browser.allowed_sites", list)
        sites = list.joined(separator: ", ")
    }
}
