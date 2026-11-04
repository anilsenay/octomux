import SwiftUI

/// How the workspace switcher marks another workspace that wants you (Settings → Appearance → Sidebar):
/// amber when something there waits for your input, else green (finished, not looked at yet). Still by default
/// (movement can read as "working"); the bar and the glow also come breathing slowly, for those who want it.
enum WorkspaceMark: String, CaseIterable, Identifiable {
    case bar, barBreathing, glow, glowBreathing, dot, badge
    static let key = "appearance.workspace_mark"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bar: return "Bar under it"
        case .barBreathing: return "Bar, breathing"
        case .glow: return "Glow behind it"
        case .glowBreathing: return "Glow, breathing"
        case .dot: return "Corner dot"
        case .badge: return "Count"
        }
    }
    var breathes: Bool { self == .barBreathing || self == .glowBreathing }
    var isBar: Bool { self == .bar || self == .barBreathing }
    var isGlow: Bool { self == .glow || self == .glowBreathing }

    static func current(_ model: AppModel) -> WorkspaceMark {
        WorkspaceMark(rawValue: model.setting(key)?.string ?? "") ?? .bar
    }
}

/// A workspace button's icon with its mark. `attention` nil: none.
struct MarkedWorkspaceIcon: View {
    let workspace: Workspace
    let mark: WorkspaceMark
    let attention: (waiting: Int, unread: Int)?
    let dimmed: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if attention != nil && mark.breathes && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                // 0…1…0 over 2.6 s, eased (a slow breath, not a blink).
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                icon(level: 0.5 - 0.5 * cos(t * 2 * .pi))
            }
        } else {
            icon(level: 1)
        }
    }

    /// `level`: 1 at full strength (a still mark), lower in a breath.
    private func icon(level: Double) -> some View {
        let color = (attention?.waiting ?? 0) > 0 ? T.amber : T.green
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let breath = mark.breathes ? 0.35 + 0.65 * level : 1
        return WorkspaceIcon(workspace: workspace, size: 13, dimmed: dimmed)
            .frame(width: width, height: 24)
            .background {
                if attention != nil && mark.isGlow {
                    shape.fill(color.opacity(0.32 * breath)).padding(3).scaleEffect(mark.breathes ? 0.85 + 0.15 * level : 1).blur(radius: 4)
                }
            }
            .overlay(alignment: .bottom) {
                if attention != nil && mark.isBar { Capsule().fill(color.opacity(breath)).frame(width: 10, height: 2.5).offset(y: -1) }
            }
            .overlay(alignment: .topTrailing) {
                if let a = attention {
                    switch mark {
                    case .dot:
                        Circle().fill(color).frame(width: 6, height: 6).overlay(Circle().stroke(T.frame, lineWidth: 1.5)).offset(x: -3, y: 3)
                    case .badge:
                        let n = a.waiting > 0 ? a.waiting : a.unread
                        Text(n > 9 ? "9+" : "\(n)").font(.system(size: T.k * 8, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.black.opacity(0.78))
                            .padding(.horizontal, 3).frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(color)).overlay(Capsule().stroke(T.frame, lineWidth: 1.5))
                            .offset(x: -1, y: 1)
                    default: EmptyView()
                    }
                }
            }
    }
}

/// Settings → Appearance → Sidebar: the four marks, each shown on a dot, an SF Symbol and an emoji workspace.
struct WorkspaceMarkSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let cur = WorkspaceMark.current(model)
        SettingsGroup("Sidebar") {
            VisualSettingRow("Other workspaces that want you", desc: "How the switcher at the bottom of the sidebar marks a workspace where something waits for your input (amber) or finished while you were away (green).") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 12, alignment: .leading), count: 4), alignment: .leading, spacing: 12) {
                    ForEach(WorkspaceMark.allCases) { m in
                        ChoiceTile(title: m.title, selected: m == cur, width: 120, height: 58,
                                   action: { model.setSetting(WorkspaceMark.key, m == .bar ? nil : m.rawValue) }) { preview(m) }
                    }
                }
            }
        }
    }

    private func preview(_ m: WorkspaceMark) -> some View {
        let ws = [Workspace(id: "a", name: "Work", color: "#4A90E8", sort: 0, icon: nil),
                  Workspace(id: "b", name: "School", color: "#3FB27F", sort: 1, icon: "graduationcap.fill"),
                  Workspace(id: "c", name: "Side", color: "#9B6BE8", sort: 2, icon: "🚀")]
        return HStack(spacing: 2) {
            ForEach(Array(ws.enumerated()), id: \.offset) { i, w in
                MarkedWorkspaceIcon(workspace: w, mark: m, attention: i == 2 ? (0, 1) : (2, 0), dimmed: true, width: 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.frame)
    }
}
