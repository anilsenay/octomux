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
