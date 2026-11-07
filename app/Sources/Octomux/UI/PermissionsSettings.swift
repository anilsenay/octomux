import AppKit
import SwiftUI

/// Settings → Permissions: macOS checks screen recording and accessibility for programs in sessions
/// (an agent taking a screenshot) against Octomux's background app, "Octomux Sessions" (the daemon).
struct SessionPermissionsGroup: View {
    @EnvironmentObject var model: AppModel
    @State private var status: [String: Any] = [:]
    @State private var asked = false

    var body: some View {
        SettingsGroup("Programs in your sessions", desc: "macOS asks for these in the name of \(Self.appName), the part of Octomux that runs your sessions.") {
            row("Screen recording", key: "screen_recording", desc: "Screenshots and screen capture (screencapture, browser tools).",
                pane: "Privacy_ScreenCapture") {
                if !asked {
                    asked = true
                    model.client.call("permissions.request", ["kind": "screen_recording"]) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() } }
                } else {
                    Self.open("Privacy_ScreenCapture")
                }
            }
            row("Accessibility", key: "accessibility", desc: "Clicking and typing in other apps (UI automation tools).", pane: "Privacy_Accessibility") {
                Self.open("Privacy_Accessibility")
            }
            if let app = status["app"] as? String, !app.isEmpty {
                SettingRow("Granted to", desc: "Add this app with + in System Settings if it is not listed. A change applies to sessions started after it; restart Octomux (Settings → Advanced) to apply it to running ones.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Self.bundle(of: app)]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    static var appName: String { Paths.isDevVariant ? "“Octomux Dev Sessions”" : "“Octomux Sessions”" }

    private func row(_ title: String, key: String, desc: String, pane: String, action: @escaping () -> Void) -> some View {
        let on = status[key] as? Bool
        return SettingRow(title, desc: desc) {
            HStack(spacing: 8) {
                if let on {
                    HStack(spacing: 5) {
                        Circle().fill(on ? T.green : T.amber).frame(width: 7, height: 7)
                        Text(on ? "Allowed" : "Not allowed").font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                    }
                }
                if on != true {
                    Button(key == "screen_recording" && !asked ? "Allow…" : "Open System Settings", action: action)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func refresh() {
        guard !model.host.isRemote else { return }
        model.client.call("permissions.status", [:]) { r in
            if case .success(let v) = r, let d = v as? [String: Any] { DispatchQueue.main.async { status = d } }
        }
    }

    static func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    /// The .app around the daemon's binary (…/Octomux Sessions.app/Contents/MacOS/octomux), else the binary.
    static func bundle(of exe: String) -> URL {
        var u = URL(fileURLWithPath: exe)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.pathExtension == "app" ? u : URL(fileURLWithPath: exe)
    }
}
