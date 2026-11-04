import AppKit
import SwiftUI

/// Model, effort and permission choices for a chat session, mapped to the CLIs' own flags
/// (Claude: --model / --effort / --permission-mode; Codex: -m / -c model_reasoning_effort / -a).
/// "nil" everywhere means: no flag, the CLI's own settings decide.
struct ChatLaunchOptions: Codable, Equatable {
    var model: String?
    var effort: String?
    var permission: String?

    struct Choice: Identifiable { let id: String?; let title: String; let detail: String; var warn = false }

    static func models(_ kind: AgentKind) -> [Choice] {
        switch kind {
        case .claude: return [
            Choice(id: nil, title: "CLI default", detail: "Whatever Claude Code is set to"),
            Choice(id: "fable", title: "Fable", detail: ""),
            Choice(id: "opus", title: "Opus", detail: ""),
            Choice(id: "sonnet", title: "Sonnet", detail: ""),
            Choice(id: "haiku", title: "Haiku", detail: ""),
        ]
        default: return [Choice(id: nil, title: "CLI default", detail: "Whatever Codex is set to")]
        }
    }

    static func efforts(_ kind: AgentKind) -> [Choice] {
        switch kind {
        case .claude: return [Choice(id: nil, title: "Default", detail: "")] + ["low", "medium", "high", "xhigh", "max"].map { Choice(id: $0, title: label($0), detail: "") }
        case .codex: return [Choice(id: nil, title: "Default", detail: "")] + ["low", "medium", "high"].map { Choice(id: $0, title: label($0), detail: "") }
        default: return []
        }
    }

    static func permissions(_ kind: AgentKind) -> [Choice] {
        switch kind {
        case .claude: return [
            Choice(id: nil, title: "CLI settings", detail: "Use the permission mode from Claude Code's settings"),
            Choice(id: "manual", title: "Manual", detail: "Ask before every edit and command"),
            Choice(id: "dontAsk", title: "Don't ask", detail: "Deny anything not already allowed, without asking"),
            Choice(id: "acceptEdits", title: "Accept edits", detail: "Edit files without asking; ask for commands"),
            Choice(id: "plan", title: "Plan", detail: "Read and plan only, no changes"),
            Choice(id: "auto", title: "Auto", detail: "Claude decides what is safe to run"),
            Choice(id: "bypassPermissions", title: "Bypass", detail: "Never ask. Runs anything — use with care", warn: true),
        ]
        case .codex: return [
            Choice(id: nil, title: "CLI settings", detail: "Use the approval policy from Codex's config"),
            Choice(id: "untrusted", title: "Untrusted", detail: "Ask before anything but trusted commands"),
            Choice(id: "on-request", title: "On request", detail: "The model decides when to ask"),
            Choice(id: "never", title: "Never ask", detail: "Failures go back to the model"),
            Choice(id: "bypass", title: "Bypass", detail: "No approvals and no sandbox — use with care", warn: true),
        ]
        default: return []
        }
    }

    static func label(_ effort: String) -> String { effort == "xhigh" ? "X-High" : effort.prefix(1).uppercased() + effort.dropFirst() }

    /// The CLI flags for these choices, plus image attachments where the CLI takes them as flags.
    func args(_ kind: AgentKind, images: [String] = []) -> [String] {
        var a: [String] = []
        switch kind {
        case .claude:
            if let model { a += ["--model", model] }
            if let effort { a += ["--effort", effort] }
            if let permission { a += ["--permission-mode", permission] }
        case .codex:
            if let model { a += ["-m", model] }
            if let effort { a += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            if permission == "bypass" { a += ["--dangerously-bypass-approvals-and-sandbox"] }
            else if let permission { a += ["-a", permission] }
            for i in images { a += ["-i", i] }
        default: break
        }
        return a
    }

    // Remembered per agent kind.
    static func load(_ kind: AgentKind) -> ChatLaunchOptions {
        guard let d = UserDefaults.standard.data(forKey: "octomux.chatOpts.\(kind.rawValue)"),
              let v = try? JSONDecoder().decode(ChatLaunchOptions.self, from: d) else { return ChatLaunchOptions() }
        return v
    }
    func save(_ kind: AgentKind) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "octomux.chatOpts.\(kind.rawValue)") }
    }

    func modelTitle(_ kind: AgentKind) -> String {
        guard let model else { return "Default model" }
        return Self.models(kind).first { $0.id == model }?.title ?? model
    }
}

/// "Provider / Model / Effort" dropdown (the model chip).
struct ModelEffortPicker: View {
    @EnvironmentObject var model: AppModel
    let profiles: [Profile]
    let selected: Profile?
    @Binding var options: ChatLaunchOptions
    var workspace: Workspace? = nil
    var isDefault = false
    var makeDefault: () -> Void = {}
    let pickProfile: (Profile) -> Void
    @State private var custom = ""

