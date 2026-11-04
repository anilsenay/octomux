import AppKit

/// Reads and edits single keys of terminal.conf (Ghostty syntax) without touching the rest of the file:
/// comments, order and unknown keys stay as the user wrote them.
struct TerminalConfig: Equatable {
    var text: String

    /// The value the file sets for `key` (the last line wins, as in Ghostty), quotes removed.
    func value(_ key: String) -> String? {
        var out: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let (k, v) = Self.entry(line), k == key { out = v }
        }
        return out
    }

    /// Sets `key` to `value` (nil removes it). The last line for the key is rewritten in place and
    /// earlier ones are dropped; a new key goes at the end.
    mutating func set(_ key: String, _ value: String?) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hits = lines.indices.filter { Self.entry(lines[$0])?.0 == key }
        if let last = hits.last {
            if let value { lines[last] = "\(key) = \(value)" } else { lines.remove(at: last) }
            for i in hits.dropLast().reversed() { lines.remove(at: i) }
        } else if let value {
            while lines.last == "" { lines.removeLast() }
            lines.append("\(key) = \(value)")
            lines.append("")
        }
        text = lines.joined(separator: "\n")
    }

    private static func entry<S: StringProtocol>(_ raw: S) -> (String, String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        return key.isEmpty ? nil : (key, v)
    }

    // MARK: Typed views of the keys Settings has controls for

    static let defaultFontSize = 13.0      // Ghostty's macOS default
    static let builtInFont = "JetBrains Mono"   // the font Ghostty ships with and uses when none is set

    var fontFamily: String? { value("font-family").flatMap { $0.isEmpty ? nil : $0 } }
    var fontSize: Double { value("font-size").flatMap(Double.init) ?? Self.defaultFontSize }
    /// `adjust-cell-height` as a percentage (Ghostty also takes pixels; those read as 0 here).
    var lineHeightPercent: Int {
        guard let v = value("adjust-cell-height"), v.hasSuffix("%"), let n = Int(v.dropLast().trimmingCharacters(in: .whitespaces)) else { return 0 }
        return n
    }
    var cursorStyle: String { value("cursor-style") ?? "block" }
    /// nil: the program decides (Ghostty's default).
    var cursorBlink: Bool? { value("cursor-style-blink").flatMap { $0 == "true" ? true : $0 == "false" ? false : nil } }
    /// nil: unlimited (Ghostty's default; memory is still capped by scrollback-limit-bytes).
    var scrollbackLines: Int? {
        guard let v = value("scrollback-limit-lines"), v != "unlimited" else { return nil }
        return Int(v)
    }

    // MARK: File

    static func load() -> TerminalConfig {
        TerminalConfig(text: (try? String(contentsOf: Paths.terminalConfig, encoding: .utf8)) ?? "")
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.terminalConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: Paths.terminalConfig, atomically: true, encoding: .utf8)
        GhosttyRuntime.shared.reloadConfig()
    }

    /// Installed fixed-pitch font families, for the font menu.
    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { fam in
            if fam.hasPrefix(".") { return false }
            guard let name = (fm.availableMembers(ofFontFamily: fam)?.first?.first as? String),
                  let f = NSFont(name: name, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono")
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
