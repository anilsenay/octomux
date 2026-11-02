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
            } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 14)
        }
    }
}

// MARK: - Remote-aware file reads

enum RemoteFS {
    /// Text of a file on the current host (nil when unreadable; "Binary file" note for binaries).
    static func readText(_ path: String, max: Int = 512 * 1024) -> String? {
        if AppModel.shared.host.isRemote {
            guard let r = try? AppModel.shared.client.callSync("fs.read", ["path": path, "max": max]) as? [String: Any] else { return nil }
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
    private let queue = DispatchQueue(label: "ade.git", qos: .utility)

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
            if branch != nil, let out = Self.git(["diff", "--numstat", "HEAD"], in: path) {
                var s = Stat()
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count >= 3 else { continue }
                    s.added += Int(parts[0]) ?? 0
                    s.removed += Int(parts[1]) ?? 0
                    s.files += 1
                }
                stat = s
            }
            DispatchQueue.main.async {
                if self.branches[path] != branch { self.branches[path] = branch }
                if self.stats[path] != stat { self.stats[path] = stat }
            }
        }
    }

    static func git(_ args: [String], in dir: String) -> String? {
        if AppModel.shared.host.isRemote {
            // Remote host: the daemon there runs git (`git.run`, allowlisted).
            guard let r = try? AppModel.shared.client.callSync("git.run", ["cwd": dir, "args": args]) as? [String: Any],
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
                if let err { NSLog("ADE notification authorization error: \(err)") }
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
        let sound = model.setting("notifications.sound")?.bool ?? true
        if available {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            if sound { content.sound = .default }
            content.userInfo = ["session_id": n.sessionId]
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        if !NSApp.isActive {
            if !available, sound { NSSound(named: "Glass")?.play() }
            NSApp.requestUserAttention(.informationalRequest)
        }
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