    var body: some View {
        let kind = selected?.kind ?? .claude
        VStack(alignment: .leading, spacing: 1) {
            header("Provider")
            ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                OptionRow(number: i + 1, title: p.name, checked: p.id == selected?.id, icon: p.icon) { pickProfile(p) }
            }
            if let workspace, selected != nil {
                Button(action: makeDefault) {
                    HStack(spacing: 6) {
                        Image(systemName: isDefault ? "star.fill" : "star").font(.system(size: 10))
                        Text(isDefault ? "Default in \(workspace.name)" : "Make default in \(workspace.name)").font(.system(size: 11.5))
                    }
                    .foregroundStyle(isDefault ? T.amber : T.text2)
                    .padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isDefault).pointerCursor()
                .help("New chats in this workspace start with this agent (change it in Settings → Workspaces)")
            }
            Hairline().padding(.vertical, 4)
            header("Model")
            ForEach(ChatLaunchOptions.models(kind)) { c in
                OptionRow(title: c.title, detail: c.detail, checked: options.model == c.id, info: true) { options.model = c.id }
            }
            HStack(spacing: 6) {
                TextField("Other model id…", text: $custom).textFieldStyle(.plain).font(T.mono(11.5))
                    .onSubmit { let v = custom.trimmingCharacters(in: .whitespaces); if !v.isEmpty { options.model = v } }
                if let m = options.model, !ChatLaunchOptions.models(kind).contains(where: { $0.id == m }) {
                    Text(m).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            let efforts = ChatLaunchOptions.efforts(kind)
            if !efforts.isEmpty {
                Hairline().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Effort").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3)
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        ForEach(efforts) { c in
                            let on = options.effort == c.id
                            Button { options.effort = c.id } label: {
                                Text(c.title).font(.system(size: 11, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? T.text : T.text2)
                                    .padding(.horizontal, 7).frame(height: 22)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? T.border : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.hover))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .padding(5).frame(width: 380)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
    }
}

/// Permission mode dropdown (numbered; ⓘ shows what each does).
struct PermissionPicker: View {
    let kind: AgentKind
    @Binding var options: ChatLaunchOptions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Permissions").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
            ForEach(Array(ChatLaunchOptions.permissions(kind).enumerated()), id: \.offset) { i, c in
                OptionRow(number: i + 1, title: c.title, detail: c.detail, checked: options.permission == c.id, warn: c.warn, info: true) {
                    options.permission = c.id; done()
                }
            }
        }
        .padding(5).frame(width: 300)
    }
}

struct OptionRow: View {
    var number: Int? = nil
    let title: String
    var detail = ""
    let checked: Bool
    var icon: String? = nil
    var warn = false
    var info = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let number { Text("\(number)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(T.text3).frame(width: 12) }
                if let icon { AgentIcon(icon: icon, size: 12) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: checked ? .semibold : .regular)).foregroundStyle(warn ? T.amber : T.text)
                    if !detail.isEmpty && !info { Text(detail).font(.system(size: 10.5)).foregroundStyle(T.text3).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(T.text) }
                if info, !detail.isEmpty {
                    Image(systemName: "info.circle").font(.system(size: 10.5)).foregroundStyle(T.text3).help(detail)
                }
            }
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(checked ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(HoverFill()).pointerCursor()
        .help(detail)
    }
}

/// Files attached to a chat message: chips above the text, removable.
struct AttachmentChips: View {
    @Binding var files: [URL]
    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { u in
                        HStack(spacing: 5) {
                            if let img = Self.thumbnail(u) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            } else {
                                FileIcon(name: u.lastPathComponent)
                            }
                            Text(u.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(T.text).lineLimit(1)
                            Button { files.removeAll { $0 == u } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                            }
                            .buttonStyle(.plain).pointerCursor().help("Remove")
                        }
                        .padding(.horizontal, 7).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.border))
                        .help(u.path)
                    }
                }
            }
        }
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]
    static func isImage(_ u: URL) -> Bool { imageExts.contains(u.pathExtension.lowercased()) }
    static func thumbnail(_ u: URL) -> NSImage? { isImage(u) ? NSImage(contentsOf: u) : nil }

    /// Open panel for files to attach.
    static func pick() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Attach"
        return p.runModal() == .OK ? p.urls : []
    }

    /// Files copied in Finder, else an image on the clipboard (screenshot).
    static func pasted() -> [URL] {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls }
        return pastedImage().map { [$0] } ?? []
    }

    /// An image on the clipboard (screenshot) saved as a PNG to attach.
    static func pastedImage() -> URL? {
        guard let img = NSImage(pasteboard: NSPasteboard.general), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("pasted-\(f.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// The message with attachments: Claude reads `@path` references (images included); Codex gets
    /// images as `-i` flags (see `ChatLaunchOptions.args`) and other files as plain paths.
    static func message(_ text: String, files: [URL], kind: AgentKind) -> String {
        let refs = files.filter { kind != .codex || !isImage($0) }.map { kind == .claude ? "@" + quoted($0.path) : $0.path }
        return refs.isEmpty ? text : text + "\n\n" + refs.joined(separator: " ")
    }

    private static func quoted(_ p: String) -> String { p.contains(" ") ? "\"\(p)\"" : p }
}

/// Reads and rewrites one option in an agent's argument list (`--model opus`, `--model=opus`, `-c key=value`),
/// leaving every other argument where it is.
enum ArgFlags {
    /// The value of the last occurrence of any of `names`.
    static func value(_ args: [String], _ names: [String]) -> String? {
        var out: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if names.contains(a), i + 1 < args.count { out = args[i + 1]; i += 2; continue }
            if let n = names.first(where: { a.hasPrefix($0 + "=") }) { out = String(a.dropFirst(n.count + 1)) }
            i += 1
        }
        return out
    }

    /// Removes every occurrence of the option, then appends `names[0] value` when there is a value.
    static func set(_ args: [String], _ names: [String], _ value: String?) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if names.contains(a) { i += i + 1 < args.count ? 2 : 1; continue }
            if names.contains(where: { a.hasPrefix($0 + "=") }) { i += 1; continue }
            out.append(a)
            i += 1
        }
        if let value, let n = names.first { out += [n, value] }
        return out
    }

    static func has(_ args: [String], _ flag: String) -> Bool { args.contains(flag) }

    static func setFlag(_ args: [String], _ flag: String, _ on: Bool) -> [String] {
        let rest = args.filter { $0 != flag }
        return on ? rest + [flag] : rest
    }

    /// A `-c key=value` config override (Codex): its value without quotes.
    static func config(_ args: [String], _ key: String) -> String? {
        var out: String?
        var i = 0
        while i < args.count {
            if ["-c", "--config"].contains(args[i]), i + 1 < args.count, args[i + 1].hasPrefix(key + "=") {
                out = String(args[i + 1].dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                i += 2; continue
            }
            i += 1
        }
        return out
    }

    static func setConfig(_ args: [String], _ key: String, _ value: String?) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if ["-c", "--config"].contains(args[i]), i + 1 < args.count, args[i + 1].hasPrefix(key + "=") { i += 2; continue }
            out.append(args[i])
            i += 1
        }
        if let value { out += ["-c", "\(key)=\"\(value)\""] }
        return out
    }
}

