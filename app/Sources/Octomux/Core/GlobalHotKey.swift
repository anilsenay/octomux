import AppKit
import Carbon.HIToolbox

/// A shortcut that works while another app is in front (Carbon hot key: no Accessibility permission).
/// One for now: the quick composer, stored per Mac in `octomux.composerHotKey`.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let defaultsKey = "octomux.composerHotKey"

    struct Combo: Equatable {
        var keyCode: UInt32
        var mods: NSEvent.ModifierFlags
        var display: String

        init(keyCode: UInt32, mods: NSEvent.ModifierFlags, display: String) {
            self.keyCode = keyCode
            self.mods = mods.intersection([.command, .option, .control, .shift])
            self.display = display
        }

        /// From a key press in the recorder: needs ⌘, ⌥ or ⌃ (a plain or ⇧ key would steal typing everywhere).
        init?(event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
            let key: String
            switch Int(event.keyCode) {
            case kVK_Space: key = "Space"
            case kVK_Return: key = "↩"
            case kVK_Tab: key = "⇥"
            default: key = (event.charactersIgnoringModifiers ?? "").uppercased()
            }
            guard !key.isEmpty else { return nil }
            var s = ""
            if mods.contains(.control) { s += "⌃" }
            if mods.contains(.option) { s += "⌥" }
            if mods.contains(.shift) { s += "⇧" }
            if mods.contains(.command) { s += "⌘" }
            self.init(keyCode: UInt32(event.keyCode), mods: mods, display: s + key)
        }

        var carbonMods: UInt32 {
            var m: UInt32 = 0
            if mods.contains(.command) { m |= UInt32(cmdKey) }
            if mods.contains(.option) { m |= UInt32(optionKey) }
            if mods.contains(.control) { m |= UInt32(controlKey) }
            if mods.contains(.shift) { m |= UInt32(shiftKey) }
            return m
        }

        var dict: [String: Any] { ["keyCode": Int(keyCode), "mods": Int(mods.rawValue), "display": display] }
        init?(dict: [String: Any]?) {
            guard let d = dict, let k = d["keyCode"] as? Int, let m = d["mods"] as? Int, let s = d["display"] as? String else { return nil }
            self.init(keyCode: UInt32(k), mods: NSEvent.ModifierFlags(rawValue: UInt(m)), display: s)
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: Combo?
    /// Set when macOS refused the combination (another app holds it).
    private(set) var failed = false
    var action: () -> Void = {}

    var saved: Combo? { Combo(dict: UserDefaults.standard.dictionary(forKey: Self.defaultsKey)) }

    func save(_ c: Combo?) {
        if let c { UserDefaults.standard.set(c.dict, forKey: Self.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        apply()
    }

    /// Registers the saved combination (or none).
    func apply() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        registered = nil
        failed = false
        installHandler()
        guard let c = saved else { return }
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F43_4D58), id: 1)   // "OCMX"
        let status = RegisterEventHotKey(c.keyCode, c.carbonMods, id, GetApplicationEventTarget(), 0, &r)
        if status == noErr, let r { ref = r; registered = c } else { failed = true }
    }

    /// While Settings records a new combination: off, so pressing the current one records it instead of
    /// opening the composer. `apply()` turns it back on.
    func suspend() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
