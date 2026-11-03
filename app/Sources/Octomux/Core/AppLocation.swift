import AppKit

/// Where the app runs from. Opened straight from the disk image (or from Downloads, which macOS runs from a
/// random read-only "translocated" path), the launchd agent and the agents' hooks would point at a path that
/// goes away; so before anything starts, offer to move the app to /Applications and relaunch it from there.
enum AppLocation {
    static var bundlePath: String { Bundle.main.bundlePath }

    /// A dev run (`OCTOMUX_HOME` / `OCTOMUX_BIN`, or the bare SwiftPM binary) is never moved.
    static var isDevRun: Bool {
        Paths.homeFromEnv || Paths.env("BIN") != nil || !bundlePath.hasSuffix(".app")
    }

    static var needsMove: Bool {
        guard !isDevRun else { return false }
        return bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    /// Returns true when the app is quitting (moved and relaunched, or the user chose Quit).
    static func offerMoveIfNeeded() -> Bool {
        guard needsMove else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Octomux to Applications?"
        alert.informativeText = "Octomux keeps a background service that runs your terminal sessions, so it has to live in a fixed place. It will be moved to the Applications folder and opened again from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }
        let dest = URL(fileURLWithPath: "/Applications/Octomux.app")
        do {
            try move(to: dest)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Could not move Octomux"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag Octomux into the Applications folder in Finder, then open it from there."
            fail.runModal()
            NSApp.terminate(nil)
            return true
        }
        relaunch(dest)
        return true
    }

    private static func move(to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            // An older copy: quit it if it is running, then put it in the Trash (recoverable).
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.bundleURL?.standardizedFileURL == dest.standardizedFileURL {
                app.terminate()
            }
            try fm.trashItem(at: dest, resultingItemURL: nil)
        }
        try fm.copyItem(at: URL(fileURLWithPath: bundlePath), to: dest)
        // A copy keeps the download's quarantine flag, and a quarantined app that Finder did not move is
        // translocated again on launch. The app is notarized; Gatekeeper already checked it to get here.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? task.run()
        task.waitUntilExit()
    }

    private static func relaunch(_ app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
