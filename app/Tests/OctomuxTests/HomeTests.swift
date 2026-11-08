import XCTest
@testable import Octomux

/// Home's sections, presets and the `ui.home` setting.
final class HomeTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    /// The presets are today's Homes, section for section.
    func testPresetsAreTodaysHomes() {
        XCTAssertEqual(HomePreset.agents.layout, HomeLayout(top: [.greeting, .composer], main: [.waiting], side: [.recent, .usage]))
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
        XCTAssertEqual(h?.layout, HomeLayout(top: [.greeting], main: [.waiting, .usage], side: [.recent]))
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
}
