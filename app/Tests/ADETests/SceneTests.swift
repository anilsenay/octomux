import XCTest
@testable import ADE

final class SceneResolveTests: XCTestCase {
    private func setting(_ scope: String, _ value: String) -> Setting {
        Setting(scope: scope, key: "appearance.scene", value: .string(value))
    }

    func testWorkspaceOverridesGlobal() {
        let s = [setting("global", "kites"), setting("workspace:w1", "aurora")]
        XCTAssertEqual(Scenes.resolve(workspace: "w1", settings: s), "aurora")
        XCTAssertEqual(Scenes.resolve(workspace: "w2", settings: s), "kites")
        XCTAssertEqual(Scenes.resolve(workspace: nil, settings: s), "kites")
    }

    func testNoneTurnsTheSceneOff() {
        XCTAssertNil(Scenes.resolve(workspace: "w1", settings: [setting("global", "kites"), setting("workspace:w1", "none")]))
        XCTAssertNil(Scenes.resolve(workspace: "w1", settings: [setting("global", "none")]))
        XCTAssertNil(Scenes.resolve(workspace: "w1", settings: []))
    }

    func testOtherKeysAreIgnored() {
        let s = [Setting(scope: "workspace:w1", key: "appearance.theme", value: .string("grid")), setting("global", "rain")]
        XCTAssertEqual(Scenes.resolve(workspace: "w1", settings: s), "rain")
    }

    func testBuiltInIdsAreUniqueAndOldIdsStillResolve() {
        let ids = Scenes.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        // Settings saved with the first versions keep working.
        XCTAssertEqual(Scenes.scene("night-sky")?.name, "Nightfall")
        XCTAssertEqual(Scenes.scene("fireflies")?.name, "Glade")
        XCTAssertEqual(Scenes.scene("sky")?.name, "Daydream")
        XCTAssertEqual(Scenes.scene("reef")?.id, "reef-v2")
    }

    func testEveryWorkspaceColorHasMatchingScenes() {
        for hex in Palette.colors { XCTAssertFalse(Scenes.matching(hex).isEmpty, hex) }
        XCTAssertTrue(Scenes.matching(nil).isEmpty)
    }

    func testEveryKindHasDarkAndLightOrIsDeliberatelyOneSided() {
        let dark = Set(Scenes.builtIn.filter(\.dark).map(\.name)), light = Set(Scenes.builtIn.filter { !$0.dark }.map(\.name))
        XCTAssertGreaterThanOrEqual(dark.count, 8)
        XCTAssertGreaterThanOrEqual(light.count, 6)
    }
}

final class AmbientMoodTests: XCTestCase {
    private func session(_ id: String, project: String = "p1", kind: String = "agent", state: String = "running", activity: String) -> Session {
        let json = """
        {"id":"\(id)","project_id":"\(project)","kind":"\(kind)","title":"t","custom_title":"","cwd":"/","state":"\(state)",
         "activity":"\(activity)","unread":false,"created_at":0,"last_activity_at":0,"placement":"tab"}
        """
        return try! JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testMostUrgentWins() {
        let p: Set<String> = ["p1"]
        XCTAssertEqual(AmbientMood.of([], projectIds: p), .calm)
        XCTAssertEqual(AmbientMood.of([session("a", activity: "idle")], projectIds: p), .calm)
        XCTAssertEqual(AmbientMood.of([session("a", activity: "working")], projectIds: p), .busy)
        XCTAssertEqual(AmbientMood.of([session("a", activity: "working"), session("b", activity: "needs_input")], projectIds: p), .attention)
        XCTAssertEqual(AmbientMood.of([session("a", activity: "needs_input"), session("b", activity: "error")], projectIds: p), .error)
    }

    func testOnlyRunningAgentsOfTheWorkspaceCount() {
        let p: Set<String> = ["p1"]
        XCTAssertEqual(AmbientMood.of([session("a", project: "p2", activity: "needs_input")], projectIds: p), .calm)
        XCTAssertEqual(AmbientMood.of([session("a", kind: "terminal", activity: "working")], projectIds: p), .calm)
        XCTAssertEqual(AmbientMood.of([session("a", state: "exited", activity: "error")], projectIds: p), .calm)
    }

    func testGlowColors() {
        XCTAssertNil(AmbientMood.calm.glow)
        XCTAssertNil(AmbientMood.busy.glow)
        XCTAssertNotNil(AmbientMood.attention.glow)
        XCTAssertNotNil(AmbientMood.error.glow)
    }
}

final class AmbientClockTests: XCTestCase {
    func testFrameRates() {
        XCTAssertEqual(AmbientClock.fps(for: "active"), 24)
        XCTAssertEqual(AmbientClock.fps(for: "background"), 6)
        for r in ["hidden", "screen off", "low power", "reduce motion", "no window"] { XCTAssertEqual(AmbientClock.fps(for: r), 0, r) }
    }
}

final class UserSceneTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/scenes/my-lake.json")

