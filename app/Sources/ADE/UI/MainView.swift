import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView().frame(width: 250)
                Divider()
            }
            VStack(spacing: 0) {
                TopBar()
                Divider()
                if model.isDockOpen(model.currentProject?.id) {
                    VSplitView {
                        TerminalArea().frame(minHeight: 120)
                        DockView().frame(minHeight: 90, idealHeight: 240)
                    }
                } else {
                    TerminalArea()
                }
                Divider()
                StatusBar()
            }
            .background(Palette.chromeBG)
            if model.rightPanelVisible {
                Divider()
                ChangesPanel().frame(width: 300).background(Palette.sidebarBG)
            }
        }
        .overlay(alignment: .top) {
            if let err = model.lastError {
                ErrorBanner(text: err) { model.lastError = nil }.padding(.top, 40)
            }
        }
        .ignoresSafeArea()
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(3)
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { dismiss() } }
    }
}

/// Tabs of the current project + new-session controls.
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        HStack(spacing: 4) {
            if !model.sidebarVisible { Spacer().frame(width: 70) }
            if let p = model.currentProject {
                HStack(spacing: 5) {
                    ProjectIconView(project: p, size: 12)
                    Text(p.name).font(.system(size: 12, weight: .semibold))
                    if let branch = GitInfo.shared.branch(for: p.path) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(branch).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.currentTabs.enumerated()), id: \.element.id) { i, t in
                        TabChip(tab: t, index: i)
                    }
                }
            }
            NewSessionMenu(projectId: model.currentProject?.id, compact: false)
            ForEach(model.pinnedProfiles) { p in
                Button { model.newSession(profileId: p.id) } label: { AgentIcon(icon: p.icon, size: 12) }
                    .buttonStyle(ChromeButtonStyle()).help("New \(p.name)")
            }
            Button { model.newSession(profileId: nil) } label: { Image(systemName: "terminal").font(.system(size: 12)) }
                .buttonStyle(ChromeButtonStyle()).help("New Terminal (⌘T)")
            Spacer(minLength: 8)
            if let p = model.currentProject, let stat = git.diffStat(for: p.path), stat.files > 0 {
                Button { model.rightPanelVisible = true } label: {
                    HStack(spacing: 3) {
                        Text("+\(stat.added)").foregroundStyle(.green)
                        Text("−\(stat.removed)").foregroundStyle(.red)
                    }.font(.system(size: 11, weight: .medium, design: .monospaced))
                }.buttonStyle(ChromeButtonStyle()).help("\(stat.files) changed files")
            }
            if let p = model.currentProject {
                OpenInButton(path: p.path)
            }
            Button { model.newSession(profileId: nil, split: .right) } label: { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(ChromeButtonStyle()).help("Split Right (⌘D)")
            Button { model.newSession(profileId: nil, split: .down) } label: { Image(systemName: "rectangle.split.1x2") }
                .buttonStyle(ChromeButtonStyle()).help("Split Down (⌘⇧D)")
            Button { model.rightPanelVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(ChromeButtonStyle()).help("Changes panel (⌘⌥B)")
                .foregroundStyle(model.rightPanelVisible ? Color.accentColor : .secondary)
            if let s = model.session(model.focusedSessionId) {
                Menu {
                    SessionMenu(session: s)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Session")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(WindowDragArea())
    }
}

struct TabChip: View {
    @EnvironmentObject var model: AppModel
    let tab: Tab
    let index: Int
    @State private var hover = false

    var body: some View {
        let selected = tab.id == model.activeTabId
        let ids = tab.layout.sessions
        let lead = model.session(tab.activeSessionId ?? ids.first)
        HStack(spacing: 5) {
            if let lead { AgentIcon(icon: iconName(for: lead, model: model), size: 10) }
            Text(lead?.displayTitle ?? "Tab").lineLimit(1).frame(maxWidth: 160)
            if ids.count > 1 { Text("\(ids.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            if let s = ids.compactMap({ model.session($0) }).first(where: { $0.activity == .needsInput || $0.activity == .working || $0.unread }) {
                ActivityIndicator(session: s)
            }
            Button { model.client.call("tab.close", ["id": tab.id]) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).opacity(hover || selected ? 0.7 : 0)
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.09) : hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selectTab(tab.id) }
        .help(index < 9 ? "⌘\(index + 1)" : "")
    }
}

/// The "+" menu: Terminal, agents, manage.
struct NewSessionMenu: View {
    @EnvironmentObject var model: AppModel
    let projectId: String?
    let compact: Bool

    var body: some View {
        Menu {
            Button { model.newSession(profileId: nil, projectId: projectId) } label: { Label("Terminal", systemImage: "terminal") }
            Section("Agents") {
                ForEach(model.enabledProfiles) { p in
                    Button { model.newSession(profileId: p.id, projectId: projectId) } label: { Text(p.name) }
                }
                Button("Manage Agents…") { SettingsWindow.show(section: .agents) }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: compact ? 10 : 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: compact ? 16 : 24)
        .help("New session")
    }
}

struct TerminalArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneContainerView {
        let c = TerminalHost.shared.container
        DispatchQueue.main.async { TerminalHost.shared.render(force: true) }
        return c
    }
    func updateNSView(_ nsView: PaneContainerView, context: Context) {
        TerminalHost.shared.render()
    }
}

/// Lets the user drag the window by empty top-bar space (window has a hidden title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct DormantPaneView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String

    var body: some View {
        let s = model.session(sessionId)
        VStack(spacing: 12) {
            if let s {
                AgentIcon(icon: iconName(for: s, model: model), size: 28).opacity(0.6)
                Text(s.displayTitle).font(.title3)
                Text(s.state == .stopped ? "Stopped" : "Exited\(s.exitCode.map { " with code \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(s.kind == .agent ? "Resume" : "Restart") { model.restart(s.id) }.keyboardShortcut(.defaultAction)
                    Button("Remove") { model.remove(s.id, confirm: false) }
                }
                if s.kind == .agent, s.agentSessionId != nil {
                    Text("Resume continues the same conversation.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.tertiary)
            if let p = model.currentProject {
                Text(p.name).font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    Button { model.newSession(profileId: nil) } label: { Label("Terminal", systemImage: "terminal") }
                    ForEach(model.enabledProfiles.prefix(4)) { prof in
                        Button { model.newSession(profileId: prof.id) } label: { Text(prof.name) }
                    }
                }
                .controlSize(.large)
            } else {
                Text("Add a project to get started").font(.title3)
                Button("Add Project…") { model.addProject() }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        HStack(spacing: 10) {
            let working = model.state.sessions.filter { $0.activity == .working && $0.state == .running }.count
            let waiting = model.state.sessions.filter { $0.activity == .needsInput }.count
            if working > 0 {
                Label("\(working) working", systemImage: "circle.dotted").help("Agents working")
            }
            if waiting > 0 {
                Button { model.nextNeedingInput() } label: { Label("\(waiting) waiting", systemImage: "exclamationmark.bubble") }
                    .buttonStyle(.plain).foregroundStyle(.orange).help("Jump to the next session waiting for input (⌘⇧U)")
            }
            if let p = model.currentProject, let stat = GitInfo.shared.diffStat(for: p.path) {
                HStack(spacing: 4) {
                    Text("+\(stat.added)").foregroundStyle(.green)
                    Text("−\(stat.removed)").foregroundStyle(.red)
                    if stat.files > 0 { Text("· \(stat.files) changed").foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if let s = model.session(model.focusedSessionId) {
                Text(s.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head).foregroundStyle(.tertiary)
            }
            ActionsControl()
            Button { model.toggleDock() } label: {
                Label("Terminal", systemImage: "terminal")
                    .foregroundStyle(model.isDockOpen(model.currentProject?.id) ? Color.accentColor : .secondary)
            }
            .buttonStyle(ChromeButtonStyle()).help("Toggle dock (⌘J)").disabled(model.currentProject == nil)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}
