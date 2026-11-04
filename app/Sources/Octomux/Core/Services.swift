import AppKit
import SwiftUI
import UserNotifications

// MARK: - Open in…

struct ExternalApp: Identifiable {
    let id: String   // bundle id
    let name: String
    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
}

enum OpenIn {
    static let known: [ExternalApp] = [
        .init(id: "com.apple.finder", name: "Finder"),
        .init(id: "com.mitchellh.ghostty", name: "Ghostty"),
        .init(id: "dev.zed.Zed", name: "Zed"),
        .init(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        .init(id: "com.microsoft.VSCode", name: "VS Code"),
        .init(id: "com.google.antigravity", name: "Antigravity"),
        .init(id: "com.apple.dt.Xcode", name: "Xcode"),
        .init(id: "com.googlecode.iterm2", name: "iTerm2"),
        .init(id: "dev.warp.Warp-Stable", name: "Warp"),
        .init(id: "com.apple.Terminal", name: "Terminal"),
        .init(id: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        .init(id: "com.sublimetext.4", name: "Sublime Text"),
    ]

    static var installed: [ExternalApp] {
        known.filter { $0.id == "com.apple.finder" || $0.url != nil }
    }

    static var defaultAppId: String {
        let v = AppModel.shared.setting("open_in.default")?.string ?? "com.apple.finder"
        return installed.contains { $0.id == v } ? v : "com.apple.finder"
    }

    static func open(_ path: String, appId: String) {
        let url = URL(fileURLWithPath: path)
        if appId == "com.apple.finder" {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct OpenInMenu: View {
    let path: String
    var body: some View {
        Menu("Open in") {
            ForEach(Array(OpenIn.installed.enumerated()), id: \.element.id) { i, app in
                Button(app.name) { OpenIn.open(path, appId: app.id) }
            }
        }
    }
}

struct OpenInButton: View {
    let path: String
    var body: some View {
        HStack(spacing: 0) {
            Button { OpenIn.open(path, appId: OpenIn.defaultAppId) } label: {
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenIn.defaultAppId) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "folder")
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .help("Open in \(OpenIn.installed.first { $0.id == OpenIn.defaultAppId }?.name ?? "Finder") (⌘O)")
            Menu {
                ForEach(Array(OpenIn.installed.enumerated()), id: \.element.id) { i, app in
                    Button("\(app.name)") { OpenIn.open(path, appId: app.id) }
                }
                Divider()
                Menu("Default") {
                    ForEach(OpenIn.installed) { app in
                        Button((app.id == OpenIn.defaultAppId ? "✓ " : "") + app.name) {
                            AppModel.shared.setSetting("open_in.default", app.id)
                        }
                    }
                }
            } label: { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3).frame(width: 14, height: 26) }
                .plainMenu().pointerCursor()
        }
    }
}

// MARK: - Remote-aware file reads

enum RemoteFS {
    /// Text of a file on the current host (nil when unreadable; "Binary file" note for binaries).
    static func readText(_ path: String, max: Int = 512 * 1024) -> String? {
        let (h, c) = AppModel.shared.host(forPath: path)
        if h.isRemote {
            guard let r = try? c.callSync("fs.read", ["path": path, "max": max]) as? [String: Any] else { return nil }
            if (r["binary"] as? Bool) == true { return "Binary file (\(r["size"] ?? "?") bytes)" }
            let t = r["text"] as? String ?? ""
            return (r["truncated"] as? Bool) == true ? t + "\n… (truncated)" : t
        }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.prefix(8000).contains(0) { return "Binary file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))" }
        let t = String(decoding: data.prefix(max), as: UTF8.self)
        return data.count > max ? t + "\n… (truncated)" : t
    }
}

// MARK: - Git

/// Branch + diff stat per project path, refreshed in the background.
final class GitInfo: ObservableObject {
    static let shared = GitInfo()
    struct Stat: Equatable { var added = 0, removed = 0, files = 0 }

    @Published private var branches: [String: String] = [:]
    @Published private var stats: [String: Stat] = [:]
    private var lastFetch: [String: Date] = [:]
    private let queue = DispatchQueue(label: "octomux.git", qos: .utility)

    func branch(for path: String) -> String? {
        refreshIfStale(path)
        return branches[path]
    }

    func diffStat(for path: String) -> Stat? {
        refreshIfStale(path)
        return stats[path]
    }

    private func refreshIfStale(_ path: String) {
        if let t = lastFetch[path], Date().timeIntervalSince(t) < 5 { return }
        lastFetch[path] = Date()
        queue.async {
            let branch = Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var stat: Stat?
            // Against the chosen base branch (merge-base) when one is set, else HEAD (uncommitted work).
            let rev = Self.diffBase(for: path) ?? "HEAD"
            if branch != nil, let out = Self.git(["diff", "--numstat", rev], in: path) {
                var s = Stat()
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count >= 3 else { continue }
                    s.added += Int(parts[0]) ?? 0
                    s.removed += Int(parts[1]) ?? 0
                    s.files += 1
                }
                // Untracked files count too (all their lines are new), like the Changes views.
                if let others = Self.git(["ls-files", "--others", "--exclude-standard"], in: path) {
                    let list = others.split(separator: "\n").map(String.init)
                    s.added += GitDiffData.untrackedStats(path, list).values.reduce(0, +)
                    s.files += list.count
                }
                stat = s
            }
            DispatchQueue.main.async {
                if self.branches[path] != branch { self.branches[path] = branch }
                if self.stats[path] != stat { self.stats[path] = stat }
            }
        }
    }

    // MARK: Compare base

    /// Branch the Changes views compare against (per work path); nil = HEAD (only uncommitted work).
    static func compareBase(for path: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "octomux.compareBase") as? [String: String])?[path]
    }

