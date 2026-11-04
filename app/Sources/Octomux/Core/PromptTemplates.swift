import AppKit

/// Saved prompts (Settings → Prompts): for every project, a workspace's projects, or one project. Picked in a
/// new chat, the quick composer and ⌘K; placeholders are filled in when picked.
struct PromptTemplate: Identifiable, Equatable {
    var id: String
    var name: String
    var text: String
    /// "global", "workspace:<id>" or "project:<id>" (the settings scope it is stored in).
    var scope: String
    /// Also offered in the Changes panel's Ask Agent menu (and a changed file's menu, where {file} is that file).
    var changes = false

    static let key = "prompts.templates"

    /// What the placeholders mean, for the editor's help line.
    static let placeholders: [(String, String)] = [
        ("{project}", "project name"), ("{path}", "its folder"), ("{branch}", "current branch"),
        ("{clipboard}", "clipboard text"), ("{date}", "today"),
        ("{file}", "the changed file (Changes panel)"), ("{base}", "the branch Changes compares with, else HEAD"),
    ]

    /// The text with its placeholders filled in.
    static func expand(_ text: String, project: Project?, folder: String?, branch: String?, clipboard: String?, date: Date = Date(),
                       extra: [String: String] = [:]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let values: [String: String] = [
            "{project}": project?.name ?? "",
            "{path}": folder ?? project?.path ?? "",
            "{branch}": branch ?? "",
            "{clipboard}": clipboard ?? "",
            "{date}": f.string(from: date),
        ]
        var out = text
        for (k, v) in values.merging(extra, uniquingKeysWith: { _, b in b }) { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Adds the picked template to what is typed: replaces an empty field, else goes on a new line.
    static func insert(_ t: String, into current: String) -> String {
        let c = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? t : current + (current.hasSuffix("\n") ? "" : "\n") + t
    }
}

extension AppModel {
    func templates(scope: String) -> [PromptTemplate] {
        guard case .array(let arr)? = settingValue(PromptTemplate.key, scope: scope) else { return [] }
        return arr.compactMap { v in
            guard case .object(let o) = v, let name = o["name"]?.string, let text = o["text"]?.string else { return nil }
            return PromptTemplate(id: o["id"]?.string ?? UUID().uuidString, name: name, text: text, scope: scope,
                                  changes: o["changes"]?.bool ?? false)
        }
    }

    /// What a project can use: its own, its workspace's, then everyone's.
    func templates(project id: String?) -> [PromptTemplate] {
        var scopes: [String] = []
        if let id, let p = project(id) { scopes += ["project:\(p.id)", "workspace:\(p.workspaceId)"] }
        scopes.append("global")
        return scopes.flatMap { templates(scope: $0) }
    }

    func saveTemplates(_ list: [PromptTemplate], scope: String) {
        let v: [[String: Any]] = list.map { t in
            var d: [String: Any] = ["id": t.id, "name": t.name, "text": t.text]
            if t.changes { d["changes"] = true }
            return d
        }
        setSetting(PromptTemplate.key, v.isEmpty ? nil : v, scope: scope)
    }

    /// Adds, replaces (same id, maybe moved to another scope) or removes (`text` nil) a template.
    func upsertTemplate(_ t: PromptTemplate, remove: Bool = false) {
        // Out of whichever scope held it before.
        for scope in Set(state.settings.filter { $0.key == PromptTemplate.key }.map(\.scope)) where scope != t.scope {
            let list = templates(scope: scope)
            if list.contains(where: { $0.id == t.id }) { saveTemplates(list.filter { $0.id != t.id }, scope: scope) }
        }
        var list = templates(scope: t.scope)
        if remove { list.removeAll { $0.id == t.id } }
        else if let i = list.firstIndex(where: { $0.id == t.id }) { list[i] = t }
        else { list.append(t) }
        saveTemplates(list, scope: t.scope)
    }

    /// A template's text for this project, placeholders filled in.
    func expandTemplate(_ t: PromptTemplate, project p: Project?, folder: String? = nil, file: String? = nil) -> String {
        let dir = folder ?? p?.path
        var extra = ["{base}": dir.flatMap { GitInfo.compareBase(for: $0) } ?? "HEAD"]
        extra["{file}"] = file ?? ""
        return PromptTemplate.expand(t.text, project: p, folder: dir, branch: dir.flatMap { GitInfo.shared.branch(for: $0) },
                                     clipboard: NSPasteboard.general.string(forType: .string), extra: extra)
    }

    /// Changes panel → Ask Agent: to the focused agent when it works in this folder and is free, else to a new
    /// agent session there (the workspace's chat agent).
    func askAgent(_ text: String, projectId: String, folder: String) {
        if let s = session(focusedSessionId), s.isAgent, s.projectId == projectId, s.state == .running,
           (s.worktree ?? project(projectId)?.path) == folder, s.activity != .working, s.activity != .needsInput {
            sendToSession(s.id, text: text)
            selectSession(s.id)
            return
        }
        let p = project(projectId)
        let profile = defaultChatProfile(workspace: p?.workspaceId) ?? enabledProfiles.first { $0.kind == .claude || $0.kind == .codex }
        guard let profile else { lastError = "Set up an agent first (Settings → Agents)."; return }
        newSession(profileId: profile.id, projectId: projectId, worktree: folder != p?.path ? folder : nil, prompt: text, chat: true,
                   extraArgs: ChatLaunchOptions.load(profile.kind).args(profile.kind))
    }
}
