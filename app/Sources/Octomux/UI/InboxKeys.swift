import AppKit
import SwiftUI

/// The Inbox's keyboard: moving through the list and acting on the open item, like a mail app.
enum InboxKeys {
    enum Action: Equatable { case next, previous, open, close, toggleRead, send, ask, openInBrowser, refresh, filter }

    /// The shortcut list (Help popover and tooltips).
    static let help: [(keys: String, what: String)] = [
        ("↓ / j", "Next item"), ("↑ / k", "Previous item"), ("Return", "Open the first item"), ("Esc", "Close the item"),
        ("u", "Mark read / unread"), ("s", "Send to agent"), ("a", "Ask about it (read-only)"), ("o", "Open on the website"), ("r", "Refresh"), ("/", "Filter"),
    ]

    /// A key press (no ⌘ / ⌃ / ⌥: those stay app shortcuts) → what it does in the Inbox.
    static func action(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        if !modifiers.intersection([.command, .control, .option]).isEmpty { return nil }
        switch keyCode {
        case 125: return .next          // ↓
        case 126: return .previous      // ↑
        case 36, 76: return .open       // Return, Enter
        case 53: return .close          // Esc
        default: break
        }
        switch characters {
        case "j": return .next
        case "k": return .previous
        case "u": return .toggleRead
        case "s": return .send
        case "a": return .ask
        case "o": return .openInBrowser
        case "r": return .refresh
        case "/": return .filter
        default: return nil
        }
    }

    /// The item `delta` rows from `current` in `ids` (the first or last when nothing is selected), stopping at the ends.
    static func step(_ ids: [String], from current: String?, by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return delta >= 0 ? ids.first : ids.last }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }
}

/// Catches keys for the Inbox while its window is key, the Inbox is the open doc and no text field is being typed in.
struct InboxKeyCatcher: NSViewRepresentable {
    let handle: (InboxKeys.Action) -> Bool

    final class V: NSView {
        var handle: ((InboxKeys.Action) -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let win = self.window, e.window === win, win.isKeyWindow,
                      case .inbox = AppModel.shared.activeDoc?.kind,
                      !(win.firstResponder is NSText),                       // typing in the filter or a comment
                      let a = InboxKeys.action(characters: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, modifiers: e.modifierFlags)
                else { return e }
                return self.handle?(a) == true ? nil : e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.handle = handle; return v }
    func updateNSView(_ v: V, context: Context) { v.handle = handle }
}
