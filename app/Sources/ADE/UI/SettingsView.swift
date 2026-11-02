import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces", agents = "Agents", appearance = "Appearance", notifications = "Notifications"
    case hosts = "Hosts", features = "Features", keyboard = "Keyboard", advanced = "Advanced"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workspaces: return "square.stack"
        case .agents: return "sparkles"
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
        case .hosts: return "network"
        case .features: return "flask"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape.2"
        }
    }
    /// Sections whose settings can be overridden per workspace.
    var scoped: Bool { self == .notifications || self == .appearance }
}

final class SettingsWindow {
    static var window: NSWindow?
    static let selection = SettingsSelection()

    static func show(section: SettingsSection? = nil) {
        if let section { selection.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared).environmentObject(selection))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var section: SettingsSection = .workspaces
    /// "global" or "workspace:<id>"
    @Published var scope: String = "global"
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Spacer().frame(height: 30)
                SectionLabel("Scope").padding(.horizontal, 10).padding(.bottom, 2)
                Picker("", selection: $sel.scope) {
                    Text("Global").tag("global")
                    ForEach(model.state.workspaces) { w in Text("Workspace: \(w.name)").tag("workspace:\(w.id)") }
                }
                .labelsHidden()
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
                .help("Some settings can be overridden per workspace")
                ForEach(SettingsSection.allCases) { s in
                    Button { sel.section = s } label: {
                        HStack(spacing: 9) {
                            Image(systemName: s.icon).font(.system(size: 12)).frame(width: 16)
                                .foregroundStyle(sel.section == s ? T.accent : T.text3)
                            Text(s.rawValue).font(.system(size: 13, weight: sel.section == s ? .semibold : .regular))
                                .foregroundStyle(sel.section == s ? T.text : T.text2)
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: T.m.rowH)
                        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(sel.section == s ? T.selection : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 212)
            .background(T.frame)
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(sel.section.rawValue).font(T.title).foregroundStyle(T.text).padding(.top, 8)
                    if sel.section.scoped {
                        Text(sel.scope == "global" ? "Applies everywhere unless a workspace or project overrides it." : "Overrides for this workspace. Unset values fall back to Global.")
                            .font(T.body).foregroundStyle(T.text2)
                    }
                    switch sel.section {
                    case .workspaces: WorkspacesSettings()
                    case .agents: AgentsSettings()
                    case .appearance: AppearanceSettings()
                    case .notifications: NotificationSettings()
                    case .hosts: HostsSettings()
                    case .features: FeatureSettings()
                    case .keyboard: KeyboardSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .padding(.horizontal, 30).padding(.vertical, 24)
                .frame(maxWidth: 700, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .background(T.surface)
        }
        .foregroundStyle(T.text)
        .tint(T.accent)
        .ignoresSafeArea()
        .id(theme.revision)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: max(T.m.cardR, 4), style: .continuous).fill(T.frame.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: max(T.m.cardR, 4), style: .continuous).stroke(T.border))
    }
}

// MARK: Workspaces

