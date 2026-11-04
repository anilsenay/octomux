import Foundation

/// The MCP servers Claude Code and Codex are set up with, read from their own config files (Settings → MCP).
/// Read only: Octomux shows them, the agents' own commands change them. Values of `env` and `headers` are
/// never kept (they often hold keys); only their names are.
struct MCPServer: Identifiable, Equatable {
    enum Scope: Equatable {
        case user                 // every project
        case local(String)        // one project, private (Claude: ~/.claude.json → projects[path])
        case project(String)      // one project, shared in its .mcp.json
    }
    var name: String
    var scope: Scope
    /// stdio: the command line; http/sse: the URL.
    var command: String?
    var url: String?
    var transport: String
    var envNames: [String] = []
    var enabled: Bool? = nil      // nil: no switch for it (Claude user/local); .mcp.json servers: approved or not
    var file: String
    var id: String { "\(file)|\(scopeKey)|\(name)" }

    var scopeKey: String {
        switch scope {
        case .user: return "user"
        case .local(let p): return "local:" + p
        case .project(let p): return "project:" + p
        }
    }
    var target: String { url ?? command ?? "" }
}

enum MCPConfig {
    // MARK: Claude

    /// `<config dir>/.claude.json`, or `~/.claude.json` without CLAUDE_CONFIG_DIR.
    static func claudeFile(configDir: String?) -> String {
        if let d = configDir, !d.isEmpty { return ((d as NSString).expandingTildeInPath as NSString).appendingPathComponent(".claude.json") }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    /// User servers, plus local and .mcp.json servers of the given project folders.
    static func claude(json: [String: Any], file: String, projects: [String], mcpJSON: (String) -> [String: Any]?) -> [MCPServer] {
        var out = servers(json["mcpServers"], scope: .user, file: file)
        let perProject = json["projects"] as? [String: Any] ?? [:]
        for path in projects {
            let p = perProject[path] as? [String: Any] ?? [:]
            out += servers(p["mcpServers"], scope: .local(path), file: file)
            if let shared = mcpJSON(path) {
                let enabled = Set(p["enabledMcpjsonServers"] as? [String] ?? [])
                let disabled = Set(p["disabledMcpjsonServers"] as? [String] ?? [])
                let all = (p["enableAllProjectMcpServers"] as? Bool) ?? false
                out += servers(shared["mcpServers"], scope: .project(path), file: (path as NSString).appendingPathComponent(".mcp.json")).map { s in
                    var s = s
                    s.enabled = disabled.contains(s.name) ? false : (all || enabled.contains(s.name)) ? true : nil
                    return s
                }
            }
        }
        return out
    }

    private static func servers(_ any: Any?, scope: MCPServer.Scope, file: String) -> [MCPServer] {
        guard let d = any as? [String: Any] else { return [] }
        return d.keys.sorted().compactMap { name in
            guard let e = d[name] as? [String: Any] else { return nil }
            let url = e["url"] as? String
            let cmd = (e["command"] as? String).map { c in ([c] + (e["args"] as? [String] ?? [])).joined(separator: " ") }
            let type = (e["type"] as? String) ?? (url != nil ? "http" : "stdio")
            let names = ((e["env"] as? [String: Any])?.keys.sorted() ?? []) + ((e["headers"] as? [String: Any])?.keys.sorted() ?? [])
            return MCPServer(name: name, scope: scope, command: cmd, url: url, transport: type, envNames: names, file: file)
        }
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // MARK: Codex

    static func codexFile(home: String?) -> String {
        let h = home.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return (h as NSString).appendingPathComponent("config.toml")
    }

    /// `[mcp_servers.<name>]` tables of a config.toml (a small reader for the keys these tables use).
    static func codex(toml: String, file: String) -> [MCPServer] {
        var tables: [String: [String: TOMLValue]] = [:]
        var order: [String] = []
        var envNames: [String: [String]] = [:]
        var current: (name: String, sub: String?)?
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                current = nil
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                let parts = splitKey(header)
                if parts.first == "mcp_servers", parts.count >= 2 {
                    let name = parts[1]
                    if tables[name] == nil { tables[name] = [:]; order.append(name) }
                    current = (name, parts.count > 2 ? parts[2] : nil)
                }
                continue
            }
            guard let cur = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            let value = parseValue(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if let sub = cur.sub {
                if sub == "env" || sub == "http_headers" || sub == "env_http_headers" { envNames[cur.name, default: []].append(key) }
            } else if key == "env" || key == "http_headers", case .table(let names) = value {
                envNames[cur.name, default: []] += names
            } else {
                tables[cur.name]?[key] = value
            }
        }
        return order.map { name in
            let t = tables[name] ?? [:]
            let url = t["url"]?.string
            let cmd = t["command"]?.string.map { c in ([c] + (t["args"]?.array ?? [])).joined(separator: " ") }
            return MCPServer(name: name, scope: .user, command: cmd, url: url, transport: url != nil ? "http" : "stdio",
                             envNames: (envNames[name] ?? []).sorted(), enabled: t["enabled"]?.bool ?? true, file: file)
        }
    }

    enum TOMLValue: Equatable {
        case string(String), array([String]), bool(Bool), other, table([String])
        var string: String? { if case .string(let s) = self { return s }; return nil }
        var array: [String]? { if case .array(let a) = self { return a }; return nil }
        var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    }

    static func parseValue(_ v: String) -> TOMLValue {
        if v == "true" { return .bool(true) }
        if v == "false" { return .bool(false) }
        if v.hasPrefix("\"") || v.hasPrefix("'") { return .string(unquote(v)) }
        if v.hasPrefix("[") {
            let inner = v.dropFirst().prefix { $0 != "]" }
            return .array(splitList(String(inner)).map(unquote).filter { !$0.isEmpty })
        }
        if v.hasPrefix("{") {   // inline table: keep the key names only
            let inner = v.dropFirst().prefix { $0 != "}" }
            return .table(splitList(String(inner)).compactMap { $0.split(separator: "=").first.map { unquote($0.trimmingCharacters(in: .whitespaces)) } })
        }
        return .other
    }

    /// `a.b."c.d"` → ["a", "b", "c.d"]
    static func splitKey(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "." { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Splits on commas outside quotes.
    private static func splitList(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); continue }
            if ch == "," { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    private static func unquote<S: StringProtocol>(_ s: S) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, (f == "\"" || f == "'"), t.last == f {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return t
    }
}

// MARK: Checking and removing (through the agents' own `mcp` commands)

extension MCPConfig {
    /// `claude mcp list` lines: "name: target - ✔ Connected". Name → status text.
    static func parseClaudeList(_ out: String) -> [String: String] {
        Dictionary(parseClaudeListEntries(out).map { ($0.name, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// Every server `claude mcp list` reports, in its order: also the ones not in the config files (claude.ai
    /// connectors of the account, plugins).
    static func parseClaudeListEntries(_ out: String) -> [(name: String, target: String, status: String)] {
        var d: [(name: String, target: String, status: String)] = []
        for line in out.split(separator: "\n") {
            // The status starts at " - " followed by its mark; error texts after it may hold " - " themselves.
            guard let colon = line.range(of: ": "),
                  let dash = ["✔", "✓", "✘", "✗", "!", "⚠"].compactMap({ line.range(of: " - " + $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
                  dash.lowerBound > colon.lowerBound else { continue }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let status = String(line[line.index(dash.lowerBound, offsetBy: 3)...]).trimmingCharacters(in: .whitespaces)
            let target = String(line[colon.upperBound..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !status.isEmpty { d.append((name, target, status)) }
        }
        return d
    }

    /// Runs `<command> <args>` through the login shell with the profile's environment. (status, stdout, stderr)
    static func runCLI(_ profile: Profile, _ args: [String], cwd: String?, timeout: TimeInterval = 60) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", "exec " + ([profile.command] + args.map(\.shellQuoted)).joined(separator: " ")]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in profile.env { env[k] = (v as NSString).expandingTildeInPath }
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let dir = FileManager.default.temporaryDirectory
        let out = dir.appendingPathComponent("octomux-mcp-\(UUID().uuidString).out"), err = out.appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err) }
        guard let oh = try? FileHandle(forWritingTo: out), let eh = try? FileHandle(forWritingTo: err) else { return (-1, "", "no temp file") }
        p.standardOutput = oh; p.standardError = eh; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return (-1, "", "timed out after \(Int(timeout)) s") }
        try? oh.close(); try? eh.close()
        let read = { (u: URL) in String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self) }
        return (p.terminationStatus, read(out), read(err))
    }

    /// What the Add Server form asks for.
    struct NewServer: Equatable {
        enum Transport: String, CaseIterable { case stdio, http, sse }
        enum Where: Equatable { case user, local(String), project(String) }
        var name = ""
        var transport = Transport.stdio
        /// The command line (stdio) or the URL.
        var target = ""
        /// KEY=value per line (stdio).
        var env = ""
        /// `Name: value` per line (Claude, HTTP/SSE).
        var headers = ""
        /// An environment variable holding a bearer token (Codex, HTTP).
        var bearerEnv = ""
        var scope = Where.user

        func lines(_ s: String) -> [String] {
            s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        /// Why it can't be added yet, or nil.
        func problem(kind: AgentKind) -> String? {
            let n = name.trimmingCharacters(in: .whitespaces)
            if n.isEmpty { return "Give it a name." }
            if n.contains(where: { $0.isWhitespace }) { return "The name can't have spaces." }
            let t = target.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return transport == .stdio ? "Enter the command that starts it." : "Enter its URL." }
            if transport != .stdio, !(t.hasPrefix("http://") || t.hasPrefix("https://")) { return "The URL starts with http:// or https://." }
            if kind == .codex, transport == .sse { return "Codex connects to HTTP servers, not SSE." }
            if transport == .stdio, let bad = lines(env).first(where: { !$0.contains("=") || $0.hasPrefix("=") }) { return "“\(bad)” isn't KEY=value." }
            if kind == .claude, transport != .stdio, let bad = lines(headers).first(where: { !$0.contains(":") }) { return "“\(bad)” isn't Name: value." }
            return nil
        }
    }

    /// The arguments that add `s` with the agent's CLI, and the folder to run them in (Claude's local and
    /// project scopes belong to a folder). Claude's -e and -H take several values, so the name comes first and
    /// the command after `--`.
    static func addCommand(_ s: NewServer, kind: AgentKind) -> (args: [String], cwd: String?) {
        let name = s.name.trimmingCharacters(in: .whitespaces)
        let target = s.target.trimmingCharacters(in: .whitespaces)
        if kind == .codex {
            if s.transport == .stdio {
                return (["mcp", "add", name] + s.lines(s.env).flatMap { ["--env", $0] } + ["--"] + ShellWords.split(target), nil)
            }
            let bearer = s.bearerEnv.trimmingCharacters(in: .whitespaces)
            return (["mcp", "add", name, "--url", target] + (bearer.isEmpty ? [] : ["--bearer-token-env-var", bearer]), nil)
        }
        var a = ["mcp", "add", name]
        let cwd: String?
        switch s.scope {
        case .user: a += ["-s", "user"]; cwd = nil
        case .local(let p): a += ["-s", "local"]; cwd = p
        case .project(let p): a += ["-s", "project"]; cwd = p
        }
        if s.transport == .stdio {
            a += s.lines(s.env).flatMap { ["-e", $0] } + ["--"] + ShellWords.split(target)
        } else {
            a += ["-t", s.transport.rawValue, target] + s.lines(s.headers).flatMap { ["-H", $0] }
        }
        return (a, cwd)
    }

    /// The arguments that remove this server with the agent's CLI, and the folder to run them in.
    static func removeCommand(_ s: MCPServer, kind: AgentKind) -> (args: [String], cwd: String?) {
        if kind == .codex { return (["mcp", "remove", s.name], nil) }
        switch s.scope {
        case .user: return (["mcp", "remove", "-s", "user", s.name], nil)
        case .local(let p): return (["mcp", "remove", "-s", "local", s.name], p)
        case .project(let p): return (["mcp", "remove", "-s", "project", s.name], p)
        }
    }
}
