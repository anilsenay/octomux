import AppKit
import Foundation

/// Dev-only control channel: NDJSON over `$ADE_HOME/run/app-debug.sock`.
/// Lets automation drive UI actions and read UI state without clicking.
/// Enabled only when `ADE_DEBUG=1` (or `--debug`) is set.
final class DebugServer {
    static let shared = DebugServer()
    typealias Handler = ([String: Any]) throws -> Any

    private var handlers: [String: Handler] = [:]
    private var fd: Int32 = -1

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ADE_DEBUG"] == "1" || CommandLine.arguments.contains("--debug")
    }

    func register(_ method: String, _ handler: @escaping Handler) {
        handlers[method] = handler
    }

    func start() {
        guard DebugServer.enabled else { return }
        registerBuiltins()
        let path = Paths.debugSocket.path
        try? FileManager.default.createDirectory(at: Paths.debugSocket.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { NSLog("debug server bind failed"); return }
        chmod(path, 0o600)
        let listenFd = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listenFd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    private func serve(_ c: Int32) {
        let handle = FileHandle(fileDescriptor: c, closeOnDealloc: true)
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let reply = self.process(line: line)
                handle.write(reply + Data([0x0A]))
            }
        }
    }

    private func process(line: Data) -> Data {
        var result: [String: Any] = [:]
        do {
            guard let req = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = req["method"] as? String else { throw DebugError.bad("bad request") }
            let params = req["params"] as? [String: Any] ?? [:]
            guard let h = handlers[method] else { throw DebugError.bad("unknown method \(method)") }
            var value: Any = NSNull()
            var thrown: Error?
            DispatchQueue.main.sync {
                do { value = try h(params) } catch { thrown = error }
            }
            if let thrown { throw thrown }
            // Never crash the app on a non-JSON value.
            result["result"] = JSONSerialization.isValidJSONObject(["v": value]) ? value : "\(value)"
        } catch {
            result["error"] = "\(error)"
        }
        return (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    }

    private func registerBuiltins() {
        register("ping") { _ in "pong" }
        register("windows") { _ in
            NSApp.windows.filter { $0.isVisible }.map { ["number": $0.windowNumber, "title": $0.title, "frame": NSStringFromRect($0.frame)] }
        }
        // Captures an app window. Uses the window server image of our own window, and falls
        // back to drawing the view hierarchy (terminal Metal content may then be blank).
        register("screenshot") { p in
            guard let path = p["path"] as? String else { throw DebugError.bad("missing path") }
            let win = NSApp.windows.first { $0.isVisible && $0.isMainWindow } ?? NSApp.windows.first { $0.isVisible }
            guard let win, let view = win.contentView?.superview ?? win.contentView else { throw DebugError.bad("no window") }
            var image: CGImage?
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
               cg.width > 1 {
                image = cg
            }
            var method = "window-server"
            if image == nil {
                method = "view-cache"
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    image = rep.cgImage
                }
            }
            guard let image else { throw DebugError.bad("capture failed") }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw DebugError.bad("png encode failed") }
            try data.write(to: URL(fileURLWithPath: path))
            return ["path": path, "method": method, "width": image.width, "height": image.height]
        }
        register("resize_window") { p in
            guard let w = p["width"] as? Double, let h = p["height"] as? Double else { throw DebugError.bad("missing size") }
            guard let win = NSApp.windows.first(where: { $0.isVisible }) else { throw DebugError.bad("no window") }
            var f = win.frame
            f.size = NSSize(width: w, height: h)
            win.setFrame(f, display: true)
            return ["ok": true]
        }
        register("terminals") { _ in
            TerminalRegistry.shared.all().map { v in
                ["session_id": v.sessionId, "cols": v.gridSize.cols, "rows": v.gridSize.rows, "focused": v.window?.firstResponder === v]
            }
        }
        register("terminal_text") { p in
            guard let id = p["session_id"] as? String, let v = TerminalRegistry.shared.view(for: id) else { throw DebugError.bad("no terminal") }
            return v.visibleText(includeScrollback: (p["scrollback"] as? Bool) ?? false)
        }
        register("terminal_type") { p in
            guard let id = p["session_id"] as? String, let text = p["text"] as? String,
                  let v = TerminalRegistry.shared.view(for: id) else { throw DebugError.bad("no terminal") }
            v.sendText(text)
            return ["ok": true]
        }
        register("terminal_key") { p in
            // Simulates real key presses through AppKit (exercises the keyboard path).
            guard let id = p["session_id"] as? String, let chars = p["chars"] as? String,
                  let v = TerminalRegistry.shared.view(for: id), let win = v.window else { throw DebugError.bad("no terminal") }
            let keyCode = UInt16((p["keycode"] as? Int) ?? 0)
            var flags: NSEvent.ModifierFlags = []
            if (p["ctrl"] as? Bool) == true { flags.insert(.control) }
            for ch in chars {
                let s = String(ch)
                if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: win.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                               isARepeat: false, keyCode: keyCode) {
                    v.keyDown(with: down)
                }
            }
            return ["ok": true]
        }
    }

    enum DebugError: Error, CustomStringConvertible {
        case bad(String)
        var description: String { if case .bad(let s) = self { return s }; return "" }
    }
}

/// Weak registry of live terminal views, keyed by session id.
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [String: WeakBox] = [:]
    private final class WeakBox { weak var view: TerminalSurfaceView?; init(_ v: TerminalSurfaceView) { view = v } }

    func add(_ v: TerminalSurfaceView) { views[v.sessionId] = WeakBox(v) }
    func remove(_ id: String) { views.removeValue(forKey: id) }
    func view(for id: String) -> TerminalSurfaceView? { views[id]?.view }
    func all() -> [TerminalSurfaceView] { views.values.compactMap { $0.view } }
}
