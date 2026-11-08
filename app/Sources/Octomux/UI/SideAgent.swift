import SwiftUI

/// The project's agent in a column beside the work area (the Editor layout; Settings → Layout → "Agent beside the
/// work area" in any layout): its chat next to the files you open, notes from the editor land in its composer.
struct SideAgentColumn: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var pick = EditorAgentPick.shared

    /// The column's agent is the one the work area shows (you didn't pin it here, no file is in front).
    static func showsTwice(_ agent: String, focused: String?, docInFront: Bool, picked: String?) -> Bool {
        !docInFront && agent == focused && picked != agent
    }

    var body: some View {
        let pid = model.currentProject?.id
        let agent = model.editorAgent(projectId: pid)
        let others = model.state.sessions.filter { $0.projectId == pid && $0.isAgent && !$0.isDormant }
        // The work area shows this very agent (no file in front): the column would show it twice.
        let twice = agent.map { SideAgentColumn.showsTwice($0.id, focused: model.focusedSessionId, docInFront: model.activeDoc != nil,
                                                          picked: pid.flatMap { pick.picked[$0] }) } ?? false
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if let a = agent {
                    AgentIcon(icon: iconName(for: a, model: model), size: 12)
                    Menu {
                        ForEach(others) { s in
                            Button(s.displayTitle) { if let pid { pick.picked[pid] = s.id } }
                        }
                    } label: {
                        Text(a.displayTitle).font(.system(size: T.k * 13, weight: .semibold)).lineLimit(1)
                    }
                    .plainMenu().fixedSize().help("The agent beside the editor")
                    ActivityIndicator(session: a)
                    Spacer(minLength: 4)
                    WorkChips(session: a, limit: 1)
                    Button { model.selectSession(a.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(IconButtonStyle(size: 20)).help("Open its pane")
                } else {
                    Text("Agent").font(.system(size: T.k * 13, weight: .semibold))
                    Spacer()
                }
            }
            .padding(.horizontal, 12).frame(height: PaneHeader.height)
            Hairline()
            if let a = agent, twice {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.lefthalf.inset.filled").font(T.icon(18)).foregroundStyle(T.text3)
                    Text("\(a.displayTitle) is open in the middle").font(T.heading).multilineTextAlignment(.center)
                    Text("This column shows it beside the files you open. Or keep another agent here:")
                        .font(T.meta).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 280)
                    ForEach(others.filter { $0.id != a.id }.prefix(5)) { s in
                        Button(s.displayTitle) { if let pid { pick.picked[pid] = s.id } }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let a = agent {
                if model.canChat(a) {
                    ChatView(sessionId: a.id).id(a.id)
                } else {
                    VStack(spacing: 10) {
                        Text("This agent has no chat view.").font(T.meta).foregroundStyle(T.text3)
                        Button("Open Its Terminal") { model.selectSession(a.id) }.buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(T.icon(20)).foregroundStyle(T.text3)
                    Text("No agent in this project yet").font(T.heading)
                    Text("Start one; it works here beside the files you open, and notes from the editor go to it.")
                        .font(T.meta).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 260)
                    Button("New Agent") { model.openNewChat() }.buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