/// Start options of an agent profile (Settings → Agents → edit): pickers over the same choices as a new chat,
/// written into the profile's arguments.
struct ProfileStartOptions {
    var kind: AgentKind
    var args: [String]

    var model: String? {
        get { ArgFlags.value(args, kind == .codex ? ["--model", "-m"] : ["--model"]) }
        set { args = ArgFlags.set(args, kind == .codex ? ["--model", "-m"] : ["--model"], newValue) }
    }
    var effort: String? {
        get { kind == .codex ? ArgFlags.config(args, "model_reasoning_effort") : ArgFlags.value(args, ["--effort"]) }
        set { args = kind == .codex ? ArgFlags.setConfig(args, "model_reasoning_effort", newValue) : ArgFlags.set(args, ["--effort"], newValue) }
    }
    static let codexBypass = "--dangerously-bypass-approvals-and-sandbox"
    var permission: String? {
        get {
            if kind == .codex { return ArgFlags.has(args, Self.codexBypass) ? "bypass" : ArgFlags.value(args, ["--ask-for-approval", "-a"]) }
            return ArgFlags.has(args, "--dangerously-skip-permissions") ? "bypassPermissions" : ArgFlags.value(args, ["--permission-mode"])
        }
        set {
            if kind == .codex {
                args = ArgFlags.setFlag(args, Self.codexBypass, newValue == "bypass")
                args = ArgFlags.set(args, ["--ask-for-approval", "-a"], newValue == "bypass" ? nil : newValue)
            } else {
                args = ArgFlags.setFlag(args, "--dangerously-skip-permissions", false)
                args = ArgFlags.set(args, ["--permission-mode"], newValue)
            }
        }
    }
    /// Codex only.
    var sandbox: String? {
        get { ArgFlags.value(args, ["--sandbox", "-s"]) }
        set { args = ArgFlags.set(args, ["--sandbox", "-s"], newValue) }
    }
    static let sandboxes: [ChatLaunchOptions.Choice] = [
        .init(id: nil, title: "CLI settings", detail: "Use the sandbox from Codex's config"),
        .init(id: "read-only", title: "Read only", detail: "No writes, no network"),
        .init(id: "workspace-write", title: "Workspace write", detail: "Writes inside the project"),
        .init(id: "danger-full-access", title: "Full access", detail: "No sandbox — use with care", warn: true),
    ]
}
