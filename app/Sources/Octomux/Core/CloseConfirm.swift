import AppKit

/// "Ask before closing a running program" (Settings → Terminal): what closing some sessions would stop,
/// and the question before it happens.
extension AppModel {
    static let confirmCloseKey = "octomux.confirmCloseRunning"

    var confirmsClose: Bool { UserDefaults.standard.object(forKey: Self.confirmCloseKey) as? Bool ?? true }

    struct RunningWork {
        enum Kind: Equatable { case working, waiting, program(String) }
        let session: Session
        let kind: Kind

        /// One sentence for a single item.
        var sentence: String {
            switch kind {
            case .working: return "The agent is still working."
            case .waiting: return "The agent is waiting for your input."
            case .program(let p): return "This terminal is still running \(p)."
            }
        }
        /// A few words after the session's name, in a list.
        var short: String {
            switch kind {
            case .working: return "working"
            case .waiting: return "waiting for you"
            case .program(let p): return "running \(p)"
            }
        }
    }

    /// Busy agents among the sessions, and terminals with a program in front of their shell (asked from
    /// each session's holder; a holder that doesn't answer in time counts as idle).
    func runningWork(_ ids: [String], done: @escaping ([RunningWork]) -> Void) {
        let live = ids.compactMap { session($0) }.filter { !$0.isDormant && $0.state == .running }
        var found: [String: RunningWork] = [:]
        var ask: [Session] = []
        for s in live {
            if s.isAgent && s.activity == .working { found[s.id] = RunningWork(session: s, kind: .working) }
            else if s.isAgent && s.activity == .needsInput { found[s.id] = RunningWork(session: s, kind: .waiting) }
            else if s.kind == .terminal { ask.append(s) }
        }
        let order = live.map(\.id)
        func finish() { done(order.compactMap { found[$0] }) }
        guard !ask.isEmpty else { finish(); return }

        var pending = ask.count
        var finished = false
        for s in ask {
            client(for: s.id).call("session.info", ["id": s.id]) { r in
                guard !finished else { return }
                if case .success(let v) = r, let fg = (v as? [String: Any])?["foreground"] as? String, !fg.isEmpty {
                    found[s.id] = RunningWork(session: s, kind: .program(fg))
                }
                pending -= 1
                if pending == 0 { finished = true; finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !finished { finished = true; finish() }
        }
    }

    /// Runs `close` now, or after asking when something in the sessions is still running.
    func closeAsking(_ ids: [String], noun: String, many: Int = 1, button: String, close: @escaping () -> Void) {
        guard confirmsClose, !ids.isEmpty else { close(); return }
        let key = ids.sorted().joined(separator: ",")
        guard !CloseQuestion.open.contains(key) else { return }   // a second ⌘W while the first one asks
        CloseQuestion.open.insert(key)
        runningWork(ids) { work in
            defer { CloseQuestion.open.remove(key) }
            guard !work.isEmpty else { close(); return }
            if Self.askToClose(work, noun: noun, many: many, button: button) { close() }
        }
    }

    /// The question itself. True when the user chose to close.
    static func askToClose(_ work: [RunningWork], noun: String, many: Int, button: String) -> Bool {
        let a = closeAlert(work, noun: noun, many: many, button: button)
        let ok = a.runModal() == .alertFirstButtonReturn
        if ok, a.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: confirmCloseKey) }
        return ok
    }

    static func closeAlert(_ work: [RunningWork], noun: String, many: Int, button: String) -> NSAlert {
        let a = NSAlert()
        if many == 1, work.count == 1, let w = work.first {
            a.messageText = "Close “\(w.session.displayTitle)”?"
            a.informativeText = "\(w.sentence) Closing the \(noun) stops it."
        } else {
            a.messageText = many > 1 ? "Close \(many) \(noun)s?" : "Close this \(noun)?"
            let list = work.prefix(4).map { "• \($0.session.displayTitle): \($0.short)" }.joined(separator: "\n")
            let more = work.count > 4 ? "\n• and \(work.count - 4) more" : ""
            a.informativeText = "Still running:\n\(list)\(more)\n\nClosing stops \(work.count == 1 ? "it" : "them")."
        }
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        return a
    }
}

private enum CloseQuestion {
    static var open: Set<String> = []
}
