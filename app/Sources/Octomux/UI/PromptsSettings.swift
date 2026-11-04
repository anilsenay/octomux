import SwiftUI

/// The prompts a project can use, as a menu: picking one adds its text (placeholders filled in).
struct TemplateMenu<Label: View>: View {
    @EnvironmentObject var model: AppModel
    let projectId: String?
    var folder: String? = nil
    let pick: (String) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        let list = model.templates(project: projectId)
        Menu {
            if list.isEmpty { Text("No saved prompts yet") }
            ForEach(Self.grouped(list, model: model), id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { t in
                        Button(t.name) { pick(model.expandTemplate(t, project: model.project(projectId), folder: folder)) }
                    }
                }
            }
            Divider()
            Button("Edit Prompts…") { SettingsWindow.show(section: .prompts) }
        } label: { label() }
    }

    static func grouped(_ list: [PromptTemplate], model: AppModel) -> [(String, [PromptTemplate])] {
        var out: [(String, [PromptTemplate])] = []
        for t in list {
            let title = scopeTitle(t.scope, model: model)
            if let i = out.firstIndex(where: { $0.0 == title }) { out[i].1.append(t) } else { out.append((title, [t])) }
        }
        return out
    }

    static func scopeTitle(_ scope: String, model: AppModel) -> String {
        if scope.hasPrefix("project:") { return model.project(String(scope.dropFirst(8)))?.name ?? "Project" }
        if scope.hasPrefix("workspace:") { return model.state.workspaces.first { "workspace:\($0.id)" == scope }?.name ?? "Workspace" }
        return "All projects"
    }
}

/// Settings → Prompts: every saved prompt, by where it applies.
struct PromptsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: PromptTemplate?

    var body: some View {
        let scopes = ["global"] + model.state.workspaces.sorted { $0.sort < $1.sort }.map { "workspace:\($0.id)" }
            + model.state.projects.filter { !$0.archived }.sorted { $0.sort < $1.sort }.map { "project:\($0.id)" }
        let filled = scopes.filter { $0 == "global" || !model.templates(scope: $0).isEmpty }
        HStack {
            Text("Pick one from the prompt menu (the text-bubble button) in a new chat or the quick composer, or type its name in ⌘K. It goes into the message box, where you can still change it.")
                .font(.system(size: 12)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button { editing = PromptTemplate(id: UUID().uuidString, name: "", text: "", scope: "global") } label: {
                Label("New Prompt", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 2)
        ForEach(filled, id: \.self) { scope in
            let list = model.templates(scope: scope)
            SettingsGroup(TemplateMenu<EmptyView>.scopeTitle(scope, model: model),
                          desc: scope == "global" ? "Every project." : scope.hasPrefix("workspace:") ? "The projects of this workspace." : "Only this project.") {
                if list.isEmpty {
                    Text("None yet.").font(.system(size: 12.5)).foregroundStyle(T.text2).padding(14)
                }
                ForEach(list) { t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(T.text3).frame(width: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(t.name).font(.system(size: 13, weight: .medium))
                                if t.changes {
                                    Text("Changes").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.text2)
                                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(T.hover))
                                }
                            }
                            Text(t.text).font(.system(size: 11.5)).foregroundStyle(T.text2).lineLimit(2)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Button("Edit") { editing = t }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        Color.clear.frame(height: 0)
            .sheet(item: $editing) { t in PromptEditor(template: t, isNew: !allIds.contains(t.id)) { editing = nil } }
    }

    private var allIds: Set<String> {
        Set(model.state.settings.filter { $0.key == PromptTemplate.key }.flatMap { model.templates(scope: $0.scope).map(\.id) })
    }
}

struct PromptEditor: View {
    @EnvironmentObject var model: AppModel
    @State var template: PromptTemplate
    let isNew: Bool
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New prompt" : "Edit prompt").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $template.name, prompt: Text("Review this branch"))
                Picker("For", selection: $template.scope) {
                    Text("All projects").tag("global")
                    Section("Workspaces") {
                        ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in Text(w.name).tag("workspace:\(w.id)") }
                    }
                    Section("Projects") {
                        ForEach(model.state.projects.filter { !$0.archived }.sorted { $0.sort < $1.sort }) { p in Text(p.name).tag("project:\(p.id)") }
                    }
                }
            }
            Toggle("Also in the Changes panel's Ask Agent menu (sends it to the focused agent, or a new one)", isOn: $template.changes)
                .font(.system(size: 12))
            TextEditor(text: $template.text).font(T.mono(12.5)).frame(height: 160)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
            Text("Filled in when picked: " + PromptTemplate.placeholders.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !isNew {
                    Button(role: .destructive) { model.upsertTemplate(template, remove: true); done() } label: { Text("Delete").foregroundStyle(T.red) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    template.name = template.name.trimmingCharacters(in: .whitespaces)
                    model.upsertTemplate(template)
                    done()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty || template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
