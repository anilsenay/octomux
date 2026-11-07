import SwiftUI

// Shared parts of the home pages (Agents, Workday, Tasks): one section header, one card, one tile, one way to
// answer an agent, one small button. Status is said by a colored dot or glyph, never by a colored heading, and a
// card has at most one prominent action.

/// "● WAITING FOR YOU 3": a neutral label; the dot carries the color.
struct HomeSection: View {
    let title: String
    var count: Int? = nil
    var dot: Color? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title.uppercased()).font(.system(size: T.k * 11, weight: .semibold)).tracking(0.5).foregroundStyle(T.text2)
            if let count, count > 0 { Text("\(count)").font(.system(size: T.k * 11, weight: .medium)).foregroundStyle(T.text3).monospacedDigit() }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .frame(height: 20)
    }
}

/// The home pages' card: raised, hairline border; `attention` outlines it in amber.
struct HomeCard: ViewModifier {
    var attention = false
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(attention ? T.amber.opacity(0.5) : T.border))
    }
}

extension View {
    func homeCard(attention: Bool = false, padding: CGFloat = 12) -> some View { modifier(HomeCard(attention: attention, padding: padding)) }
}

/// A number with its label and one line under it ("NEEDS YOU · 2 · 1 question, 1 permission").
struct KPITile: View {
    let label: String
    let value: String
    var sub: String = ""
    var tone: Color = T.text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.5).foregroundStyle(T.text3).lineLimit(1)
            Text(value).font(.system(size: T.k * 22, weight: .semibold)).foregroundStyle(tone).monospacedDigit().lineLimit(1)
            Text(sub.isEmpty ? " " : sub).font(T.meta).foregroundStyle(T.text3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCard(padding: 12)
    }
}

/// An agent's question as numbered answers: a click or the number picks one (the keys you'd press in its terminal).
struct AnswerOptions: View {
    let options: [String]
    let pick: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { pick(i) } label: {
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(T.mono(11, .semibold)).foregroundStyle(i == 0 ? T.text : T.text2)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.hover))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(T.border))
                        Text(o).font(.system(size: T.k * 12, weight: i == 0 ? .medium : .regular)).foregroundStyle(T.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(hover == i ? T.hover : i == 0 ? T.amber.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                .pointerCursor()
            }
        }
    }
}

/// A compact button for rows and cards: `prominent` is the one main action, else a quiet outline.
struct SmallButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.k * 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? .white : T.text)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: R.md, style: .continuous)
                .fill(prominent ? T.accent.opacity(configuration.isPressed ? 0.8 : 1) : configuration.isPressed ? T.border : hover ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(prominent ? .clear : T.border))
            .contentShape(RoundedRectangle(cornerRadius: R.md, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hover = $0 }
            .pointerCursor()
    }
}

/// "Open ›" style text action.
struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(T.meta).foregroundStyle(T.accent) }
            .buttonStyle(.plain).pointerCursor()
    }
}

/// "Show 12 more" / "Show fewer" under a cut list.
struct MoreToggle: View {
    let hidden: Int
    @Binding var expanded: Bool
    var body: some View {
        if hidden > 0 || expanded {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Text(expanded ? "Show fewer" : "Show \(hidden) more").font(T.meta).foregroundStyle(T.text3)
            }
            .buttonStyle(.plain).pointerCursor().padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// A row whose actions show while the pointer is over it (or always, when `pinned`).
struct HoverRow<Content: View, Actions: View>: View {
    var pinned = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 6)
            actions().opacity(hover || pinned ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hover ? T.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// The status vocabulary shared by every home: color for an agent's or task's state.
enum HomeTone {
    static func agent(_ g: AgentsList.Group) -> Color {
        switch g {
        case .needsInput: return T.amber
        case .working: return T.accent
        case .error: return T.red
        case .finished: return T.green
        default: return T.text3
        }
    }
}

/// What an agent waits for, answerable in place: a permission (Allow / Deny) or a question (numbered answers).
struct PendingAnswer: View {
    let session: Session
    let pending: AgentDigest.Pending
    var compact = false
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pending {
            case .permission(let what):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.shield").font(T.icon(10)).foregroundStyle(T.amber)
                    Text("Allow \(what)?").font(.system(size: T.k * 12, weight: .semibold)).lineLimit(compact ? 3 : 2)
                }
                HStack(spacing: 6) {
                    Button("Allow") { AgentDigests.answer(session.id, option: 0) }.buttonStyle(SmallButtonStyle(prominent: true))
                    Button("Deny") { AgentDigests.deny(session.id) }.buttonStyle(SmallButtonStyle())
                    Spacer()
                    LinkButton(title: "Open ›", action: open)
                }
            case .question(let q, let opts):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "questionmark.circle").font(T.icon(10)).foregroundStyle(T.amber)
                    Text(q).font(.system(size: T.k * 12, weight: .semibold)).lineLimit(compact ? 4 : 3)
                }
                AnswerOptions(options: Array(opts.prefix(compact ? 3 : 4))) { AgentDigests.answer(session.id, option: $0) }
                HStack { Spacer(); LinkButton(title: "Open ›", action: open) }
            }
        }
    }
}
