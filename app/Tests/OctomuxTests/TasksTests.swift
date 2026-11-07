import XCTest
@testable import Octomux

final class TasksTests: XCTestCase {
    private func session(_ id: String, _ a: Activity, state: SessionState = .running) -> Session {
        Session(id: id, projectId: "p", kind: .agent, profileId: nil, title: id, customTitle: "", cwd: "/",
                state: state, activity: a, unread: false, agentSessionId: nil, createdAt: 0, lastActivityAt: 0,
                exitCode: nil, placement: .tab, command: nil, worktree: nil, transcriptPath: nil, agentTitle: nil)
    }

    func testDecodesTheDaemonsTaskAndStateWithoutTasks() throws {
        let json = #"""
        {"id":"a1b2c3d4e5f6","project_id":"p","title":"Fix cart","description":"","parent_id":null,"worktree":null,"branch":null,
         "sessions":["s1"],"state":"needs_you","state_manual":false,"pr_url":null,"source":"jira:SHOP-12","agent_profile":null,
         "created_by":"agent:s9","assistant_session":null,"turns":2,"created_at":10,"updated_at":11}
        """#
        let t = try JSONDecoder().decode(WorkTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.state, .needsYou)
        XCTAssertEqual(t.sessions, ["s1"])
        XCTAssertEqual(t.sourceKey, "SHOP-12")
        XCTAssertEqual(t.turns, 2)
        let st = try JSONDecoder().decode(DaemonState.self, from: Data(#"{"workspaces":[],"projects":[],"profiles":[],"sessions":[],"tabs":[],"settings":[]}"#.utf8))
        XCTAssertEqual(st.tasks, [])
        var gh = t; gh.source = "gh:o/r#12"
        XCTAssertEqual(gh.sourceKey, "#12")
        gh.source = "manual"
        XCTAssertNil(gh.sourceKey)
    }

    func testStateFollowsTheSessionsAndThePullRequest() {
        var t = WorkTask(id: "t", projectId: "p", title: "x")
        XCTAssertEqual(TaskRules.derive(t, sessions: [], pr: nil), .planned)
        t.sessions = ["a", "b"]
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .working), session("b", .idle)], pr: nil), .working)
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .working), session("b", .needsInput)], pr: nil), .needsYou)
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .done), session("b", .idle)], pr: nil), .readyToReview)
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .needsInput, state: .exited)], pr: nil), .readyToReview)   // a dead session waits for nobody
        t.prUrl = "https://github.com/o/r/pull/1"
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .done)], pr: nil), .inReview)
        var pr = InboxItem(id: "gh:o/r#1", source: .github, kind: .pr, key: "#1", place: "o/r", title: "x", author: "You", assignee: nil,
                           status: "Merged", statusTone: "done", reason: .mine, updated: Date(), body: "", url: t.prUrl!)
        pr.ended = InboxItem.Ended(label: "Merged", merged: true, at: Date())
        XCTAssertEqual(TaskRules.derive(t, sessions: [], pr: pr), .done)
        t.stateManual = true; t.state = .planned
        XCTAssertEqual(TaskRules.derive(t, sessions: [session("a", .working)], pr: pr), .planned)   // by hand stays
    }

    func testAssistantGetsAtMostFiveTurnsPerTaskAndNoneWithAutopilotOff() {
        var t = WorkTask(id: "t", projectId: "p", title: "x", state: .working)
        XCTAssertEqual(Autopilot.maxTurns, 5)
        XCTAssertNotNil(TaskAssistant.notify(t, from: .working, to: .done, level: .start))
        XCTAssertNil(TaskAssistant.notify(t, from: .working, to: .done, level: .off))
        t.turns = 4
        XCTAssertNotNil(TaskAssistant.notify(t, from: .working, to: .needsInput, level: .pr))
        t.turns = 5
        XCTAssertNil(TaskAssistant.notify(t, from: .working, to: .done, level: .start))   // the sixth: not sent
        XCTAssertNil(TaskAssistant.notify(WorkTask(id: "u", projectId: "p", title: "y"), from: .working, to: .working, level: .start))
    }

    func testTasksRailGroupsByWhatTheyNeedDoneOnlyWhenAsked() {
        var a = WorkTask(id: "a", projectId: "p", title: "a", state: .planned); a.createdAt = 1
        var b = WorkTask(id: "b", projectId: "p", title: "b", state: .needsYou); b.createdAt = 2
        var c = WorkTask(id: "c", projectId: "p", title: "c", state: .working); c.createdAt = 3
        let d = WorkTask(id: "d", projectId: "p", title: "d", state: .done)
        let all = [a, b, c, d]
        XCTAssertEqual(TasksRailModel.grouped(all, filter: nil, showDone: false).map(\.0), [.needsYou, .working, .planned])
        XCTAssertEqual(TasksRailModel.flat(all, filter: nil, showDone: false).map(\.id), ["b", "c", "a"])   // ⌘1…9 order
        XCTAssertEqual(TasksRailModel.flat(all, filter: nil, showDone: true).map(\.id), ["b", "c", "a", "d"])
        XCTAssertEqual(TasksRailModel.flat(all, filter: .working, showDone: false).map(\.id), ["c"])
        XCTAssertEqual(TasksRailModel.flat(all, filter: .done, showDone: false).map(\.id), ["d"])           // the Done chip shows them
        XCTAssertTrue(TasksRailModel.grouped([], filter: nil, showDone: true).isEmpty)
    }

    func testBranchPromptAndOrder() {
        XCTAssertEqual(TaskRules.branch("Fix the cart total!", id: "abc"), "task/fix-the-cart-total")
        XCTAssertEqual(TaskRules.branch("Sepet toplamını düzelt", id: "abc"), "task/sepet-toplamini-duzelt")
        XCTAssertEqual(TaskRules.branch("!!!", id: "abc"), "task/abc")
        var t = WorkTask(id: "t", projectId: "p", title: "Do it"); t.description = "Carefully."
        XCTAssertEqual(TaskRules.prompt(t), "Do it\n\nCarefully.")
        var a = WorkTask(id: "a", projectId: "p", title: "a", state: .planned); a.createdAt = 1
        var b = WorkTask(id: "b", projectId: "p", title: "b", state: .needsYou); b.createdAt = 2
        var c = WorkTask(id: "c", projectId: "p", title: "c", state: .working); c.parentId = "a"
        let d = WorkTask(id: "d", projectId: "p", title: "d", state: .done)
        XCTAssertEqual(TaskRules.ordered([a, c, d, b]).map(\.id), ["b", "a", "c", "d"])   // needs you first; subtask after its parent
    }

    func testAutopilotRules() {
        XCTAssertFalse(TaskAssistant.mayStart(level: .off, byAssistant: true, running: 0, maxAgents: 3))
        XCTAssertTrue(TaskAssistant.mayStart(level: .start, byAssistant: true, running: 2, maxAgents: 3))
        XCTAssertFalse(TaskAssistant.mayStart(level: .start, byAssistant: true, running: 3, maxAgents: 3))
        XCTAssertFalse(TaskAssistant.mayStart(level: .pr, byAssistant: false, running: 0, maxAgents: 3))   // only the assistant
        let t = WorkTask(id: "t1", projectId: "p", title: "Cart")
        XCTAssertTrue(TaskAssistant.update(t, from: .working, to: .done)?.hasPrefix("[Octomux] Task “Cart” (t1): its agent finished") ?? false)
        XCTAssertTrue(TaskAssistant.update(t, from: .working, to: .needsInput)?.contains("Don't answer for them") ?? false)
        XCTAssertNil(TaskAssistant.update(t, from: .idle, to: .working))
        XCTAssertNil(TaskAssistant.update(t, from: .done, to: .done))
    }

    func testTheAssistantCannotEdit() {
        let c = TaskAssistant.args(for: .claude)
        XCTAssertEqual(c[0], "--disallowedTools")
        XCTAssertTrue(c[1].contains("Edit") && c[1].contains("Write"))
        XCTAssertEqual(c[2], "--append-system-prompt")
        XCTAssertNil(TaskAssistant.firstMessage(for: .claude))
        XCTAssertEqual(TaskAssistant.args(for: .codex), ["--sandbox", "read-only"])
        XCTAssertNotNil(TaskAssistant.firstMessage(for: .codex))
    }

    func testTasksAreOptInOutsideTheirLayout() {
        XCTAssertFalse(RightTab.shown(LayoutConfig.builtIn(.terminal)).contains(.tasks))
        XCTAssertEqual(RightTab.shown(LayoutConfig.builtIn(.terminal)), [.files, .changes, .sessions])
        XCTAssertFalse(LayoutConfig.builtIn(.terminal).has("tasks", in: .sidebar))
    }
}
