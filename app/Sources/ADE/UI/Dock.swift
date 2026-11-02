import AppKit
import SwiftUI

/// A saved one-click command for a project (stored as the project-scoped setting `actions`).
struct ProjectAction: Identifiable, Equatable {
    var id: String { name + "\u{0}" + command }
    var name: String
    var icon: String
    var command: String

    static let icons = ["play.fill", "flask", "hammer", "paperplane", "ant", "shippingbox"]
}

extension AppModel {
    // MARK: Dock state (per project, local UI state)

    func isDockOpen(_ projectId: String?) -> Bool {
        guard let projectId else { return false }
        return (UserDefaults.standard.dictionary(forKey: "ade.dockOpen") as? [String: Bool])?[projectId] ?? false
    }

    func setDockOpen(_ projectId: String, _ open: Bool) {
        var d = UserDefaults.standard.dictionary(forKey: "ade.dockOpen") as? [String: Bool] ?? [:]
        d[projectId] = open
        UserDefaults.standard.set(d, forKey: "ade.dockOpen")
        objectWillChange.send()
    }

    func dockSessions(_ projectId: String?) -> [Session] {
        state.sessions.filter { $0.projectId == projectId && $0.placement == .dock }.sorted { $0.createdAt < $1.createdAt }
    }

    func dockSelection(_ projectId: String?) -> String? {
        guard let projectId else { return nil }
        let sel = (UserDefaults.standard.dictionary(forKey: "ade.dockSel") as? [String: String])?[projectId]
        let list = dockSessions(projectId)
        return list.first { $0.id == sel }?.id ?? list.last?.id
    }

    func selectDock(_ projectId: String, _ sessionId: String) {
        var d = UserDefaults.standard.dictionary(forKey: "ade.dockSel") as? [String: String] ?? [:]
        d[projectId] = sessionId
        UserDefaults.standard.set(d, forKey: "ade.dockSel")
        objectWillChange.send()
        DispatchQueue.main.async { TerminalHost.shared.renderDock(force: true, focus: true) }
    }

    func toggleDock() {
        guard let p = currentProject?.id else { return }
        let open = !isDockOpen(p)
        setDockOpen(p, open)
        // Opening an empty dock gives you a terminal right away.
        if open && dockSessions(p).isEmpty { newDockTerminal() }
        DispatchQueue.main.async { TerminalHost.shared.renderDock(force: true, focus: open) }
        if !open { TerminalHost.shared.focusCurrent() }
    }

    func newDockTerminal() {
        guard let p = currentProject?.id else { return }
        setDockOpen(p, true)
        createDockSession(projectId: p, command: nil, title: nil)
    }

    private func createDockSession(projectId: String, command: String?, title: String?) {
        var params: [String: Any] = ["project_id": projectId, "placement": "dock"]
        if let command { params["command"] = command }
        if let title { params["title"] = title }
        client(for: projectId).call("session.create", params) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let v):
                if let s = (v as? [String: Any])?["session"] as? [String: Any], let id = s["id"] as? String {
                    self.selectDock(projectId, id)
                }
            case .failure(let e): self.lastError = "\(e)"
            }
        }
    }

    // MARK: Actions

    func actions(_ projectId: String?) -> [ProjectAction] {
        guard let projectId, case .array(let arr)? = settingValue("actions", scope: "project:\(projectId)") else { return [] }
        return arr.compactMap { v in
            guard case .object(let o) = v, let name = o["name"]?.string, let cmd = o["command"]?.string else { return nil }
            return ProjectAction(name: name, icon: o["icon"]?.string ?? "play.fill", command: cmd)
        }
    }

    func saveActions(_ projectId: String, _ list: [ProjectAction]) {
        setSetting("actions", list.map { ["name": $0.name, "icon": $0.icon, "command": $0.command] }, scope: "project:\(projectId)")
    }

    func lastAction(_ projectId: String?) -> ProjectAction? {
        let list = actions(projectId)
        guard let projectId else { return list.first }
        let name = (UserDefaults.standard.dictionary(forKey: "ade.lastAction") as? [String: String])?[projectId]
        return list.first { $0.name == name } ?? list.first
    }

    func runAction(_ a: ProjectAction) {
        guard let p = currentProject?.id else { return }
        var d = UserDefaults.standard.dictionary(forKey: "ade.lastAction") as? [String: String] ?? [:]
        d[p] = a.name
        UserDefaults.standard.set(d, forKey: "ade.lastAction")
        setDockOpen(p, true)
        createDockSession(projectId: p, command: a.command, title: a.name)
    }
}

