import SwiftUI

/// Settings → MCP: the MCP servers each agent's config gives it, per config file (agents that share a config
/// share a group). Read only.
struct MCPSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var groups: [Group] = []

    struct Group: Identifiable {
        var id: String { file }
        let kind: AgentKind
        let agents: [String]
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
                if g.exists {
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.file)]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }) {
                if g.servers.isEmpty {
                    Text("No MCP servers.").font(.system(size: T.k * 12.5)).foregroundStyle(T.text2).padding(14)
                }
                ForEach(g.servers) { s in row(s) }
            }
        }
        SettingsFootnote("Read from the agents' own config files when this page opens. Add or remove servers with `claude mcp add` / `claude mcp remove` or `codex mcp add` / `codex mcp remove`. Whether a server starts is not checked here. Values of environment variables and headers are not shown.")
        HStack {
            Spacer()
            Button("Reload") { load() }.buttonStyle(SecondaryButtonStyle())
        }
        Color.clear.frame(height: 0).onAppear(perform: load)
    }

    private func row(_ s: MCPServer) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.url != nil ? "globe" : "terminal").font(.system(size: T.k * 12)).foregroundStyle(T.text3).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name).font(.system(size: T.k * 13, weight: .medium))
                    pill(scopeLabel(s.scope), color: T.text2)
                    if s.enabled == false { pill("Off", color: T.text3) }
                    if s.enabled == nil, case .project = s.scope { pill("Not approved yet", color: T.amber) }
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
        var byFile: [(kind: AgentKind, file: String, agents: [String])] = []
        func add(_ kind: AgentKind, _ file: String, _ agent: String) {
            if let i = byFile.firstIndex(where: { $0.file == file }) { byFile[i].agents.append(agent) } else { byFile.append((kind, file, [agent])) }
        }
        for p in profiles {
            if p.kind == .claude { add(.claude, MCPConfig.claudeFile(configDir: p.env["CLAUDE_CONFIG_DIR"]), p.name) }
            else { add(.codex, MCPConfig.codexFile(home: p.env["CODEX_HOME"]), p.name) }
        }
        if !byFile.contains(where: { $0.kind == .claude }) { add(.claude, MCPConfig.claudeFile(configDir: nil), "claude") }
        if !byFile.contains(where: { $0.kind == .codex }) { add(.codex, MCPConfig.codexFile(home: nil), "codex") }
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
            return Group(kind: g.kind, agents: g.agents, file: g.file, exists: exists, servers: servers)
        }
    }
}
