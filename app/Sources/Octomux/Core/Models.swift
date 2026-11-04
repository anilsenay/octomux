import Foundation

// Mirrors octomux-proto/src/control.rs (snake_case JSON).

struct Workspace: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: String
    var sort: Int
    var icon: String?
}

struct ProjectIcon: Codable, Equatable {
    var kind: String
    var value: String?
}

struct Project: Codable, Identifiable, Equatable {
    var id: String
    var workspaceId: String
    var name: String
    var path: String
    var color: String
    var icon: ProjectIcon
    var sort: Int
    var archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, path, color, icon, sort, archived
        case workspaceId = "workspace_id"
    }
}

enum AgentKind: String, Codable, CaseIterable {
    case claude, codex, generic
}

struct Profile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String
    var kind: AgentKind
    var command: String
    var args: [String]
    var env: [String: String]
    var viaLoginShell: Bool
    var resumeTemplate: String
    var enabled: Bool
    var pinned: Bool
    var sort: Int
    var statusline: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, icon, kind, command, args, env, enabled, pinned, sort, statusline
        case viaLoginShell = "via_login_shell"
        case resumeTemplate = "resume_template"
    }

    init(id: String, name: String, icon: String, kind: AgentKind, command: String, args: [String], env: [String: String],
         viaLoginShell: Bool, resumeTemplate: String, enabled: Bool, pinned: Bool, sort: Int, statusline: Bool = true) {
        (self.id, self.name, self.icon, self.kind, self.command, self.args, self.env) = (id, name, icon, kind, command, args, env)
        (self.viaLoginShell, self.resumeTemplate, self.enabled, self.pinned, self.sort, self.statusline) = (viaLoginShell, resumeTemplate, enabled, pinned, sort, statusline)
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        kind = try c.decode(AgentKind.self, forKey: .kind)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        viaLoginShell = try c.decodeIfPresent(Bool.self, forKey: .viaLoginShell) ?? true
        resumeTemplate = try c.decodeIfPresent(String.self, forKey: .resumeTemplate) ?? ""
        enabled = try c.decode(Bool.self, forKey: .enabled)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        sort = try c.decode(Int.self, forKey: .sort)
        statusline = try c.decodeIfPresent(Bool.self, forKey: .statusline) ?? true
    }
}

enum SessionKind: String, Codable { case terminal, agent, action }
enum SessionState: String, Codable { case running, stopped, exited, interrupted }
enum Activity: String, Codable { case idle, working, needsInput = "needs_input", done, error }
enum Placement: String, Codable { case tab, dock }

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var projectId: String
    var kind: SessionKind
    var profileId: String?
    var title: String
    var customTitle: String
    var cwd: String
    var state: SessionState
    var activity: Activity
    var unread: Bool
    var agentSessionId: String?
    var createdAt: Int
    var lastActivityAt: Int
    var exitCode: Int?
    var placement: Placement
    var command: String?
    var worktree: String?
    var transcriptPath: String?
    /// Conversation title the agent wrote to its transcript (Claude ai-title / custom-title).
    var agentTitle: String?
    /// An agent running in a terminal tab (a `claude` typed at the prompt), as it names itself ("claude-code").
    var agentApp: String?
    /// The program reports its own state (OSC 7501).
    var reportsStatus: Bool?
    /// Shells the agent left running in the background (Claude's "N shells still running").
    var backgroundShells: Int?
    /// The first message sent to the agent (start screen, or the first one typed in its terminal).
    var firstPrompt: String?

    /// Settings → Sessions → Tab titles: the first message instead of the agent's own title.
    static var titleFromPrompt = false

    /// Launched as an agent, or a terminal where one runs now.
    var isAgent: Bool { kind == .agent || agentApp != nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, cwd, state, activity, unread, placement, command, worktree
        case agentApp = "agent_app"
        case reportsStatus = "reports_status"
        case backgroundShells = "background_shells"
        case firstPrompt = "first_prompt"
        case transcriptPath = "transcript_path"
        case agentTitle = "agent_title"
        case projectId = "project_id"
        case profileId = "profile_id"
        case customTitle = "custom_title"
        case agentSessionId = "agent_session_id"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case exitCode = "exit_code"
    }

    var displayTitle: String {
        if !customTitle.isEmpty { return customTitle }
        if Self.titleFromPrompt, isAgent, let p = firstPrompt, !p.isEmpty {
            return p.count > 60 ? String(p.prefix(59)) + "…" : p
        }
        if let a = agentTitle, !a.isEmpty { return a }
        if kind == .terminal, let app = agentApp {
            // The agent's own title (Claude: "✳ Fix the test", with a spinner glyph in front while working).
            let t = String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? agentAppLabel(app) : t
        }
        if kind == .terminal {
            // Shells usually report a (truncated) path: show the folder name instead.
            var t = title.trimmingCharacters(in: .whitespaces)
            if let colon = t.range(of: ": "), t[..<colon.lowerBound].contains("@") { t = String(t[colon.upperBound...]) }
            // Prompts clip long paths from the left ("..onal_projects", "…/new-ade" — oh-my-zsh keeps 15 chars).
            let clipped = t.hasPrefix("..") || t.hasPrefix("…")
            while t.hasPrefix(".") || t.hasPrefix("…") { t.removeFirst() }
            let partial = clipped && !t.contains("/")   // the cut went through the folder name itself
            if t.hasPrefix("/") || t.hasPrefix("~") || (t.contains("/") && !t.contains(" ")) {
                let last = (t as NSString).lastPathComponent
                t = last.isEmpty || last == "~" ? "~" : last
            }
            if partial, !t.isEmpty {
                // The working directory (OSC 7 / start dir) usually has the full name the prompt cut.
                let dir = (cwd as NSString).lastPathComponent
                return dir.count > t.count && dir.hasSuffix(t) ? dir : "…" + t
            }
            return t.isEmpty ? "Terminal" : t
        }
        return title.isEmpty ? "Session" : title
    }

    /// Stopped or ended: drawn dimmed, with restart/remove controls.
    var isDormant: Bool { state == .stopped || state == .exited }
}

