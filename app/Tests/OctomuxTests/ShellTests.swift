import XCTest
import AppKit
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
        let rail = ["a", "b", "c"]
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
        let go = #selector(AppDelegate.goToTab(_:))
        XCTAssertEqual(ShellKeys.menuName(go, tag: 3, nav: .agents), "Agent 3")
        XCTAssertEqual(ShellKeys.menuName(go, tag: 3, nav: .tasks), "Task 3")
        XCTAssertEqual(ShellKeys.menuName(go, tag: 3, nav: .tabs), "Tab 3")
        XCTAssertEqual(ShellKeys.menuName(#selector(AppDelegate.newTerminal(_:)), tag: 0, nav: .tabs), "New Terminal Tab")
        XCTAssertEqual(ShellKeys.menuName(#selector(AppDelegate.newTerminal(_:)), tag: 0, nav: .tasks), "New Task")
        XCTAssertEqual(ShellKeys.menuName(#selector(AppDelegate.showMain(_:)), tag: 0, nav: .agents), "Home")
        XCTAssertNil(ShellKeys.menuName(#selector(AppDelegate.toggleSidebar(_:)), tag: 0, nav: .agents))
        XCTAssertTrue(ShellKeys.shellOnly(#selector(AppDelegate.prevAgent(_:))))   // ⌘[ / ⌘]: list windows only
        XCTAssertTrue(ShellKeys.shellOnly(#selector(AppDelegate.nextAgent(_:))))
        XCTAssertFalse(ShellKeys.shellOnly(#selector(AppDelegate.prevTab(_:))))
    }

    func testRailKeysStayInTheRailsWindow() {
        let rail = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertTrue(RailKeyMonitor.mine(rail, flags: [], rail: rail, modal: nil))
        XCTAssertTrue(RailKeyMonitor.mine(rail, flags: [.shift], rail: rail, modal: nil))
        XCTAssertFalse(RailKeyMonitor.mine(settings, flags: [], rail: rail, modal: nil))        // Settings keeps ↩ Esc ↑ ↓
        XCTAssertFalse(RailKeyMonitor.mine(nil, flags: [], rail: rail, modal: nil))
        XCTAssertFalse(RailKeyMonitor.mine(rail, flags: [], rail: rail, modal: settings))       // an alert is up
        XCTAssertFalse(RailKeyMonitor.mine(rail, flags: [.command], rail: rail, modal: nil))
        XCTAssertFalse(RailKeyMonitor.mine(rail, flags: [], rail: nil, modal: nil))             // the rail left its window
    }

    // MARK: Hidden blocks do nothing

    func testDigestsOnlyWhileARailOrHomeIsOnScreen() throws {
        let agents = try XCTUnwrap(ShellTree.builtIn("agents"))
        XCTAssertTrue(ShellView.wantsDigests(agents, railShown: true, homeShown: false))
        XCTAssertTrue(ShellView.wantsDigests(agents, railShown: false, homeShown: true))
        XCTAssertFalse(ShellView.wantsDigests(agents, railShown: false, homeShown: false))   // ⌘B on a session: no readers
        let bare = try ShellTree.parse(Data(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"workArea"}]}}"#.utf8)).get()
        XCTAssertFalse(ShellView.wantsDigests(bare, railShown: false, homeShown: true))      // no Home block in that tree
        // Every built-in tree: readers only where a rail, Home or the task detail shows.
        for name in ["aquarium", "terminal"] {
            let t = try XCTUnwrap(ShellTree.builtIn(name))
            XCTAssertFalse(ShellView.wantsDigests(t, railShown: true, homeShown: true, detailShown: true), name)
        }
        let workday = try XCTUnwrap(ShellTree.builtIn("workday"))
        XCTAssertTrue(ShellView.wantsDigests(workday, railShown: false, homeShown: true))
        let tasks = try XCTUnwrap(ShellTree.builtIn("tasks"))
        XCTAssertTrue(ShellView.wantsDigests(tasks, railShown: true, homeShown: false, detailShown: true))
        XCTAssertFalse(ShellView.wantsDigests(tasks, railShown: true, homeShown: true, detailShown: false))   // ⌘⌥B: none
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

    // MARK: Home and docs

    func testOpeningADocLeavesHome() {
        let m = AppModel.shared
        let (home, doc) = (m.shellHome, m.activeDocId)
        defer { m.activeDocId = doc; m.shellHome = home }
        m.shellHome = true
        m.activeDocId = "doc-x"                                        // a file, Inbox, Changes, new chat, PR…
        XCTAssertFalse(m.shellHome)
        m.shellHome = true                                             // ⌘0 back to Home keeps the doc for later
        XCTAssertEqual(m.activeDocId, "doc-x")
        m.activeDocId = nil
        XCTAssertTrue(m.shellHome)
    }

    func testLayoutIsReadAgainOnlyWhenASettingChanged() {
        let m = AppModel.shared
        let saved = m.layoutStored
        defer { m.setSettingLocally(AppModel.layoutKey, saved, scope: "global"); LayoutCache.reset() }
        LayoutCache.reset()
        var loads = 0
        let load: () -> (stored: JSONValue?, saved: JSONValue?) = { loads += 1; return (m.layoutStored, m.savedLayoutsStored) }
        _ = LayoutCache.get(revision: m.settingsRevision, load)
        _ = LayoutCache.get(revision: m.settingsRevision, load)
        XCTAssertEqual(loads, 1)
        m.setSettingLocally(AppModel.layoutKey, LayoutEdit.choose(.tasks, in: saved), scope: "global")
        XCTAssertEqual(LayoutCache.get(revision: m.settingsRevision, load).config.preset, .tasks)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(m.layout.preset, .tasks)
    }

    func testARailWithoutHomeIsNeverOnHome() throws {
        let m = AppModel.shared
        let (saved, home) = (m.layoutStored, m.shellHome)
        defer { m.setSettingLocally(AppModel.layoutKey, saved, scope: "global"); m.shellHome = home; LayoutCache.reset() }
        let bare = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"layout":"agents","custom":{"agents":{"tree":{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"workArea"}]}}}}}"#.utf8))
        m.setSettingLocally(AppModel.layoutKey, bare, scope: "global")
        XCTAssertEqual(m.shellNav, .agents)
        XCTAssertEqual(m.shellTree?.has(.home), false)
        m.shellHome = true
        XCTAssertFalse(m.shellHomeShown)                               // ⌘W closes the pane, the rail marks the session
        m.focusedSessionId = "s1"
        XCTAssertEqual(m.shellListCurrent, "s1")
        m.setSettingLocally(AppModel.layoutKey, LayoutEdit.choose(.agents, in: nil), scope: "global")
        m.shellHome = true
        XCTAssertTrue(m.shellHomeShown)
        XCTAssertNil(m.shellListCurrent)
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
        XCTAssertEqual(m.shellNav, .tabs)                              // Terminal: tabs again
        XCTAssertEqual(m.focusedSessionId, "s-keep")
        XCTAssertEqual(m.activeTabId, "t-keep")
    }
}
