import SwiftUI

/// A small window over any app (global shortcut, menu bar menu, File menu): pick a project and an agent, type a
/// prompt. Return starts the session and leaves you where you were (its notification tells you when it needs
/// you); ⌘Return also brings Octomux forward on it.
final class QuickComposer {
    static let shared = QuickComposer()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resignObs: Any?
    let state = QuickComposerState()

    func toggle() { panel == nil ? show() : close() }
    var debugWindow: NSWindow? { panel }

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        state.reset()
        let host = NSHostingView(rootView: QuickComposerView(state: state, send: { [weak self] show in self?.send(show: show) },
                                                            close: { [weak self] in self?.close() })
            .environmentObject(AppModel.shared))
        let size = NSSize(width: 640, height: host.fittingSize.height)
        let w = ComposerPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.appearance = NSAppearance(named: ThemeStore.shared.isDark ? .darkAqua : .aqua)
        w.contentView = host
        // Like Spotlight: centered, a third of the way down the screen the mouse is on.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.maxY - vis.height / 3 - size.height / 2))
        }
        w.orderFrontRegardless()
        w.makeKey()
        panel = w
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            if e.keyCode == 53 { self.close(); return nil }                                  // esc
            if e.keyCode == 36 || e.keyCode == 76 {                                          // return
                if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) { return e }   // a new line
                self.send(show: e.modifierFlags.contains(.command))
                return nil
            }
            return e
        }
        resignObs = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            // Clicking elsewhere closes it (after a moment: its own pop-up menus take key while open).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, let p = self.panel, !p.isKeyWindow else { return }
                self.close()
            }
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObs { NotificationCenter.default.removeObserver(o) }
        keyMonitor = nil; resignObs = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func debugSend(show: Bool) { send(show: show) }

    private func send(show: Bool) {
        let model = AppModel.shared
        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let project = model.project(state.projectId), let profile = model.profile(state.profileId) else { return }
        UserDefaults.standard.set(profile.id, forKey: "octomux.chatProfile")
        let kind = profile.kind
        close()
        model.newSession(profileId: profile.id, projectId: project.id, prompt: text, chat: true,
                         extraArgs: ChatLaunchOptions.load(kind).args(kind)) { id in
            ChatFirstMessage.set(id, text)
            if show {
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.delegate as? AppDelegate)?.openMainWindow()
                model.selectSession(id)
            }
        }
    }
}

final class QuickComposerState: ObservableObject {
    @Published var text = ""
    @Published var projectId: String?
    @Published var profileId: String?

    func reset() {
        let m = AppModel.shared
        text = ""
        if m.project(projectId) == nil || projectId == nil { projectId = m.currentProject?.id ?? m.state.projects.first { !$0.archived }?.id }
        let ws = m.project(projectId)?.workspaceId
        let options = QuickComposerView.profiles(m, project: projectId)
        let last = UserDefaults.standard.string(forKey: "octomux.chatProfile")
        profileId = (options.first { $0.id == m.defaultChatProfile(workspace: ws)?.id } ?? options.first { $0.id == last } ?? options.first)?.id
    }
}

struct QuickComposerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: QuickComposerState
    let send: (Bool) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    static func profiles(_ m: AppModel, project: String?) -> [Profile] {
        m.enabledProfiles(forProject: project).filter { $0.kind == .claude || $0.kind == .codex || $0.icon == "claude" || $0.icon == "codex" }
    }

    var body: some View {
        let profiles = Self.profiles(model, project: state.projectId)
        let profile = profiles.first { $0.id == state.profileId }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentIcon(icon: profile?.icon ?? "claude", size: 18)
                TextField("Ask \(profile?.name ?? "an agent") to…", text: $state.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 17)).lineLimit(1...8)
                    .focused($focused)
            }
            HStack(spacing: 8) {
                Picker("", selection: $state.projectId) {
                    ForEach(model.state.workspaces.sorted { $0.sort < $1.sort }) { w in
                        let ps = model.state.projects.filter { $0.workspaceId == w.id && !$0.archived }.sorted { $0.sort < $1.sort }
                        if !ps.isEmpty {
                            Section(w.name) { ForEach(ps) { p in Text(p.name).tag(Optional(p.id)) } }
                        }
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: state.projectId) { _, _ in
                    if !Self.profiles(model, project: state.projectId).contains(where: { $0.id == state.profileId }) {
                        state.profileId = Self.profiles(model, project: state.projectId).first?.id
                    }
                }
                Picker("", selection: $state.profileId) {
                    ForEach(profiles) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Text("↩ start   ⌘↩ start and show   ⇧↩ new line   esc close")
                    .font(.system(size: 11)).foregroundStyle(T.text3)
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(T.border))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