struct WorkspacesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        Text("Workspaces group projects. Switch with the dots at the bottom of the sidebar, a two-finger swipe on the sidebar, or ⌃1…⌃9.")
            .foregroundStyle(T.text2)
        SettingsCard {
            ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                HStack {
                    Menu {
                        ForEach(Palette.colors, id: \.self) { c in Button(c) { model.updateWorkspace(w.id, ["color": c]) } }
                    } label: { Circle().fill(Color(hex: w.color)).frame(width: 12, height: 12) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    TextField("Name", text: Binding(get: { w.name }, set: { model.updateWorkspace(w.id, ["name": $0]) }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    Text("\(model.state.projects.filter { $0.workspaceId == w.id }.count) projects").foregroundStyle(T.text2)
                    let def = model.defaultChatProfile(workspace: w.id)
                    Menu {
                        Button((def == nil ? "✓ " : "") + "Last used") { model.setDefaultChatProfile(nil, workspace: w.id) }
                        Divider()
                        ForEach(model.chatProfiles) { p in
                            Button((def?.id == p.id ? "✓ " : "") + p.name) { model.setDefaultChatProfile(p.id, workspace: w.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let def { AgentIcon(icon: def.icon, size: 11) }
                            Text(def?.name ?? "Last used agent").font(.system(size: 12)).foregroundStyle(T.text2)
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Agent the New Chat screen starts with in this workspace")
                    Button { model.updateWorkspace(w.id, ["sort": w.sort - 2]) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain)
                    Button(role: .destructive) { model.deleteWorkspace(w.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(model.state.workspaces.count <= 1)
                }
                Hairline()
            }
            HStack {
                TextField("New workspace name", text: $newName).onSubmit(add)
                Button("Add", action: add).disabled(newName.isEmpty)
            }
        }
        let archived = model.state.projects.filter { $0.archived }
        if !archived.isEmpty {
            Text("Archived projects").font(.headline)
            SettingsCard {
                ForEach(archived) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Button("Unarchive") { model.updateProject(p.id, ["archived": false]) }
                    }
                }
            }
        }
    }

    func add() {
        guard !newName.isEmpty else { return }
        model.createWorkspace(name: newName)
        newName = ""
    }
}

// MARK: Agents

struct AgentsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Profile?
    @State private var detected: [[String: Any]] = []

    var body: some View {
        Text("Agents appear in the + menu. Pinned agents also get a one-click button in the tab bar. Claude and Codex sessions resume their conversation after a crash or reboot.")
            .foregroundStyle(T.text2)
        SettingsCard {
            ForEach(model.state.profiles.filter { model.owner[$0.id] == nil }.sorted { $0.sort < $1.sort }) { p in
                HStack(spacing: 10) {
                    AgentIcon(icon: p.icon, size: 14).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(([p.command] + p.args).joined(separator: " ") + (p.env.isEmpty ? "" : "  ·  " + p.env.map { "\($0)=\($1)" }.joined(separator: " ")))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(T.text2).lineLimit(1)
                    }
                    Spacer()
                    Text(p.kind.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(T.hover))
                    Button { update(p, ["pinned": !p.pinned]) } label: { Image(systemName: p.pinned ? "pin.fill" : "pin") }
                        .buttonStyle(.plain).help("Show as a shortcut next to +")
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { update(p, ["enabled": $0]) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button { editing = p } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain)
                }
                Hairline()
            }
            Button { editing = Profile(id: "", name: "", icon: "terminal", kind: .generic, command: "", args: [], env: [:], viaLoginShell: true, resumeTemplate: "", enabled: true, pinned: false, sort: 99) } label: {
                Label("Add custom agent…", systemImage: "plus")
            }.buttonStyle(.plain)
        }
        let notAdded = detected.filter { d in
            let cmd = d["command"] as? String ?? ""
            return (d["installed"] as? Bool) == true && !model.state.profiles.contains { $0.command == cmd }
        }
        if !notAdded.isEmpty {
            Text("Installed on this Mac").font(.headline)
            SettingsCard {
                ForEach(Array(notAdded.enumerated()), id: \.offset) { _, d in
                    HStack {
                        AgentIcon(icon: d["icon"] as? String ?? "agent")
                        Text(d["command"] as? String ?? "")
                        Text(d["path"] as? String ?? "").font(.caption).foregroundStyle(T.text2)
                        Spacer()
                        Button("Add") {
                            model.client.call("profile.create", ["name": d["command"] as? String ?? "", "command": d["command"] as? String ?? "",
                                                                 "icon": d["icon"] as? String ?? "agent", "kind": d["kind"] as? String ?? "generic"])
                        }
                    }
                }
            }
        }
        Text("Tip: for a second Claude account, duplicate the claude agent and set CLAUDE_CONFIG_DIR, or point Command at a wrapper like `claude-work`.")
            .font(.caption).foregroundStyle(T.text2)
            .sheet(item: $editing) { p in ProfileEditor(profile: p) { editing = nil } }
            .onAppear {
                model.client.call("profile.detect") { r in
                    if case .success(let v) = r { detected = v as? [[String: Any]] ?? [] }
                }
            }
    }

    func update(_ p: Profile, _ fields: [String: Any]) {
        var f = fields
        f["id"] = p.id
        model.client.call("profile.update", f, completion: model.report)
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @State var profile: Profile
    let done: () -> Void
    @State private var argsText = ""
    @State private var envText = ""
    @State private var resolved = ""

    init(profile: Profile, done: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.id.isEmpty ? "Add agent" : "Edit \(profile.name)").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                Picker("Type", selection: $profile.kind) {
                    Text("Claude Code").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                    Text("Other").tag(AgentKind.generic)
                }
                Picker("Icon", selection: $profile.icon) {
                    ForEach(["claude", "codex", "gemini", "terminal", "agent"], id: \.self) { i in Text(i).tag(i) }
                }
                TextField("Command", text: $profile.command).font(.system(.body, design: .monospaced))
                    .onSubmit(check)
                if !resolved.isEmpty { Text(resolved).font(.caption).foregroundStyle(T.text2) }
                TextField("Arguments", text: $argsText).font(.system(.body, design: .monospaced))
                VStack(alignment: .leading) {
                    Text("Environment (KEY=value per line)").font(.caption)
                    TextEditor(text: $envText).font(.system(.body, design: .monospaced)).frame(height: 60)
                }
                Toggle("Run through my login shell (aliases, PATH)", isOn: $profile.viaLoginShell)
                if profile.kind == .claude {
                    Toggle("Read usage limits through Claude's status line (runs your own status line too)", isOn: $profile.statusline)
                }
                if !profile.id.isEmpty {
                    Toggle("Always show usage limits in the status bar (workspaces without their own list)", isOn: Binding(
                        get: { AppModel.shared.alwaysShowList(scope: "global")?.contains(profile.id) ?? false },
                        set: { AppModel.shared.setUsageAlwaysShown(profile.id, $0, scope: "global") }))
                }
                if profile.kind == .generic {
                    TextField("Resume command after reboot (optional)", text: $profile.resumeTemplate).font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                if !profile.id.isEmpty {
                    Button(role: .destructive) {
                        model.client.call("profile.delete", ["id": profile.id], completion: model.report)
                        done()
                    } label: { Text("Delete").foregroundStyle(T.red) }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(profile.command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            argsText = profile.args.map(\.shellQuoted).joined(separator: " ")
            envText = profile.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            check()
        }
    }

    func check() {
        guard !profile.command.isEmpty else { return }
        model.client.call("profile.check", ["command": profile.command.split(separator: " ").first.map(String.init) ?? profile.command]) { r in
            if case .success(let v) = r { resolved = ((v as? [String: Any])?["path"] as? String).map { "Found: \($0)" } ?? "Not found on PATH (it may still work through your login shell)" }
        }
    }

    func save() {
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        var params: [String: Any] = [
            "name": profile.name, "kind": profile.kind.rawValue, "icon": profile.icon, "command": profile.command,
            "args": ShellWords.split(argsText), "env": env, "via_login_shell": profile.viaLoginShell,
            "resume_template": profile.resumeTemplate, "enabled": profile.enabled, "pinned": profile.pinned,
            "statusline": profile.statusline,
        ]
        if profile.id.isEmpty {
            model.client.call("profile.create", params, completion: model.report)
        } else {
            params["id"] = profile.id
            model.client.call("profile.update", params, completion: model.report)
        }
        done()
    }
}

enum ShellWords {
    /// Splits a command line into words (handles '…', "…" and backslash escapes).
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch)
            inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection
    @State private var config = ""
    @State private var status = ""

    var body: some View {
        if sel.scope == "global" {
            ThemePicker()
        }
        if sel.scope == "global" || sel.scope.hasPrefix("workspace:") {
            SceneSettingsCard(scope: sel.scope)
        }
        if sel.scope.hasPrefix("workspace:"), let w = model.state.workspaces.first(where: { "workspace:\($0.id)" == sel.scope }) {
            SettingsCard {
                Text("Workspace color").font(.headline)
                HStack {
                    ForEach(Palette.colors, id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(T.text, lineWidth: w.color == c ? 2 : 0))
                            .onTapGesture { model.updateWorkspace(w.id, ["color": c]) }
                    }
                }
            }
        }
        SettingsCard {
            Text("Terminal").font(.headline)
            Text("Uses Ghostty's config syntax (font-family, font-size, cursor-style, …). The theme's colors are applied on top unless “Use theme colors” is off. Saved to \(Paths.terminalConfig.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                .font(.caption).foregroundStyle(T.text2)
            TextEditor(text: $config).font(T.mono(12)).frame(height: 220)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
            HStack {
                Button("Import from Ghostty") { importGhostty() }
                Button("Insert example") { config += (config.isEmpty ? "" : "\n") + "font-family = JetBrains Mono\nfont-size = 13\ncursor-style = bar\n" }
                Spacer()
                Text(status).font(.caption).foregroundStyle(T.text2)
                Button("Apply") { save() }.keyboardShortcut("s")
            }
        }
        .onAppear { config = (try? String(contentsOf: Paths.terminalConfig, encoding: .utf8)) ?? "" }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.terminalConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try config.write(to: Paths.terminalConfig, atomically: true, encoding: .utf8)
            GhosttyRuntime.shared.reloadConfig()
            status = "Applied"
        } catch { status = "\(error)" }
    }

    func importGhostty() {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.config/ghostty/config", "\(home)/.config/ghostty/config.ghostty",
                          "\(home)/Library/Application Support/com.mitchellh.ghostty/config"]
        for c in candidates {
            if let s = try? String(contentsOfFile: c, encoding: .utf8) {
                // Keybinds and window options belong to Ghostty.app, not to us.
                let kept = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !(t.hasPrefix("keybind") || t.hasPrefix("window-") && !t.hasPrefix("window-padding") || t.hasPrefix("quick-terminal") || t.hasPrefix("macos-"))
                }
                config = "# Imported from \(c)\n" + kept.joined(separator: "\n")
                status = "Imported — press Apply"
                return
            }
        }
        status = "No Ghostty config found"
    }
}

