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
