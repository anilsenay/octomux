import AppKit
import SwiftUI

/// ⌘K: fuzzy search over sessions, projects, workspaces, menu commands, new-session
/// profiles, settings pages and themes.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle = ""
    var kind: String          // "Session", "Project", "Command", …
    var icon: AnyView
    var shortcut: String = ""
    let run: () -> Void
}

enum PaletteSource {
    static func items(model: AppModel) -> [PaletteItem] {
        var out: [PaletteItem] = []
        let sym = { (n: String) in AnyView(Image(systemName: n).font(.system(size: T.k * 12)).foregroundStyle(T.text3).frame(width: 18)) }
        for s in model.state.sessions where s.placement == .tab {
            let proj = model.project(s.projectId)
            out.append(PaletteItem(id: "s:" + s.id, title: s.displayTitle, subtitle: proj?.name ?? "", kind: "Session",
                                   icon: AnyView(AgentIcon(icon: iconName(for: s, model: model), size: 12).frame(width: 18))) {
                if let p = proj, model.project(p.id)?.workspaceId != model.selectedWorkspaceId { model.selectWorkspace(p.workspaceId) }
                model.selectSession(s.id)
            })
        }
        for p in model.state.projects where !p.archived {
            out.append(PaletteItem(id: "p:" + p.id, title: p.name, subtitle: p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), kind: "Project",
                                   icon: AnyView(ProjectIconView(project: p, size: 16).frame(width: 18))) {
                if p.workspaceId != model.selectedWorkspaceId { model.selectWorkspace(p.workspaceId) }
                model.selectProject(p.id)
            })
        }
        for w in model.state.workspaces {
            out.append(PaletteItem(id: "w:" + w.id, title: "Switch to \(w.name)", kind: "Workspace",
                                   icon: AnyView(Circle().fill(Color(hex: w.color)).frame(width: 8, height: 8).frame(width: 18))) { model.selectWorkspace(w.id) })
        }
        for p in model.enabledProfiles {
            out.append(PaletteItem(id: "n:" + p.id, title: "New \(p.name)", subtitle: model.currentProject?.name ?? "", kind: "Agent",
                                   icon: AnyView(AgentIcon(icon: p.icon, size: 12).frame(width: 18))) { model.newSession(profileId: p.id) })
        }
        if model.currentWorkPath != nil {
            out.append(PaletteItem(id: "pr:create", title: "Create Pull Request", subtitle: model.currentProject?.name ?? "", kind: "Command", icon: sym("arrow.triangle.pull")) {
                DispatchQueue.main.async { PullRequestWindow.show(model: model) }
            })
        }
        let here = model.currentProject
        for t in model.templates(project: here?.id) {
            out.append(PaletteItem(id: "prompt:" + t.id, title: "Prompt: \(t.name)", subtitle: t.text.prefix(80).replacingOccurrences(of: "\n", with: " "),
                                   kind: "Prompt", icon: sym("text.bubble")) {
                model.openNewChat(projectId: here?.id, draft: model.expandTemplate(t, project: here, folder: model.currentWorkPath))
            })
        }
        for c in KeyBindings.shared.commands where c.id != "cmd.command-palette" {
            out.append(PaletteItem(id: c.id, title: c.title.replacingOccurrences(of: "…", with: ""), subtitle: c.group, kind: "Command",
                                   icon: sym("command"), shortcut: KeyBindings.shared.current(c.id)?.display ?? "") {
                KeyBindings.shared.perform(c.id)
            })
        }
        for s in SettingsSection.allCases {
            out.append(PaletteItem(id: "set:" + s.rawValue, title: "Settings: \(s.rawValue)", kind: "Settings", icon: sym(s.icon)) { SettingsWindow.show(section: s) })
        }
        for t in Themes.all {
            out.append(PaletteItem(id: "th:" + t.id, title: "Theme: \(t.name)", subtitle: t.summary, kind: "Theme", icon: sym("paintpalette")) { ThemeStore.shared.set(theme: t.id) })
        }
        if (model.activeTab?.layout.sessions.count ?? 0) > 1 {
            out.append(PaletteItem(id: "pane:equalize", title: "Equalize Panes", subtitle: "Split tab", kind: "Command", icon: sym("rectangle.split.3x1")) {
                model.equalizePanes()
            })
        }
        out.append(PaletteItem(id: "scene:agent", title: "Create Scene with Agent", subtitle: "", kind: "Theme", icon: sym("wand.and.stars")) {
            DispatchQueue.main.async { UserScenes.createWithAgent() }
        })
        out.append(PaletteItem(id: "scene:pick", title: "Change Scene", subtitle: model.workspace?.name ?? "", kind: "Theme", icon: sym("sparkles")) {
            DispatchQueue.main.async { ScenePickerPanel.shared.show() }
        })
        for (m, label) in [("system", "System"), ("dark", "Dark"), ("light", "Light")] {
            out.append(PaletteItem(id: "mode:" + m, title: "Appearance: \(label)", kind: "Theme", icon: sym("circle.lefthalf.filled")) { ThemeStore.shared.set(mode: m) })
        }
        return out
    }

    /// Subsequence match; higher is better, nil = no match.
    static func score(_ q: String, _ text: String) -> Int? {
        if q.isEmpty { return 0 }
        let t = Array(text.lowercased()), qs = Array(q.lowercased())
        var ti = 0, score = 0, streak = 0, first = -1
        for c in qs where c != " " {
            var found = false
            while ti < t.count {
                if t[ti] == c {
                    if first < 0 { first = ti }
                    streak += 1
                    score += 1 + streak * 2 + (ti == 0 || t[ti - 1] == " " || t[ti - 1] == "-" ? 6 : 0)
                    ti += 1; found = true; break
                }
                streak = 0; ti += 1
            }
            if !found { return nil }
        }
        return score - max(0, first) - t.count / 10
    }

    static func search(_ q: String, model: AppModel) -> [PaletteItem] {
        let all = items(model: model)
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            // Default: sessions waiting first, then current project's sessions, then commands.
            let waiting = Set(model.state.sessions.filter { $0.activity == .needsInput }.map { "s:" + $0.id })
            return all.filter { waiting.contains($0.id) } + all.filter { $0.kind == "Session" && !waiting.contains($0.id) } + all.filter { $0.kind == "Command" }
        }
        return all.compactMap { i in
            let s = max(score(q, i.title) ?? -999, (score(q, i.kind + " " + i.title) ?? -999) - 4, (score(q, i.subtitle) ?? -999) - 12)
            return s > -999 ? (i, s) : nil
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}

struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    @State private var selected = 0
    /// Esc, arrows and Return work while the palette is open even if the search field has not taken focus yet
    /// (the terminal can keep first responder for a moment after ⌘K).
    @State private var keyMonitor: Any?

    var body: some View {
        let results = Array(PaletteSource.search(model.paletteQuery, model: model).prefix(50))
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(T.text3)
                    TextField("Search sessions, projects, commands…", text: $model.paletteQuery)
                        .textFieldStyle(.plain).font(.system(size: T.k * 15))
                        .focused($focused)
                        .onSubmit { run(results) }
                        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    ShortcutHint("esc")
                }
                .padding(.horizontal, 16).frame(height: 50)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            let grouped = model.paletteQuery.trimmingCharacters(in: .whitespaces).isEmpty
                            let waiting = Set(model.state.sessions.filter { $0.activity == .needsInput }.map { "s:" + $0.id })
                            let group = { (r: PaletteItem) in waiting.contains(r.id) ? "Waiting for you" : r.kind + "s" }
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                                // Without a query the list comes in groups (waiting, sessions, commands): a header per group.
                                if grouped, i == 0 || group(results[i - 1]) != group(r) {
                                    SectionHeader(group(r))
                                        .padding(.horizontal, 10).padding(.top, i == 0 ? 2 : 8)
                                }
                                row(r, selected: i == selected, showKind: !grouped)
                                    .onTapGesture { selected = i; run(results) }
                                    .onHover { if $0 { selected = i } }
                            }
                            if results.isEmpty {
                                Text("No matches").font(T.body).foregroundStyle(T.text3).padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(400, CGFloat(max(results.count, 1)) * 33 + 40))
                    .onChange(of: selected) { _, v in if v < results.count { proxy.scrollTo(results[v].id) } }
                }
                HStack(spacing: 14) {
                    HStack(spacing: 4) { ShortcutHint("↑↓"); Text("Navigate") }
                    HStack(spacing: 4) { ShortcutHint("↵"); Text("Open") }
                    Spacer()
                    Text("\(results.count) results").monospacedDigit()
                }
                .font(T.meta).foregroundStyle(T.text3)
                .padding(.horizontal, 14).frame(height: 30)
                .overlay(alignment: .top) { Hairline() }
            }
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: R.float, style: .continuous).fill(T.raised))
            .clipShape(RoundedRectangle(cornerRadius: R.float, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: R.float, style: .continuous).stroke(T.border))
            .shadow(color: .black.opacity(0.35), radius: 36, y: 16)
            .padding(.top, 70)
        }
        .onAppear {
            selected = 0
            focused = true
            for d in [0.05, 0.15, 0.35] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { if !focused { focused = true } } }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard model.paletteVisible else { return e }
                let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
                guard flags.isEmpty else { return e }
                // An input method composing text keeps its own Return / arrows / Esc.
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return e }
                let results = Array(PaletteSource.search(model.paletteQuery, model: model).prefix(50))
                switch e.keyCode {
                case 53: close(); return nil                                                          // esc
                case 125: selected = min(selected + 1, max(0, results.count - 1)); return nil         // ↓
                case 126: selected = max(selected - 1, 0); return nil                                // ↑
                case 36, 76: run(results); return nil                                                // return
                default:
                    if !focused { focused = true }   // typing goes to the search field
                    return e
                }
            }
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
        .onChange(of: model.paletteQuery) { _, _ in selected = 0 }
    }

    private func row(_ r: PaletteItem, selected: Bool, showKind: Bool = true) -> some View {
        HStack(spacing: 10) {
            r.icon
            Text(r.title).font(.system(size: T.k * 13, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
            if !r.subtitle.isEmpty { Text(r.subtitle).font(.system(size: T.k * 12)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 8)
            if !r.shortcut.isEmpty { ShortcutHint(r.shortcut) }
            if showKind { Text(r.kind).font(T.meta).foregroundStyle(T.text3).frame(width: 74, alignment: .trailing) }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(selected ? T.selection : .clear))
        .contentShape(Rectangle())
    }

    private func run(_ results: [PaletteItem]) {
        guard selected < results.count else { return }
        let r = results[selected]
        close()
        DispatchQueue.main.async { r.run() }
    }

    private func close() {
        model.paletteVisible = false
        model.paletteQuery = ""
        DispatchQueue.main.async { TerminalHost.shared.focusCurrent() }
    }
}