struct ThemePicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = ThemeStore.shared

    var body: some View {
        SettingsCard {
            Text("Theme").font(.headline)
            HStack(spacing: 12) {
                ForEach(Themes.all) { p in
                    let on = p.id == store.preset.id
                    Button { store.set(theme: p.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemeSwatch(preset: p)
                            Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.text)
                            Text(p.summary).font(.system(size: 11)).foregroundStyle(T.text2).lineLimit(2, reservesSpace: true)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? T.selection : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? T.accent : T.border, lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Appearance")
                Spacer()
                Picker("", selection: Binding(get: { store.mode }, set: { store.set(mode: $0) })) {
                    Text("System").tag("system"); Text("Dark").tag("dark"); Text("Light").tag("light")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if let sc = store.scene {
                Text("The current workspace's scene (\(sc.name)) is \(sc.dark ? "dark" : "light"), so it decides while it is shown.")
                    .font(.caption).foregroundStyle(T.text3)
            }
            Toggle("Use theme colors in the terminal", isOn: Binding(
                get: { model.settingValue("appearance.terminal_colors", scope: "global")?.bool ?? true },
                set: { model.setSetting("appearance.terminal_colors", $0 ? nil : false) }))
        }
    }
}

/// Miniature of a preset: frame, sidebar rows, terminal card, accent.
struct ThemeSwatch: View {
    let preset: ThemePreset
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let c = scheme == .dark ? preset.dark : preset.light
        let r = preset.metrics.cardR > 0 ? 4.0 : 0.0
        HStack(spacing: preset.metrics.inset > 0 ? 4 : 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i == 1 ? Color(nsColor: c.accent) : Color(nsColor: c.text3).opacity(0.5))
                        .frame(width: i == 0 ? 26 : 34, height: 3)
                }
                Spacer()
            }
            .padding(6)
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: i == 4 ? c.accent : c.termFg).opacity(i == 4 ? 1 : 0.55))
                        .frame(width: [60, 44, 70, 30, 6][i], height: 3)
                }
                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: r).fill(Color(nsColor: c.surface)))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(Color(nsColor: c.border)))
            .padding(.vertical, preset.metrics.inset > 0 ? 4 : 0)
            .padding(.trailing, preset.metrics.inset > 0 ? 4 : 0)
        }
        .frame(width: 150, height: 74)
        .background(Color(nsColor: c.frame))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color(nsColor: c.border)))
    }
}

