import AppKit
import GhosttyKit

/// An NSView hosting one libghostty surface. The surface runs `octomux attach <session>`,
/// so the real program lives in a daemon-owned holder and survives this view.
/// Keyboard/IME/mouse handling is adapted from Ghostty's macOS SurfaceView (MIT).
final class TerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    let sessionId: String

    var onProcessExit: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onFocus: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var focused = false
    private var cellSize = NSSize(width: 8, height: 16)
    private var trackingArea: NSTrackingArea?

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    init(sessionId: String, command: String, env: [String: String], workingDirectory: String? = nil) {
        self.sessionId = sessionId
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.wait_after_command = false
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        let keys = Array(env.keys)
        let values = keys.map { env[$0]! }
        let cKeys = keys.map { strdup($0) }
        let cValues = values.map { strdup($0) }
        defer {
            cKeys.forEach { free($0) }
            cValues.forEach { free($0) }
        }
        var envVars = (0..<keys.count).map { ghostty_env_var_s(key: cKeys[$0], value: cValues[$0]) }
        let created: ghostty_surface_t? = command.withCString { cCmd in
            (workingDirectory ?? NSHomeDirectory()).withCString { cWd in
                envVars.withUnsafeMutableBufferPointer { buf in
                    cfg.command = cCmd
                    cfg.working_directory = cWd
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }
        surface = created
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Frees the surface now (kills the attach client; the session itself keeps running).
    func close() {
        if let s = surface {
            surface = nil
            ghostty_surface_free(s)
        }
    }

    // MARK: Layout

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateScale()
        updateSurfaceSize()
    }

    private func updateScale() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 1, bounds.height > 1 else { return }
        let scaled = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
        let sz = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? 2
        cellSize = NSSize(width: Double(sz.cell_width_px) / scale, height: Double(sz.cell_height_px) / scale)
    }

    /// Grid size in cells (for logs/debug state).
    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let sz = ghostty_surface_size(surface)
        return (Int(sz.columns), Int(sz.rows))
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
        super.updateTrackingAreas()
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { setFocused(true); onFocus?() }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { setFocused(false) }
        return r
    }

    private func setFocused(_ f: Bool) {
        guard focused != f else { return }
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
    }

    // MARK: Keyboard

    /// Sessions the user has typed into (an untouched auto-opened dock terminal can be dropped on close).
    static var touched = Set<String>()

    override func keyDown(with event: NSEvent) {
        Self.touched.insert(sessionId)
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: GhosttyInput.characters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        let action = (mods.rawValue & mod) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = keyAction(action, event: event)
    }

    /// Lets Ctrl+key combos and similar reach the terminal instead of the menu bar,
    /// while ⌘ shortcuts stay with the app menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        if event.modifierFlags.contains(.command) { return false }
        if event.modifierFlags.contains(.control) {
            keyDown(with: event)
            return true
        }
        return false
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var key = GhosttyInput.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 || text.count > 1 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            str.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(len - 1)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    override func doCommand(by selector: Selector) {
        // Swallow to avoid NSBeep; key encoding happens in keyDown.
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = cellSize.width, h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: 0, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        var chars = ""
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        guard let surface, !chars.isEmpty else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        chars.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Sends text as if pasted (used by the debug channel and drag & drop).
    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(len - 1)) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            super.rightMouseDown(with: event)
        }
    }

    /// Right-click (when the program does not take the mouse): copy / paste, splits, pane actions.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = AppModel.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, enabled: Bool = true, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title, run)
            i.keyEquivalent = key
            i.keyEquivalentModifierMask = mods
            i.isEnabled = enabled
            menu.addItem(i)
        }
        let hasSel = surface.map { ghostty_surface_has_selection($0) } ?? false
        add("Copy", "c", enabled: hasSel) { [weak self] in self?.binding("copy_to_clipboard") }
        add("Paste", "v") { [weak self] in self?.binding("paste_from_clipboard") }
        menu.addItem(.separator())
        let sid = sessionId
        if m.session(sid)?.placement == .tab {
            add("Split Right", "d") { m.selectSession(sid); m.newSession(profileId: nil, split: .right) }
            add("Split Down", "d", [.command, .shift]) { m.selectSession(sid); m.newSession(profileId: nil, split: .down) }
            if (m.tab(containing: sid)?.layout.sessions.count ?? 1) > 1 {
                add(m.isZoomed(sid) ? "Restore Split" : "Zoom Pane", "\r", [.command, .shift]) { m.toggleZoom(sid) }
                add("Move to New Tab") { m.movePaneToNewTab(sid) }
            }
            add("Move to Dock") { m.client(for: sid).call("session.move", ["id": sid, "placement": "dock"]) }
            menu.addItem(.separator())
        }
        add("Clear Screen", "k") { [weak self] in self?.binding("clear_screen") }
        if let s = m.session(sid), m.canChat(s) {
            add(m.isChat(sid) ? "Show Terminal" : "Show as Chat") { m.toggleChat(sid) }
        }
        add("Rename…") { m.renamingSessionId = sid }
        menu.addItem(.separator())
        add("Close Pane", "w") { m.closePane(sid) }
        return menu
    }

    private func binding(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(GhosttyInput.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: Text access (debug + copy)

    /// Visible screen text, read from libghostty (what the user actually sees).
    func visibleText(includeScrollback: Bool = false) -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let tag = includeScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}

/// Key/modifier conversions (adapted from Ghostty, MIT).
enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func keyEvent(_ event: NSEvent, action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags?) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.text = nil
        k.composing = false
        k.mods = mods(event.modifierFlags)
        k.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let cp = chars.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        return k
    }

    static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }
}
