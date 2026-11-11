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
    /// The data directory is one of the user's real ones (in ~/Library/Application Support), even when the
    /// environment names it: terminals inside Octomux export the real OCTOMUX_HOME.
    static var homeIsUsers: Bool {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return home.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(support.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    /// The "Octomux Dev" build (`OctomuxVariant` = dev in Info.plist): its own data folder, launchd agent and
    /// bundle id, so it runs next to an installed Octomux. Exported as `OCTOMUX_VARIANT=dev` at launch so the
    /// bundled CLI (daemon, holders, attach) resolves the same folder and agent.
    static let isDevVariant: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "OctomuxVariant") as? String) == "dev" || env("VARIANT") == "dev"
    static func exportVariant() { if isDevVariant { setenv("OCTOMUX_VARIANT", "dev", 1) } }
    static var appName: String { isDevVariant ? "Octomux Dev" : "Octomux" }
    static var launchLabel: String { isDevVariant ? "dev.octomux.daemon.dev" : "dev.octomux.daemon" }

    /// Same resolution as the Rust side (`octomux_proto::Paths::from_env`): `OCTOMUX_HOME`/`ADE_HOME`, else
    /// ~/Library/Application Support/Octomux, or the pre-rename `ade-dev` folder when only that has data.
    static var home: URL {
        if let h = env("HOME") { return URL(fileURLWithPath: h) }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        if isDevVariant { return support.appendingPathComponent("Octomux Dev") }
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
    /// The binary the launchd agent runs as the daemon: the one inside the bundled background app
    /// (Contents/Helpers/<name> Sessions.app), so permissions asked by programs in sessions carry that app's
    /// name; the plain CLI when there is none (development builds, OCTOMUX_BIN).
    static var daemonBinary: String {
        if env("BIN") != nil { return cliBinary }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        if let apps = try? FileManager.default.contentsOfDirectory(at: helpers, includingPropertiesForKeys: nil) {
            for a in apps.sorted(by: { $0.path < $1.path }) where a.pathExtension == "app" {
                let exe = a.appendingPathComponent("Contents/MacOS/octomux")
                if FileManager.default.isExecutableFile(atPath: exe.path) { return exe.path }
            }
        }
        return cliBinary
    }

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