// MARK: Notifications

struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection

    var body: some View {
        SettingsCard {
            toggle("Notifications", key: "notifications.enabled")
            Hairline()
            toggle("Agent finished", key: "notifications.done")
            toggle("Agent needs input or permission", key: "notifications.needs_input")
            toggle("Agent error", key: "notifications.error")
            toggle("Long-running terminal command finished", key: "notifications.command_done")
            toggle("Program notifications (OSC 9 / 777)", key: "notifications.program")
            Hairline()
            HStack {
                Text("Command threshold")
                Spacer()
                let v = Int(model.settingValue("notifications.command_threshold_secs", scope: sel.scope)?.number ?? 10)
                Stepper("\(v) s", value: Binding(get: { v }, set: { model.setSetting("notifications.command_threshold_secs", $0, scope: sel.scope) }), in: 1...600)
            }
            Hairline()
            toggle("Sound", key: "notifications.sound")
            toggle("Dock badge", key: "notifications.badge")
        }
        Text("You are never notified about the pane you are looking at. Mute a single project from its right-click menu.")
            .font(.caption).foregroundStyle(T.text2)
        if !Notifier.shared.authorized {
            Text("System notifications are not authorized for ADE (or ADE runs outside its app bundle). Enable them in System Settings → Notifications.")
                .font(.caption).foregroundStyle(T.amber)
        }
    }

    func toggle(_ title: String, key: String) -> some View {
        let explicit = model.settingValue(key, scope: sel.scope)?.bool
        let inherited = sel.scope == "global" ? true : (model.settingValue(key, scope: "global")?.bool ?? true)
        return HStack {
            Toggle(title, isOn: Binding(get: { explicit ?? inherited }, set: { model.setSetting(key, $0, scope: sel.scope) }))
                .toggleStyle(.switch)
            if sel.scope != "global", explicit != nil {
                Button("Reset") { model.setSetting(key, nil, scope: sel.scope) }.controlSize(.small)
            }
        }
    }
}

