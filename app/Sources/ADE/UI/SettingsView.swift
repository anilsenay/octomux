import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces", agents = "Agents", appearance = "Appearance", notifications = "Notifications"
    case features = "Features", keyboard = "Keyboard", advanced = "Advanced"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workspaces: return "square.stack"
        case .agents: return "sparkles"
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
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

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: $sel.scope) {
                    Text("Global").tag("global")
                    ForEach(model.state.workspaces) { w in Text("Workspace: \(w.name)").tag("workspace:\(w.id)") }
                }
                .labelsHidden()
                .padding(.bottom, 10)
                .help("Some settings can be overridden per workspace")
                ForEach(SettingsSection.allCases) { s in
                    Button { sel.section = s } label: {
                        Label(s.rawValue, systemImage: s.icon).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(sel.section == s ? Palette.selection : .clear))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 210)
            .background(Palette.sidebarBG)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(sel.section.rawValue).font(.largeTitle.weight(.semibold))
                    if sel.section.scoped {
                        Text(sel.scope == "global" ? "Applies everywhere unless a workspace or project overrides it." : "Overrides for this workspace. Unset values fall back to Global.")
                            .foregroundStyle(.secondary)
                    }
                    switch sel.section {
                    case .workspaces: WorkspacesSettings()
                    case .agents: AgentsSettings()
                    case .appearance: AppearanceSettings()
                    case .notifications: NotificationSettings()
                    case .features: FeatureSettings()
                    case .keyboard: KeyboardSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: Workspaces

struct WorkspacesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        Text("Workspaces group projects. Switch with the dots at the bottom of the sidebar, a two-finger swipe on the sidebar, or ⌃1…⌃9.")
            .foregroundStyle(.secondary)
        SettingsCard {
            ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                HStack {
                    Menu {
                        ForEach(Palette.colors, id: \.self) { c in Button(c) { model.updateWorkspace(w.id, ["color": c]) } }
                    } label: { Circle().fill(Color(hex: w.color)).frame(width: 12, height: 12) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    TextField("Name", text: Binding(get: { w.name }, set: { model.updateWorkspace(w.id, ["name": $0]) }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    Text("\(model.state.projects.filter { $0.workspaceId == w.id }.count) projects").foregroundStyle(.secondary)
                    Button { model.updateWorkspace(w.id, ["sort": w.sort - 2]) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain)
                    Button(role: .destructive) { model.deleteWorkspace(w.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(model.state.workspaces.count <= 1)
                }
                Divider()
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
            .foregroundStyle(.secondary)
        SettingsCard {
            ForEach(model.state.profiles.sorted { $0.sort < $1.sort }) { p in
                HStack(spacing: 10) {
                    AgentIcon(icon: p.icon, size: 14).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(([p.command] + p.args).joined(separator: " ") + (p.env.isEmpty ? "" : "  ·  " + p.env.map { "\($0)=\($1)" }.joined(separator: " ")))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(p.kind.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Button { update(p, ["pinned": !p.pinned]) } label: { Image(systemName: p.pinned ? "pin.fill" : "pin") }
                        .buttonStyle(.plain).help("Show as a shortcut next to +")
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { update(p, ["enabled": $0]) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button { editing = p } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain)
                }
                Divider()
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
                        Text(d["path"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
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
            .font(.caption).foregroundStyle(.secondary)
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
                if !resolved.isEmpty { Text(resolved).font(.caption).foregroundStyle(.secondary) }
                TextField("Arguments", text: $argsText).font(.system(.body, design: .monospaced))
                VStack(alignment: .leading) {
                    Text("Environment (KEY=value per line)").font(.caption)
                    TextEditor(text: $envText).font(.system(.body, design: .monospaced)).frame(height: 60)
                }
                Toggle("Run through my login shell (aliases, PATH)", isOn: $profile.viaLoginShell)
                if profile.kind == .generic {
                    TextField("Resume command after reboot (optional)", text: $profile.resumeTemplate).font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                if !profile.id.isEmpty {
                    Button("Delete", role: .destructive) {
                        model.client.call("profile.delete", ["id": profile.id], completion: model.report)
                        done()
                    }
                }
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(profile.command.isEmpty)
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
        if sel.scope.hasPrefix("workspace:"), let w = model.state.workspaces.first(where: { "workspace:\($0.id)" == sel.scope }) {
            SettingsCard {
                Text("Workspace color").font(.headline)
                HStack {
                    ForEach(Palette.colors, id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary, lineWidth: w.color == c ? 2 : 0))
                            .onTapGesture { model.updateWorkspace(w.id, ["color": c]) }
                    }
                }
            }
        }
        SettingsCard {
            Text("Terminal").font(.headline)
            Text("Uses Ghostty's config syntax (font-family, font-size, theme, cursor-style, …). Saved to \(Paths.terminalConfig.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $config).font(.system(size: 12, design: .monospaced)).frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            HStack {
                Button("Import from Ghostty") { importGhostty() }
                Button("Insert example") { config += (config.isEmpty ? "" : "\n") + "font-family = JetBrains Mono\nfont-size = 13\ntheme = Builtin Dark\ncursor-style = bar\nwindow-padding-x = 6\n" }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
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

// MARK: Notifications

struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection

    var body: some View {
        SettingsCard {
            toggle("Notifications", key: "notifications.enabled")
            Divider()
            toggle("Agent finished", key: "notifications.done")
            toggle("Agent needs input or permission", key: "notifications.needs_input")
            toggle("Agent error", key: "notifications.error")
            toggle("Long-running terminal command finished", key: "notifications.command_done")
            toggle("Program notifications (OSC 9 / 777)", key: "notifications.program")
            Divider()
            HStack {
                Text("Command threshold")
                Spacer()
                let v = Int(model.settingValue("notifications.command_threshold_secs", scope: sel.scope)?.number ?? 10)
                Stepper("\(v) s", value: Binding(get: { v }, set: { model.setSetting("notifications.command_threshold_secs", $0, scope: sel.scope) }), in: 1...600)
            }
            Divider()
            toggle("Sound", key: "notifications.sound")
            toggle("Dock badge", key: "notifications.badge")
        }
        Text("You are never notified about the pane you are looking at. Mute a single project from its right-click menu.")
            .font(.caption).foregroundStyle(.secondary)
        if !Notifier.shared.authorized {
            Text("System notifications are not authorized for ADE (or ADE runs outside its app bundle). Enable them in System Settings → Notifications.")
                .font(.caption).foregroundStyle(.orange)
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
            feature("Git worktrees", key: "features.worktrees", desc: "Run sessions in isolated git worktrees. (Planned for phase 2.)", available: false)
            Divider()
            feature("Remote workspaces", key: "features.remote", desc: "Run the daemon on a server and attach over SSH. (Planned for phase 2.)", available: false)
            Divider()
            feature("Chat view for agents", key: "features.chat", desc: "Switch an agent session between the terminal and a chat UI. (Experimental, phase 3.)", available: false)
            Divider()
            feature("Usage via OAuth API", key: "features.usage_oauth", desc: "Read Claude plan limits from Anthropic's usage endpoint even with no session open. (Phase 2.)", available: false)
        }
    }

    func feature(_ title: String, key: String, desc: String, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: Binding(get: { model.setting(key)?.bool ?? false }, set: { model.setSetting(key, $0) }))
                .toggleStyle(.switch).disabled(!available)
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Keyboard

struct KeyboardSettings: View {
    static let shortcuts: [(String, String)] = [
        ("⌘T", "New terminal tab"), ("⌘⇧T", "New tab with the first pinned agent"), ("⌘D", "Split right (terminal)"),
        ("⌘⇧D", "Split down (terminal)"), ("⌘W", "Close pane"), ("⌘⌥←↑→↓", "Move focus between panes"),
        ("⌘1…⌘9", "Go to tab"), ("⌘⇧[ / ⌘⇧]", "Previous / next tab"), ("⌃1…⌃9", "Go to workspace"),
        ("⌃⌘← / ⌃⌘→", "Previous / next workspace"), ("⌘⇧U", "Next session waiting for input"), ("⌘.", "Stop session"),
        ("⌘B", "Toggle sidebar"), ("⌘O", "Open project in default app"), ("⌘⇧O", "Add project"), ("⌘,", "Settings"),
    ]

    var body: some View {
        SettingsCard {
            ForEach(Self.shortcuts, id: \.0) { k, v in
                HStack {
                    Text(k).font(.system(.body, design: .monospaced)).frame(width: 130, alignment: .leading)
                    Text(v)
                    Spacer()
                }
            }
        }
        Text("Custom key bindings are planned. Terminal key handling (Ctrl/Option combos) goes straight to the program.")
            .font(.caption).foregroundStyle(.secondary)
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
            Text("Sessions keep running while the daemon restarts; they live in their own processes.").font(.caption).foregroundStyle(.secondary)
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
