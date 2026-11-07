import XCTest
@testable import Octomux

final class ShellTests: XCTestCase {
    private func s(_ id: String, _ a: Activity, kind: SessionKind = .agent, project: String = "p", at: Int = 0,
                   placement: Placement = .tab, state: SessionState = .running, unread: Bool = false) -> Session {
        Session(id: id, projectId: project, kind: kind, profileId: nil, title: id, customTitle: "", cwd: "/", state: state, activity: a,
                unread: unread, agentSessionId: nil, createdAt: 0, lastActivityAt: at, exitCode: nil, placement: placement, command: nil,
                worktree: nil, transcriptPath: nil, agentTitle: nil)
    }

    // MARK: Rail

    func testRailGroupsByWhatTheyNeedNewestFirst() {
        let list = [s("w1", .working, at: 5), s("q", .needsInput, at: 1), s("e", .error, at: 9), s("d", .done, at: 3),
                    s("u", .idle, at: 4, unread: true), s("i", .idle, at: 8), s("t", .idle, kind: .terminal, at: 7),
                    s("x", .working, at: 6, state: .exited)]
        let g = AgentRailModel.grouped(list)
        XCTAssertEqual(g.map(\.0), [.waiting, .working, .done, .idle])
        XCTAssertEqual(g.map { $0.1.map(\.id) }, [["e", "q"], ["w1"], ["u", "d"], ["i", "t", "x"]])
        XCTAssertEqual(AgentRailModel.flat(list).map(\.id), ["e", "q", "w1", "u", "d", "i", "t", "x"])
    }

    func testRailListsTabSessionsOfTheWorkspaceAndTheFilter() {
        let list = [s("a", .working, project: "p1"), s("b", .working, project: "p2"), s("c", .working, project: "other"),
                    s("dock", .idle, kind: .terminal, project: "p1", placement: .dock), s("run", .idle, kind: .action, project: "p1")]
        XCTAssertEqual(AgentRailModel.sessions(list, projects: ["p1", "p2"], filter: nil).map(\.id), ["a", "b"])
        XCTAssertEqual(AgentRailModel.sessions(list, projects: ["p1", "p2"], filter: "p2").map(\.id), ["b"])
        XCTAssertTrue(AgentRailModel.grouped([]).isEmpty)
    }

    // MARK: Keys

    func testTabKeysMoveOverTheRail() {
        let rail = [s("a", .working), s("b", .idle), s("c", .idle)]
        XCTAssertEqual(ShellKeys.goTo(1, rail: rail), "a")
        XCTAssertEqual(ShellKeys.goTo(3, rail: rail), "c")
        XCTAssertNil(ShellKeys.goTo(4, rail: rail))
        XCTAssertEqual(ShellKeys.goTo(9, rail: rail), "c")              // ⌘9: the last
        XCTAssertNil(ShellKeys.goTo(1, rail: []))
        XCTAssertEqual(ShellKeys.step(1, current: nil, rail: rail), "a")  // from Home
        XCTAssertEqual(ShellKeys.step(-1, current: nil, rail: rail), "c")
        XCTAssertEqual(ShellKeys.step(1, current: "c", rail: rail), "a")  // wraps
        XCTAssertEqual(ShellKeys.step(-1, current: "a", rail: rail), "c")
        XCTAssertEqual(ShellKeys.step(1, current: "gone", rail: rail), "a")
    }

    func testMenuSpeaksAgentsOnlyInTheEngineWindow() {
        XCTAssertEqual(ShellKeys.menuNames(#selector(AppDelegate.goToTab(_:)), tag: 3)?.shell, "Agent 3")
        XCTAssertEqual(ShellKeys.menuNames(#selector(AppDelegate.goToTab(_:)), tag: 3)?.classic, "Tab 3")
        XCTAssertEqual(ShellKeys.menuNames(#selector(AppDelegate.newTerminal(_:)), tag: 0)?.classic, "New Terminal Tab")
        XCTAssertEqual(ShellKeys.menuNames(#selector(AppDelegate.showMain(_:)), tag: 0)?.shell, "Home")
        XCTAssertNil(ShellKeys.menuNames(#selector(AppDelegate.toggleSidebar(_:)), tag: 0))
        XCTAssertTrue(ShellKeys.shellOnly(#selector(AppDelegate.prevAgent(_:))))   // ⌘[ / ⌘]: engine window only
        XCTAssertTrue(ShellKeys.shellOnly(#selector(AppDelegate.nextAgent(_:))))
        XCTAssertFalse(ShellKeys.shellOnly(#selector(AppDelegate.prevTab(_:))))
    }

    // MARK: Hidden blocks do nothing

    func testDigestsOnlyWhileARailOrHomeIsOnScreen() throws {
        let agents = try XCTUnwrap(ShellTree.builtIn("agents"))
        XCTAssertTrue(ShellView.wantsDigests(agents, railShown: true, homeShown: false))
        XCTAssertTrue(ShellView.wantsDigests(agents, railShown: false, homeShown: true))
        XCTAssertFalse(ShellView.wantsDigests(agents, railShown: false, homeShown: false))   // ⌘B on a session: no readers
        let bare = try ShellTree.parse(Data(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"workArea"}]}}"#.utf8)).get()
        XCTAssertFalse(ShellView.wantsDigests(bare, railShown: false, homeShown: true))      // no Home block in that tree
    }

    // MARK: Home

    func testHomeWords() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 7
        c.hour = 9; let morning = Calendar.current.date(from: c)!
        c.hour = 21; let night = Calendar.current.date(from: c)!
        XCTAssertEqual(ShellHome.greeting(morning, name: "Ada Lovelace"), "Good morning, Ada.")
        XCTAssertEqual(ShellHome.greeting(night, name: ""), "Good evening.")
        XCTAssertEqual(ShellHome.status(waiting: 3, working: 1, done: 0), "3 agents are waiting for you · 1 working")
        XCTAssertEqual(ShellHome.status(waiting: 1, working: 0, done: 2), "1 agent is waiting for you · 2 done")
        XCTAssertEqual(ShellHome.status(waiting: 0, working: 0, done: 0), "No agent is running. Start one below.")
    }

    // MARK: Switching layouts

    func testSwitchingLayoutsKeepsTheSelection() {
        let m = AppModel.shared
        let saved = m.layoutStored
        defer { m.setSettingLocally(AppModel.layoutKey, saved, scope: "global"); LayoutCache.reset() }
        m.focusedSessionId = "s-keep"; m.activeTabId = "t-keep"
        m.chooseLayout(.agents)
        XCTAssertNotNil(m.shellTree)
        XCTAssertTrue(m.shellHome)
        XCTAssertEqual(m.focusedSessionId, "s-keep")
        XCTAssertEqual(m.activeTabId, "t-keep")
        m.chooseLayout(.terminal)
        XCTAssertNil(m.shellTree)                                      // the classic window again
        XCTAssertEqual(m.focusedSessionId, "s-keep")
        XCTAssertEqual(m.activeTabId, "t-keep")
    }
}