// MARK: Features

struct FeatureSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsCard {
            feature("Git worktrees", key: "features.worktrees", desc: "New Worktree… in the project menu and worktree groups in the sidebar.", available: true, defaultOn: true)
            Hairline()
            feature("Remote hosts", key: "features.remote", desc: "Connect the window to an ADE daemon on another machine over SSH (Settings → Hosts).", available: true, defaultOn: true)
            Hairline()
            feature("Hosts side by side", key: "features.multi_host", desc: "Show projects of selected remote hosts next to this Mac's, in the workspace with the same name (Settings → Hosts → Show here).", available: true, defaultOn: false)
            Hairline()
            feature("Chat view for Claude", key: "features.chat", desc: "Show a Claude session as a chat (its transcript) and type into the same session. ⌘⇧C.", available: true, defaultOn: true)
            Hairline()
            feature("Usage via OAuth API", key: "features.usage_oauth", desc: "Read Claude plan limits from Anthropic's usage endpoint even with no session open. (Phase 2.)", available: false)
        }
    }

    func feature(_ title: String, key: String, desc: String, available: Bool, defaultOn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: Binding(get: { model.setting(key)?.bool ?? defaultOn }, set: { model.setSetting(key, $0) }))
                .toggleStyle(.switch).disabled(!available)
            Text(desc).font(.caption).foregroundStyle(T.text2)
        }
    }
}

// MARK: Keyboard

struct KeyboardSettings: View {
    @ObservedObject var kb = KeyBindings.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var filter = ""

