import SwiftUI

/// Which of the workspace's projects a list shows, as one control however many projects there are: the project (its
/// icon and name, or "All projects") and Octomux's own panel to pick from, with a search field once there are many.
/// The agent rail, the tasks rail and New task's project use it.
struct ProjectScopeButton: View {
    @EnvironmentObject var model: AppModel
    /// The picked project (nil: all of them).
    let selected: String?
    /// Whether "All projects" is a choice (a list's filter), or one project must be picked (where a task goes).
    var allowsAll = true
    /// A count after each choice (nil: none), e.g. the agents waiting in it.
    var count: ((String?) -> Int)? = nil
    var compact = false
    let pick: (String?) -> Void
    @State private var open = false
    @State private var hover = false

    /// From this many projects on, the panel has a search field.
    static let searchFrom = 7

    var body: some View {
        let p = selected.flatMap { model.project($0) }
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if let p { ProjectIconView(project: p, size: 14) } else { Image(systemName: "square.stack").font(T.icon(11)).frame(width: 14) }
                Text(p?.name ?? (allowsAll ? "All projects" : "Pick a project"))
                    .font(.system(size: T.k * (compact ? 11 : 12), weight: .medium)).lineLimit(1)
                if !compact { Spacer(minLength: 4) }
                Image(systemName: "chevron.down").font(T.icon(8, .semibold)).foregroundStyle(T.text3)
            }
            .foregroundStyle(T.text)
            .padding(.horizontal, compact ? 4 : 8).frame(height: compact ? 22 : 26)
            .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous)
                .fill(open || hover ? T.hover : compact ? Color.clear : T.hover.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { hover = $0 }
        .help(allowsAll ? "Show one project, or all" : "The project")
        .floatingPanel(isPresented: $open, alignment: .leading) {
            ProjectScopePanel(selected: selected, allowsAll: allowsAll, count: count, pick: pick)
        }
        .debugOpens(allowsAll ? "project_scope" : "project_pick", $open)
    }
}

/// The projects to pick from: All, then each (icon, name, count, the picked one checked); typing filters them,
/// ↑ ↓ move, ↩ picks.
struct ProjectScopePanel: View {
    @EnvironmentObject var model: AppModel
    let selected: String?
    let allowsAll: Bool
    let count: ((String?) -> Int)?
    let pick: (String?) -> Void
    @State private var query = ""
    @State private var index: Int?
    @FocusState private var searching: Bool

    static func matching(_ projects: [Project], _ q: String) -> [Project] {
        let q = q.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The rows in order: nil is "All projects".
    private var choices: [String?] {
        let shown = Self.matching(model.projects, query).map { Optional($0.id) }
        return (allowsAll && query.isEmpty ? [nil] : []) + shown
    }
    private var searchable: Bool { model.projects.count >= ProjectScopeButton.searchFrom }

    var body: some View {
        let rows = choices
        PanelCard(width: 260) {
            if searchable {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(T.icon(11)).foregroundStyle(T.text3)
                    TextField("Find a project", text: $query).textFieldStyle(.plain).font(.system(size: T.k * 13))
                        .focused($searching)
                }
                .padding(.horizontal, 9).frame(height: 30)
                PanelDivider()
            } else {
                PanelSectionTitle("Project")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, id in
                        let p = id.flatMap { model.project($0) }
                        let n = count?(id) ?? 0
                        PanelRow(title: p?.name ?? "All projects", detail: n > 0 ? "\(n)" : nil, detailColor: T.amber,
                                 checked: id == selected, highlighted: index == i) {
                            if let p { ProjectIconView(project: p, size: 16) } else { Image(systemName: "square.stack").font(T.icon(11)).foregroundStyle(T.text3) }
                        }
                        .onHover { h in if h { index = i } else if index == i { index = nil } }
                        .onTapGesture { choose(id) }
                        .panelPointer()
                    }
                    if rows.isEmpty { Text("No project matches.").font(T.meta).foregroundStyle(T.text3).padding(9) }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: query) { _, _ in index = choices.isEmpty ? nil : 0 }
        .onAppear {
            if searchable { searching = true }
            FloatingPanelController.shared.onKey = { e in
                let n = choices.count
                switch e.keyCode {
                case 125: index = n == 0 ? nil : min((index ?? -1) + 1, n - 1); return true
                case 126: index = n == 0 ? nil : max((index ?? n) - 1, 0); return true
                case 36, 76:
                    guard let i = index ?? (query.isEmpty ? nil : 0), i < n else { return false }
                    choose(choices[i]); return true
                default: return false   // typing goes to the search field
                }
            }
        }
    }

    private func choose(_ id: String?) {
        FloatingPanelController.shared.close()
        pick(id)
    }
}