    func setCompareBase(_ base: String?, for path: String) {
        var d = (UserDefaults.standard.dictionary(forKey: "octomux.compareBase") as? [String: String]) ?? [:]
        d[path] = base
        UserDefaults.standard.set(d, forKey: "octomux.compareBase")
        lastFetch[path] = nil
        objectWillChange.send()
        NotificationCenter.default.post(name: .adeCompareBaseChanged, object: path)
    }

    /// Merge-base commit of HEAD and the compare branch (nil when none is set or it does not resolve).
    static func diffBase(for path: String) -> String? {
        guard let b = compareBase(for: path) else { return nil }
        return git(["merge-base", "HEAD", b], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Local branches, most recently committed first; with `remotes`, remote branches after them.
    static func branches(in path: String, remotes: Bool) -> [String] {
        let refs = remotes ? ["refs/heads", "refs/remotes"] : ["refs/heads"]
        let out = git(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)"] + refs, in: path) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") && $0 != "origin" }
    }

    /// Like `git`, with stderr kept (for messages such as a failed checkout).
    static func gitResult(_ args: [String], in dir: String) -> (ok: Bool, out: String, err: String) {
        let (h, c) = AppModel.shared.host(forPath: dir)
        if h.isRemote {
            guard let r = try? c.callSync("git.run", ["cwd": dir, "args": args]) as? [String: Any] else { return (false, "", "Remote host did not answer") }
            return ((r["ok"] as? Bool) == true, r["stdout"] as? String ?? "", r["stderr"] as? String ?? "")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// Forces the next `branch` / `diffStat` read to refetch (after checkout, commit…).
    func invalidate(_ path: String) { lastFetch[path] = nil; objectWillChange.send() }

    static func git(_ args: [String], in dir: String) -> String? {
        let (h, c) = AppModel.shared.host(forPath: dir)
        if h.isRemote {
            // Remote host: the daemon there runs git (`git.run`, allowlisted).
            guard let r = try? c.callSync("git.run", ["cwd": dir, "args": args]) as? [String: Any],
                  (r["ok"] as? Bool) == true else { return nil }
            return r["stdout"] as? String
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: - Notifications

/// Whether macOS lets Octomux show notifications (System Settings → Notifications → Octomux), for the Settings page.
/// Read again when the app comes back to the front, so returning from System Settings updates it.
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()

    enum Status: Equatable {
        case checking
        /// Not running from the app bundle (dev build): macOS has no notification settings for it.
        case unavailable
        /// Never asked.
        case notDetermined
        /// Turned off for Octomux.
        case denied
        /// Allowed, but the alert style is None (nothing on screen, only Notification Center).
        case noBanners
        case allowed
    }

    @Published private(set) var status: Status = .checking
    /// Allowed but sounds are off in System Settings.
    @Published private(set) var soundOff = false
    private var token: Any?

    private init() {
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { status = .unavailable; return }
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let s: Status
            switch st.authorizationStatus {
            case .notDetermined: s = .notDetermined
            case .denied: s = .denied
            default: s = st.alertStyle == .none ? .noBanners : .allowed
            }
            let soundOff = st.soundSetting == .disabled
            DispatchQueue.main.async {
                self.status = s
                self.soundOff = soundOff
            }
        }
    }

    /// Debug only (DebugActions "notification_permission"): show a status without changing System Settings.
    func debugShow(_ name: String, soundOff: Bool = false) {
        let all: [String: Status] = ["unavailable": .unavailable, "not_determined": .notDetermined, "denied": .denied, "no_banners": .noBanners, "allowed": .allowed]
        if let s = all[name] { status = s }
        self.soundOff = soundOff
    }
    var debugName: String { "\(status)" }

    /// The macOS prompt (only shows while never asked).
    func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// System Settings → Notifications, on Octomux's page where macOS supports it.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.octomux.app"
        for s in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                  "x-apple.systempreferences:com.apple.preference.notifications"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private(set) var available = false
    private(set) var lastAuthError: String?
    private(set) var authorized = false

    func start() {
        // UNUserNotificationCenter requires a real app bundle.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        available = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
            DispatchQueue.main.async {
                self.authorized = ok
                self.lastAuthError = err.map { "\($0)" }
                NotificationPermission.shared.refresh()
                if let err { NSLog("Octomux notification authorization error: \(err)") }
            }
        }
    }

    func deliver(_ n: AppNotification) {
        let model = AppModel.shared
        // Nothing to say about the pane the user is looking at.
        if NSApp.isActive, model.focusedSessionId == n.sessionId, n.kind != "command_done" {
            model.markRead(n.sessionId)
            return
        }
        if NSApp.isActive, model.activeTab?.layout.sessions.contains(n.sessionId) == true, n.kind == "command_done" { return }
        recent.insert((n, Date()), at: 0)
        recent = Array(recent.prefix(50))
        post(n)
    }

    /// Shows the notification and plays its sound (no checks: `deliver` decides whether it is worth it).
    private func post(_ n: AppNotification) {
        let model = AppModel.shared
        let sound = model.setting("notifications.sound", project: n.projectId)?.bool ?? true
        let name = Self.soundName(for: n.kind, project: n.projectId)
        if available {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            if sound { content.sound = name.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default }
            content.userInfo = ["session_id": n.sessionId]
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        if !NSApp.isActive {
            if !available, sound { NSSound(named: name ?? "Glass")?.play() }
            NSApp.requestUserAttention(.informationalRequest)
        } else if !available, sound, n.sessionId.isEmpty {
            NSSound(named: name ?? "Glass")?.play()   // a test from Settings, in a build without notifications
        }
    }

    // MARK: Sounds

    /// The notification kinds that have a sound of their own, and the setting that holds it.
    static let soundKinds: [(kind: String, title: String, key: String)] = [
        ("done", "Agent finished", "notifications.sound_done"),
        ("needs_input", "Agent needs input", "notifications.sound_needs_input"),
        ("error", "Agent error", "notifications.sound_error"),
        ("other", "Commands and programs", "notifications.sound_other"),
    ]

    /// macOS's alert sounds (System Settings → Sound), by name.
    static let systemSounds: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }()

    static func soundKey(for kind: String) -> String {
        soundKinds.first { $0.kind == kind }?.key ?? "notifications.sound_other"
    }

    /// The sound chosen for a kind; nil is the system's default notification sound.
    static func soundName(for kind: String, project: String?) -> String? {
        guard let v = AppModel.shared.setting(soundKey(for: kind), project: project)?.string, !v.isEmpty, v != "default" else { return nil }
        return v
    }

    /// A sample of a kind, from Settings → Notifications → Send Test (ignores the focused pane and the
    /// per-kind switches, so it always shows if macOS lets it).
    func sendTest(kind: String = "needs_input") {
        let samples = ["done": ("Fix the flaky test", "Claude finished its turn."),
                       "needs_input": ("Fix the flaky test", "Claude wants to run: cargo test"),
                       "error": ("Fix the flaky test", "Claude stopped with an error."),
                       "other": ("cargo build", "The command finished after 42 s.")]
        let (title, body) = samples[kind] ?? samples["needs_input"]!
        post(AppNotification(sessionId: "", projectId: AppModel.shared.currentProject?.id ?? "", kind: kind, title: "Test: " + title, body: body))
    }

    var recent: [(AppNotification, Date)] = []

    func updateBadge(state: DaemonState) {
        guard AppModel.shared.setting("notifications.badge")?.bool ?? true else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let n = state.sessions.filter { $0.activity == .needsInput || ($0.unread && $0.state == .running) }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["session_id"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                AppModel.shared.selectSession(id)
            }
        }
        completionHandler()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    static let adeCompareBaseChanged = Notification.Name("octomux.compareBaseChanged")
}
