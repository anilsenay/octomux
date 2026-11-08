import SwiftUI

/// Which of the workspace's projects a list shows, as one control however many projects there are: the project (its
/// icon and name, or "All projects") and a list to pick from, with a search field once there are many. The agent
/// rail, the tasks rail and New task's project use it.
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

    /// From this many projects on, the list has a search field.
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
            .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous).fill(compact ? Color.clear : T.hover.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(allowsAll ? "Show one project, or all" : "The project")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectScopeList(selected: selected, allowsAll: allowsAll, count: count) { id in open = false; pick(id) }
                .environmentObject(model)
        }
    }
}

/// The projects to pick from: All, then each (icon, name, count); typing filters them.
struct ProjectScopeList: View {
    @EnvironmentObject var model: AppModel
    let selected: String?
    let allowsAll: Bool
    let count: ((String?) -> Int)?
    let pick: (String?) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    static func matching(_ projects: [Project], _ q: String) -> [Project] {
        let q = q.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let shown = Self.matching(model.projects, query)
        VStack(alignment: .leading, spacing: 2) {
            if model.projects.count >= ProjectScopeButton.searchFrom {
                TextField("Find a project", text: $query)
                    .textFieldStyle(.roundedBorder).font(.system(size: T.k * 12))
                    .focused($searching)
                    .onSubmit { if let first = shown.first { pick(first.id) } }
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if allowsAll && query.isEmpty {
                        row(nil) { Image(systemName: "square.stack").font(T.icon(11)).frame(width: 16) }
                    }
                    ForEach(shown) { p in row(p.id) { ProjectIconView(project: p, size: 16) } }
                    if shown.isEmpty { Text("No project matches.").font(T.meta).foregroundStyle(T.text3).padding(8) }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(8)
        .frame(width: 250)
        .onAppear { if model.projects.count >= ProjectScopeButton.searchFrom { searching = true } }
    }

    private func row(_ id: String?, @ViewBuilder icon: () -> some View) -> some View {
        let on = selected == id
        return Button { pick(id) } label: {
            HStack(spacing: 8) {
                icon()
                Text(id.flatMap { model.project($0)?.name } ?? "All projects").font(.system(size: T.k * 12, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let n = count?(id), n > 0 { Text("\(n)").font(.system(size: T.k * 11)).foregroundStyle(T.text3).monospacedDigit() }
                if on { Image(systemName: "checkmark").font(T.icon(10, .semibold)).foregroundStyle(T.accent) }
            }
            .foregroundStyle(T.text)
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: R.sm, style: .continuous).fill(on ? T.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
