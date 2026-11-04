import AppKit

/// ✨ in the Changes panel: one background run of an agent CLI (`claude -p` / `codex exec`) with the diff on
/// stdin, its plain-text answer put in the message box. Your CLI, login and config; no tools, no session kept,
/// hooks and MCP servers off, run in an empty folder.
enum CommitMessageGen {
    static let diffBudget = 80_000

    // MARK: Settings (global, or per project)

    static func profile(model: AppModel, project: String?) -> Profile? {
        let usable = model.enabledProfiles.filter { $0.kind == .claude || $0.kind == .codex }
        if let id = model.setting("commit_message.profile", project: project)?.string, let p = usable.first(where: { $0.id == id }) { return p }
        return usable.first { $0.kind == .claude } ?? usable.first
    }

    /// nil: the CLI's default model. Claude defaults to Haiku (fast, cheap, plenty for a commit message).
    static func modelName(model: AppModel, project: String?, kind: AgentKind) -> String? {
        if let v = model.setting("commit_message.model", project: project)?.string { return v.isEmpty || v == "default" ? nil : v }
        return kind == .claude ? "haiku" : nil
    }

    static func instructions(model: AppModel, project: String?) -> String {
        model.setting("commit_message.instructions", project: project)?.string ?? ""
    }

    // MARK: Prompt

    static func prompt(diff: String, untracked: [String], branch: String?, recent: [String], instructions: String) -> String {
        var p = """
        You are writing a single git commit message for the change below.

        Rules:
        - First line: imperative mood, at most 72 characters, no trailing period.
        - Then, only if it helps: a blank line and a short body wrapped at 72 characters that explains why.
        - Output ONLY the commit message: no preamble, no code fences, no quotes, no Co-authored-by or other trailers.
        - Do not use tools; everything you need is here.

        """
        if let branch, !branch.isEmpty { p += "Branch: \(branch)\n\n" }
        if !recent.isEmpty {
            p += "Recent commit subjects in this repository (match their style and language):\n" + recent.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        }
        let custom = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { p += "Additional instructions from the user (these win over the rules above):\n\(custom)\n\n" }
        if !untracked.isEmpty { p += "New files:\n" + untracked.prefix(200).map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
        p += "Diff:\n```diff\n\(truncate(diff))\n```\n"
        return p
    }

    /// Fits the diff into the budget, each file getting a fair share so one huge file can't push out the rest.
    static func truncate(_ diff: String, budget: Int = diffBudget) -> String {
        guard diff.count > budget else { return diff }
        var sections: [String] = []
        var cur = ""
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), !cur.isEmpty { sections.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { sections.append(cur) }
        var alloc = Array(repeating: 0, count: sections.count)
        var active = Array(sections.indices)
        var left = budget
        while !active.isEmpty, left > 0 {
            let share = left / active.count
            if share == 0 { break }
            var next: [Int] = []
            for i in active {
                let need = sections[i].count - alloc[i]
                let grant = min(need, share)
                alloc[i] += grant
                left -= grant
                if grant < need { next.append(i) }
            }
            active = next
        }
        return sections.indices.map { i in
            let s = sections[i]
            guard s.count > alloc[i] else { return s }
            var cut = String(s.prefix(max(0, alloc[i])))
            if let nl = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: nl) > alloc[i] / 2 { cut = String(cut[...nl]) }
            return cut + "… (\(s.count - cut.count) characters of this file left out)\n"
        }.joined()
    }

