import Foundation

enum Paths {
    /// Same resolution as the Rust side (`ADE_HOME`, default ~/Library/Application Support/ade-dev).
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["ADE_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ade-dev")
    }

    static var daemonSocket: URL { home.appendingPathComponent("run/daemon.sock") }
    static var terminalConfig: URL { home.appendingPathComponent("terminal.conf") }
    static var debugSocket: URL { home.appendingPathComponent("run/app-debug.sock") }

    /// The `ade` CLI: bundled inside the app, or `ADE_BIN` / the dev build for development.
    static var adeBinary: String {
        if let b = ProcessInfo.processInfo.environment["ADE_BIN"], !b.isEmpty { return b }
        if let bundled = Bundle.main.url(forResource: "ade", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/target/debug/ade").path
        return dev
    }
}