    var body: some View {
        Text("Click a shortcut to record a new one. Esc cancels, Delete removes it. Keys not bound here go straight to the terminal program.")
            .font(T.body).foregroundStyle(T.text2)
        TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        let groups = Dictionary(grouping: kb.commands.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }, by: \.group)
        ForEach(["ADE", "File", "Session", "View", "Window"].filter { groups[$0] != nil }, id: \.self) { g in
            SettingsCard {
                SectionLabel(g)
                ForEach(groups[g] ?? []) { c in
                    HStack {
                        Text(c.title).font(T.body)
                        if kb.isOverridden(c.id) {
                            Text("custom").font(T.caption).foregroundStyle(T.accent)
                        }
                        Spacer()
                        if let sc = kb.current(c.id), recording != c.id, let other = kb.conflict(sc, except: c.id) {
                            Text("also: \(other.title)").font(T.caption).foregroundStyle(T.amber).lineLimit(1)
                        }
                        Button { startRecording(c.id) } label: {
                            Text(recording == c.id ? "Press keys…" : (kb.current(c.id)?.display ?? "—"))
                                .font(T.mono(12, .medium))
                                .foregroundStyle(recording == c.id ? T.accent : T.text)
                                .frame(minWidth: 86)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(recording == c.id ? T.accent : T.border))
                        }
                        .buttonStyle(.plain)
                        Button { kb.reset(c.id) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10)) }
                            .buttonStyle(ChromeButtonStyle()).help("Reset to default")
                            .opacity(kb.isOverridden(c.id) ? 1 : 0).disabled(!kb.isOverridden(c.id))
                    }
                    .frame(height: 28)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let id = recording else { return e }
            if e.keyCode == 53 { stopRecording(); return nil }                           // esc
            if e.keyCode == 51 || e.keyCode == 117 { kb.set(id, nil); stopRecording(); return nil }  // delete
            if let sc = Shortcut(event: e) { kb.set(id, sc); stopRecording() }
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }
}

// MARK: Hosts

struct HostsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var hosts = HostStore.all
    @State private var editing: Host?
    @State private var status: [String: String] = [:]

    var body: some View {
        Text("A host is a machine running its own ADE daemon. ADE reaches it with `ssh <host> ade stdio` (no open ports); panes attach with `ssh -t`. Sessions keep running there when you disconnect. Install `ade` on the host first (Linux build: see README).")
            .font(T.body).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
        SettingsCard {
            ForEach(HostStore.withLocal) { h in
                HStack(spacing: 10) {
                    Image(systemName: h.isRemote ? "server.rack" : "laptopcomputer").foregroundStyle(T.text3).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name).font(.system(size: 13, weight: .semibold))
                        Text(h.subtitle).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                    }
                    Spacer()
                    if let st = status[h.id] { Text(st).font(T.caption).foregroundStyle(st.hasPrefix("OK") ? T.green : T.red).lineLimit(1) }
                    if h.isRemote {
                        Button("Test") { test(h) }.buttonStyle(SecondaryButtonStyle())
                        Button { editing = h } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(ChromeButtonStyle())
                        Button { HostStore.all.removeAll { $0.id == h.id }; hosts = HostStore.all; if model.hostId == h.id { model.switchHost("local") } } label: { Image(systemName: "trash") }
                            .buttonStyle(ChromeButtonStyle())
                    }
                    if h.isRemote, model.multiHost, model.hostId != h.id {
                        Toggle("Show here", isOn: Binding(get: { HostStore.attached.contains(h.id) }, set: { model.setAttached(h.id, $0); hosts = HostStore.all }))
                            .toggleStyle(.checkbox).font(T.caption)
                    }
                    if model.hostId == h.id {
                        Text("Connected").font(T.caption).foregroundStyle(T.accent)
                    } else {
                        Button("Connect") { model.switchHost(h.id) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .frame(minHeight: 40)
            }
            Button { editing = Host(id: String(UUID().uuidString.prefix(8)).lowercased(), name: "", kind: "ssh") } label: {
                Label("Add host…", systemImage: "plus")
            }.buttonStyle(.plain).foregroundStyle(T.text2)
        }
        Text("Changes / History / Files and worktrees work on remote projects too: the host's daemon runs git (allowlisted commands) and serves file previews. Open in… is local only.")
            .font(T.caption).foregroundStyle(T.text3)
        .sheet(item: $editing) { h in
            HostEditor(host: h) { saved in
                if let saved {
                    var all = HostStore.all
                    if let i = all.firstIndex(where: { $0.id == saved.id }) { all[i] = saved } else { all.append(saved) }
                    HostStore.all = all
                    hosts = all
                }
                editing = nil
            }
        }
    }

    private func test(_ h: Host) {
        status[h.id] = "Testing…"
        DispatchQueue.global().async {
            var msg = "Failed: no answer"
            if let argv = h.controlArgv, let s = ProcessLineStream(argv: argv) {
                let req = try! JSONSerialization.data(withJSONObject: ["id": 1, "method": "hello", "params": [:]])
                if s.writeLine(req), let line = s.readLine(), let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let r = obj["result"] as? [String: Any] { msg = "OK · daemon \(r["version"] ?? r["protocol"] ?? "")" } else { msg = "Failed: \(obj["error"] ?? "?")" }
                }
                s.close()
            }
            DispatchQueue.main.async { status[h.id] = msg }
        }
    }
}

