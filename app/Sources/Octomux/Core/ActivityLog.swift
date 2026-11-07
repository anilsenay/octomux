import AppKit
import Foundation

/// What happened while you were elsewhere: agents that finished, stopped on an error or started waiting for you,
/// automations and Autopilot starting work. Kept on disk (the last few hundred), so "while you were away" survives a
/// restart. Workday shows it; anything can record into it.
struct WorkEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case finished, waiting, error, automation, autopilot, task }
    var id = UUID().uuidString
    var date: Date
    var kind: Kind
    var title: String
    var detail = ""
    var sessionId: String? = nil
    var itemId: String? = nil
}

final class ActivityLog: ObservableObject {
    static let shared = ActivityLog(file: Paths.home.appendingPathComponent("activity-log.json"))
    static let keep = 300

    @Published private(set) var events: [WorkEvent] = []
    /// When the app last went to the background (you left), and came back.
    @Published private(set) var left: Date?
    @Published private(set) var back: Date?
    private let file: URL?
    var now: () -> Date = Date.init

    init(file: URL?) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            events = (try? dec.decode([WorkEvent].self, from: d)) ?? []
        }
        left = UserDefaults.standard.object(forKey: "octomux.awayLeft") as? Date
        guard file != nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.left = Date(); UserDefaults.standard.set(self?.left, forKey: "octomux.awayLeft")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.back = Date()
        }
    }

    func record(_ e: WorkEvent) {
        events.append(e)
        if events.count > Self.keep { events.removeFirst(events.count - Self.keep) }
        save()
    }

    func record(_ kind: WorkEvent.Kind, _ title: String, detail: String = "", session: String? = nil, item: String? = nil) {
        record(WorkEvent(date: now(), kind: kind, title: title, detail: detail, sessionId: session, itemId: item))
    }

    /// The events of "while you were away": since you last left the app (else the last 8 hours), newest first.
    func away(limit: Int = 30) -> [WorkEvent] {
        let since = left ?? now().addingTimeInterval(-8 * 3600)
        return Array(events.filter { $0.date >= since }.reversed().prefix(limit))
    }

    /// Today's events, newest first.
    func today(calendar: Calendar = .current) -> [WorkEvent] {
        events.filter { calendar.isDate($0.date, inSameDayAs: now()) }.reversed()
    }

    /// Agents that moved to finished / waiting / error between two daemon states.
    static func transitions(old: [Session], new: [Session], title: (Session) -> String) -> [WorkEvent] {
        var out: [WorkEvent] = []
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in new where s.isAgent {
            guard let o = before[s.id], o.activity != s.activity else { continue }
            let kind: WorkEvent.Kind
            switch s.activity {
            case .done: kind = .finished
            case .needsInput: kind = .waiting
            case .error: kind = .error
            default: continue
            }
            out.append(WorkEvent(date: Date(), kind: kind, title: title(s), sessionId: s.id))
        }
        return out
    }

    func observe(old: [Session], new: [Session], title: (Session) -> String) {
        guard !old.isEmpty else { return }
        for e in Self.transitions(old: old, new: new, title: title) { record(e) }
    }

    private func save() {
        guard let file else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(events) { try? d.write(to: file, options: .atomic) }
    }
}
