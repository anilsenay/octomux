import AppKit

/// A key + modifiers, stored as "cmd+shift+t" / "ctrl+cmd+left".
struct Shortcut: Equatable {
    var key: String              // menu keyEquivalent (lowercase char or an NS*FunctionKey char)
    var mods: NSEvent.ModifierFlags

    static let names: [(String, Int)] = [("left", NSLeftArrowFunctionKey), ("right", NSRightArrowFunctionKey),
                                         ("up", NSUpArrowFunctionKey), ("down", NSDownArrowFunctionKey)]

    init(key: String, mods: NSEvent.ModifierFlags) {
        self.key = key
        self.mods = mods.intersection([.command, .shift, .option, .control])
    }

    init?(string: String) {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for part in string.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "alt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            default:
                if let f = Shortcut.names.first(where: { $0.0 == part }) { key = String(Character(UnicodeScalar(f.1)!)) }
                else if part == "plus" { key = "+" }
                else { key = part }
            }
        }
        guard !key.isEmpty else { return nil }
        self.init(key: key, mods: mods)
    }

    var string: String {
        var p: [String] = []
        if mods.contains(.control) { p.append("ctrl") }
        if mods.contains(.option) { p.append("opt") }
        if mods.contains(.shift) { p.append("shift") }
        if mods.contains(.command) { p.append("cmd") }
        if let f = Shortcut.names.first(where: { String(Character(UnicodeScalar($0.1)!)) == key }) { p.append(f.0) }
        else { p.append(key == "+" ? "plus" : key) }
        return p.joined(separator: "+")
    }

    var display: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let arrows = [NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→", NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓"]
        if let u = key.unicodeScalars.first, let a = arrows[Int(u.value)] { return s + a }
        let named = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "⎋", "\u{8}": "⌫", "\u{7f}": "⌫"]
        if let n = named[key] { return s + n }
        return s + key.uppercased()
    }

    /// From a keyDown event (for the recorder).
    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.isEmpty else { return nil }
        var key = chars
        // Shift+[ arrives as "{"; store the base key, shift is in mods.
        let shifted: [String: String] = ["{": "[", "}": "]", "<": ",", ">": ".", "?": "/", ":": ";", "\"": "'", "|": "\\", "_": "-", "+": "=", "~": "`",
                                         "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]
        if let b = shifted[key] { key = b }
        self.init(key: key, mods: mods)
    }
}

/// Bindable menu commands (items with an identifier) and the user's overrides
/// (global setting `keybindings`: { "<command id>": "cmd+shift+t" | "" }).
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()

    struct Command: Identifiable {
        let id: String
        let title: String
        let group: String
        let defaultShortcut: Shortcut?
        weak var item: NSMenuItem?
    }

    @Published private(set) var commands: [Command] = []
    private var lastApplied: [String: String] = [:]

    /// Records every identified menu item and its built-in shortcut.
    func capture(_ menu: NSMenu) {
        var out: [Command] = []
        func walk(_ m: NSMenu, group: String) {
            for it in m.items {
                if let sub = it.submenu { walk(sub, group: sub.title.isEmpty ? group : sub.title); continue }
                guard let id = it.identifier?.rawValue, id.hasPrefix("cmd.") else { continue }
                let def = it.keyEquivalent.isEmpty ? nil : Shortcut(key: it.keyEquivalent, mods: it.keyEquivalentModifierMask)
                out.append(Command(id: id, title: it.title, group: group, defaultShortcut: def, item: it))
            }
        }
        walk(menu, group: "Octomux")
        commands = out
    }

    func current(_ id: String) -> Shortcut? {
        guard let c = commands.first(where: { $0.id == id }) else { return nil }
        if let o = lastApplied[id] { return o.isEmpty ? nil : Shortcut(string: o) }
        return c.defaultShortcut
    }

    func isOverridden(_ id: String) -> Bool { lastApplied[id] != nil }

    func apply(_ overrides: [String: String]) {
        guard overrides != lastApplied else { return }
        lastApplied = overrides
        for c in commands {
            guard let it = c.item else { continue }
            let sc: Shortcut? = overrides[c.id].map { $0.isEmpty ? nil : Shortcut(string: $0) } ?? c.defaultShortcut
            it.keyEquivalent = sc?.key ?? ""
            it.keyEquivalentModifierMask = sc?.mods ?? []
        }
        objectWillChange.send()
    }

    func sync(from model: AppModel) {
        if model.host.isRemote { return }   // shortcuts are this Mac's preference
        var o: [String: String] = [:]
        if case .object(let d)? = model.settingValue("keybindings", scope: "global") {
            for (k, v) in d { if let s = v.string { o[k] = s } }
        }
        apply(o)
    }

    func set(_ id: String, _ sc: Shortcut?, model: AppModel = .shared) {
        var o = lastApplied
        if let sc { o[id] = sc.string } else { o[id] = "" }
        if let def = commands.first(where: { $0.id == id })?.defaultShortcut, def == sc { o.removeValue(forKey: id) }
        model.setSetting("keybindings", o.isEmpty ? nil : o)
    }

    var hasOverrides: Bool { !lastApplied.isEmpty }

    func resetAll(model: AppModel = .shared) { model.setSetting("keybindings", nil) }

    /// What a command acts on, for the "Acts on" column (all of them work while Octomux is in front).
    static func target(_ id: String) -> String {
        let c = id.hasPrefix("cmd.") ? String(id.dropFirst(4)) : id
        switch c {
        case "split-right", "split-down", "zoom-pane", "close-pane", "stop-session", "rename-session", "toggle-chat-view":
            return "Focused pane"
        case _ where c.hasPrefix("focus-"): return "Split tab"
        case "new-terminal-tab", "new-agent-tab", "new-chat", "open-project-in-default-app", "toggle-dock", "previous-tab", "next-tab":
            return "Current project"
        case _ where c.hasPrefix("tab-"): return "Current project"
        case "add-project": return "Current workspace"
        case "next-waiting-for-input": return "All workspaces"
        case "previous-workspace", "next-workspace": return "Workspaces"
        case _ where c.hasPrefix("workspace-"): return "Workspaces"
        case "settings", "check-for-updates": return "App"
        default: return "Window"
        }
    }

    func reset(_ id: String, model: AppModel = .shared) {
        var o = lastApplied
        o.removeValue(forKey: id)
        model.setSetting("keybindings", o.isEmpty ? nil : o)
    }

    /// Who else uses this shortcut (conflict hint).
    func conflict(_ sc: Shortcut, except id: String) -> Command? {
        commands.first { $0.id != id && current($0.id) == sc }
    }

    func perform(_ id: String) {
        guard let it = commands.first(where: { $0.id == id })?.item, let action = it.action else { return }
        NSApp.sendAction(action, to: it.target, from: it)
    }
}