/// Bottom dock: chip strip of the project's dock sessions + the selected one in a card.
struct DockView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("ade.dockHeight") private var height: Double = 220
    @State private var dragStart: Double?

    var body: some View {
        let pid = model.currentProject?.id
        let sessions = model.dockSessions(pid)
        let sel = model.dockSelection(pid)
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(sessions) { s in
                    Chip(selected: s.id == sel, action: { if let pid { model.selectDock(pid, s.id) } }) {
                        Circle().fill(s.isDormant ? T.text3 : s.kind == .action ? T.green : T.text3.opacity(0.7)).frame(width: 6, height: 6)
                        Text(s.displayTitle).lineLimit(1)
                        if s.isDormant { Text("exited").font(.system(size: 10)).foregroundStyle(T.text3) }
                        Button { model.remove(s.id, confirm: false) } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(T.text3)
                    }
                    .contextMenu {
                        Button("Move to Tab") { model.client(for: s.id).call("session.move", ["id": s.id, "placement": "tab"]) }
                        Button("Restart") { model.restart(s.id) }
                        Button("Close", role: .destructive) { model.remove(s.id, confirm: false) }
                    }
                }
                Spacer()
                Text("⌘J").font(T.caption).foregroundStyle(T.text3)
                Button { model.newDockTerminal() } label: { Image(systemName: "plus") }.buttonStyle(ChromeButtonStyle()).help("New terminal in dock")
                Button { model.toggleDock() } label: { Image(systemName: "chevron.down") }.buttonStyle(ChromeButtonStyle()).help("Hide dock (⌘J)")
            }
            .font(.system(size: 11.5))
            .padding(.leading, T.m.inset == 0 ? 8 : 2)
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil { dragStart = height }
                    height = min(700, max(90, (dragStart ?? height) - v.translation.height))
                }
                .onEnded { _ in dragStart = nil })
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            DockArea().frame(height: height)
        }
        .padding(.top, T.m.inset == 0 ? 0 : 0)
        .overlay(alignment: .top) { if T.m.inset == 0 { Hairline() } }
    }
}

struct DockArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneContainerView {
        let c = TerminalHost.shared.dockContainer
        DispatchQueue.main.async { TerminalHost.shared.renderDock(force: true) }
        return c
    }
    func updateNSView(_ nsView: PaneContainerView, context: Context) {
        TerminalHost.shared.renderDock()
    }
}

/// Bottom-bar Actions control: run the last action, pick another, add/edit.
struct ActionsControl: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var editing: ProjectAction?

    var body: some View {
        let pid = model.currentProject?.id
        let list = model.actions(pid)
        HStack(spacing: 2) {
            if let last = model.lastAction(pid) {
                Button { model.runAction(last) } label: {
                    HStack(spacing: 5) { Image(systemName: last.icon).font(.system(size: 10)); Text(last.name) }
                }
                    .buttonStyle(ChromeButtonStyle()).help("Run “\(last.command)” in the dock")
            }
            Menu {
                ForEach(list) { a in
                    Button { model.runAction(a) } label: { Label(a.name, systemImage: a.icon) }
                }
                if !list.isEmpty {
                    Divider()
                    Menu("Edit Action") {
                        ForEach(list) { a in Button(a.name) { editing = a } }
                    }
                }
                Button("Add Action…") { adding = true }
            } label: {
                if list.isEmpty {
                    HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("Actions") }.foregroundStyle(T.text2)
                } else { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(T.text2) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .disabled(pid == nil)
        .sheet(isPresented: $adding) { ActionEditor(action: nil) { adding = false } }
        .sheet(item: $editing) { a in ActionEditor(action: a) { editing = nil } }
    }
}

struct ActionEditor: View {
    @EnvironmentObject var model: AppModel
    let original: ProjectAction?
    let done: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var icon = "play.fill"

    init(action: ProjectAction?, done: @escaping () -> Void) {
        original = action
        self.done = done
        _name = State(initialValue: action?.name ?? "")
        _command = State(initialValue: action?.command ?? "")
        _icon = State(initialValue: action?.icon ?? "play.fill")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Add action" : "Edit action").font(T.title)
            Text("Save a project command to run with one click. It runs in a dock terminal at the project root.")
                .font(.caption).foregroundStyle(T.text2)
            HStack {
                ForEach(ProjectAction.icons, id: \.self) { i in
                    Image(systemName: i).frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(i == icon ? T.accent : T.border))
                        .onTapGesture { icon = i }
                }
            }
            TextField("Name (e.g. Test)", text: $name)
            TextField("Command (e.g. bun test)", text: $command).font(.system(.body, design: .monospaced))
            HStack {
                if let original {
                    Button(role: .destructive) {
                        if let p = model.currentProject?.id { model.saveActions(p, model.actions(p).filter { $0 != original }) }
                        done()
                    } label: { Text("Delete").foregroundStyle(T.red) }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(T.surface)
    }

    func save() {
        guard let p = model.currentProject?.id else { return }
        var list = model.actions(p)
        let a = ProjectAction(name: name, icon: icon, command: command)
        if let original, let i = list.firstIndex(of: original) { list[i] = a } else { list.append(a) }
        model.saveActions(p, list)
        done()
    }
}
