import SwiftUI

/// How full an agent's context is: a percentage when the window is known, else just the tokens.
struct ContextReading: Equatable {
    var percent: Double?
    var used: Int?
    var size: Int?
    var model: String?

    init(percent: Double?, used: Int?, size: Int?, model: String?) {
        self.percent = percent; self.used = used; self.size = size; self.model = model
    }

    /// From Claude's status line payload as Octomux saves it: `{ context_window: {...}, model: "…" }`.
    init(statusLine o: [String: Any]) {
        let c = o["context_window"] as? [String: Any] ?? [:]
        let size = ChatModel.int(c["context_window_size"])
        var used = 0
        if let cur = c["current_usage"] as? [String: Any] {
            used = ChatModel.int(cur["input_tokens"]) + ChatModel.int(cur["cache_creation_input_tokens"])
                + ChatModel.int(cur["cache_read_input_tokens"])   // input only, like Claude's own percentage
        }
        var pct = (c["used_percentage"] as? NSNumber)?.doubleValue
        if pct == nil, used > 0, size > 0 { pct = Double(used) / Double(size) * 100 }
        if used == 0, let p = pct, size > 0 { used = Int(Double(size) * p / 100) }
        self.init(percent: pct, used: used > 0 ? used : nil, size: size > 0 ? size : nil, model: o["model"] as? String)
    }

    var help: String {
        var parts: [String] = []
        if let p = percent { parts.append("\(Int(p.rounded()))% context used") }
        if let u = used { parts.append(size.map { "\(Self.k(u)) / \(Self.k($0)) tokens" } ?? "\(Self.k(u)) tokens in context") }
        return parts.joined(separator: " · ")
    }

    static func k(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))K" : "\(n)"
    }
}

/// Small ring next to Send: context used (amber from 75 %, red from 90 %), details on hover.
struct ContextRing: View {
    let reading: ContextReading?
    var body: some View {
        if let r = reading, r.percent != nil {   // tokens alone say little without the window
            let p = min(max((r.percent ?? 0) / 100, 0), 1)
            let color = (r.percent ?? 0) >= 90 ? T.red : (r.percent ?? 0) >= 75 ? T.amber : T.text2
            ZStack {
                Circle().stroke(T.text3.opacity(0.3), lineWidth: 2)
                if r.percent != nil {
                    Circle().trim(from: 0, to: p).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 26)
            .contentShape(Rectangle())
            .help(r.help)
        }
    }
}

/// Replaces Send while the agent works and the field is empty: interrupts it like Esc in the terminal.
struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.white).frame(width: 9, height: 9)
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(T.text2))
        .pointerCursor().help("Stop the agent (Esc)")
    }
}

enum ChatModels {
    struct Choice { let alias: String; let title: String }
    /// What `/model` accepts in Claude Code (aliases follow the latest models of each family).
    static let claude: [Choice] = [
        Choice(alias: "default", title: "Default (account setting)"),
        Choice(alias: "opus", title: "Opus"),
        Choice(alias: "sonnet", title: "Sonnet"),
        Choice(alias: "haiku", title: "Haiku"),
        Choice(alias: "opusplan", title: "Opus for plans, Sonnet to build"),
    ]

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5"; others as they are.
    static func pretty(_ id: String?) -> String {
        guard var s = id?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        if s.contains(" ") { return s }                                     // already a display name
        var suffix = ""
        if let r = s.range(of: "[1m]") { s.removeSubrange(r); suffix = " (1M)" }
        guard s.hasPrefix("claude-") else { return s + suffix }
        var parts = s.dropFirst(7).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }   // date stamp
        guard let family = parts.first else { return s }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version) + suffix
    }
}

extension AppModel {
    /// Interrupts the agent the way Esc does in its terminal.
    func interruptSession(_ id: String) {
        client(for: id).call("session.input", ["id": id, "data": "\u{1b}"], completion: report)
    }
}
