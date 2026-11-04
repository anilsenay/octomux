import SwiftUI

/// Settings → MCP: the MCP servers each agent's config gives it, per config file (agents that share a config
/// share a group). Read only.
struct MCPSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var groups: [Group] = []
    /// `claude mcp list` results per config file: server name → status.
    @State private var status: [String: [String: String]] = [:]
    @State private var checking: Set<String> = []
    @State private var message = ""

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
        ForEach(groups) { g in
            SettingsGroup("\(g.kind == .codex ? "Codex" : "Claude Code") · \(g.agents.joined(separator: ", "))",
                          desc: (g.file as NSString).abbreviatingWithTildeInPath + (g.exists ? "" : " (not there yet)"),
                          trailing: {
                if g.kind == .claude, g.profile != nil {
                    Button(checking.contains(g.file) ? "Checking…" : "Check") { check(g) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(checking.contains(g.file))
                        .help("Starts each server the way Claude Code does (claude mcp list) and shows whether it connects")
                }
                if g.exists {
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.file)]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }) {
                if g.servers.isEmpty {
                    Text("No MCP servers.").font(.system(size: T.k * 12.5)).foregroundStyle(T.text2).padding(14)
                }
                ForEach(g.servers) { s in row(s, g) }
            }
        }
        if !message.isEmpty { Text(message).font(.system(size: T.k * 12)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true) }
        SettingsFootnote("Read from the agents' own config files when this page opens. Add servers with `claude mcp add` or `codex mcp add`; Remove and Check use those same commands. Turning a server off is done in the agent (Claude: /mcp). Values of environment variables and headers are not shown.")
        HStack {
            Spacer()
            Button("Reload") { load() }.buttonStyle(SecondaryButtonStyle())
        }
        Color.clear.frame(height: 0).onAppear(perform: load)
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

    private func pill(_ t: String, color: Color) -> some View {
        Text(t).font(.system(size: T.k * 10.5, weight: .semibold)).foregroundStyle(color)
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
                if code == 0 { status[g.file] = MCPConfig.parseClaudeList(out); message = "" }
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
