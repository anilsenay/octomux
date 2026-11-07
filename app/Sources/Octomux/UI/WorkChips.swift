import SwiftUI

/// A session's work as chips: its pull request (number, checks) and issue (key, status). A click opens the item in
/// the Inbox. Used on agent cards, Workday, and — when the layout has it — the pane header.
struct WorkChips: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = InboxStore.shared
    let session: Session
    var limit = 2

    var body: some View {
        let branch = GitInfo.shared.branch(for: model.workPath(of: session))
        let list = WorkLinks.items(session: session.id, branch: branch, items: store.items, links: store.links)
        if !list.isEmpty {
            HStack(spacing: 4) {
                ForEach(list.prefix(limit), id: \.id) { WorkChip(item: $0) }
            }
        }
    }
}

struct WorkChip: View {
    @EnvironmentObject var model: AppModel
    let item: InboxItem

    var body: some View {
        Button {
            InboxStore.shared.select(item.id)
            model.openInbox()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.kind == .pr ? "arrow.triangle.pull" : "ticket").font(.system(size: T.k * 9, weight: .semibold))
                Text(item.key).font(T.mono(10)).lineLimit(1)
                if let c = dot { Circle().fill(c).frame(width: 5, height: 5) }
            }
            .foregroundStyle(T.text2)
            .padding(.horizontal, 5).frame(height: 17)
            .background(Capsule().fill(T.hover))
            .overlay(Capsule().stroke(T.border))
        }
        .buttonStyle(.plain).pointerCursor()
        .help(help)
    }

    private var dot: Color? {
        if item.kind == .pr {
            switch item.checks {
            case .passing?: return T.green
            case .failing?: return T.red
            case .pending?: return T.amber
            case nil: return nil
            }
        }
        switch item.statusTone {
        case "done": return T.green
        case "progress": return T.accent
        default: return T.text3
        }
    }

    private var help: String {
        var parts = ["\(item.key) \(item.title)", item.status]
        if item.kind == .pr, let c = item.checks { parts.append("checks \(c.rawValue)") }
        return parts.joined(separator: " · ") + " — open in the Inbox"
    }
}

/// "3 files since you looked": a click lists them, each with its diff since then. Nothing when you never looked
/// or nothing changed.
struct SinceLookedBadge: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var since = SinceLooked.shared
    let session: Session
    @State private var open = false

    var body: some View {
        if let files = since.files(session.id), !files.isEmpty {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye").font(.system(size: T.k * 9, weight: .semibold))
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") since you looked").font(T.meta)
                }
                .foregroundStyle(T.accent)
            }
            .buttonStyle(.plain).pointerCursor()
            .help(lookedHelp)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SinceLookedList(session: session, files: files)
            }
        }
    }

    private var lookedHelp: String {
        guard let d = since.lookedAt(session.id) else { return "" }
        return "Changed after you last looked (\(AgentRow.elapsed(since: Int(d.timeIntervalSince1970))) ago)"
    }
}

/// The files changed since you looked, with the diff of the one picked; "Seen" makes now the new starting point.
struct SinceLookedList: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let files: [String]
    @State private var picked: String?
    @State private var diff = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Since you looked").font(T.heading)
                Spacer()
                Button("Seen") { model.lookedAt(session.id) }.buttonStyle(SecondaryButtonStyle())
                    .help("Start counting from now")
            }
            .padding(10)
            Hairline()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files, id: \.self) { f in
                            Text(f).font(T.mono(11)).lineLimit(1).truncationMode(.head)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(picked == f ? T.selection : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(f) }
                        }
                    }
                }
                .frame(width: 220)
                Rectangle().fill(T.border).frame(width: 1)
                ScrollView([.vertical, .horizontal]) {
                    DiffText(text: diff).padding(8)
                }
                .frame(width: 460)
            }
            .frame(height: 320)
        }
        .onAppear { if let f = files.first { pick(f) } }
    }

    private func pick(_ f: String) {
        picked = f
        guard let old = SinceLooked.shared.tree(for: session.id) else { return }
        let path = model.workPath(of: session)
        DispatchQueue.global(qos: .userInitiated).async {
            let now = SinceLooked.tree(of: path) ?? old
            let d = SinceLooked.run(["diff", old, now, "--", f], in: path) ?? ""
            DispatchQueue.main.async { if picked == f { diff = d.isEmpty ? "(no textual change)" : d } }
        }
    }
}

/// A unified diff, lines tinted.
struct DiffText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(1500).enumerated()), id: \.offset) { _, l in
                Text(String(l).isEmpty ? " " : String(l))
                    .font(T.mono(11))
                    .foregroundStyle(l.hasPrefix("+") && !l.hasPrefix("+++") ? T.green : l.hasPrefix("-") && !l.hasPrefix("---") ? T.red : l.hasPrefix("@@") ? T.accent : T.text2)
                    .fixedSize()
            }
        }
    }
}
