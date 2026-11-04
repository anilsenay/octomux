import AppKit

/// Saved prompts (Settings → Prompts): for every project, a workspace's projects, or one project. Picked in a
/// new chat, the quick composer and ⌘K; placeholders are filled in when picked.
struct PromptTemplate: Identifiable, Equatable {
    var id: String
    var name: String
    var text: String
    /// "global", "workspace:<id>" or "project:<id>" (the settings scope it is stored in).
    var scope: String

    static let key = "prompts.templates"

    /// What the placeholders mean, for the editor's help line.
    static let placeholders: [(String, String)] = [
        ("{project}", "project name"), ("{path}", "its folder"), ("{branch}", "current branch"),
        ("{clipboard}", "clipboard text"), ("{date}", "today"),
    ]

    /// The text with its placeholders filled in.
    static func expand(_ text: String, project: Project?, folder: String?, branch: String?, clipboard: String?, date: Date = Date()) -> String {
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
        for (k, v) in values { out = out.replacingOccurrences(of: k, with: v) }
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
            return PromptTemplate(id: o["id"]?.string ?? UUID().uuidString, name: name, text: text, scope: scope)
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
        let v = list.map { ["id": $0.id, "name": $0.name, "text": $0.text] }
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
    func expandTemplate(_ t: PromptTemplate, project p: Project?, folder: String? = nil) -> String {
        let dir = folder ?? p?.path
        return PromptTemplate.expand(t.text, project: p, folder: dir, branch: dir.flatMap { GitInfo.shared.branch(for: $0) },
                                     clipboard: NSPasteboard.general.string(forType: .string))
    }
}
