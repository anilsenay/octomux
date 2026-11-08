import XCTest
@testable import Octomux

final class LayoutTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    // MARK: The default stays today's window

    func testNothingStoredIsTerminalAsItShips() {
        let c = LayoutConfig.resolve(nil)
        XCTAssertEqual(c, LayoutConfig.builtIn(.terminal))
        XCTAssertEqual(c.preset, .terminal)
        XCTAssertTrue(c.statusBar)
        XCTAssertFalse(c.chat)
    }

    /// Terminal's items are exactly today's window, in today's order (the brand's default look).
    func testTerminalIsTodaysWindow() {
        let c = LayoutConfig.builtIn(.terminal)
        XCTAssertEqual(c.shown(.sidebar), ["search", "inbox", "projects", "agents"])
        XCTAssertEqual(c.shown(.sidebarFooter), ["add", "workspaces", "settings"])
        XCTAssertEqual(c.shown(.statusLeft), ["agents", "git"])
        XCTAssertEqual(c.shown(.statusRight), ["keepAwake", "usage", "actions", "dock"])   // no Layout button
        XCTAssertEqual(c.shown(.topBar), ["diff", "openIn", "git", "rightPanel"])
        XCTAssertEqual(c.shown(.paneHeader), [])   // opt-in items stay off
    }

    /// Items added later are off in Terminal, also for a Terminal whose stored list predates them.
    func testNewItemsStayOffInTerminal() {
        for r in LayoutRegion.allCases {
            for id in r.optIn { XCTAssertFalse(LayoutConfig.builtIn(.terminal).has(id, in: r), "\(r).\(id)") }
        }
        let old = json(#"{"layout":"terminal","custom":{"terminal":{"regions":{"statusRight":[{"id":"usage","on":false}]}}}}"#)
        let c = LayoutConfig.resolve(old)
        for id in LayoutRegion.statusRight.optIn { XCTAssertFalse(c.has(id, in: .statusRight), id) }
        XCTAssertTrue(LayoutConfig.builtIn(.workday).has("work", in: .paneHeader))
    }

    /// Each layout turns on only the opt-in parts it is about.
    func testLayoutsTurnOnTheirOwnParts() {
        XCTAssertEqual(LayoutConfig.builtIn(.aquarium).shown(.views), [])               // its Home is the aquarium: no strip
        XCTAssertEqual(LayoutConfig.builtIn(.tasks).shown(.views), ["tasks"])
        XCTAssertTrue(LayoutConfig.builtIn(.tasks).has("tasks", in: .sidebar))
        for p in [LayoutPreset.agents, .workday, .tasks] {
            XCTAssertFalse(LayoutConfig.builtIn(p).has("aquarium", in: .statusRight), p.rawValue)
        }
    }

    func testOtherLayoutsShowTheWayBack() {
        for p in LayoutPreset.allCases where p != .terminal {
            XCTAssertTrue(LayoutConfig.builtIn(p).has("layout", in: .statusRight), p.rawValue)
        }
        XCTAssertTrue(LayoutConfig.builtIn(.agents).chat)
        XCTAssertEqual(LayoutConfig.builtIn(.workday).shown(.sidebar).first, "inbox")
    }

    // MARK: Broken values fall back

    func testUnreadableFallsBackToDefault() {
        for s in [#""agents""#, "5", "[1,2]", #"{"layout": 5, "custom": [1]}"#, #"{"layout": "nope"}"#] {
            XCTAssertEqual(LayoutConfig.resolve(json(s)).preset, .terminal, s)
            XCTAssertEqual(LayoutConfig.resolve(json(s)), .default, s)
        }
    }

    func testPartlyBrokenKeepsWhatItCanRead() {
        let v = json(#"{"layout":"workday","custom":{"workday":{"statusBar":"x","regions":{"sidebar":"oops","topBar":[{"id":"zzz"},{"id":"rightPanel","on":false},{"id":"rightPanel","on":true},7]}}}}"#)
        let c = LayoutConfig.resolve(v)
        XCTAssertEqual(c.preset, .workday)
        XCTAssertTrue(c.statusBar)                                               // wrong type: built-in
        XCTAssertEqual(c.items(.sidebar), LayoutConfig.builtIn(.workday).items(.sidebar))   // not a list: built-in
        XCTAssertEqual(c.shown(.topBar), ["diff", "openIn", "git"])               // unknown and repeated dropped
        XCTAssertEqual(c.items(.topBar).map(\.id), ["diff", "openIn", "git", "rightPanel"])
    }

    /// An item a later version adds shows up where its layout puts it, after the item before it.
    func testMissingItemsAreAddedInPlace() {
        let base = LayoutConfig.builtIn(.terminal).items(.statusRight)
        let stored: [JSONValue] = [json(#"{"id":"dock","on":true}"#), json(#"{"id":"usage","on":false}"#)]
        let out = LayoutConfig.merge(stored, into: base, known: LayoutRegion.statusRight.items)
        XCTAssertEqual(out.map(\.id), ["layout", "keepAwake", "dock", "usage", "actions", "aquarium"])
        XCTAssertEqual(out.first { $0.id == "usage" }?.on, false)
        XCTAssertEqual(out.first { $0.id == "aquarium" }?.on, false)   // opt-in: comes in off
        XCTAssertEqual(out.first { $0.id == "layout" }?.on, false)
    }

    // MARK: Editing

    func testEachLayoutKeepsItsOwnChanges() {
        var v = LayoutEdit.choose(.agents, in: nil)
        v = LayoutEdit.toggle("usage", in: .statusRight, on: false, stored: v)
        XCTAssertFalse(LayoutConfig.resolve(v).has("usage", in: .statusRight))
        v = LayoutEdit.choose(.workday, in: v)
        XCTAssertTrue(LayoutConfig.resolve(v).has("usage", in: .statusRight))
        v = LayoutEdit.choose(.agents, in: v)
        XCTAssertFalse(LayoutConfig.resolve(v).has("usage", in: .statusRight))
        XCTAssertTrue(LayoutEdit.isCustomized(v))
        v = LayoutEdit.reset(stored: v)
        XCTAssertFalse(LayoutEdit.isCustomized(v))
        XCTAssertEqual(LayoutConfig.resolve(v), LayoutConfig.builtIn(.agents))
    }

    func testMoveAndFlags() {
        var v = LayoutEdit.move("agents", in: .sidebar, by: -1, stored: nil)
        XCTAssertEqual(LayoutConfig.resolve(v).shown(.sidebar), ["search", "inbox", "agents", "projects"])
        let same = LayoutEdit.move("search", in: .sidebar, by: -1, stored: v)   // already first
        XCTAssertEqual(LayoutConfig.resolve(same).shown(.sidebar), ["search", "inbox", "agents", "projects"])
        v = LayoutEdit.flag("statusBar", false, stored: v)
        v = LayoutEdit.flag("chat", true, stored: v)
        let c = LayoutConfig.resolve(v)
        XCTAssertEqual(c.preset, .terminal)
        XCTAssertFalse(c.statusBar)
        XCTAssertTrue(c.chat)
    }

    // MARK: Moving the old setting

    func testHiddenCupMovesIntoTheLayout() throws {
        let v = try XCTUnwrap(LayoutEdit.migrate(stored: nil, keepAwakeHidden: true))
        let c = LayoutConfig.resolve(v)
        XCTAssertEqual(c.preset, .terminal)
        XCTAssertEqual(c.shown(.statusRight), ["usage", "actions", "dock"])
        // Everything else stays as it ships.
        for r in LayoutRegion.allCases where r != .statusRight { XCTAssertEqual(c.items(r), LayoutConfig.builtIn(.terminal).items(r)) }
    }

    func testMigrationOnlyWhenNeeded() {
        XCTAssertNil(LayoutEdit.migrate(stored: nil, keepAwakeHidden: false))                       // nothing to move
        XCTAssertNil(LayoutEdit.migrate(stored: LayoutEdit.choose(.agents, in: nil), keepAwakeHidden: true))   // already has a layout
    }

    // Files: a layout as a file (format v1) — LayoutFileTests.
}