    private func parse(_ json: String) throws -> AmbientScene { try UserScenes.parse(Data(json.utf8), file: file) }

    func testMinimalSceneUsesFileNameAsId() throws {
        let s = try parse(#"{"name": "Lake"}"#)
        XCTAssertEqual(s.id, "user.my-lake")
        XCTAssertEqual(s.name, "Lake")
        XCTAssertEqual(s.kind, .custom)
        XCTAssertTrue(s.dark)
        XCTAssertNil(s.base)
    }

    func testBaseSceneSuppliesAppearanceAndAnimation() throws {
        let s = try parse(#"{"id": "wet", "name": "Wet", "base": "rain"}"#)
        XCTAssertEqual(s.id, "user.wet")
        XCTAssertEqual(s.base, .rain)
        XCTAssertTrue(s.dark)
        let light = try parse(#"{"name": "Pink", "base": "sakura"}"#)
        XCTAssertFalse(light.dark)
    }

    func testColorsOverride() throws {
        let s = try parse(##"{"name": "X", "dark": false, "colors": {"accent": "#FF0000"}}"##)
        let a = s.colors.accent.usingColorSpace(.sRGB)!
        XCTAssertEqual(a.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(a.greenComponent, 0, accuracy: 0.01)
        XCTAssertFalse(s.dark)
    }

    func testTemplateParses() throws {
        // The example ADE writes for "New from Template" must always load.
        let s = try parse(UserScenes.template(name: "Lanterns", id: "lanterns"))
        XCTAssertEqual(s.id, "user.lanterns")
        XCTAssertEqual(s.spec?.sprites?.isEmpty, false)
        XCTAssertEqual(s.spec?.particles?.first?.direction, "up")
        XCTAssertNotNil(s.spec?.twinkle)
    }

    func testErrorsAreReadable() {
        func message(_ json: String) -> String {
            do { _ = try parse(json); return "parsed" } catch let e as DecodingError { return UserScenes.describe(e) } catch { return "\(error)" }
        }
        XCTAssertEqual(message(#"{"dark": true}"#), "missing “name”")
        XCTAssertEqual(message(#"{"name": "A", "sprites": [{"colors": {}}]}"#), "missing “rows” in sprites.0")
        XCTAssertEqual(message(#"{"name": 3}"#), "wrong type at name")
        XCTAssertEqual(message("{name"), "not valid JSON")
    }
}

final class TerminalSceneModeTests: XCTestCase {
    private func s(_ scope: String, _ key: String, _ v: JSONValue) -> Setting { Setting(scope: scope, key: key, value: v) }

    func testWorkspaceOverridesGlobalAndOldBoolStillWorks() {
        let k = "appearance.scene_terminals"
        XCTAssertEqual(TerminalSceneMode.resolve(workspace: "w", settings: []), .off)
        XCTAssertEqual(TerminalSceneMode.resolve(workspace: "w", settings: [s("global", k, .bool(true))]), .live)
        XCTAssertEqual(TerminalSceneMode.resolve(workspace: "w", settings: [s("global", k, .string("still")), s("workspace:w", k, .string("off"))]), .off)
        XCTAssertEqual(TerminalSceneMode.resolve(workspace: "x", settings: [s("global", k, .string("still")), s("workspace:w", k, .string("off"))]), .still)
        XCTAssertEqual(TerminalSceneMode.resolve(workspace: nil, settings: [s("global", k, .string("bogus"))]), .off)
    }

    func testOpacityIsClamped() {
        let k = "appearance.scene_terminal_opacity"
        XCTAssertEqual(TerminalSceneMode.resolveOpacity(workspace: nil, settings: []), TerminalSceneMode.defaultOpacity)
        XCTAssertEqual(TerminalSceneMode.resolveOpacity(workspace: "w", settings: [s("workspace:w", k, .number(0.6))]), 0.6)
        XCTAssertEqual(TerminalSceneMode.resolveOpacity(workspace: nil, settings: [s("global", k, .number(0.1))]), 0.5)
        XCTAssertEqual(TerminalSceneMode.resolveOpacity(workspace: nil, settings: [s("global", k, .number(2))]), 0.95)
    }
}

final class SceneFormatTests: XCTestCase {
    func testAdesceneExtensionAndFormat() throws {
        let f = URL(fileURLWithPath: "/tmp/scenes/lake.adescene.json")
        let s = try UserScenes.parse(Data(#"{"format": "ade-scene/1", "name": "Lake"}"#.utf8), file: f)
        XCTAssertEqual(s.id, "user.lake")
        XCTAssertThrowsError(try UserScenes.parse(Data(#"{"format": "ade-scene/9", "name": "Lake"}"#.utf8), file: f))
    }

    func testGhosttyThemeParsing() {
        let t = TerminalThemes.parse("""
        # comment
        palette = 0=#45475a
        palette = 15 = #a6adc8
        palette = 99=#ffffff
        background = #1e1e2e
        foreground = cdd6f4
        cursor-color = #f5e0dc
        selection-background = nonsense
        """)
        XCTAssertEqual(t.palette[0], "#45475a")
        XCTAssertEqual(t.palette[15], "#a6adc8")
        XCTAssertNil(t.palette[99])
        XCTAssertEqual(t.background, "#1e1e2e")
        XCTAssertEqual(t.foreground, "#cdd6f4")
        XCTAssertEqual(t.cursor, "#f5e0dc")
        XCTAssertNil(t.selection)
    }

    func testTerminalSchemeAppliesAndUnknownOneFails() throws {
        let f = URL(fileURLWithPath: "/tmp/scenes/x.json")
        XCTAssertThrowsError(try UserScenes.parse(Data(#"{"name": "X", "terminal": "No Such Theme 123"}"#.utf8), file: f))
        guard TerminalThemes.load("Catppuccin Mocha", relativeTo: f) != nil else { throw XCTSkip("no Ghostty themes on this machine") }
        let s = try UserScenes.parse(Data(#"{"name": "X", "terminal": "Catppuccin Mocha"}"#.utf8), file: f)
        XCTAssertEqual(s.colors.ansi[1].lowercased(), "#f38ba8")
        let bg = s.colors.surface.usingColorSpace(.sRGB)!
        XCTAssertEqual(Int(round(bg.blueComponent * 255)), 0x2e)
    }

    func testSchemaIsValidJSONAndTemplateParses() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(UserScenes.schema.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["title"] as? String, "ADE scene")
        let props = obj?["properties"] as? [String: Any]
        // Every field the decoder knows is described in the schema.
        for k in ["format", "id", "name", "dark", "base", "gradient", "colors", "terminal", "twinkle", "sprites", "particles"] { XCTAssertNotNil(props?[k], k) }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(UserScenes.template(name: "L", id: "l").utf8)))
    }
}
