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

    func testBuiltInIdsAreUniqueAndLegacyIdsStillResolve() {
        let ids = Scenes.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        // Settings saved with the first versions keep working until they are mapped to the new scenes.
        for id in ["night-sky", "reef", "fireflies", "sky"] { XCTAssertEqual(Scenes.scene(id)?.legacy, true, id) }
        for id in ["aurora", "reef-v2", "circuit", "kites"] { XCTAssertEqual(Scenes.scene(id)?.legacy, false, id) }
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
