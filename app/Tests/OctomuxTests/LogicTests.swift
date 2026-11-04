import XCTest
@testable import Octomux

final class PaletteTests: XCTestCase {
    func testSubsequenceScoring() {
        XCTAssertNotNil(PaletteSource.score("split", "Split Right"))
        XCTAssertNil(PaletteSource.score("split", "Review PR #42"))
        // Word starts and contiguous runs rank higher.
        let a = PaletteSource.score("sr", "Split Right")!, b = PaletteSource.score("sr", "Session restart")!
        XCTAssertGreaterThan(a, 0); XCTAssertGreaterThan(b, 0)
        XCTAssertGreaterThan(PaletteSource.score("tog", "Toggle Dock")!, PaletteSource.score("tog", "Stop Session go")!)
        XCTAssertEqual(PaletteSource.score("", "anything"), 0)
    }
}

final class ShortcutTests: XCTestCase {
    func testRoundTrip() {
        let s = Shortcut(string: "cmd+shift+t")!
        XCTAssertEqual(s.key, "t")
        XCTAssertEqual(s.mods, [.command, .shift])
        XCTAssertEqual(s.string, "shift+cmd+t")
        XCTAssertEqual(s.display, "⇧⌘T")
        XCTAssertEqual(Shortcut(string: s.string), s)
    }
    func testArrowsAndControl() {
        let s = Shortcut(string: "ctrl+cmd+left")!
        XCTAssertEqual(s.display, "⌃⌘←")
        XCTAssertEqual(Shortcut(string: s.string), s)
        XCTAssertNil(Shortcut(string: "cmd+"))
    }
}

final class WorktreeTests: XCTestCase {
    func testParsePorcelain() {
        let out = """
        worktree /Users/me/proj
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/proj.worktrees/feat-x
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat/x

        worktree /Users/me/proj.worktrees/detached
        HEAD 3333333333333333333333333333333333333333
        detached
        """
        let w = Worktrees.parse(out)
        XCTAssertEqual(w.map(\.branch), ["main", "feat/x", "(detached)"])
        XCTAssertEqual(w.map(\.isMain), [true, false, false])
    }
    func testDefaultPath() {
        XCTAssertEqual(Worktrees.defaultPath(project: "/a/b/proj", branch: "feat/usage limits"), "/a/b/proj.worktrees/feat-usagelimits")
    }
}

