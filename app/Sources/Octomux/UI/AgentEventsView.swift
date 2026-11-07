import SwiftUI

/// Settings → Advanced → Agent events: what the daemon heard from agents lately (hooks, their own status
/// reports) and how each session's state changed, newest first. For when an agent shows the wrong state.
struct AgentEventsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sel: SettingsSelection
    @State private var events: [[String: Any]] = []
    @State private var timer: Timer?

    var body: some View {
        let agents = model.state.sessions.filter { $0.isAgent || $0.reportsStatus == true }
        SettingsGroup("Agent events", desc: "The last 500 hooks, status reports and state changes the daemon saw (kept in memory until it restarts; no prompt text).", trailing: {
            Picker("", selection: Binding(get: { sel.eventsSession ?? "" }, set: { sel.eventsSession = $0.isEmpty ? nil : $0; refresh() })) {
                Text("All sessions").tag("")
                ForEach(agents) { s in Text(s.displayTitle).tag(s.id) }
            }
            .labelsHidden().frame(maxWidth: 220)
        }) {
            if events.isEmpty {
                Text("Nothing yet.").font(.system(size: T.k * 13)).foregroundStyle(T.text2).padding(14)
            }
            ForEach(Array(events.prefix(200).enumerated()), id: \.offset) { _, e in row(e) }
        }
        .settingAnchor("Agent events")
        .onAppear { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() } }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func row(_ e: [String: Any]) -> some View {
        let source = e["source"] as? String ?? ""
        let sid = e["session"] as? String ?? ""
        let title = model.session(sid)?.displayTitle ?? sid
        return HStack(spacing: 8) {
            Text(Self.time(e["ts"] as? Double ?? 0)).font(T.mono(11)).foregroundStyle(T.text3).frame(width: 84, alignment: .leading)
            Text(source).font(.system(size: T.k * 11, weight: .semibold))
                .foregroundStyle(source == "state" ? T.accent : source == "program" ? T.blue : T.text2)
                .frame(width: 56, alignment: .leading)
            Text(e["name"] as? String ?? "").font(T.mono(12)).foregroundStyle(T.text)
            if let d = e["detail"] as? String, !d.isEmpty { Text(d).font(T.mono(11)).foregroundStyle(T.text2).lineLimit(1) }
            Spacer(minLength: 8)
            if sel.eventsSession == nil { Text(title).font(.system(size: T.k * 12)).foregroundStyle(T.text3).lineLimit(1) }
        }
        .padding(.horizontal, 14).frame(height: 26)
    }

    private func refresh() {
        var p: [String: Any] = [:]
        if let s = sel.eventsSession { p["session_id"] = s }
        model.client.call("events.list", p) { r in
            if case .success(let v) = r, let list = (v as? [String: Any])?["events"] as? [[String: Any]] { events = list.reversed() }
        }
    }

    static func time(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
