import AppKit

/// Settings → Advanced → Save Diagnostics: a zip for bug reports with versions, the daemon's state, settings,
/// terminal.conf and the end of the logs. Tokens, keys, passwords and email addresses are removed, the home
/// folder becomes `~`, and agents' environment values are hidden. Project paths and tab titles stay.
enum Diagnostics {
    private static let rules: [(NSRegularExpression, String)] = {
        func r(_ p: String, _ t: String, _ o: NSRegularExpression.Options = []) -> (NSRegularExpression, String) {
            (try! NSRegularExpression(pattern: p, options: o), t)
        }
        return [
            // key = value / "key": "value" for anything that looks secret.
            r(#"((?:token|secret|password|passwd|api[_-]?key|access[_-]?key|authorization|bearer|cookie|session[_-]?key)[A-Za-z_]*["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1<hidden>", [.caseInsensitive]),
            r(#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1<hidden>"),
            r(#"\bsk-[A-Za-z0-9_-]{16,}"#, "<token>"),
            r(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#, "<token>"),
            r(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "<token>"),
            r(#"\bAKIA[0-9A-Z]{16}\b"#, "<token>"),
            r(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "<token>"),
            r(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        ]
    }()

    static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var s = text
        for (re, t) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
        }
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        return s
    }

    /// The daemon state as JSON, agents' environment values replaced.
    static func scrubbedState(_ state: Any) -> String {
        var st = state
        if var d = st as? [String: Any], var profiles = d["profiles"] as? [[String: Any]] {
            for i in profiles.indices {
                if let env = profiles[i]["env"] as? [String: Any] { profiles[i]["env"] = env.mapValues { _ in "<hidden>" } }
            }
            d["profiles"] = profiles
            st = d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return scrub(String(decoding: data, as: UTF8.self))
    }

    static func tail(_ url: URL, lines: Int = 3000) -> String {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return t.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Asks where to save, then writes the zip. Calls back with the saved file or an error text.
    static func save(model: AppModel, done: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Octomux-diagnostics-\(stamp).zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        model.client.call("state.get") { r in
            let state = (try? r.get()) ?? [:]
            model.client.call("hello") { h in
                let hello = (try? h.get()) as? [String: Any] ?? [:]
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try write(to: dest, state: state, hello: hello) }
                    DispatchQueue.main.async { done(result.map { dest }) }
                }
            }
        }
    }

    static func write(to dest: URL, state: Any, hello: [String: Any]) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("octomux-diag-\(UUID().uuidString)/Octomux diagnostics")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir.deletingLastPathComponent()) }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var arch = utsname(); uname(&arch)
        let machine = withUnsafeBytes(of: &arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = """
        Octomux \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))\(Paths.isDevVariant ? " dev variant" : "")
        macOS \(os) · \(machine)
        Daemon: \(hello.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        Created \(ISO8601DateFormatter().string(from: Date()))

        Removed from these files: tokens, keys, passwords, email addresses, agents' environment values; the home
        folder is shown as ~. Project paths, tab titles and log lines stay as they are.
        """
        try scrub(info).write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        try scrubbedState(state).write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        if let conf = try? String(contentsOf: Paths.terminalConfig, encoding: .utf8) {
            try scrub(conf).write(to: dir.appendingPathComponent("terminal.conf"), atomically: true, encoding: .utf8)
        }
        let logs = dir.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let src = Paths.home.appendingPathComponent("logs")
        for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where f.hasSuffix(".log") {
            try scrub(tail(src.appendingPathComponent(f))).write(to: logs.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir.path, dest.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "Octomux", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ditto failed (\(p.terminationStatus))"]) }
    }
}
