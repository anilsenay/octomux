import AppKit
import SwiftUI

/// Create Pull Request (Changes panel ▾, ⌘K): title and description, ✨ written by the commit-message agent from
/// the branch's commits and diff; pushes the branch and runs `gh pr create`, or opens GitHub's compare page with
/// both filled in when `gh` isn't there.
enum PullRequest {
    struct Context {
        var branch: String
        var base: String
        var commits: String
        var stat: String
        var diff: String
    }

    /// The branch PRs go to: origin's default branch, else main / master.
    static func defaultBase(_ path: String) -> String {
        if let h = GitInfo.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines),
           h.hasPrefix("origin/") { return String(h.dropFirst(7)) }
        for b in ["main", "master"] where GitInfo.git(["rev-parse", "--verify", "--quiet", b], in: path) != nil { return b }
        return "main"
    }

    static func context(_ path: String, base: String) -> Context {
        let branch = GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Against origin's copy of the base when there is one (what the PR is compared with on GitHub).
        let ref = GitInfo.git(["rev-parse", "--verify", "--quiet", "origin/\(base)"], in: path) != nil ? "origin/\(base)" : base
        let commits = GitInfo.git(["log", "--format=- %s%n%b", "--no-merges", "-50", "\(ref)..HEAD"], in: path) ?? ""
        let stat = GitInfo.git(["diff", "--stat", "\(ref)...HEAD"], in: path) ?? ""
        let diff = GitInfo.git(["diff", "--no-ext-diff", "\(ref)...HEAD"], in: path) ?? ""
        return Context(branch: branch, base: base, commits: commits, stat: stat, diff: diff)
    }

    static func prompt(_ c: Context, instructions: String) -> String {
        var p = """
        You are writing a GitHub pull request for the change below.

        Output format, nothing else:
        - First line: the title, plain text, at most 72 characters, no trailing period.
        - Then a blank line, then the description in Markdown with the headings "## Summary" (short bullet points
          on what changed and why) and "## Testing" (bullet points with concrete checks, or "Not run").
        No preamble, no code fences around the whole answer.

        Base branch: \(c.base)
        Head branch: \(c.branch)

        """
        let custom = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { p += "Additional instructions from the user (these win over the rules above):\n\(custom)\n\n" }
        p += "Commits:\n\(String(c.commits.prefix(12_000)))\n\nDiff stat:\n\(String(c.stat.prefix(8_000)))\n\n"
        p += "Diff:\n```diff\n\(CommitMessageGen.truncate(c.diff, budget: 60_000))\n```\n"
        return p
    }

    /// The model's answer as (title, body).
    static func parse(_ raw: String) -> (String, String)? {
        let text = CommitMessageGen.clean(raw)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard var title = lines.first?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        for prefix in ["Title:", "title:", "# "] where title.hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"`*")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(title.prefix(120)), body)
    }

    static func generate(path: String, base: String, project: String?, model: AppModel, done: @escaping (Result<(String, String), Error>) -> Void) -> CommitMessageGen.Run? {
        guard let profile = CommitMessageGen.profile(model: model, project: project) else {
            done(.failure(CommitMessageGen.GenError("No Claude Code or Codex agent is set up (Settings → Agents).")))
            return nil
        }
        let m = CommitMessageGen.modelName(model: model, project: project, kind: profile.kind)
        let instructions = model.setting("pr.instructions", project: project)?.string ?? ""
        let run = CommitMessageGen.Run()
        DispatchQueue.global(qos: .userInitiated).async {
            let c = context(path, base: base)
            let r = Result { () -> (String, String) in
                if c.commits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && c.diff.isEmpty {
                    throw CommitMessageGen.GenError("\(c.branch) has no commits that \(base) doesn't have.")
                }
                guard let out = parse(try CommitMessageGen.runText(profile: profile, model: m, prompt: prompt(c, instructions: instructions), run: run)) else {
                    throw CommitMessageGen.GenError("\(profile.name) gave no usable title.")
                }
                return out
            }
            DispatchQueue.main.async { if !run.cancelled { done(r) } }
        }
        return run
    }

    // MARK: Creating

    /// `owner/repo` of a GitHub remote URL (ssh or https).
    static func githubRepo(_ url: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"].first(where: { u.hasPrefix($0) }) else { return nil }
        u = String(u.dropFirst(p.count))
        if u.hasSuffix(".git") { u = String(u.dropLast(4)) }
        let parts = u.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }

    /// GitHub's compare page with the PR filled in (the way without `gh`).
    static func compareURL(repo: String, base: String, head: String, title: String, body: String, draft: Bool) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/compare/\(base)...\(head)")
        c?.queryItems = [URLQueryItem(name: "expand", value: "1"), URLQueryItem(name: "title", value: title),
                         URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        if draft { c?.queryItems?.append(URLQueryItem(name: "draft", value: "1")) }
        return c?.url
    }

    /// Pushes the branch, then `gh pr create` (local projects); else the compare page. Calls back with the PR (or
    /// compare page) to open, or what went wrong.
    static func create(path: String, local: Bool, base: String, title: String, body: String, draft: Bool, done: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { () -> URL in
                let head = GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !head.isEmpty, head != "HEAD" else { throw CommitMessageGen.GenError("Not on a branch.") }
                guard head != base else { throw CommitMessageGen.GenError("You are on \(base) itself; make a branch first.") }
                if GitInfo.git(["push", "-u", "origin", "HEAD"], in: path) == nil {
                    throw CommitMessageGen.GenError("git push failed (see a terminal: git push -u origin HEAD).")
                }
                if local, let url = try? ghCreate(path: path, base: base, head: head, title: title, body: body, draft: draft) { return url }
                guard let remote = GitInfo.git(["remote", "get-url", "origin"], in: path), let repo = githubRepo(remote),
                      let url = compareURL(repo: repo, base: base, head: head, title: title, body: body, draft: draft) else {
                    throw CommitMessageGen.GenError("origin is not a GitHub repository, and gh couldn't create the PR.")
                }
                return url
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func ghCreate(path: String, base: String, head: String, title: String, body: String, draft: Bool) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        var cmd = ["gh", "pr", "create", "--base", base, "--head", head, "--title", title, "--body-file", "-"]
        if draft { cmd.append("--draft") }
        p.arguments = ["-lc", "exec " + cmd.map(\.shellQuoted).joined(separator: " ")]
        p.currentDirectoryURL = URL(fileURLWithPath: path)
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input; p.standardOutput = out; p.standardError = err
        try p.run()
        input.fileHandleForWriting.write(Data(body.utf8))
        try? input.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: o, as: UTF8.self)
        if p.terminationStatus == 0, let line = text.split(separator: "\n").last(where: { $0.hasPrefix("https://") }), let url = URL(string: String(line)) { return url }
        throw CommitMessageGen.GenError(String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The Create Pull Request window, as a sheet on the main window.
enum PullRequestWindow {
    static func show(model: AppModel) {
        guard let path = model.currentWorkPath, let main = (NSApp.delegate as? AppDelegate)?.mainWindow else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let view = PullRequestSheet(path: path, projectId: model.currentProject?.id, local: !model.host(forPath: path).0.isRemote) {
            main.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(rootView: view.environmentObject(model))
        main.beginSheet(sheet)
    }
}

struct PullRequestSheet: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let projectId: String?
    let local: Bool
    let done: () -> Void
    @State private var base = ""
    @State private var bases: [String] = []
    @State private var head = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = false
    @State private var writing: CommitMessageGen.Run?
    @State private var creating = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create pull request").font(T.title)
            HStack(spacing: 8) {
                Text(head.isEmpty ? "…" : head).font(T.mono(12)).foregroundStyle(T.text)
                Image(systemName: "arrow.right").font(.system(size: T.k * 10)).foregroundStyle(T.text3)
                Picker("", selection: $base) { ForEach(bases, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().fixedSize()
                Spacer()
                Button { write() } label: {
                    HStack(spacing: 5) {
                        if writing != nil { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(writing != nil ? "Stop" : "Write with \(CommitMessageGen.profile(model: model, project: projectId)?.name ?? "agent")")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).font(T.mono(12)).frame(minHeight: 220)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.frame.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
            Toggle("Draft", isOn: $draft).toggleStyle(.checkbox)
            if !status.isEmpty { Text(status).font(T.caption).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(local ? "Pushes \(head.isEmpty ? "the branch" : head), then gh pr create (GitHub's page opens if gh can't)." : "Pushes the branch and opens GitHub's page.")
                    .font(T.caption).foregroundStyle(T.text3)
                Spacer()
                Button("Cancel") { writing?.cancel(); done() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create") { create() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(creating || title.trimmingCharacters(in: .whitespaces).isEmpty || base.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(T.surface)
        .onAppear(perform: load)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let def = PullRequest.defaultBase(path)
            let h = GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var list = GitInfo.branches(in: path, remotes: false).filter { $0 != h }
            if !list.contains(def) { list.insert(def, at: 0) }
            DispatchQueue.main.async { bases = list; base = def; head = h }
        }
    }

    private func write() {
        if let w = writing { w.cancel(); writing = nil; status = ""; return }
        status = "Writing the title and description…"
        writing = PullRequest.generate(path: path, base: base, project: projectId, model: model) { r in
            writing = nil
            switch r {
            case .success(let (t, b)): title = t; bodyText = b; status = ""
            case .failure(let e): status = e.localizedDescription
            }
        }
    }

    private func create() {
        creating = true
        status = "Pushing…"
        PullRequest.create(path: path, local: local, base: base, title: title, body: bodyText, draft: draft) { r in
            creating = false
            switch r {
            case .success(let url): NSWorkspace.shared.open(url); done()
            case .failure(let e): status = e.localizedDescription
            }
        }
    }
}