final class ChatParsingTests: XCTestCase {
    private func lines(_ objs: [[String: Any]]) -> Data {
        Data(objs.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n" }.joined().utf8)
    }

    func testClaudeTranscript() {
        let m = ChatModel()
        m.feed(lines([
            ["type": "user", "message": ["role": "user", "content": "fix the bug"]],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "meta"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Looking."],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "cargo test"]]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok", "is_error": true]]]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
        ]))
        XCTAssertEqual(m.items.map(\.kind), [.user, .assistant, .tool, .note])
        XCTAssertEqual(m.items[2].detail, "cargo test")
        XCTAssertEqual(m.items[2].result, "ok")
        XCTAssertTrue(m.items[2].failed)
        XCTAssertEqual(m.items[3].text, "/clear")
    }

    func testCodexRolloutAndPartialLines() {
        let m = ChatModel()
        let all = lines([
            ["type": "session_meta", "payload": ["id": "x", "cwd": "/p"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>…</environment_context>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "bump deps"]]]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": "c1", "arguments": "{\"command\":[\"bash\",\"-lc\",\"cargo update\"]}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "{\"output\":\"done\"}"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Bumped."]]]],
        ])
        // Arrives in two chunks split mid-line.
        let cut = all.count / 2
        m.feed(all.prefix(cut))
        m.feed(all.suffix(from: cut))
        XCTAssertEqual(m.items.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(m.items[0].text, "bump deps")
        XCTAssertEqual(m.items[1].detail, "bash -lc cargo update")
        XCTAssertEqual(m.items[1].result, "done")
    }
}

final class UsageTests: XCTestCase {
    func testResetWindowsReadAsZero() {
        let past = UsageReading(profileId: "p", window: "five_hour", usedPercent: 80, resetsAt: Date().timeIntervalSince1970 - 10, observedAt: 0)
        XCTAssertTrue(past.isReset)
        XCTAssertEqual(past.effectivePercent, 0)
        let future = UsageReading(profileId: "p", window: "seven_day", usedPercent: 30, resetsAt: Date().timeIntervalSince1970 + 3600, observedAt: 0)
        XCTAssertFalse(future.isReset)
        XCTAssertEqual(future.shortName, "week")
    }
}

final class HostTests: XCTestCase {
    func testDecodesPreRenameCLIKey() throws {
        let old = try JSONDecoder().decode(Host.self, from: Data(#"{"id":"b","name":"box","kind":"ssh","target":"me@box","ade":"/usr/local/bin/ade","prefix":""}"#.utf8))
        XCTAssertEqual(old.cli, "/usr/local/bin/ade")
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""cli":"#) && !encoded.contains(#""ade":"#), encoded)
        let fresh = try JSONDecoder().decode(Host.self, from: Data(#"{"id":"c","name":"c","kind":"ssh"}"#.utf8))
        XCTAssertEqual(fresh.cli, "octomux")
    }

    func testSSHSharesOneConnection() {
        let h = Host(id: "b", name: "box", kind: "ssh", target: "me@box")
        let argv = h.controlArgv!
        XCTAssertTrue(argv.contains("ControlMaster=auto"))
        XCTAssertTrue(argv.contains("ControlPath=\(Host.muxDir)/%C"))
        XCTAssertTrue(h.attachCommand("s1").contains("ControlPath="))
        XCTAssertEqual(argv.suffix(3), ["me@box", "octomux", "stdio"])
    }

    func testUserMultiplexingWins() {
        let h = Host(id: "b", name: "box", kind: "ssh", target: "me@box", sshOptions: "-o ControlPath=~/.ssh/cm-%C")
        XCTAssertFalse(h.controlArgv!.contains("ControlMaster=auto"))
    }

    func testCommandHostHasNoMux() {
        let h = Host(id: "c", name: "c", kind: "command", prefix: "docker exec -i x")
        XCTAssertFalse(h.controlArgv!.joined(separator: " ").contains("ControlMaster"))
    }
}

final class WorkspaceScrollTests: XCTestCase {
    private func wheel(_ dy: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    func testWheelStepsOncePerBurst() {
        let s = WorkspaceScroller()
        var steps: [Int] = []
        s.onStep = { steps.append($0) }
        for _ in 0..<6 { s.handle(wheel(-3)) }          // spinning the wheel: one step
        XCTAssertEqual(steps, [1])
        Thread.sleep(forTimeInterval: 0.45)              // pause, then the other way
        s.handle(wheel(3)); s.handle(wheel(3))
        XCTAssertEqual(steps, [1, -1])
    }
}

final class GitDiffDataTests: XCTestCase {
    func testLineCountMatchesGit() {
        XCTAssertEqual(GitDiffData.lineCount(""), 0)
        XCTAssertEqual(GitDiffData.lineCount("new\n"), 1)
        XCTAssertEqual(GitDiffData.lineCount("a\nb"), 2)
        XCTAssertEqual(GitDiffData.lineCount("a\n\nb\n"), 3)
    }

    func testNumstatParsesRenames() {
        let s = GitDiffData.numstat("3\t1\tsrc/a.rs\n-\t-\timg.png\n2\t0\tsrc/{old => new}.rs\n")
        XCTAssertEqual(s["src/a.rs"]?.0, 3)
        XCTAssertEqual(s["img.png"]?.2, true)
        XCTAssertEqual(s["src/new.rs"]?.0, 2)
    }
}

final class GraphTests: XCTestCase {
    func testMergeKeepsMainlineInLaneZero() {
        func c(_ id: String, _ p: [String]) -> Commit { Commit(id: id, short: id, author: "", when: "", relative: "", subject: id, refs: "", parents: p) }
        // M merges F2 into A; F1 and B share the base.
        let rows = GraphRow.layout([c("M", ["A", "F2"]), c("F2", ["F1"]), c("F1", ["B"]), c("A", ["B"]), c("B", [])])
        XCTAssertEqual(rows.map(\.graph.node), [0, 1, 1, 0, 0])
        XCTAssertEqual(rows[0].graph.outgoing, [1])
        XCTAssertEqual(rows[4].graph.incoming, [1])
    }
}

final class TerminalTitleTests: XCTestCase {
    private func title(_ t: String, cwd: String) -> String {
        Session(id: "s", projectId: "p", kind: .terminal, profileId: nil, title: t, customTitle: "", cwd: cwd,
                state: .running, activity: .idle, unread: false, agentSessionId: nil, createdAt: 0, lastActivityAt: 0,
                exitCode: nil, placement: .tab, command: nil, worktree: nil, transcriptPath: nil, agentTitle: nil).displayTitle
    }

    func testClippedPromptTitles() {
        XCTAssertEqual(title("..onal_projects", cwd: "/Users/a/personal_projects"), "personal_projects")
        XCTAssertEqual(title("..onal_projects", cwd: "/Users/a/new-ade"), "…onal_projects")
        XCTAssertEqual(title("..cts/new-ade", cwd: "/x"), "new-ade")
        XCTAssertEqual(title("~/personal_projects/new-ade", cwd: "/x"), "new-ade")
        XCTAssertEqual(title("a@host: ~", cwd: "/x"), "~")
    }
}

final class WorktreeLockTests: XCTestCase {
    func testDetachedAndLocked() {
        let out = "worktree /r\nHEAD 01ee341aaf\nbranch refs/heads/main\n\nworktree /x/.tool-preparing/25795-d7f8\nHEAD 01ee341aaf\ndetached\nlocked tool-create-preparation:v1\n\nworktree /r.worktrees/f\nHEAD abcdef123\nbranch refs/heads/f\nlocked\n"
        let w = Worktrees.parse(out)
        XCTAssertEqual(w.count, 3)
        XCTAssertTrue(w[1].detached)
        XCTAssertEqual(w[1].label, "25795-d7f8")
        XCTAssertEqual(w[1].head, "01ee341")
        XCTAssertEqual(w[1].locked, "tool-create-preparation:v1")
        XCTAssertEqual(w[2].label, "f")
        XCTAssertEqual(w[2].locked, "")
        XCTAssertNil(w[0].locked)
    }
}

final class DefaultsMigrationTests: XCTestCase {
    func testRenamesPreRenameKeys() {
        XCTAssertEqual(DefaultsMigration.renamed("ade.sidebarWidth"), "octomux.sidebarWidth")
        XCTAssertEqual(DefaultsMigration.renamed("ade.lastNew.ws1"), "octomux.lastNew.ws1")
        XCTAssertEqual(DefaultsMigration.renamed("NSWindow Frame ADE.main"), "NSWindow Frame Octomux.main")
        XCTAssertNil(DefaultsMigration.renamed("NSNavLastRootDirectory"))
        XCTAssertEqual(DefaultsMigration.renamed("customKey"), "customKey")
    }

    func testCopiesWithoutOverwriting() {
        // One fixed suite, emptied before and after (a fresh name per run left a plist behind each time).
        let name = "octomux.tests.defaultsMigration"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        defer {
            d.removePersistentDomain(forName: name)
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        d.set(320.0, forKey: "ade.sidebarWidth")
        d.set("keep", forKey: "octomux.ws")
        d.set("old", forKey: "ade.ws")
        DefaultsMigration.run(d, from: [])
        XCTAssertEqual(d.double(forKey: "octomux.sidebarWidth"), 320)
        XCTAssertEqual(d.string(forKey: "octomux.ws"), "keep")
        XCTAssertTrue(d.bool(forKey: "octomux.defaultsMigrated"))
    }
}

final class CodexChatTests: XCTestCase {
    /// Codex's code mode writes tool calls as scripts; the chat view shows the tool and its command.
    func testCodeModeCall() {
        let script = "const r = await tools.exec_command({\n  cmd: \"touch \\\"a b\\\" /tmp/x\",\n  sandbox_permissions: \"require_escalated\",\n});\ntext(r)"
        let (name, input) = ChatModel.codeModeCall(script, fallback: "exec")
        XCTAssertEqual(name, "exec_command")
        XCTAssertEqual(input["command"] as? String, "touch \"a b\" /tmp/x")
        XCTAssertEqual(ChatModel.summary(name, input), "touch \"a b\" /tmp/x")
        let (other, rest) = ChatModel.codeModeCall("  \nconsole.log(1)\n", fallback: "exec")
        XCTAssertEqual(other, "exec")
        XCTAssertEqual(rest["command"] as? String, "console.log(1)")
    }
}

final class NotificationTextTests: XCTestCase {
    func testDoneKeepsBackgroundNote() {
        let n = { (t: String) in AppNotification(sessionId: "s", projectId: "p", kind: "done", title: t, body: "proj · name") }
        XCTAssertEqual(NotificationRow.message(n("Claude finished"), hasSession: true), "Finished a turn")
        XCTAssertEqual(NotificationRow.message(n("Claude finished · 1 shell still running"), hasSession: true), "Finished a turn · 1 shell still running")
    }
}

final class SettingsSearchTests: XCTestCase {
    func testMatchesTitlesAndWords() {
        XCTAssertEqual(Set(SettingsIndex.search("dock").map(\.title)), ["App icon", "Dock badge", "Icons"])
        XCTAssertEqual(SettingsIndex.search("ssh remote").first?.section, .hosts)
        XCTAssertTrue(SettingsIndex.search("  ").isEmpty)
        XCTAssertTrue(SettingsIndex.search("nothing-like-this").isEmpty)
    }

    func testEveryPageIsFindable() {
        for s in SettingsSection.allCases { XCTAssertFalse(SettingsIndex.search(s.rawValue).isEmpty, s.rawValue) }
    }
}

final class TerminalConfigTests: XCTestCase {
    func testReadsLastValueAndDefaults() {
        let c = TerminalConfig(text: "# font-size = 99\nfont-size = 12\nfont-family = \"Fira Code\"\nfont-size = 15\nadjust-cell-height = 20%\n")
        XCTAssertEqual(c.fontSize, 15)
        XCTAssertEqual(c.fontFamily, "Fira Code")
        XCTAssertEqual(c.lineHeightPercent, 20)
        let empty = TerminalConfig(text: "")
        XCTAssertEqual(empty.fontSize, TerminalConfig.defaultFontSize)
        XCTAssertNil(empty.fontFamily)
        XCTAssertEqual(empty.cursorStyle, "block")
        XCTAssertNil(empty.cursorBlink)
        XCTAssertNil(empty.scrollbackLines)
        XCTAssertEqual(TerminalConfig(text: "adjust-cell-height = 2").lineHeightPercent, 0, "pixels are not a percentage")
        XCTAssertNil(TerminalConfig(text: "scrollback-limit-lines = unlimited").scrollbackLines)
    }

    func testSetKeepsTheRestOfTheFile() {
        var c = TerminalConfig(text: "# mine\nfont-size = 12\ncursor-style = bar\nfont-size = 14\n")
        c.set("font-size", "16")
        XCTAssertEqual(c.text, "# mine\ncursor-style = bar\nfont-size = 16\n", "last line rewritten, earlier duplicates dropped")
        c.set("cursor-style", nil)
        XCTAssertEqual(c.text, "# mine\nfont-size = 16\n")
        c.set("font-family", "JetBrains Mono")
        XCTAssertEqual(c.text, "# mine\nfont-size = 16\nfont-family = JetBrains Mono\n")
        var e = TerminalConfig(text: "")
        e.set("font-size", "13")
        XCTAssertEqual(e.text, "font-size = 13\n")
        e.set("font-size", nil)
        XCTAssertEqual(e.value("font-size"), nil)
    }

    func testFontMenuListsFixedPitchFamilies() {
        let f = TerminalConfig.monospacedFamilies()
        XCTAssertTrue(f.contains("Menlo"))
        XCTAssertFalse(f.contains("Helvetica"))
    }

    func testScrollbackChoicesKeepAnUnlistedValue() {
        XCTAssertEqual(TerminalSettings.scrollbackChoices(current: nil), [1_000, 10_000, 100_000, 0])
        XCTAssertEqual(TerminalSettings.scrollbackChoices(current: 5_000), [1_000, 5_000, 10_000, 100_000, 0])
    }
}

final class ShortcutTargetTests: XCTestCase {
    func testTargets() {
        XCTAssertEqual(KeyBindings.target("cmd.close-pane"), "Focused pane")
        XCTAssertEqual(KeyBindings.target("cmd.focus-left"), "Split tab")
        XCTAssertEqual(KeyBindings.target("cmd.tab-3"), "Current project")
        XCTAssertEqual(KeyBindings.target("cmd.workspace-2"), "Workspaces")
        XCTAssertEqual(KeyBindings.target("cmd.toggle-sidebar"), "Window")
        XCTAssertEqual(KeyBindings.target("cmd.settings"), "App")
    }
}

final class UsageLabelTests: XCTestCase {
    func testUsedAndLeft() {
        let r = UsageReading(profileId: "p", window: "five_hour", usedPercent: 34.4, resetsAt: nil, observedAt: 0)
        XCTAssertEqual(r.label(left: false), "34%")
        XCTAssertEqual(r.label(left: true), "66%")
        let over = UsageReading(profileId: "p", window: "five_hour", usedPercent: 104, resetsAt: nil, observedAt: 0)
        XCTAssertEqual(over.label(left: true), "0%")
    }

    func testSoundSettings() {
        XCTAssertEqual(Notifier.soundKey(for: "done"), "notifications.sound_done")
        XCTAssertEqual(Notifier.soundKey(for: "command_done"), "notifications.sound_other")
        XCTAssertTrue(Notifier.systemSounds.contains("Glass"))
    }
}

final class StartOptionTests: XCTestCase {
    func testFlagsReadAndRewrite() {
        let a = ["--add-dir", "../x", "--model=sonnet", "--verbose", "--model", "opus"]
        XCTAssertEqual(ArgFlags.value(a, ["--model"]), "opus", "last one wins")
        XCTAssertEqual(ArgFlags.set(a, ["--model"], "haiku"), ["--add-dir", "../x", "--verbose", "--model", "haiku"])
        XCTAssertEqual(ArgFlags.set(a, ["--model"], nil), ["--add-dir", "../x", "--verbose"])
    }

    func testClaudeOptions() {
        var o = ProfileStartOptions(kind: .claude, args: ["--dangerously-skip-permissions", "--add-dir", "a"])
        XCTAssertEqual(o.permission, "bypassPermissions")
        o.permission = "plan"
        XCTAssertEqual(o.args, ["--add-dir", "a", "--permission-mode", "plan"])
        o.effort = "high"
        o.model = "opus"
        XCTAssertEqual(o.args, ["--add-dir", "a", "--permission-mode", "plan", "--effort", "high", "--model", "opus"])
        o.permission = nil
        XCTAssertNil(o.permission)
    }

    func testCodexOptions() {
        var o = ProfileStartOptions(kind: .codex, args: ["-m", "gpt-x", "-c", "model_reasoning_effort=\"low\"", "-c", "other=1"])
        XCTAssertEqual(o.model, "gpt-x")
        XCTAssertEqual(o.effort, "low")
        o.effort = "high"
        XCTAssertEqual(o.args, ["-m", "gpt-x", "-c", "other=1", "-c", "model_reasoning_effort=\"high\""])
        o.permission = "bypass"
        XCTAssertTrue(o.args.contains(ProfileStartOptions.codexBypass))
        XCTAssertEqual(o.permission, "bypass")
        o.permission = "on-request"
        XCTAssertFalse(o.args.contains(ProfileStartOptions.codexBypass))
        XCTAssertEqual(o.permission, "on-request")
        o.sandbox = "read-only"
        XCTAssertEqual(o.sandbox, "read-only")
    }

    func testOpenInOrder() {
        let apps = [ExternalApp(id: "a", name: "A"), ExternalApp(id: "b", name: "B"), ExternalApp(id: "c", name: "C")]
        XCTAssertEqual(OpenIn.ordered(apps, order: ["c", "a"]).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(OpenIn.ordered(apps, order: []).map(\.id), ["a", "b", "c"])
    }
}

final class DiagnosticsTests: XCTestCase {
    func testScrubRemovesSecrets() {
        let t = """
        ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuv
        "token": "abc123def", Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk
        mail me at someone.name@example.com, gh ghp_abcdefghijklmnopqrstuvwxyz0123
        /Users/me/projects/x is fine
        """
        let s = Diagnostics.scrub(t, home: "/Users/me")
        for leaked in ["sk-ant", "abc123def", "eyJhbGci", "someone.name", "ghp_abc", "/Users/me"] {
            XCTAssertFalse(s.contains(leaked), "\(leaked) in \(s)")
        }
        XCTAssertTrue(s.contains("~/projects/x is fine"))
        XCTAssertTrue(s.contains("<email>"))
    }

    func testStateHidesAgentEnvironment() {
        let st: [String: Any] = ["profiles": [["name": "Claude", "env": ["CLAUDE_CONFIG_DIR": "/x", "SECRET": "v"]]], "sessions": []]
        let out = Diagnostics.scrubbedState(st)
        XCTAssertFalse(out.contains("\"/x\""))
        XCTAssertTrue(out.contains("CLAUDE_CONFIG_DIR"))
    }

    func testWritesAZip() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("diag-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: dest) }
        try Diagnostics.write(to: dest, state: ["sessions": []], hello: ["version": 1])
        let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 100)
    }
}

final class WorktreePathTests: XCTestCase {
    func testDefaultAndCustomRoot() {
        XCTAssertEqual(Worktrees.defaultPath(project: "/p/app", branch: "feat/x", root: nil), "/p/app.worktrees/feat-x")
        XCTAssertEqual(Worktrees.defaultPath(project: "/p/app", branch: "feat/x", root: "/w"), "/w/app/feat-x")
    }
}

final class MCPConfigTests: XCTestCase {
    func testClaudeScopes() {
        let json: [String: Any] = [
            "mcpServers": ["fs": ["type": "stdio", "command": "npx", "args": ["-y", "server-fs"], "env": ["TOKEN": "secret"]]],
            "projects": ["/p/a": ["mcpServers": ["docs": ["type": "http", "url": "https://x/mcp"]],
                                  "enabledMcpjsonServers": ["shared"], "disabledMcpjsonServers": ["old"]]],
        ]
        let mcp: [String: Any] = ["mcpServers": ["shared": ["command": "s"], "old": ["command": "o"], "new": ["command": "n"]]]
        let s = MCPConfig.claude(json: json, file: "/h/.claude.json", projects: ["/p/a", "/p/b"]) { $0 == "/p/a" ? mcp : nil }
        XCTAssertEqual(s.map(\.name), ["fs", "docs", "new", "old", "shared"])
        XCTAssertEqual(s[0].command, "npx -y server-fs")
        XCTAssertEqual(s[0].envNames, ["TOKEN"])
        XCTAssertEqual(s[1].scope, .local("/p/a"))
        XCTAssertEqual(s[1].url, "https://x/mcp")
        XCTAssertEqual(s.first { $0.name == "shared" }?.enabled, true)
        XCTAssertEqual(s.first { $0.name == "old" }?.enabled, false)
        XCTAssertNil(s.first { $0.name == "new" }?.enabled, "not approved yet")
        XCTAssertFalse("\(s)".contains("secret"), "env values are never kept")
    }

    func testCodexToml() {
        let toml = """
        model = "x"
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github"]
        env = { GITHUB_TOKEN = "ghp_secret" }

        [mcp_servers.github.env]
        OTHER = "v"

        [mcp_servers."docs.site"]
        url = 'https://docs/mcp'
        enabled = false

        [profiles.fast]
        command = "nope"
        """
        let s = MCPConfig.codex(toml: toml, file: "/c/config.toml")
        XCTAssertEqual(s.map(\.name), ["github", "docs.site"])
        XCTAssertEqual(s[0].command, "npx -y @modelcontextprotocol/server-github")
        XCTAssertEqual(s[0].envNames, ["GITHUB_TOKEN", "OTHER"])
        XCTAssertEqual(s[0].enabled, true)
        XCTAssertEqual(s[1].url, "https://docs/mcp")
        XCTAssertEqual(s[1].enabled, false)
        XCTAssertFalse("\(s)".contains("ghp_secret"))
    }

    func testConfigFiles() {
        XCTAssertEqual(MCPConfig.claudeFile(configDir: "/x/cfg"), "/x/cfg/.claude.json")
        XCTAssertTrue(MCPConfig.claudeFile(configDir: nil).hasSuffix("/.claude.json"))
        XCTAssertEqual(MCPConfig.codexFile(home: "/c"), "/c/config.toml")
    }
}

final class GlobalHotKeyTests: XCTestCase {
    func testRegistersAndClears() {
        let hk = GlobalHotKey.shared
        let combo = GlobalHotKey.Combo(keyCode: 111 /* F12 */, mods: [.control, .option, .command], display: "⌃⌥⌘F12")
        XCTAssertEqual(combo.carbonMods, UInt32(4096 | 2048 | 256))
        XCTAssertEqual(GlobalHotKey.Combo(dict: combo.dict), combo)
        hk.save(combo)
        XCTAssertEqual(hk.registered, combo)
        XCTAssertFalse(hk.failed)
        hk.save(nil)
        XCTAssertNil(hk.registered)
    }
}

final class PromptTemplateTests: XCTestCase {
    func testExpandAndInsert() {
        let p = Project(id: "p", workspaceId: "w", name: "storefront", path: "/src/storefront", color: "#fff", icon: ProjectIcon(kind: "folder"), sort: 0, archived: false)
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let out = PromptTemplate.expand("Review {branch} of {project} in {path} ({date}): {clipboard} {unknown}", project: p, folder: nil, branch: "feat/x", clipboard: "err", date: d)
        XCTAssertEqual(out, "Review feat/x of storefront in /src/storefront (2026-11-04): err {unknown}")
        XCTAssertEqual(PromptTemplate.insert("T", into: "  "), "T")
        XCTAssertEqual(PromptTemplate.insert("T", into: "hi"), "hi\nT")
    }
}

final class CommitMessageGenTests: XCTestCase {
    func testCleanStripsWrapping() {
        XCTAssertEqual(CommitMessageGen.clean("```\nFix the resize race\n\nBody here\n```\n"), "Fix the resize race\n\nBody here")
        XCTAssertEqual(CommitMessageGen.clean("Generating…\n\"Add usage meter\""), "Add usage meter")
        XCTAssertEqual(CommitMessageGen.clean("Add x\n\nCo-authored-by: Bot <b@x>"), "Add x")
    }

    func testTruncateSharesBudgetPerFile() {
        let small = "diff --git a/s b/s\n+tiny\n"
        let huge = "diff --git a/h b/h\n" + String(repeating: "+line of a generated file\n", count: 5000)
        let out = CommitMessageGen.truncate(huge + small, budget: 2000)
        XCTAssertTrue(out.contains("+tiny"), "the small file survives the huge one")
        XCTAssertTrue(out.contains("left out"))
        XCTAssertLessThan(out.count, 2400)
        XCTAssertEqual(CommitMessageGen.truncate(small, budget: 2000), small)
    }

    func testPromptAndCommandLine() {
        let p = CommitMessageGen.prompt(diff: "D", untracked: ["new.swift"], branch: "feat/x", recent: ["Fix a", "Add b"], instructions: "Use Conventional Commits")
        for part in ["Branch: feat/x", "- Fix a", "Use Conventional Commits", "- new.swift", "```diff\nD\n```"] { XCTAssertTrue(p.contains(part), part) }
        let claude = Profile(id: "c", name: "Claude", icon: "claude", kind: .claude, command: "claude", args: [], env: [:], viaLoginShell: true, resumeTemplate: "", enabled: true, pinned: false, sort: 0)
        let cl = CommitMessageGen.commandLine(claude, model: "haiku")
        XCTAssertTrue(cl.hasPrefix("claude -p --output-format text --tools '' --no-session-persistence"), cl)
        XCTAssertTrue(cl.contains("--model haiku"))
        var codex = claude; codex.kind = .codex; codex.command = "codex"
        let cx = CommitMessageGen.commandLine(codex, model: nil, lastMessage: "/tmp/l")
        XCTAssertEqual(cx, "codex exec --ephemeral --skip-git-repo-check -s read-only --color never -o /tmp/l -")
    }
}

final class SmallItemsTests: XCTestCase {
    private let project = Project(id: "p", workspaceId: "w", name: "Storefront", path: "/src/storefront", color: "#fff", icon: ProjectIcon(kind: "folder"), sort: 0, archived: false)

    func testBranchPattern() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let taken: Set<String> = ["anil/2026-11-04-1", "anil/2026-11-04-2"]
        XCTAssertEqual(BranchNames.fromPattern("{user}/{date}-{n}", project: project, exists: { taken.contains($0) }, date: d, user: "Anil"), "anil/2026-11-04-3")
        XCTAssertEqual(BranchNames.fromPattern("{project}/wip", project: project, exists: { _ in false }, date: d), "storefront/wip")
        XCTAssertNil(BranchNames.fromPattern("  ", project: project, exists: { _ in false }))
    }

    func testSanitizeBranch() {
        XCTAssertEqual(BranchNames.sanitize("`Fix/Flaky Resize Test`\nmore"), "fix/flaky-resize-test")
        XCTAssertEqual(BranchNames.sanitize("feat//a..b--c.lock"), "feat/a.b-c")
        XCTAssertEqual(BranchNames.sanitize("/çok güzel/"), "ok-gzel")
    }

    func testUsageWindowsAndTitles() {
        let r = [UsageReading(profileId: "p", window: "five_hour", usedPercent: 1, resetsAt: nil, observedAt: 0),
                 UsageReading(profileId: "p", window: "seven_day", usedPercent: 2, resetsAt: nil, observedAt: 0)]
        XCTAssertEqual(UsageReading.shown(r, "weekly").map(\.window), ["seven_day"])
        XCTAssertEqual(UsageReading.shown(r, "all").count, 2)
        XCTAssertEqual(UsageReading.shown([r[1]], "five_hour").map(\.window), ["seven_day"], "falls back to what there is")
    }
}

final class PullRequestTests: XCTestCase {
    func testGithubRepo() {
        XCTAssertEqual(PullRequest.githubRepo("git@github.com:anilsenay/octomux.git"), "anilsenay/octomux")
        XCTAssertEqual(PullRequest.githubRepo("https://github.com/anilsenay/octomux"), "anilsenay/octomux")
        XCTAssertEqual(PullRequest.githubRepo("ssh://git@github.com/a/b.git\n"), "a/b")
        XCTAssertNil(PullRequest.githubRepo("https://gitlab.com/a/b.git"))
        XCTAssertNil(PullRequest.githubRepo("/local/repo"))
    }

    func testCompareURLAndParse() {
        let u = PullRequest.compareURL(repo: "a/b", base: "main", head: "feat/x", title: "Add x & y", body: "## Summary\n- one", draft: true)!.absoluteString
        XCTAssertTrue(u.hasPrefix("https://github.com/a/b/compare/main...feat/x?expand=1&title=Add%20x%20%26%20y"), u)
        XCTAssertTrue(u.contains("draft=1"))
        let (t, b) = PullRequest.parse("```\nTitle: Add usage meter.\n\n## Summary\n- shows limits\n```")!
        XCTAssertEqual(t, "Add usage meter")
        XCTAssertEqual(b, "## Summary\n- shows limits")
        XCTAssertNil(PullRequest.parse("   \n"))
    }
}
