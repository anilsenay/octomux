import AppKit
import Sparkle
import SwiftUI

/// In-app updates: Sparkle 2 checks the appcast (`SUFeedURL` in Info.plist), downloads and verifies the
/// EdDSA-signed zip, and installs it; our toast (`UpdateToast`) is its whole UI, instead of Sparkle's windows.
/// Without a feed URL (dev builds) the updater does not start.
final class Updater: NSObject, ObservableObject, SPUUserDriver {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking                     // a check the user asked for
        case upToDate                     // ... and nothing newer
        case available(version: String)
        case downloading(Double?)         // fraction, nil until the size is known
        case extracting(Double)
        case ready(version: String)       // downloaded; installs on relaunch (or on quit)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var toastVisible = false

    private var updater: SPUUpdater?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancel: (() -> Void)?
    private var ack: (() -> Void)?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var foundVersion = ""

    var feedURL: String? {
        let s = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        return s.isEmpty ? nil : s
    }
    var isEnabled: Bool { updater != nil }
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "a dev build"
    }

    func start() {
        // Dev runs (fixture homes) only with OCTOMUX_UPDATER_TEST=1, for the end-to-end update test.
        guard updater == nil, feedURL != nil, !AppLocation.isDevRun || Paths.env("UPDATER_TEST") == "1" else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try u.start()
            updater = u
        } catch {
            NSLog("updater: \(error.localizedDescription)")
        }
    }

    /// Settings → "Check for Updates…" (and the app menu).
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    // MARK: Toast buttons

    func install() {
        let c = choice; choice = nil
        c?(.install)
    }

    /// × on the toast. An offered update: remind later. A downloaded one: Sparkle installs it when the app quits.
    func dismiss() {
        toastVisible = false
        if let c = choice { choice = nil; c(.dismiss) }
        if let a = ack { ack = nil; a() }
        if case .downloading = phase { cancel?(); cancel = nil }
    }

    func skip() {
        toastVisible = false
        let c = choice; choice = nil
        c?(.skip)
    }

    private func show(_ p: Phase) {
        phase = p
        withAnimation(.easeOut(duration: 0.2)) { toastVisible = true }
    }

    // MARK: SPUUserDriver (Sparkle calls these on the main thread)

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so this is not normally asked; answer yes, no system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancel = cancellation
        show(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundVersion = appcastItem.displayVersionString
        choice = reply
        switch state.stage {
        case .notDownloaded: show(.available(version: foundVersion))
        case .downloaded: show(.ready(version: foundVersion))
        case .installing: show(.installing)
        @unknown default: show(.available(version: foundVersion))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        ack = acknowledgement
        show(.upToDate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.phase == .upToDate { self?.dismiss() }
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        NSLog("updater error: \(e.domain) \(e.code) \(e.localizedDescription) \(e.userInfo)")
        ack = acknowledgement
        show(.failed(error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancel = cancellation
        expected = 0; received = 0
        show(.downloading(nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        phase = .downloading(expected > 0 ? 0 : nil)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        if expected > 0 { phase = .downloading(min(1, Double(received) / Double(expected))) }
    }

    func showDownloadDidStartExtractingUpdate() { cancel = nil; phase = .extracting(0) }
    func showExtractionReceivedProgress(_ progress: Double) { phase = .extracting(progress) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        show(.ready(version: foundVersion))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        toastVisible = false
        phase = .idle
    }

    func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true) }

    func dismissUpdateInstallation() {
        choice = nil; cancel = nil; ack = nil
        if case .failed = phase { return }   // leave the error up until the user closes it
        toastVisible = false
        phase = .idle
    }

    // MARK: Debug

    /// Puts the toast in a state without a feed (screenshots).
    func debugShow(_ p: Phase) { show(p) }
}

/// Bottom-right card: "Octomux 0.2.0 is available · Update Now", then the download progress, then
/// "Update ready · Relaunch Now".
struct UpdateToast: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if updater.toastVisible {
            HStack(alignment: .top, spacing: 10) {
                icon.frame(width: 18, height: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(T.headline).foregroundStyle(T.text)
                    if let detail { Text(detail).font(T.caption).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true) }
                    if let progress = progressValue {
                        ProgressView(value: progress ?? 0, total: 1)
                            .progressViewStyle(.linear).tint(T.accent)
                            .opacity(progress == nil ? 0.4 : 1)
                    }
                    actions
                }
                Spacer(minLength: 0)
                Button { updater.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: T.k * 10, weight: .bold)).foregroundStyle(T.text3)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(closeHelp)
            }
            .padding(12)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 10).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "Octomux is up to date"
        case .available(let v): return "Octomux \(v) is available"
        case .downloading: return "Downloading update…"
        case .extracting: return "Preparing update…"
        case .ready(let v): return "Octomux \(v) is ready"
        case .installing: return "Installing update…"
        case .failed: return "Update failed"
        }
    }

    private var detail: String? {
        switch updater.phase {
        case .upToDate: return "You have \(updater.currentVersion)."
        case .available: return "You have \(updater.currentVersion). Sessions keep running while it updates."
        case .ready: return "Relaunch to finish. Your sessions keep running."
        case .failed(let m): return m
        default: return nil
        }
    }

    /// nil: no bar. .some(nil): indeterminate.
    private var progressValue: Double?? {
        switch updater.phase {
        case .checking: return .some(nil)
        case .downloading(let f): return .some(f)
        case .extracting(let f): return .some(f)
        case .installing: return .some(nil)
        default: return nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch updater.phase {
        case .available:
            HStack(spacing: 8) {
                Button("Update Now") { updater.install() }.buttonStyle(.borderedProminent).tint(T.accent)
                Button("Skip This Version") { updater.skip() }.buttonStyle(.borderless).foregroundStyle(T.text2)
            }
            .controlSize(.small).padding(.top, 2)
        case .ready:
            Button("Relaunch Now") { updater.install() }
                .buttonStyle(.borderedProminent).tint(T.accent).controlSize(.small).padding(.top, 2)
        default: EmptyView()
        }
    }

    private var closeHelp: String {
        switch updater.phase {
        case .available: return "Remind me later"
        case .ready: return "Install when Octomux quits"
        case .downloading: return "Cancel the download"
        default: return "Close"
        }
    }

    @ViewBuilder private var icon: some View {
        switch updater.phase {
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(T.green)
        case .ready: Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(T.accent)
        default: Image(systemName: "arrow.down.circle.fill").foregroundStyle(T.accent)
        }
    }
}
