import SwiftUI

/// Instead of the tab strip: where you are ("Home · Personal" or "agent · project · branch"), then the project's
/// buttons. A chat-capable session gets its Chat / Terminal switch here.
struct ShellBreadcrumb: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var git = GitInfo.shared

    var body: some View {
        GeometryReader { g in content(compact: g.size.width < 820) }
            .frame(height: T.m.topH)
    }

    private func content(compact: Bool) -> some View {
        // The Tasks window has no Home: its root is the tasks (⌘0 opens the assistant), then the picked task.
        let tasks = model.shellNav == .tasks
        let home = !tasks && (model.shellHomeShown || (model.activeTab == nil && model.activeDoc == nil))
        let s = home ? nil : model.session(model.focusedSessionId)
        let task = tasks ? model.task(model.shellTaskId) : nil
        return HStack(spacing: 6) {
            if !model.sidebarVisible { WindowDragArea().frame(width: TopLeftControls.width) }
            Button { model.shellGoHome() } label: {
                Text(tasks ? "Tasks" : "Home").font(.system(size: T.k * 13, weight: home ? .semibold : .medium)).foregroundStyle(home ? T.text : T.text2)
            }
            .buttonStyle(.plain).pointerCursor().help(tasks ? "The assistant (⌘0)" : "Home (⌘0)")
            // On Home, which Home (when the window's tree leaves it to the layout).
            if home, !tasks, model.shellTree?.has(.home) == true, model.shellTree?.variant(of: .home) == nil { HomeStyleButton() }
            Text("·").foregroundStyle(T.text3)
            if let task {
                TaskRow.glyph(task.state).frame(width: 14)
                Text(task.title).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
                if s != nil { Text("·").foregroundStyle(T.text3) }
            }
            if home {
                Text(model.workspace?.name ?? "").font(.system(size: T.k * 13)).foregroundStyle(T.text3).lineLimit(1)
            } else if let d = model.activeDoc {
                Image(systemName: d.icon).font(T.icon(11)).foregroundStyle(T.text3)
                Text(d.title).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
            } else if let s {
                AgentIcon(icon: iconName(for: s, model: model), size: 12)
                Text(s.displayTitle).font(.system(size: T.k * 13, weight: task == nil ? .semibold : .regular)).lineLimit(1)
                if let p = model.project(s.projectId) {
                    Text("·").foregroundStyle(T.text3)
                    Text(p.name).font(.system(size: T.k * 13)).foregroundStyle(T.text2).lineLimit(1)
                }
                if let b = git.branch(for: model.workPath(of: s)) {
                    Text("·").foregroundStyle(T.text3)
                    Image(systemName: "arrow.triangle.branch").font(T.icon(10)).foregroundStyle(T.text3)
                    Text(b).font(T.mono(12)).foregroundStyle(T.text3).lineLimit(1)
                }
                ActivityIndicator(session: s)
                if model.canChat(s) {
                    SegmentedTabs(items: [("chat", "Chat"), ("terminal", "Terminal")], selection: Binding(
                        get: { model.isChat(s.id) ? "chat" : "terminal" },
                        set: { v in if (v == "chat") != model.isChat(s.id) { model.toggleChat(s.id) } }))
                        .frame(width: 150).padding(.leading, 6)
                }
            }
            WindowDragArea().frame(minWidth: 8, maxWidth: .infinity)
            HStack(spacing: 4) {
                ForEach(model.layout.shown(.topBar), id: \.self) { id in TopBarTool(id: id, compact: compact) }
            }
            .fixedSize()
        }
        .font(.system(size: T.k * 13))
        .foregroundStyle(T.text2)
        .padding(.leading, model.sidebarVisible ? 14 : 0)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }
}

