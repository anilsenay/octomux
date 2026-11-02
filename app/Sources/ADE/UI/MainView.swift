import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        let m = T.m
        let flat = m.inset == 0
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .frame(width: 252)
                    .background(m.sidebarMaterial ? AnyView(VisualEffect(material: .sidebar)) : AnyView(T.frame))
                if flat { Hairline(vertical: true) }
            }
            VStack(spacing: 0) {
                TopBar()
                if flat { Hairline() }
                VStack(spacing: m.inset) {
                    TerminalArea()
                    if model.isDockOpen(model.currentProject?.id) {
                        DockView()
                    }
                }
                .padding(.trailing, model.rightPanelVisible ? 0 : m.inset)
                .padding(.leading, model.sidebarVisible ? 0 : m.inset)
                if flat { Hairline() }
                StatusBar()
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            if model.rightPanelVisible {
                if flat { Hairline(vertical: true) }
                RightPanel()
                    .frame(width: 320)
                    .background(T.surface)
                    .clipShape(RoundedRectangle(cornerRadius: m.cardR, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: m.cardR, style: .continuous).stroke(T.border))
                    .padding(.leading, m.inset)
                    .padding(.trailing, m.inset)
                    .padding(.top, m.topH)
                    .padding(.bottom, m.statusH)
            }
        }
        .background(T.frame)
        .foregroundStyle(T.text)
        .tint(T.accent)
        .overlay {
            if model.paletteVisible { CommandPalette() }
        }
        .sheet(item: $model.newWorktreeFor) { p in
            NewWorktreeSheet(project: p) { model.newWorktreeFor = nil }.environmentObject(model)
        }
        .overlay(alignment: .top) {
            if let err = model.lastError {
                ErrorBanner(text: err) { model.lastError = nil }.padding(.top, 40)
            }
        }
        .ignoresSafeArea()
        .id(theme.revision)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
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
        GeometryReader { geo in content(width: geo.size.width) }
            .frame(height: T.m.topH)
            .background(WindowDragArea())
    }

    /// Fits the bar into `width`: pinned agent labels go first, then tab titles shrink.
    private func layout(width: CGFloat) -> (labels: Bool, chars: Int, compact: Bool) {
        let n = CGFloat(max(1, model.currentTabs.count))
        let leading: CGFloat = model.sidebarVisible ? 2 : 72 + 140
        let compact = width < 620
        let fixed: CGFloat = (compact ? 170 : 390) + leading   // +, terminal, diff, open in, splits, panel, menu, gaps
        let pinnedIcons = CGFloat(model.pinnedProfiles.count) * 30
        let pinnedFull = model.pinnedProfiles.reduce(CGFloat(0)) { $0 + 40 + CGFloat($1.name.count) * 7 }
        let tabMinimum = n * 110
        let labels = !compact && width - fixed - pinnedFull - tabMinimum > 0
        let avail = width - fixed - (labels ? pinnedFull : pinnedIcons)
        let perTab = min(210, avail / n)
        return (labels, max(3, Int((perTab - 64) / 7)), compact)
    }

    private func content(width: CGFloat) -> some View {
        let m = T.m
        let fit = layout(width: width)
        return HStack(spacing: 6) {
            if !model.sidebarVisible {
                Spacer().frame(width: 72)
                if let p = model.currentProject {
                    ProjectIconView(project: p, size: 16)
                    Text(p.name).font(T.headline).padding(.trailing, 6)
                }
            }
            HStack(spacing: m.tabStyle == .underline ? 0 : 2) {
                ForEach(Array(model.currentTabs.enumerated()), id: \.element.id) { i, t in
                    TabChip(tab: t, index: i, maxChars: fit.chars)
                }
            }
            .padding(m.tabStyle == .segment ? 3 : 0)
            .background(m.tabStyle == .segment && !model.currentTabs.isEmpty ? RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.hover) : nil)
            .fixedSize()
            NewSessionMenu(projectId: model.currentProject?.id, compact: false)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                pinned(labels: fit.labels)
                Button { model.newSession(profileId: nil) } label: { AgentIcon(icon: "terminal", size: 12) }
                    .buttonStyle(ChromeButtonStyle()).help("New Terminal (⌘T)")
                Hairline(vertical: true).frame(height: 16).padding(.horizontal, 4)
                if !fit.compact {
                    if let wp = model.currentWorkPath, let stat = git.diffStat(for: wp), stat.files > 0 {
                        Button { model.rightPanelVisible = true } label: {
                            HStack(spacing: 4) {
                                Text("+\(stat.added)").foregroundStyle(T.green)
                                Text("−\(stat.removed)").foregroundStyle(T.red)
                            }
                            .font(T.mono(11.5, .medium))
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
                        }
                        .buttonStyle(.plain).help("\(stat.files) changed files")
                    }
                    if let p = model.currentProject {
                        OpenInButton(path: p.path)
                    }
                    Button { model.newSession(profileId: nil, split: .right) } label: { Image(systemName: "rectangle.split.2x1") }
                        .buttonStyle(ChromeButtonStyle()).help("Split Right (⌘D)")
                    Button { model.newSession(profileId: nil, split: .down) } label: { Image(systemName: "rectangle.split.1x2") }
                        .buttonStyle(ChromeButtonStyle()).help("Split Down (⌘⇧D)")
                }
                Button { model.rightPanelVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(ChromeButtonStyle(active: model.rightPanelVisible)).help("Changes / History / Files (⌘⌥B)")
                if let s = model.session(model.focusedSessionId) {
                    Menu {
                        SessionMenu(session: s)
                    } label: { Image(systemName: "ellipsis").foregroundStyle(T.text2) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("Session")
                }
            }
            }
            .fixedSize()
        .font(.system(size: 12.5))
        .foregroundStyle(T.text2)
        .padding(.leading, model.sidebarVisible ? 2 : 0)
        .padding(.trailing, 10)
        .frame(width: width, height: m.topH, alignment: .leading)
        .clipped()
    }
}

