import AppKit
import GhosttyKit

/// Owns the libghostty app instance and routes its runtime callbacks.
/// Portions adapted from Ghostty's macOS app (MIT, © Mitchell Hashimoto).
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {}

    /// Initializes libghostty. Must be called once on the main thread before any surface is created.
    func start() -> Bool {
        if app != nil { return true }
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ghostty_init failed")
            return false
        }
        guard let cfg = ghostty_config_new() else { return false }
        // Our own config file, in Ghostty syntax. We deliberately do not read the
        // user's Ghostty config (it can be imported from Settings instead).
        let path = Paths.terminalConfig.path
        if FileManager.default.fileExists(atPath: path) {
            ghostty_config_load_file(cfg, path)
        }
        ghostty_config_finalize(cfg)
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.shared.handleAction(app: app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, mimesLen: Int(mimesLen))
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // We do not prompt: deny unconfirmed reads (OSC 52 reads).
                guard let view = TerminalSurfaceView.from(userdata), let s = view.surface else { return }
                ghostty_surface_deny_clipboard_request(s, state)
            },
            write_clipboard_cb: { _, location, content, len, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, len: Int(len))
            },
            close_surface_cb: { userdata, _ in
                guard let view = TerminalSurfaceView.from(userdata) else { return }
                DispatchQueue.main.async { view.onProcessExit?() }
            }
        )
        guard let a = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new failed")
            return false
        }
        app = a
        ghostty_app_set_focus(a, NSApp.isActive)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let a = self.app { ghostty_app_set_focus(a, true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            if let a = self.app { ghostty_app_set_focus(a, false) }
        }
        NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            if let a = self.app { ghostty_app_keyboard_changed(a) }
        }
        return true
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Reloads the terminal config file into the running app.
    func reloadConfig() {
        guard let app, let cfg = ghostty_config_new() else { return }
        let path = Paths.terminalConfig.path
        if FileManager.default.fileExists(atPath: path) {
            ghostty_config_load_file(cfg, path)
        }
        ghostty_config_finalize(cfg)
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    private func handleAction(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalSurfaceView? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface else { return nil }
            return TerminalSurfaceView.from(ghostty_surface_userdata(s))
        }()
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let data = Data(bytes: ptr, count: Int(u.len))
            if let str = String(data: data, encoding: .utf8) {
                let url = URL(string: str) ?? URL(fileURLWithPath: str)
                NSWorkspace.shared.open(url)
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                switch shape {
                case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
                case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
                default: NSCursor.arrow.set()
                }
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            if let view, let t = action.action.set_title.title {
                let title = String(cString: t)
                DispatchQueue.main.async { view.onTitle?(title) }
            }
            return true
        case GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_SHOW_CHILD_EXITED, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT:
            return true
        default:
            // Window/tab/split management is ours, not libghostty's.
            return false
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = TerminalSurfaceView.from(userdata), let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        var mime = "text/plain;charset=utf-8"
        if let mimes {
            for i in 0..<mimesLen {
                if let p = mimes[i] {
                    let m = String(cString: p)
                    if m.hasPrefix("text/plain") { mime = m; break }
                }
            }
        }
        let bytes = Array(text.utf8)
        mime.withCString { mimePtr in
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dataPtr in
                    var content = ghostty_clipboard_content_s(mime: mimePtr, data: dataPtr, len: bytes.count)
                    withUnsafePointer(to: &content) { cptr in
                        var complete = ghostty_clipboard_complete_s()
                        complete.contents = cptr
                        complete.contents_len = 1
                        complete.available = nil
                        complete.available_len = 0
                        complete.confirmed = true
                        ghostty_surface_complete_clipboard_request(surface, &complete, state)
                    }
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        for i in 0..<len {
            let c = content[i]
            guard let mime = c.mime, String(cString: mime).hasPrefix("text/plain"), let data = c.data else { continue }
            let str = String(decoding: Data(bytes: data, count: c.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
            return
        }
    }
}
