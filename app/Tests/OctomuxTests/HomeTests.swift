import XCTest
@testable import Octomux

/// Home's sections, presets and the `ui.home` setting.
final class HomeTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    /// The presets are today's Homes, section for section.
    func testPresetsAreTodaysHomes() {
        XCTAssertEqual(HomePreset.agents.layout, HomeLayout(top: [.greeting, .composer], main: [.waiting], side: [.recent, .usage], width: .narrow, split: HomeLayout.narrowSide))
        XCTAssertEqual(HomePreset.workday.layout, HomeLayout(top: [.today, .stats], main: [.waiting, .away], side: [.pullRequests, .reviews, .issues]))
        XCTAssertEqual(HomePreset.board.layout, HomeLayout(top: [.composer, .board]))
        XCTAssertEqual(HomePreset.aquarium.layout, HomeLayout(top: [.aquarium]))
        for p in HomePreset.allCases { XCTAssertEqual(Set(p.layout.all).count, p.layout.all.count, p.rawValue) }   // each once
    }

    func testOldNamesAreUnderstood() {
        XCTAssertEqual(HomePreset.named("workday"), .workday)
        XCTAssertEqual(HomePreset.named("aquarium"), .aquarium)
        XCTAssertEqual(HomePreset.named("columns"), .board)
        XCTAssertEqual(HomePreset.named("nonsense"), .agents)
        XCTAssertEqual(HomePreset.named(nil), .agents)
        XCTAssertTrue(ShellBlock.home.variants.contains("board"))
    }

    func testBigSectionFillsOnlyWhenColumnsAreEmpty() {
        XCTAssertEqual(HomePreset.aquarium.layout.filling, .aquarium)
        XCTAssertEqual(HomePreset.board.layout.filling, .board)          // the composer above it
        XCTAssertNil(HomePreset.agents.layout.filling)
        XCTAssertNil(HomeLayout(top: [.aquarium], main: [.waiting]).filling)   // a strip on top then
        XCTAssertNil(HomeLayout(top: [.aquarium, .greeting]).filling)
    }

    // MARK: Changing the arrangement

    func testMoveAcrossAndWithinBands() {
        let a = HomePreset.agents.layout
        // usage under waiting in the main column
        XCTAssertEqual(a.moving(.usage, to: .main).main, [.waiting, .usage])
        XCTAssertEqual(a.moving(.usage, to: .main).side, [.recent])
        // to the top, first
        XCTAssertEqual(a.moving(.recent, to: .top, at: 0).top, [.recent, .greeting, .composer])
        // down in its own band: dropped on the slot after composer
        XCTAssertEqual(a.moving(.greeting, to: .top, at: 2).top, [.composer, .greeting])
        // up in its own band
        XCTAssertEqual(a.moving(.usage, to: .side, at: 0).side, [.usage, .recent])
        // a new section
        XCTAssertEqual(a.moving(.issues, to: .side).side, [.recent, .usage, .issues])
        XCTAssertEqual(a.moving(.issues, to: .side, at: 99).side.last, .issues)
        XCTAssertEqual(a.removing(.recent).side, [.usage])
        XCTAssertFalse(a.missing.contains(.waiting))
        XCTAssertTrue(a.missing.contains(.board))
        XCTAssertEqual(a.band(of: .usage), .side)
    }

    // MARK: The setting

    func testNothingStoredReadsAsNothing() {
        XCTAssertNil(HomeSetting.read(nil))
        XCTAssertNil(HomeSetting.read(.string("agents")))
    }

    func testPresetOnlyIsThePresetAsItShips() {
        let h = HomeSetting.read(json(#"{"preset":"workday"}"#))
        XCTAssertEqual(h, HomeSetting(preset: .workday))
        XCTAssertEqual(h?.layout, HomePreset.workday.layout)
        XCTAssertEqual(h?.changed, false)
        XCTAssertEqual(HomeSetting.read(json(#"{"preset":"later"}"#))?.preset, .agents)
    }

    func testCustomRoundTripsAndDropsUnknownsAndRepeats() {
        let h = HomeSetting.read(json(#"{"preset":"agents","top":["greeting","sparkles","greeting"],"main":["waiting","usage"],"side":["usage","recent"]}"#))
        XCTAssertEqual(h?.layout, HomeLayout(top: [.greeting], main: [.waiting, .usage], side: [.recent], width: .narrow, split: HomeLayout.narrowSide))
        XCTAssertEqual(h?.changed, true)
        XCTAssertEqual(HomeSetting.read(h!.json), h)
    }

    func testThePresetsOwnArrangementIsNoChange() {
        let s = HomeSetting(preset: .agents)
        XCTAssertFalse(s.with(HomePreset.agents.layout).changed)
        XCTAssertNil(s.with(HomePreset.agents.layout).custom)
        XCTAssertEqual(s.with(HomePreset.agents.layout).json, json(#"{"preset":"agents"}"#))
        // stored with bands equal to the preset: read as unchanged
        XCTAssertEqual(HomeSetting.read(json(#"{"preset":"board","top":["composer","board"],"main":[],"side":[]}"#)), HomeSetting(preset: .board))
        // emptied is a change (Customize shows "+ Add section")
        let empty = s.with(HomeLayout())
        XCTAssertTrue(empty.changed)
        XCTAssertEqual(HomeSetting.read(empty.json)?.layout, HomeLayout())
    }

    // MARK: On the model (settings stay in the test's model: no daemon in unit tests)

    func testModelReadsLegacyHomeUntilOneIsChosen() {
        let m = AppModel.shared
        XCTAssertTrue(DaemonClient.isolated)
        let saved = (m.layoutStored, m.settingValue(HomeSetting.key, scope: "global"))
        defer {
            m.setSettingLocally(AppModel.layoutKey, saved.0, scope: "global")
            m.setSettingLocally(HomeSetting.key, saved.1, scope: "global")
            LayoutCache.reset()
        }
        m.setSettingLocally(HomeSetting.key, nil, scope: "global")
        m.setSettingLocally(AppModel.layoutKey, nil, scope: "global")
        XCTAssertEqual(m.homeSetting, HomeSetting(preset: .agents))
        XCTAssertNil(m.homeFixedByTree)                                       // Terminal: no Home block in its tree

        // An older version's Workday layout: Agents with the Workday Home, also read from the Terminal window.
        m.setSettingLocally(AppModel.layoutKey, json(#"{"layout":"workday"}"#), scope: "global")
        XCTAssertEqual(m.homeSetting.preset, .workday)
        m.setSettingLocally(AppModel.layoutKey, json(#"{"layout":"terminal","custom":{"agents":{"home":"aquarium"}}}"#), scope: "global")
        XCTAssertEqual(m.homeSetting.preset, .aquarium)

        // Once chosen, `ui.home` wins.
        m.chooseHomePreset(.board)
        XCTAssertEqual(m.homeSetting, HomeSetting(preset: .board))
        m.setHomeLayout(HomePreset.board.layout.moving(.usage, to: .side))
        XCTAssertTrue(m.homeSetting.changed)
        XCTAssertEqual(m.homeLayout.side, [.usage])
        m.chooseHomePreset(.board)                                            // Reset
        XCTAssertFalse(m.homeSetting.changed)
    }

    // MARK: The page

    /// The first waiting agent is open; one you open stays open while it waits; once answered, the one in its place opens.
    func testWaitingOpensFirstThenTheNext() {
        XCTAssertEqual(HomeWaiting.open(["a", "b", "c"], picked: nil, allClosed: false), "a")
        XCTAssertEqual(HomeWaiting.open(["a", "b", "c"], picked: "b", allClosed: false), "b")
        XCTAssertNil(HomeWaiting.open(["a", "b"], picked: nil, allClosed: true))          // you closed it
        XCTAssertEqual(HomeWaiting.open(["a", "c"], picked: "b", allClosed: false), "a")  // gone without a next: the first
        XCTAssertNil(HomeWaiting.open([], picked: nil, allClosed: false))
        // b answered: c (now in its place) opens; the last answered: the one before it
        XCTAssertEqual(HomeWaiting.next(after: "b", old: ["a", "b", "c"], new: ["a", "c"]), "c")
        XCTAssertEqual(HomeWaiting.next(after: "c", old: ["a", "b", "c"], new: ["a", "b"]), "b")
        XCTAssertNil(HomeWaiting.open([], picked: HomeWaiting.next(after: "a", old: ["a"], new: []), allClosed: false))   // the last answered: none
        XCTAssertEqual(HomeWaiting.next(after: "a", old: ["a", "b"], new: ["a", "b", "c"]), "a")   // still waiting: stays
        XCTAssertNil(HomeWaiting.next(after: nil, old: ["a"], new: ["b"]))                          // the first is open anyway
    }

    /// The page's width and the columns' split come from the preset (Agents: today's 980 pt page with a 300 pt side
    /// column; Workday: 1200 pt, halves) or your choice, never from what the columns hold.
    func testWidthAndSplitAreSettings() {
        XCTAssertEqual(HomePreset.agents.layout.width, .narrow)
        XCTAssertEqual(HomePreset.workday.layout.width, .wide)
        XCTAssertEqual(HomePreset.workday.layout.split, 0.5)
        let agentsColumns = HomePage.columnWidths(980 - 88, split: HomePreset.agents.layout.split)
        XCTAssertEqual(agentsColumns.side, 300)
        XCTAssertEqual(agentsColumns.main + agentsColumns.side + HomePage.columnGap, 892)
        // a wide section in the side column changes nothing
        XCTAssertEqual(HomePreset.agents.layout.moving(.issues, to: .side).width, .narrow)

        let h = HomeSetting.read(json(#"{"preset":"agents","width":"full","split":0.9}"#))
        XCTAssertEqual(h?.layout.width, .full)
        XCTAssertEqual(h?.layout.split, HomeLayout.splitRange.upperBound)       // clamped
        XCTAssertEqual(h?.layout.top, HomePreset.agents.layout.top)             // bands not stored: the preset's
        XCTAssertEqual(h?.changed, true)
        XCTAssertEqual(HomeSetting.read(h!.json), h)
        // bands stored before width/split existed: the preset's width and split
        let older = HomeSetting.read(json(#"{"preset":"workday","top":["today"],"main":[],"side":[]}"#))
        XCTAssertEqual(older?.layout.width, .wide)
        XCTAssertEqual(older?.layout.split, 0.5)
        XCTAssertEqual(HomeSetting.read(json(#"{"preset":"agents","width":"huge"}"#))?.layout.width, .narrow)
    }

    // MARK: Customize

    /// The eye takes a section off Home at once and keeps it faded in its place until Done; again, it comes back there.
    func testHideKeepsItsPlaceUntilDone() {
        let m = AppModel.shared
        let saved = m.settingValue(HomeSetting.key, scope: "global")
        defer { m.setSettingLocally(HomeSetting.key, saved, scope: "global"); HomeCustomizeState.shared.done() }
        let c = HomeCustomizeState.shared
        m.chooseHomePreset(.agents)
        c.start()
        c.toggleEye(.recent, model: m)
        XCTAssertEqual(m.homeLayout.side, [.usage])                                         // saved at once
        XCTAssertEqual(HomeCustomizeState.drawn(m.homeLayout, hidden: c.hidden).side, [.recent, .usage])   // drawn faded in place
        c.toggleEye(.recent, model: m)
        XCTAssertEqual(m.homeLayout, HomePreset.agents.layout)
        XCTAssertFalse(m.homeSetting.changed)

        // A drop counts in the drawn band: past the faded section, it lands after usage.
        c.toggleEye(.recent, model: m)
        c.drop(.waiting, at: .init(band: .side, index: 2), model: m)
        XCTAssertEqual(m.homeLayout.side, [.usage, .waiting])
        XCTAssertEqual(m.homeLayout.main, [])
        c.drop(.greeting, at: .init(band: .side, index: Int.max), model: m)
        XCTAssertEqual(m.homeLayout.side, [.usage, .waiting, .greeting])
        c.done()
        XCTAssertTrue(c.hidden.isEmpty)
        XCTAssertFalse(m.homeLayout.contains(.recent))                                     // gone after Done
    }

    func testStoredIndexSkipsFaded() {
        let stored = HomeLayout(side: [.usage])
        let drawn = HomeCustomizeState.drawn(stored, hidden: [.init(id: .recent, band: .side, index: 0)])
        XCTAssertEqual(drawn.side, [.recent, .usage])
        XCTAssertEqual(HomeCustomizeState.storedIndex(0, band: .side, drawn: drawn, stored: stored), 0)
        XCTAssertEqual(HomeCustomizeState.storedIndex(1, band: .side, drawn: drawn, stored: stored), 0)
        XCTAssertEqual(HomeCustomizeState.storedIndex(2, band: .side, drawn: drawn, stored: stored), 1)
        // a hidden one that came back another way (+ Add section) is not drawn twice
        XCTAssertEqual(HomeCustomizeState.drawn(HomeLayout(side: [.recent]), hidden: [.init(id: .recent, band: .side, index: 0)]).side, [.recent])
    }

    /// Home ⌄: the four presets, Customize, and Reset only when you changed the preset.
    func testMenuRows() {
        XCTAssertEqual(HomeMenuPanel.rows(HomeSetting(preset: .agents)),
                       [.preset(.agents), .preset(.workday), .preset(.board), .preset(.aquarium), .customize])
        XCTAssertEqual(HomeMenuPanel.rows(HomeSetting(preset: .board, custom: HomeLayout(top: [.board]))).last, .reset)
    }

    // MARK: The Home tab

    /// An older version's Agents and Workday tabs open as Home, one per project; other tabs read as before.
    func testOldTabsBecomeOneHomeTab() throws {
        let stored = #"""
        [{"id":"1","projectId":"p","workPath":"/w","kind":{"agents":{}}},
         {"id":"2","projectId":"p","workPath":"/w","kind":{"workday":{}}},
         {"id":"3","projectId":"q","workPath":"/v","kind":{"workday":{}}},
         {"id":"4","projectId":"p","workPath":"/w","kind":{"file":{"_0":"a.swift"}}},
         {"id":"5","projectId":"p","workPath":"/w","kind":{"aquarium":{}}}]
        """#
        let v = DocTab.oneHomePerProject(try JSONDecoder().decode([DocTab].self, from: Data(stored.utf8)))
        XCTAssertEqual(v.map(\.id), ["1", "3", "4", "5"])
        XCTAssertEqual(v.map(\.kind), [.home, .home, .file("a.swift"), .aquarium])
        // written back as Home, read again the same
        let again = try JSONDecoder().decode([DocTab].self, from: JSONEncoder().encode(v))
        XCTAssertEqual(again, v)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(v[0]), as: UTF8.self).contains("\"home\""))
    }

    // MARK: The sidebar's Home

    /// Off in every layout as it ships (the Terminal window looks as it did); turned on, it is the first row, also in a
    /// sidebar list stored before it existed.
    func testSidebarHomeIsOptInAndFirst() {
        for p in LayoutPreset.allCases { XCTAssertFalse(LayoutConfig.builtIn(p).has("home", in: .sidebar), p.rawValue) }
        let on = LayoutEdit.toggle("home", in: .sidebar, on: true, stored: LayoutEdit.choose(.terminal, in: nil))
        XCTAssertEqual(LayoutConfig.resolve(on).shown(.sidebar), ["home", "search", "inbox", "projects", "agents"])
        let old = json(#"{"layout":"terminal","custom":{"terminal":{"regions":{"sidebar":[{"id":"search","on":true},{"id":"agents","on":true},{"id":"inbox","on":true},{"id":"projects","on":true}]}}}}"#)
        XCTAssertEqual(LayoutConfig.resolve(old).items(.sidebar).map(\.id).first, "home")
        XCTAssertFalse(LayoutConfig.resolve(old).has("home", in: .sidebar))
        XCTAssertEqual(LayoutConfig.builtIn(.tasks).items(.sidebar).first?.id, "home")
        XCTAssertEqual(LayoutRegion.itemTitle("home", in: .sidebar), "Home")
    }

    // MARK: Keys

    /// ↑ ↓ go through the waiting agents (stopping at the ends); the number keys are 1…9, also on the keypad.
    func testWaitingKeys() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(HomeWaiting.step(ids, open: "a", by: 1), "b")
        XCTAssertEqual(HomeWaiting.step(ids, open: "c", by: 1), "c")
        XCTAssertEqual(HomeWaiting.step(ids, open: "a", by: -1), "a")
        XCTAssertEqual(HomeWaiting.step(ids, open: nil, by: 1), "a")      // all closed: the first
        XCTAssertEqual(HomeWaiting.step(ids, open: nil, by: -1), "c")     // or the last
        XCTAssertNil(HomeWaiting.step([], open: nil, by: 1))
        XCTAssertEqual(HomeWaiting.digit(18), 1)
        XCTAssertEqual(HomeWaiting.digit(20), 3)
        XCTAssertEqual(HomeWaiting.digit(85), 3)
        XCTAssertNil(HomeWaiting.digit(29))                               // 0 isn't an answer
    }

    /// Home's keys are free only while nobody types: not in a field, a terminal or a web page.
    func testHomeKeysLeaveFieldsAlone() {
        XCTAssertTrue(HomeKeyMonitor.free(nil))
        XCTAssertTrue(HomeKeyMonitor.free(NSView()))
        XCTAssertFalse(HomeKeyMonitor.free(NSTextView()))
        let inField = NSView(); let field = NSTextView(); field.addSubview(inField)
        XCTAssertFalse(HomeKeyMonitor.free(inField))
    }
}