    /// Drops what CLIs and models put around the message: code fences, quotes, "Generating…" lines.
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let f = lines.first, f.range(of: #"^(generating|thinking|working)\b|^[.…]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            lines.removeFirst()
        }
        if lines.first?.hasPrefix("```") == true, lines.count > 1 {
            lines.removeFirst()
            if let i = lines.lastIndex(where: { $0.hasPrefix("```") }) { lines.removeSubrange(i...) }
        }
        lines.removeAll { $0.range(of: #"^(co-authored-by|signed-off-by):"#, options: [.regularExpression, .caseInsensitive]) != nil }
        t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for q in ["\"", "'", "`"] where t.count > 1 && t.hasPrefix(q) && t.hasSuffix(q) { t = String(t.dropFirst().dropLast()) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Running

    /// The command line for the profile's CLI (run through the login shell, so its PATH and aliases apply).
    static func commandLine(_ p: Profile, model: String?, lastMessage: String? = nil) -> String {
        var args: [String]
        switch p.kind {
        case .codex:
            args = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--color", "never"]
            if let model { args += ["-m", model] }
            if let lastMessage { args += ["-o", lastMessage] }   // only the answer, without the progress output
            args += ["-"]
        default:
            args = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                    "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#]
            if let model { args += ["--model", model] }
        }
        return ([p.command] + args.map(\.shellQuoted)).joined(separator: " ")
    }

    final class Run {
        let process = Process()
        private(set) var cancelled = false
        func cancel() { cancelled = true; if process.isRunning { kill(-process.processIdentifier, SIGTERM); process.terminate() } }
    }

    /// Gathers the diff (staged, else everything), runs the CLI, calls back on the main queue.
    @discardableResult
    static func generate(path: String, projectId: String?, model: AppModel, done: @escaping (Result<String, Error>) -> Void) -> Run? {
        guard let profile = profile(model: model, project: projectId) else {
            done(.failure(GenError("No Claude Code or Codex agent is set up (Settings → Agents).")))
            return nil
        }
        let modelName = modelName(model: model, project: projectId, kind: profile.kind)
        let instructions = instructions(model: model, project: projectId)
        let run = Run()
        DispatchQueue.global(qos: .userInitiated).async {
            let staged = GitInfo.git(["diff", "--cached", "--no-ext-diff"], in: path) ?? ""
            var diff = staged
            var untracked: [String] = []
            if staged.isEmpty {
                diff = GitInfo.git(["diff", "HEAD", "--no-ext-diff"], in: path) ?? GitInfo.git(["diff", "--no-ext-diff"], in: path) ?? ""
                untracked = (GitInfo.git(["ls-files", "--others", "--exclude-standard"], in: path) ?? "").split(separator: "\n").map(String.init)
            }
            guard !diff.isEmpty || !untracked.isEmpty else {
                DispatchQueue.main.async { done(.failure(GenError("Nothing to commit."))) }
                return
            }
            let branch = GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recent = (GitInfo.git(["log", "-8", "--format=%s"], in: path) ?? "").split(separator: "\n").map(String.init)
            let text = prompt(diff: diff, untracked: untracked, branch: branch, recent: recent, instructions: instructions)
            let r = Result { try runText(profile: profile, model: modelName, prompt: text, run: run) }
            DispatchQueue.main.async { if !run.cancelled { done(r) } }
        }
        return run
    }

    struct GenError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// One background answer from the profile's CLI (also used for branch names). Blocks; call off the main queue.
    static func runText(profile: Profile, model: String?, prompt: String, run: Run) throws -> String {
        let p = run.process
        p.executableURL = URL(fileURLWithPath: profile.viaLoginShell ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : "/bin/sh")
        let last = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-commit-\(UUID().uuidString).last")
        defer { try? FileManager.default.removeItem(at: last) }
        p.arguments = [profile.viaLoginShell ? "-lc" : "-c", "exec " + commandLine(profile, model: model, lastMessage: profile.kind == .codex ? last.path : nil)]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in profile.env { env[k] = (v as NSString).expandingTildeInPath }
        p.environment = env
        // An empty folder: nothing of the project gets read or loaded besides what the prompt holds.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-commit-msg")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-commit-\(UUID().uuidString).out")
        let err = out.appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err) }
        let outH = try FileHandle(forWritingTo: out), errH = try FileHandle(forWritingTo: err)
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = outH
        p.standardError = errH
        try p.run()
        setpgid(p.processIdentifier, p.processIdentifier)
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { run.cancel(); throw GenError("\(profile.name) didn't answer within 90 seconds.") }
        try? outH.close(); try? errH.close()
        if run.cancelled { throw GenError("Stopped.") }
        let answer = profile.kind == .codex ? (try? Data(contentsOf: last)) : (try? Data(contentsOf: out))
        let text = clean(String(decoding: answer ?? Data(), as: UTF8.self))
        if p.terminationStatus != 0 || text.isEmpty {
            let e = String(decoding: ((try? Data(contentsOf: err)) ?? Data()).suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GenError("\(profile.name) failed" + (e.isEmpty ? " (exit \(p.terminationStatus))." : ": \(e)"))
        }
        return text
    }
}

/// Branch names for new worktrees: a pattern from Settings, or a short name an agent derives from the task.
enum BranchNames {
    /// `{user}`, `{date}`, `{project}`, `{n}` (the first number not taken). Nil when no pattern is set.
    static func fromPattern(_ pattern: String, project: Project, exists: (String) -> Bool, date: Date = Date(), user: String = NSUserName()) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        func fill(_ n: Int) -> String {
            sanitize(p.replacingOccurrences(of: "{user}", with: user.lowercased())
                .replacingOccurrences(of: "{date}", with: f.string(from: date))
                .replacingOccurrences(of: "{project}", with: project.name.lowercased())
                .replacingOccurrences(of: "{n}", with: String(n)))
        }
        guard p.contains("{n}") else { return fill(1) }
        for n in 1...999 where !exists(fill(n)) { return fill(n) }
        return fill(1000)
    }

    /// Something git accepts as a branch name: lower case, dashes for spaces, no `..`, no leading or trailing `/`.
    static func sanitize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(separator: "\n").first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "`'\" "))
        s = String(s.map { $0 == " " || $0 == "_" ? "-" : $0 }.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-/.".contains($0)) })
        while s.contains("..") { s = s.replacingOccurrences(of: "..", with: ".") }
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/.-"))
        if s.hasSuffix(".lock") { s = String(s.dropLast(5)) }
        return String(s.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "/.-"))
    }

    static func prompt(task: String, recent: [String]) -> String {
        var p = """
        Suggest one short git branch name for the task below.
        Rules: lower-case ASCII, words joined by dashes, at most 40 characters, starting with a type prefix such as
        feat/, fix/, chore/, docs/ or refactor/. Output ONLY the branch name, nothing else.

        """
        if !recent.isEmpty { p += "Existing branches in this repository (follow their style if they have one):\n" + recent.prefix(15).map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
        return p + "Task:\n\(task)\n"
    }

    /// Asks the commit-message agent for a branch name; calls back on the main queue.
    static func suggest(task: String, project: Project, model: AppModel, done: @escaping (Result<String, Error>) -> Void) -> CommitMessageGen.Run? {
        guard let profile = CommitMessageGen.profile(model: model, project: project.id) else {
            done(.failure(CommitMessageGen.GenError("No Claude Code or Codex agent is set up (Settings → Agents).")))
            return nil
        }
        let m = CommitMessageGen.modelName(model: model, project: project.id, kind: profile.kind)
        let run = CommitMessageGen.Run()
        DispatchQueue.global(qos: .userInitiated).async {
            let recent = GitInfo.branches(in: project.path, remotes: false)
            let r = Result { () -> String in
                let name = sanitize(try CommitMessageGen.runText(profile: profile, model: m, prompt: prompt(task: task, recent: recent), run: run))
                if name.isEmpty { throw CommitMessageGen.GenError("\(profile.name) gave no usable name.") }
                return name
            }
            DispatchQueue.main.async { if !run.cancelled { done(r) } }
        }
        return run
    }
}
