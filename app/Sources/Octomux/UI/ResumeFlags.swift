import SwiftUI

/// "Resume with Flags…": the flags an agent session comes back with (`--chrome`, a model…). Kept on the
/// session, so later resumes and restores start it the same way.
enum ResumeFlags {
    struct Shortcut { let flag: String; let title: String }

    /// Common switches, one checkbox each (they only add or remove their flag in the text).
    static func shortcuts(_ kind: AgentKind?) -> [Shortcut] {
        switch kind {
        case .claude:
            return [Shortcut(flag: "--chrome", title: "Chrome"),
                    Shortcut(flag: "--dangerously-skip-permissions", title: "Skip permission prompts"),
                    Shortcut(flag: "--ide", title: "Connect to IDE"),
                    Shortcut(flag: "--verbose", title: "Verbose")]
        case .codex:
            return [Shortcut(flag: "--search", title: "Web search"),
                    Shortcut(flag: "--dangerously-bypass-approvals-and-sandbox", title: "No approvals or sandbox")]
        default:
            return []
        }
    }

    /// Splits like a shell: spaces separate, quotes keep a value together ("a b" or 'a b').
    static func split(_ text: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, has = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if has || !cur.isEmpty { out.append(cur) }
                cur = ""; has = false
            } else {
                cur.append(ch)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The flags as text again (quoted where they need it).
    static func join(_ args: [String]) -> String {
        args.map { a in
            a.isEmpty || a.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ? "'" + a.replacingOccurrences(of: "'", with: "\"") + "'" : a
        }.joined(separator: " ")
    }

    /// Adds `flag` at the end or removes every copy of it.
    static func toggle(_ flag: String, in text: String, on: Bool) -> String {
        var args = split(text).filter { $0 != flag }
        if on { args.append(flag) }
        return join(args)
    }
}

struct ResumeFlagsView: View {
    let model: AppModel
    let session: Session
    let done: () -> Void
    @State private var text: String

    init(model: AppModel, session: Session, done: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.done = done
        _text = State(initialValue: ResumeFlags.join(session.extraArgs ?? []))
    }

    private var profile: Profile? { model.profile(session.profileId) }

    var body: some View {
        let args = ResumeFlags.split(text)
        VStack(alignment: .leading, spacing: 10) {
            Text("Resume with flags").font(.system(size: T.k * 13, weight: .semibold)).foregroundStyle(T.text)
            TextField("e.g. --chrome --model opus", text: $text)
                .textFieldStyle(.plain).font(T.mono(12))
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.frame.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.border))
                .onSubmit(resume)
            let shortcuts = ResumeFlags.shortcuts(profile?.kind)
            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(shortcuts, id: \.flag) { s in
                        Toggle(isOn: Binding(get: { args.contains(s.flag) }, set: { text = ResumeFlags.toggle(s.flag, in: text, on: $0) })) {
                            HStack(spacing: 6) {
                                Text(s.title).font(T.body).foregroundStyle(T.text)
                                Text(s.flag).font(T.mono(11)).foregroundStyle(T.text3)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Text("Runs: " + command(args)).font(T.mono(11)).foregroundStyle(T.text3)
                .lineLimit(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("The conversation goes on where it stopped. These flags stay for later resumes.")
                .font(T.caption).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Resume", action: resume).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    /// Roughly what the daemon runs (it also adds Octomux's own settings file).
    private func command(_ args: [String]) -> String {
        let cmd = ([profile?.command ?? "claude"] + (profile?.args ?? []) + args).joined(separator: " ")
        guard let id = session.agentSessionId else { return cmd }
        switch profile?.kind {
        case .codex: return cmd + " resume " + id
        case .claude: return cmd + " --resume " + id
        default: return cmd
        }
    }

    private func resume() {
        model.restart(session.id, extraArgs: ResumeFlags.split(text))
        done()
    }
}