extension TopBar {
    @ViewBuilder func pinned(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(model.pinnedProfiles) { p in
                Button { model.newSession(profileId: p.id) } label: {
                    HStack(spacing: 6) {
                        AgentIcon(icon: p.icon, size: 11)
                        if labels { Text(p.name).font(T.small).foregroundStyle(T.text2).lineLimit(1).fixedSize() }
                    }
                }
                .buttonStyle(ChromeButtonStyle()).help("New \(p.name) session")
            }
        }
    }
}

struct TabChip: View {
    @EnvironmentObject var model: AppModel
    let tab: Tab
    let index: Int
    var maxChars = 24
    @State private var hover = false

    var body: some View {
        let m = T.m
        let selected = tab.id == model.activeTabId
        let ids = tab.layout.sessions
        let lead = model.session(tab.activeSessionId ?? ids.first)
        HStack(spacing: 7) {
            if let lead { AgentIcon(icon: iconName(for: lead, model: model), size: 11) }
            Text(Self.clip(lead?.displayTitle ?? "Tab", maxChars)).lineLimit(1).fixedSize()
            if ids.count > 1 { Text("\(ids.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3) }
            if let s = ids.compactMap({ model.session($0) }).first(where: { $0.activity == .needsInput || $0.activity == .working || $0.unread }) {
                if s.activity == .needsInput { Circle().fill(T.amber).frame(width: 6, height: 6) }
                else if s.activity == .working { Circle().fill(T.accent).frame(width: 6, height: 6) }
                else { Circle().fill(T.green).frame(width: 6, height: 6) }
            }
            Button { model.client.call("tab.close", ["id": tab.id]) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain).foregroundStyle(T.text3).opacity(hover ? 1 : 0)
        }
        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? T.text : T.text2)
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(height: m.tabStyle == .underline ? m.topH : m.tabH)
        .background(background(selected: selected))
        .overlay(alignment: .bottom) {
            if m.tabStyle == .underline {
                Rectangle().fill(selected ? T.accent : .clear).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selectTab(tab.id) }
        .help(index < 9 ? "⌘\(index + 1)" : "")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(1, n - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    @ViewBuilder private func background(selected: Bool) -> some View {
        let m = T.m
        switch m.tabStyle {
        case .underline:
            Rectangle().fill(hover && !selected ? T.hover : .clear)
        case .pill, .segment:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? T.raised : hover ? T.hover : .clear)
                .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1)
        }
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
            Image(systemName: "plus").font(.system(size: compact ? 10 : 13, weight: .semibold)).foregroundStyle(T.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: compact ? 18 : 26, height: compact ? 18 : 26)
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
        VStack(spacing: 10) {
            if let s {
                AgentIcon(icon: iconName(for: s, model: model), size: 26).opacity(0.7).padding(.bottom, 4)
                Text(s.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(T.text)
                Text(s.state == .stopped ? "Stopped" : "Exited\(s.exitCode.map { " with code \($0)" } ?? "")")
                    .font(T.body).foregroundStyle(T.text2)
                HStack(spacing: 8) {
                    Button(s.kind == .agent ? "Resume" : "Restart") { model.restart(s.id) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    Button("Remove") { model.remove(s.id, confirm: false) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 6)
                if s.kind == .agent, s.agentSessionId != nil {
                    Text("Resume continues the same conversation.").font(T.caption).foregroundStyle(T.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.surface)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let p = model.currentProject {
                ProjectIconView(project: p, size: 44).padding(.bottom, 6)
                Text(p.name).font(.system(size: 20, weight: .bold)).foregroundStyle(T.text)
                Text(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(T.mono(12)).foregroundStyle(T.text3)
                HStack(spacing: 8) {
                    ForEach(model.enabledProfiles.prefix(4)) { prof in
                        Button { model.newSession(profileId: prof.id) } label: {
                            HStack(spacing: 7) { AgentIcon(icon: prof.icon, size: 12); Text(prof.name) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button { model.newSession(profileId: nil) } label: {
                        HStack(spacing: 7) { AgentIcon(icon: "terminal", size: 12); Text("Terminal") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 10)
                Text("⌘T terminal · ⌘⇧T first pinned agent").font(T.caption).foregroundStyle(T.text3).padding(.top, 4)
            } else {
                Image(systemName: "folder.badge.plus").font(.system(size: 36, weight: .light)).foregroundStyle(T.text3)
                Text("Add a project to get started").font(.system(size: 17, weight: .semibold)).foregroundStyle(T.text)
                Text("A project is any folder. Sessions, tabs and actions live under it.").font(T.body).foregroundStyle(T.text2)
                Button("Add Project…") { model.addProject() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.surface)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        let m = T.m
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
        }
        .font(m.monoLabels ? T.mono(11) : T.caption)
        .foregroundStyle(T.text2)
        .padding(.leading, model.sidebarVisible ? 6 : 14)
        .padding(.trailing, 8)
        .frame(height: m.statusH)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func bar(full: Bool) -> some View {
        HStack(spacing: 14) {
            let working = model.state.sessions.filter { $0.activity == .working && $0.state == .running }.count
            let waiting = model.state.sessions.filter { $0.activity == .needsInput }.count
            if working > 0 {
                HStack(spacing: 6) { Circle().fill(T.accent).frame(width: 6, height: 6); Text(full ? "\(working) working" : "\(working)") }
                    .fixedSize().help("\(working) agents working")
            }
            if waiting > 0 {
                Button { model.nextNeedingInput() } label: {
                    HStack(spacing: 6) { Circle().fill(T.amber).frame(width: 6, height: 6); Text(full ? "\(waiting) waiting" : "\(waiting)") }
                }
                .buttonStyle(.plain).foregroundStyle(T.amber).fixedSize().help("Jump to the next session waiting for input (⌘⇧U)")
            }
            if working == 0 && waiting == 0 {
                Text("Idle").foregroundStyle(T.text3).fixedSize()
            }
            if full, let wp = model.currentWorkPath, let branch = git.branch(for: wp) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(branch).font(T.mono(11))
                    if let stat = git.diffStat(for: wp), stat.files > 0 {
                        Text("· \(stat.files) changed").foregroundStyle(T.text3)
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 8)
            UsageStatus(compact: !full)
            ActionsControl().fixedSize()
            Button { model.toggleDock() } label: {
                HStack(spacing: 5) { Image(systemName: "terminal").font(.system(size: 10.5)); if full { Text("Terminal") } }
            }
            .buttonStyle(ChromeButtonStyle(active: model.isDockOpen(model.currentProject?.id)))
            .fixedSize()
            .help("Toggle dock (⌘J)").disabled(model.currentProject == nil)
        }
    }
}

/// Agent rate limits in the status bar: the focused session's profile plus
/// profiles marked "always show". Click for details.
struct UsageStatus: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        let open = Binding(get: { model.usagePopoverOpen && !compact }, set: { model.usagePopoverOpen = $0 })
        let shown = model.usageProfilesShown()
        if !shown.isEmpty {
            Button { model.usagePopoverOpen.toggle() } label: {
                HStack(spacing: 12) {
                    ForEach(shown, id: \.0.id) { prof, readings in
                        HStack(spacing: 6) {
                            AgentIcon(icon: prof.icon, size: 10)
                            ForEach(compact ? Array(readings.prefix(1)) : readings) { r in
                                if !compact { Text(r.shortName).foregroundStyle(T.text3) }
                                UsageMeter(percent: r.effectivePercent, primary: r.window == "five_hour").frame(width: compact ? 30 : 44)
                                Text(r.isReset ? "0%" : "\(Int(r.usedPercent.rounded()))%").font(T.mono(11))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Usage limits — click for details")
            .popover(isPresented: open, arrowEdge: .top) { UsagePopover().environmentObject(model) }
        }
    }
}

struct UsageMeter: View {
    let percent: Double
    var primary = true
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(T.border)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, percent / 100)))
            }
        }
        .frame(height: 5)
    }
    var color: Color { percent >= 90 ? T.red : percent >= 70 ? T.amber : primary ? T.accent : T.text2 }
}

struct UsagePopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage limits").font(T.headline).foregroundStyle(T.text)
            let profiles = model.enabledProfiles.filter { p in model.state.usage.contains { $0.profileId == p.id } }
            if profiles.isEmpty {
                Text("No readings yet. They arrive while a Claude or Codex session runs.").font(T.body).foregroundStyle(T.text2)
            }
            ForEach(profiles) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        AgentIcon(icon: p.icon, size: 12)
                        Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                        Spacer()
                        Toggle("Always show", isOn: Binding(get: { model.usageAlwaysShown(p.id) }, set: { model.setUsageAlwaysShown(p.id, $0) }))
                            .toggleStyle(.checkbox).font(T.caption).foregroundStyle(T.text2)
                    }
                    ForEach(model.usage(of: p.id)) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.longName).font(T.body).foregroundStyle(T.text2)
                                Spacer()
                                Text(r.isReset ? "reset" : "\(Int(r.usedPercent.rounded()))%").font(T.mono(12, .semibold)).foregroundStyle(T.text)
                            }
                            UsageMeter(percent: r.effectivePercent, primary: r.window == "five_hour")
                            HStack {
                                if let at = r.resetsAt, !r.isReset { Text("resets \(relative(at))").font(T.caption).foregroundStyle(T.text3) }
                                Spacer()
                                Text("updated \(relative(r.observedAt))").font(T.caption).foregroundStyle(T.text3)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border))
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(T.raised)
    }

    func relative(_ t: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}
