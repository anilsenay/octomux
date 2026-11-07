import AppKit
import SwiftUI

/// Keep the Mac awake: the daemon holds it (`power.*` settings, daemon/power.rs); this reads its status for the
/// status bar's cup and Settings → Sessions, and installs the closed-lid rule when the user asks.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    struct Status: Equatable {
        var mode = "off"
        var active = false
        var working = 0
        var grace = false
        var lidEnabled = false
        var lidSetup = false
        var lidActive = false
        var onAC = true
        var lidOnBattery = false
        /// Always, until then (a timed keep-awake), then back to the previous mode.
        var until: Date?
    }

    /// The cup is hidden from the status bar (Settings → Sessions brings it back).
    static let hiddenKey = "octomux.keepAwakeHidden"

    @Published private(set) var status = Status()
    @Published var installing = false
    @Published var setupError: String?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh(_ method: String = "power.status") {
        let model = AppModel.shared
        guard !model.host.isRemote else { return }
        model.client.call(method, [:]) { [weak self] r in
            guard case .success(let v) = r, let d = v as? [String: Any] else { return }
            let lid = d["lid"] as? [String: Any] ?? [:]
            let s = Status(mode: d["mode"] as? String ?? "off", active: d["active"] as? Bool ?? false,
                           working: (d["working"] as? NSNumber)?.intValue ?? 0, grace: d["grace"] as? Bool ?? false,
                           lidEnabled: lid["enabled"] as? Bool ?? false, lidSetup: lid["setup"] as? Bool ?? false,
                           lidActive: lid["active"] as? Bool ?? false, onAC: lid["on_ac"] as? Bool ?? true,
                           lidOnBattery: lid["on_battery_allowed"] as? Bool ?? false,
                           until: (d["until"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            DispatchQueue.main.async { if self?.status != s { self?.status = s } }
        }
    }

    func setMode(_ m: String) {
        let model = AppModel.shared
        model.setSetting("power.until", nil)
        model.setSetting("power.after", nil)
        model.setSetting("power.keep_awake", m == "off" ? nil : m)
        status.mode = m
        status.until = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func setLid(_ on: Bool) {
        AppModel.shared.setSetting("power.lid", on ? true : nil)
        status.lidEnabled = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func setLidOnBattery(_ on: Bool) {
        AppModel.shared.setSetting("power.lid_on_battery", on ? true : nil)
        status.lidOnBattery = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    /// Always for a while, then back to the mode before (a timed one keeps the mode it came from).
    func keepAwake(for seconds: TimeInterval) {
        let model = AppModel.shared
        let previous = status.until != nil ? (model.setting("power.after")?.string ?? "off") : status.mode
        let until = Date().addingTimeInterval(seconds)
        model.setSetting("power.after", previous == "always" ? nil : previous)
        model.setSetting("power.until", Int(until.timeIntervalSince1970))
        model.setSetting("power.keep_awake", "always")
        status.mode = "always"
        status.until = until
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    /// Ends a timed keep-awake now: back to the mode before it.
    func stopTimer() { setMode(AppModel.shared.setting("power.after")?.string ?? "off") }

    static let durations: [(title: String, seconds: TimeInterval)] = [("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400), ("8 hours", 28800)]

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        return f.string(from: d)
    }

    static let modes: [(id: String, title: String)] = [("off", "Off"), ("agents", "While agents work"), ("always", "Always")]

    var tooltip: String {
        let s = status
        guard s.mode != "off" else { return "Keep Mac awake: off" }
        if let u = s.until { return "Keeping this Mac awake until \(Self.clock(u))" + (s.lidActive ? " · also with the lid closed" : "") }
        var t: String
        if s.active {
            t = s.mode == "always" ? "Keeping this Mac awake"
                : s.working > 0 ? "Keeping this Mac awake · \(s.working) agent\(s.working == 1 ? "" : "s") working"
                : "Keeping this Mac awake a little longer after the agents stopped"
        } else {
            t = "Keep Mac awake while agents work · no agent working now"
        }
        if s.lidActive { t += " · also with the lid closed" }
        return t
    }

    // MARK: Closed-lid rule

    /// /etc/sudoers.d file that lets this user (only) run `pmset -a disablesleep 0|1` without a password.
    static var ruleFile: String { "/etc/sudoers.d/octomux-\(NSUserName())" }

    /// Installs the rule after macOS's administrator prompt (validated with visudo first).
    func installRule(remove: Bool = false) {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { setupError = "Unusual user name; set it up by hand."; return }
        let file = Self.ruleFile
        let script: String
        if remove {
            script = "/usr/bin/pmset -a disablesleep 0; /bin/rm -f '\(file)'"
        } else {
            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
            script = "T=$(/usr/bin/mktemp) && echo '\(rule)' > \"$T\" && /usr/sbin/visudo -cf \"$T\" >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \"$T\" '\(file)'; R=$?; /bin/rm -f \"$T\"; exit $R"
        }
        let prompt = remove ? "Octomux wants to remove its permission to keep this Mac awake with the lid closed."
            : "Octomux wants permission to keep this Mac awake with the lid closed (it may run pmset disablesleep, nothing else)."
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with prompt \"\(prompt)\" with administrator privileges"
        installing = true
        setupError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", apple]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self.installing = false
                if !ok, !msg.contains("-128") { self.setupError = "Couldn't \(remove ? "remove" : "set up") the permission." }   // -128: cancelled
                if ok, !remove { self.setLid(true) }
                if ok, remove { self.setLid(false) }
                self.refresh("power.rule_changed")
            }
        }
    }
}

/// The status bar's cup: mode menu, lit while the Mac is kept awake.
struct KeepAwakeControl: View {
    @ObservedObject var awake = KeepAwake.shared
    private var cupColor: Color { awake.status.active ? T.amber : awake.status.mode == "off" ? T.text3 : T.text2 }
    var body: some View {
        let s = awake.status
        Menu {
            Section("Keep Mac awake") {
                ForEach(KeepAwake.modes, id: \.id) { m in
                    Button { awake.setMode(m.id) } label: {
                        if s.mode == m.id && (m.id != "always" || s.until == nil) { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
                Menu {
                    ForEach(KeepAwake.durations, id: \.seconds) { d in
                        Button(d.title) { awake.keepAwake(for: d.seconds) }
                    }
                } label: {
                    if let u = s.until { Label("For a While (until \(KeepAwake.clock(u)))", systemImage: "checkmark") } else { Text("For a While") }
                }
            }
            Divider()
            if s.lidSetup {
                Button { awake.setLid(!s.lidEnabled) } label: {
                    if s.lidEnabled { Label("Also with the lid closed", systemImage: "checkmark") } else { Text("Also with the lid closed") }
                }
                .disabled(s.mode == "off")
            } else {
                Button("Set Up Closed-Lid Mode…") { awake.installRule() }
            }
            Divider()
            Button("Settings…") { SettingsWindow.show(section: .sessions) }
            Button("Hide from Status Bar") { UserDefaults.standard.set(true, forKey: KeepAwake.hiddenKey) }
        } label: {
            Image(systemName: s.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: T.k * 11))
                .foregroundStyle(cupColor)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(cupColor)   // a borderless menu draws its label in the tint, not the label's own color
        .pointerCursor()
        .help(awake.tooltip)
        .onAppear { awake.start() }
    }
}

/// Settings → Sessions → Keep Mac awake.
struct KeepAwakeSettings: View {
    @ObservedObject var awake = KeepAwake.shared
    @AppStorage(KeepAwake.hiddenKey) private var hidden = false
    var body: some View {
        let s = awake.status
        SettingsGroup("Keep Mac awake", desc: "Stops the Mac from sleeping on its own while agents run, so long jobs finish. The display can still turn off. Also in the status bar (the cup).") {
            SettingRow("Keep awake", desc: s.mode == "agents" ? "While at least one agent is working, and two minutes after (pauses between steps). An agent waiting for your answer does not count." : nil) {
                Picker("", selection: Binding(get: { s.mode }, set: { awake.setMode($0) })) {
                    ForEach(KeepAwake.modes, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingRow("For a while", desc: s.until.map { "Always until \(KeepAwake.clock($0)), then back to what it was." } ?? "Always for a set time, then back to the mode above.") {
                Menu {
                    ForEach(KeepAwake.durations, id: \.seconds) { d in Button(d.title) { awake.keepAwake(for: d.seconds) } }
                    if s.until != nil { Divider(); Button("Stop Now") { awake.stopTimer() } }
                } label: { Text(s.until.map { "Until \(KeepAwake.clock($0))" } ?? "Choose…").font(.system(size: T.k * 12.5)) }
                .menuStyle(.button).fixedSize()
            }
            if s.mode != "off" {
                SettingRow("Now", desc: nil) {
                    HStack(spacing: 6) {
                        Circle().fill(s.active ? T.amber : T.text3).frame(width: 7, height: 7)
                        Text(s.active ? (s.lidActive ? "Awake, also with the lid closed" : "Keeping awake") : "Not needed now").foregroundStyle(T.text2)
                    }
                    .font(.system(size: T.k * 12))
                }
            }
            SettingRow("Show in the status bar", desc: "The cup next to the usage meters: the mode at a click, lit while the Mac is kept awake.") {
                Toggle("", isOn: Binding(get: { !hidden }, set: { hidden = !$0 })).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Also with the lid closed", desc: "macOS sleeps when the lid closes whatever apps ask. This turns that off (pmset disablesleep) only while Octomux keeps the Mac awake, and turns it back on after. Needs your administrator password once. A closed Mac in a bag gets hot: leave it on a desk.") {
                if s.lidSetup {
                    Toggle("", isOn: Binding(get: { s.lidEnabled }, set: { awake.setLid($0) })).labelsHidden().toggleStyle(.switch)
                } else {
                    Button(awake.installing ? "Waiting…" : "Set Up…") { awake.installRule() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(awake.installing)
                }
            }
            if s.lidSetup {
                SettingRow("On battery too", desc: "Off: with the lid closed it stays awake only on the power adapter.") {
                    Toggle("", isOn: Binding(get: { s.lidOnBattery }, set: { awake.setLidOnBattery($0) })).labelsHidden().toggleStyle(.switch)
                        .disabled(!s.lidEnabled)
                }
                SettingRow("Permission", desc: "The rule in \(KeepAwake.ruleFile) that lets Octomux run only `pmset -a disablesleep 0/1`.") {
                    Button("Remove…") { awake.installRule(remove: true) }.buttonStyle(SecondaryButtonStyle()).disabled(awake.installing)
                }
            }
            if let e = awake.setupError {
                Text(e).font(T.caption).foregroundStyle(T.red)
            }
        }
        .onAppear { awake.start(); awake.refresh("power.rule_changed") }
    }
}