enum SplitDir: String, Codable { case right, down }

indirect enum PaneNode: Codable, Equatable {
    case leaf(sessionId: String)
    case split(dir: SplitDir, ratio: Double, a: PaneNode, b: PaneNode)

    enum CodingKeys: String, CodingKey { case type, dir, ratio, a, b; case sessionId = "session_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "leaf" {
            self = .leaf(sessionId: try c.decode(String.self, forKey: .sessionId))
        } else {
            self = .split(dir: try c.decode(SplitDir.self, forKey: .dir),
                          ratio: try c.decode(Double.self, forKey: .ratio),
                          a: try c.decode(PaneNode.self, forKey: .a),
                          b: try c.decode(PaneNode.self, forKey: .b))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode("leaf", forKey: .type)
            try c.encode(id, forKey: .sessionId)
        case .split(let dir, let ratio, let a, let b):
            try c.encode("split", forKey: .type)
            try c.encode(dir, forKey: .dir)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }

    var sessions: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let a, let b): return a.sessions + b.sessions
        }
    }

    func withRatio(path: [Bool], ratio r: Double) -> PaneNode {
        guard case .split(let dir, let ratio, let a, let b) = self else { return self }
        if path.isEmpty { return .split(dir: dir, ratio: r, a: a, b: b) }
        let rest = Array(path.dropFirst())
        return path[0] ? .split(dir: dir, ratio: ratio, a: a, b: b.withRatio(path: rest, ratio: r))
                       : .split(dir: dir, ratio: ratio, a: a.withRatio(path: rest, ratio: r), b: b)
    }
}

struct Tab: Codable, Identifiable, Equatable {
    var id: String
    var projectId: String
    var sort: Int
    var layout: PaneNode
    var activeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case id, sort, layout
        case projectId = "project_id"
        case activeSessionId = "active_session_id"
    }
}

struct Setting: Codable, Equatable {
    var scope: String
    var key: String
    var value: JSONValue
}

struct DaemonState: Codable, Equatable {
    var workspaces: [Workspace] = []
    var projects: [Project] = []
    var profiles: [Profile] = []
    var sessions: [Session] = []
    var tabs: [Tab] = []
    var settings: [Setting] = []
    var usage: [UsageReading] = []

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        projects = try c.decode([Project].self, forKey: .projects)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        sessions = try c.decode([Session].self, forKey: .sessions)
        tabs = try c.decode([Tab].self, forKey: .tabs)
        settings = try c.decode([Setting].self, forKey: .settings)
        usage = try c.decodeIfPresent([UsageReading].self, forKey: .usage) ?? []
    }
}

/// Rate-limit window reading (Claude statusline / Codex rollout).
struct UsageReading: Codable, Equatable, Identifiable {
    var profileId: String
    var window: String
    var usedPercent: Double
    var resetsAt: Double?
    var observedAt: Double
    var id: String { profileId + ":" + window }

    enum CodingKeys: String, CodingKey {
        case window
        case profileId = "profile_id"
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case observedAt = "observed_at"
    }

    /// The window already reset since this reading was taken.
    var isReset: Bool { resetsAt.map { Date().timeIntervalSince1970 >= $0 } ?? false }
    var effectivePercent: Double { isReset ? 0 : usedPercent }
    static let showsLeftKey = "octomux.usageShowsLeft"
    /// Which limits the status bar shows: "all", "five_hour" or "weekly" (the popover always lists all).
    static let windowsKey = "octomux.usageWindows"
    static func shown(_ readings: [UsageReading], _ which: String) -> [UsageReading] {
        let f: [UsageReading]
        switch which {
        case "five_hour": f = readings.filter { $0.window == "five_hour" }
        case "weekly": f = readings.filter { $0.window.hasPrefix("seven_day") }
        default: return readings
        }
        return f.isEmpty ? readings : f   // a profile without that limit still shows what it has
    }
    /// "34%" used, or "66%" left.
    func label(left: Bool) -> String { "\(Int((left ? max(0, 100 - usedPercent) : usedPercent).rounded()))%" }
    var shortName: String {
        switch window {
        case "five_hour": return "5h"
        case "seven_day": return "week"
        case "spend_limit": return "spend"
        default: return window
        }
    }
    var longName: String {
        switch window {
        case "five_hour": return "5-hour window"
        case "seven_day": return "Weekly"
        case "spend_limit": return "Spend limit"
        default:
            // Per-model weekly limits from `/usage` ("seven_day_fable" → "Weekly · Fable").
            if window.hasPrefix("seven_day_") { return "Weekly · " + window.dropFirst(10).replacingOccurrences(of: "_", with: " ").capitalized }
            return window.capitalized
        }
    }
    static func order(_ w: String) -> Int { ["five_hour": 0, "seven_day": 1, "spend_limit": 2][w] ?? 3 }
}

struct AppNotification: Codable {
    var sessionId: String
    var projectId: String
    var kind: String
    var title: String
    var body: String
    /// Set when the daemon stored it (notification center); older daemons send none.
    var id: Int64?
    var ts: Int?
    var read: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, title, body, id, ts, read
        case sessionId = "session_id"
        case projectId = "project_id"
    }
}

/// Minimal JSON value for settings.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }
}


/// Display name for an agent that named itself (OSC 7501 `app`).
func agentAppLabel(_ app: String) -> String {
    switch app {
    case "claude-code", "claude": return "Claude Code"
    case "codex": return "Codex"
    default: return app.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
