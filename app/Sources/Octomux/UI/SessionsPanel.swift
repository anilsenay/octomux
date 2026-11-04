import SwiftUI

/// Agent sessions started in Octomux (the daemon keeps them after they are closed), newest first.
/// Open ones jump to their pane; closed ones resume the agent's conversation in a new tab.
final class SessionHistoryModel: ObservableObject {
    struct Item: Identifiable {
        let client: DaemonClient
        let s: Session
        var id: String { s.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false

    func load(projectId: String?) {
        let m = AppModel.shared
        let clients = projectId.map { [m.client(for: $0)] } ?? ([m.client] + Array(m.extraClients.values))
        loading = true
        var results: [[Item]] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for c in clients {
            group.enter()
            var params: [String: Any] = ["limit": 300]
            if let projectId { params["project_id"] = projectId }
            c.call("history.list", params) { r in
                defer { group.leave() }
                guard case .success(let v) = r, let arr = (v as? [String: Any])?["sessions"],
                      let data = try? JSONSerialization.data(withJSONObject: arr),
                      let list = try? JSONDecoder().decode([Session].self, from: data) else { return }
                lock.lock(); results.append(list.map { Item(client: c, s: $0) }); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let all = results.flatMap { $0 }.sorted { max($0.s.lastActivityAt, $0.s.createdAt) > max($1.s.lastActivityAt, $1.s.createdAt) }
            // A resumed conversation is a new Octomux session with the same agent id: list it once (newest, open first).
            let live = Set(m.state.sessions.map(\.id))
            var seen = Set<String>()
            let ordered = all.filter { live.contains($0.s.id) } + all.filter { !live.contains($0.s.id) }
            let keep = Set(ordered.filter { seen.insert($0.s.agentSessionId ?? $0.s.id).inserted }.map(\.id))
            self?.items = all.filter { keep.contains($0.id) }
            self?.loading = false
        }
    }

    func forget(_ item: Item) {
        item.client.call("history.delete", ["id": item.s.id])
        items.removeAll { $0.id == item.id }
    }
}

struct SessionsPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var history = SessionHistoryModel()
    @AppStorage("octomux.sessionsAllProjects") private var allProjects = false
    @State private var query = ""

    var body: some View {
        let pid = model.currentProject?.id
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: T.k * 11)).foregroundStyle(T.text3)
                TextField("Search sessions", text: $query).textFieldStyle(.plain).font(.system(size: T.k * 12.5))
                Picker("", selection: $allProjects) {
                    Text("This project").tag(false)
                    Text("All projects").tag(true)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                Button { history.load(projectId: allProjects ? nil : pid) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: T.k * 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(size: 22)).help("Refresh")
            }
            .padding(.horizontal, 12).frame(height: 36)
            Hairline()
            let list = filtered
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: T.k * 20)).foregroundStyle(T.text3)
                    Text(history.loading ? "Loading…" : query.isEmpty ? "No agent sessions yet" : "No matches").font(T.body).foregroundStyle(T.text2)
                    if query.isEmpty && !history.loading {
                        Text("Agent sessions you start here are listed, also after you close them, so you can pick a conversation up again.")
                            .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let cut = Int(Date().timeIntervalSince1970) - 86400
                        let recent = list.filter { stamp($0) >= cut }, older = list.filter { stamp($0) < cut }
                        if !recent.isEmpty { section("Last 24 hours", recent) }
                        if !older.isEmpty { section("Older", older) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
            }
        }
        .onAppear { history.load(projectId: allProjects ? nil : pid) }
        .onChange(of: allProjects) { _, v in history.load(projectId: v ? nil : pid) }
        .onChange(of: pid) { _, p in if !allProjects { history.load(projectId: p) } }
        // A session closing or starting changes "open" vs "closed"; reload when the set of sessions changes.
        .onChange(of: model.state.sessions.filter { $0.kind == .agent }.map(\.id)) { _, _ in history.load(projectId: allProjects ? nil : pid) }
    }

    private func stamp(_ i: SessionHistoryModel.Item) -> Int { max(i.s.lastActivityAt, i.s.createdAt) }

    private var filtered: [SessionHistoryModel.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.items }
        return history.items.filter { i in
            [i.s.displayTitle, model.profile(i.s.profileId)?.name ?? "", model.project(i.s.projectId)?.name ?? ""]
                .contains { $0.lowercased().contains(q) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [SessionHistoryModel.Item]) -> some View {
        Text(title.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.text3)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
        ForEach(list) { i in SessionHistoryRow(item: i, showProject: allProjects) { history.forget(i) } }
    }
}

struct SessionHistoryRow: View {
    @EnvironmentObject var model: AppModel
    let item: SessionHistoryModel.Item
    let showProject: Bool
    let forget: () -> Void
    @State private var hover = false

    var body: some View {
        let s = item.s
        let live = model.session(s.id)
        let profile = model.profile(s.profileId)
        let canResume = profile != nil && s.agentSessionId != nil
        HStack(spacing: 9) {
            AgentIcon(icon: profile?.icon ?? "claude", size: 13).frame(width: 16).opacity(live == nil ? 0.75 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text((live ?? s).displayTitle).font(.system(size: T.k * 12.5, weight: .medium))
                    .foregroundStyle(live == nil ? T.text2 : T.text).lineLimit(1)
                Text([profile?.name ?? "Agent", showProject ? model.project(s.projectId)?.name : nil,
                      NotificationRow.when(Date(timeIntervalSince1970: TimeInterval(max(s.lastActivityAt, s.createdAt))))]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: T.k * 10.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let live {
                ActivityIndicator(session: live)
                Text("Open").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.green)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(Capsule().fill(T.green.opacity(0.14)))
            } else if hover && canResume {
                Text("Resume").font(.system(size: T.k * 10.5, weight: .semibold)).foregroundStyle(T.accent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: T.m.rowR, style: .continuous).fill(hover ? T.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { open(live: live != nil, canResume: canResume) }
        .contextMenu {
            if live != nil { Button("Go to Session") { model.selectSession(s.id) } }
            else { Button("Resume in New Tab") { resume() }.disabled(!canResume) }
            if let aid = s.agentSessionId { Button("Copy Session ID") { copy(aid) } }
            Divider()
            Button("Remove from History", action: forget).disabled(live != nil)
        }
        .help(live != nil ? "Open — go to it" : canResume ? "Closed — click to resume the conversation in a new tab"
              : profile == nil ? "Its agent profile no longer exists" : "No conversation id to resume")
    }

    private func open(live: Bool, canResume: Bool) {
        if live { model.selectSession(item.s.id) } else if canResume { resume() }
    }

    private func resume() {
        let s = item.s
        guard let aid = s.agentSessionId else { return }
        model.newSession(profileId: s.profileId, projectId: s.projectId, worktree: s.worktree, resume: aid)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
