import XCTest
@testable import ADE

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
