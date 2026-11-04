import SwiftUI

/// Settings → Sessions: every running session with the CPU and memory of its processes, and the idle-agent stop.
struct SessionsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var usage: [String: SessionUsage] = [:]
    @State private var timer: Timer?
    @State private var loaded = false

    var body: some View {
        let running = model.state.sessions.filter { $0.state == .running }
            .sorted { (usage[$0.id]?.rssBytes ?? 0) > (usage[$1.id]?.rssBytes ?? 0) }
        let totalRSS = running.compactMap { usage[$0.id]?.rssBytes }.reduce(0, +)
        let totalCPU = running.compactMap { usage[$0.id]?.cpuPercent }.reduce(0, +)
        SettingsGroup("Running", desc: "Each session with everything it started (shell, agent, dev servers). Updated every 2 seconds while this page is open.", trailing: {
            if loaded {
                Text("\(Self.bytes(totalRSS)) · \(Self.cpu(totalCPU)) CPU").font(T.mono(12)).foregroundStyle(T.text2)
            }
        }) {
            if running.isEmpty {
                Text("Nothing is running.").font(.system(size: T.k * 12.5)).foregroundStyle(T.text2).padding(14)
            }
            ForEach(running) { s in row(s) }
        }
        let fromPrompt = model.settingValue("sessions.title_source", scope: "global")?.string == "prompt"
        SettingsGroup("Tab titles") {
            SettingRow("Agent tabs are named after", desc: fromPrompt
                       ? "Your first message to the agent. A name you give a tab yourself always wins."
                       : "The title the agent gives its conversation (Claude names it after a few turns), else your first message. A name you give a tab yourself always wins.") {
                Picker("", selection: Binding(get: { fromPrompt ? "prompt" : "agent" }, set: { model.setSetting("sessions.title_source", $0 == "prompt" ? "prompt" : nil) })) {
                    Text("The agent's title").tag("agent")
                    Text("Your first message").tag("prompt")
                }
                .labelsHidden().fixedSize()
            }
        }
        let mins = Int(model.settingValue("sessions.auto_stop_idle_mins", scope: "global")?.number ?? 0)
        SettingsGroup("Idle agents") {
            SettingRow("Stop idle agents", desc: mins == 0
                       ? "Agents keep running until you stop them."
                       : "An agent that finished its turn, has nothing running in the background and showed no output for \(Self.duration(mins)) is stopped. Resume picks up the same conversation.") {
                Picker("", selection: Binding(get: { mins }, set: { model.setSetting("sessions.auto_stop_idle_mins", $0 == 0 ? nil : $0) })) {
                    Text("Never").tag(0)
                    ForEach([15, 30, 60, 120, 240], id: \.self) { Text("After \(Self.duration($0))").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            let hours = model.settingValue("sessions.close_stopped_after_hours", scope: "global")?.number ?? 0
            SettingRow("Close stopped agent tabs", desc: hours == 0
                       ? "Stopped agents keep their tab until you close it."
                       : "An agent tab that has been stopped or ended that long is closed; pinned tabs stay. The session stays in the sidebar, where Resume opens it again.") {
                Picker("", selection: Binding(get: { Int(hours) }, set: { model.setSetting("sessions.close_stopped_after_hours", $0 == 0 ? nil : $0) })) {
                    Text("Never").tag(0)
                    Text("After 1 hour").tag(1); Text("After 8 hours").tag(8); Text("After 1 day").tag(24); Text("After 1 week").tag(168)
                }
                .labelsHidden().fixedSize()
            }
        }
        SettingsFootnote(model.host.isRemote ? "Terminals are never stopped for being idle. These are the sessions on \(model.host.name)." : "Terminals are never stopped for being idle.")
            .onAppear(perform: start)
            .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func row(_ s: Session) -> some View {
        let u = usage[s.id]
        return HStack(spacing: 10) {
            AgentIcon(icon: iconName(for: s, model: model), size: 14).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayTitle).font(.system(size: T.k * 13, weight: .medium)).lineLimit(1)
                Text([model.project(s.projectId)?.name, Self.status(s), (u?.processes ?? 0) > 1 ? u.flatMap { u in u.top.map { "\(u.processes) processes, largest \($0)" } } : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: T.k * 11.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(u.map { Self.cpu($0.cpuPercent) } ?? "–").font(T.mono(12)).foregroundStyle((u?.cpuPercent ?? 0) >= 50 ? T.amber : T.text2)
                .frame(width: 60, alignment: .trailing)
            Text(u.map { Self.bytes($0.rssBytes) } ?? "–").font(T.mono(12)).foregroundStyle(T.text)
                .frame(width: 72, alignment: .trailing)
                .help(u.map { "\($0.processes) process\($0.processes == 1 ? "" : "es")" } ?? "")
            Button("Open") {
                (NSApp.delegate as? AppDelegate)?.openMainWindow()
                model.selectSession(s.id)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Stop") { model.stop(s.id) }.buttonStyle(SecondaryButtonStyle())
                .help(s.isAgent ? "Stops the agent; Resume continues the conversation" : "Ends the shell and what runs in it")
        }
        .padding(.horizontal, 14).frame(height: 48)
    }

    private func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() }
    }

    private func refresh() {
        model.client.call("sessions.resources") { r in
            guard case .success(let v) = r, let d = (v as? [String: Any])?["sessions"] as? [String: [String: Any]] else { return }
            usage = d.mapValues(SessionUsage.init)
            loaded = true
        }
    }

    static func status(_ s: Session) -> String {
        switch s.activity {
        case .working: return "working"
        case .needsInput: return "waiting for you"
        case .done: return "finished"
        case .error: return "error"
        case .idle: return s.isAgent ? "idle" : s.kind == .action ? "action" : "terminal"
        }
    }

    static func bytes(_ b: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = b >= 1 << 30 ? [.useGB] : [.useMB]
        return f.string(fromByteCount: Int64(b))
    }

    static func cpu(_ p: Double) -> String {
        (p / 100).formatted(.percent.precision(.fractionLength(p < 10 ? 1 : 0)))
    }

    static func duration(_ mins: Int) -> String { mins < 60 ? "\(mins) min" : mins == 60 ? "1 hour" : "\(mins / 60) hours" }
}

struct SessionUsage: Equatable {
    var rssBytes: UInt64
    var cpuPercent: Double
    var processes: Int
    var top: String?

    init(_ d: [String: Any]) {
        rssBytes = (d["rss_bytes"] as? NSNumber)?.uint64Value ?? 0
        cpuPercent = (d["cpu_percent"] as? NSNumber)?.doubleValue ?? 0
        processes = (d["processes"] as? Int) ?? 0
        top = d["top"] as? String
    }
}
