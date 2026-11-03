import Foundation

enum Paths {
    /// An Octomux environment variable, falling back to its pre-rename `ADE_*` name (same as the Rust side).
    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        return (e["OCTOMUX_\(name)"] ?? e["ADE_\(name)"]).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Set on child processes (terminals, `octomux` runs).
    static let homeVar = "OCTOMUX_HOME"
    /// Whether the data directory was chosen by the environment (dev/fixture runs: no launchd agent).
    static var homeFromEnv: Bool { env("HOME") != nil }

    /// Same resolution as the Rust side (`octomux_proto::Paths::from_env`): `OCTOMUX_HOME`/`ADE_HOME`, else
    /// ~/Library/Application Support/Octomux, or the pre-rename `ade-dev` folder when only that has data.
    static var home: URL {
        if let h = env("HOME") { return URL(fileURLWithPath: h) }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let current = support.appendingPathComponent("Octomux"), legacy = support.appendingPathComponent("ade-dev")
        let fm = FileManager.default
        let hasData = { (dir: URL) in ["octomux.sqlite3", "ade.sqlite3"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } }
        if !fm.fileExists(atPath: current.path) && hasData(legacy) {
            return legacy
        }
        return current
    }

    static var daemonSocket: URL { home.appendingPathComponent("run/daemon.sock") }
    static var terminalConfig: URL { home.appendingPathComponent("terminal.conf") }
    /// Generated from the current theme preset; loaded after terminal.conf.
    static var themeConfig: URL { home.appendingPathComponent("theme.conf") }
    static var debugSocket: URL { home.appendingPathComponent("run/app-debug.sock") }

    /// The `octomux` CLI: bundled inside the app, or `OCTOMUX_BIN` / the dev build for development.
    static var cliBinary: String {
        if let b = env("BIN") { return b }
        if let bundled = Bundle.main.url(forResource: "octomux", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/target/debug/octomux").path
        return dev
    }
}