struct HostEditor: View {
    @State var host: Host
    let done: (Host?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host.name.isEmpty ? "Add host" : "Edit host").font(T.title)
            TextField("Name (e.g. devbox)", text: $host.name).textFieldStyle(.roundedBorder)
            Picker("Connect with", selection: $host.kind) {
                Text("SSH").tag("ssh")
                Text("Custom command").tag("command")
            }
            .pickerStyle(.segmented)
            if host.kind == "ssh" {
                TextField("SSH destination (user@host, or a Host from ~/.ssh/config)", text: $host.target).textFieldStyle(.roundedBorder)
                TextField("Extra ssh options (optional, e.g. -p 2222 -i ~/.ssh/devbox)", text: Binding(get: { host.sshOptions ?? "" }, set: { host.sshOptions = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(T.mono(12))
                Text("Uses your ssh config and keys; BatchMode, so keys/agent must work without prompts.").font(T.caption).foregroundStyle(T.text3)
            } else {
                TextField("Command prefix (e.g. ssh -p 2222 box, or env ADE_HOME=/tmp/x)", text: $host.prefix).textFieldStyle(.roundedBorder).font(T.mono(12))
                TextField("Prefix for panes, if it needs a TTY (e.g. ssh -t -p 2222 box) — optional", text: Binding(get: { host.attachPrefix ?? "" }, set: { host.attachPrefix = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(T.mono(12))
            }
            TextField("Path of ade on the host", text: $host.ade).textFieldStyle(.roundedBorder).font(T.mono(12))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { done(host) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(host.name.isEmpty || (host.kind == "ssh" ? host.target.isEmpty : host.prefix.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(T.surface)
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var info = ""

    var body: some View {
        SettingsCard {
            Text("Daemon").font(.headline)
            Text(info.isEmpty ? "…" : info).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Restart Daemon") {
                    model.client.call("daemon.shutdown") { _ in
                        DispatchQueue.global().async { _ = DaemonClient.ensureDaemon(); DispatchQueue.main.async { refresh() } }
                    }
                }
                Button("Open Data Folder") { NSWorkspace.shared.open(Paths.home) }
                Button("Open Logs") { NSWorkspace.shared.open(Paths.home.appendingPathComponent("logs")) }
            }
            Text("Sessions keep running while the daemon restarts; they live in their own processes.").font(.caption).foregroundStyle(T.text2)
        }
        .onAppear(perform: refresh)
    }

    func refresh() {
        model.client.call("hello") { r in
            if case .success(let v) = r, let d = v as? [String: Any] {
                info = "pid \(d["pid"] ?? "?") · protocol v\(d["version"] ?? "?")\nhome \(d["home"] ?? "")\ncli \(Paths.adeBinary)"
            }
        }
    }
}
