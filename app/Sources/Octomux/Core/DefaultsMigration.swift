import Foundation

/// One-time copy of UI state from the pre-rename app: bundle id `dev.ade-dev.app` (or the unbundled `ADE`
/// dev binary), keys `ade.*` → `octomux.*`, the main window frame `ADE.main` → `Octomux.main`.
/// Runs before anything reads UserDefaults; never overwrites a key that already has a value.
enum DefaultsMigration {
    private static let doneKey = "octomux.defaultsMigrated"

    static func run(_ d: UserDefaults = .standard, from domains: [String] = ["dev.ade-dev.app", "ADE"]) {
        guard !d.bool(forKey: doneKey) else { return }
        var old: [String: Any] = [:]
        for name in domains {
            old.merge(d.persistentDomain(forName: name) ?? [:]) { first, _ in first }
        }
        // The current domain too: dev builds that kept their domain still hold `ade.*` keys.
        old.merge(d.dictionaryRepresentation().filter { $0.key.hasPrefix("ade.") }) { first, _ in first }
        for (key, value) in old {
            guard let newKey = renamed(key), d.object(forKey: newKey) == nil else { continue }
            d.set(value, forKey: newKey)
        }
        d.set(true, forKey: doneKey)
    }

    static func renamed(_ key: String) -> String? {
        if key.hasPrefix("ade.") { return "octomux." + key.dropFirst(4) }
        if key.contains("ADE.main") { return key.replacingOccurrences(of: "ADE.main", with: "Octomux.main") }
        if key.hasPrefix("NS") || key.hasPrefix("com.apple.") || key.hasPrefix("Apple") { return nil }
        return key
    }
}
