import Foundation

/// Pages visited in the Octomux browser (for the address bar's suggestions). Kept in `$OCTOMUX_HOME/browser-history.json`.
@MainActor
final class BrowserHistory {
    static let shared = BrowserHistory(file: Paths.home.appendingPathComponent("browser-history.json"))

    struct Entry: Codable, Equatable {
        var url: String
        var title: String
        var visits: Int
        var last: Date
    }

    private(set) var entries: [Entry] = []
    private let file: URL?
    private var saveWork: DispatchWorkItem?
    static let limit = 1500

    init(file: URL?) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([Entry].self, from: d) { entries = v }
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        let s = c?.string ?? url.absoluteString
        if let i = entries.firstIndex(where: { $0.url == s }) {
            entries[i].visits += 1
            entries[i].last = Date()
            if !title.isEmpty { entries[i].title = title }
        } else {
            entries.append(Entry(url: s, title: title, visits: 1, last: Date()))
            if entries.count > Self.limit {
                entries.sort { $0.last > $1.last }
                entries.removeLast(entries.count - Self.limit)
            }
        }
        scheduleSave()
    }

    /// Titles arrive after the page loads.
    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let i = entries.firstIndex(where: { $0.url == url.absoluteString }), entries[i].title != title else { return }
        entries[i].title = title
        scheduleSave()
    }

    func remove(_ url: String) { entries.removeAll { $0.url == url }; scheduleSave() }

    /// Best matches for what is typed: every word must appear in the address or title; addresses that start with
    /// it, often and recently visited pages first.
    func suggestions(_ query: String, limit: Int = 6) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let now = Date()
        func stripped(_ u: String) -> String {
            var s = u.lowercased()
            for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
            return s
        }
        return entries.compactMap { e -> (Entry, Double)? in
            let u = stripped(e.url), t = e.title.lowercased()
            guard words.allSatisfy({ u.contains($0) || t.contains($0) }) else { return nil }
            var score = log(Double(e.visits) + 1) * 2
            score += max(0, 3 - now.timeIntervalSince(e.last) / 86_400 / 3)   // last few days
            if u.hasPrefix(words[0]) { score += 6 }
            if u.split(separator: "/").first.map(String.init)?.contains(words[0]) == true { score += 2 }
            return (e, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }

    private func scheduleSave() {
        guard let file else { return }
        saveWork?.cancel()
        let snapshot = entries
        let w = DispatchWorkItem {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}
