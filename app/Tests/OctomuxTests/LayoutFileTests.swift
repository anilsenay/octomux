import XCTest
@testable import Octomux

final class LayoutFileTests: XCTestCase {
    private let themes: Set<String> = ["ink", "grid"]
    private let commands: Set<String> = ["cmd.new-terminal-tab", "cmd.next-tab"]
    private func read(_ s: String) -> Result<(file: LayoutFile, notes: [String]), LayoutFile.Problem> {
        LayoutFile.read(Data(s.utf8), themes: themes, commands: commands)
    }
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    private let tree = #"{"row":[{"block":"agentRail"},{"column":[{"block":"breadcrumb"},{"stack":[{"block":"home","variant":"workday"},{"block":"workArea"}]},{"block":"statusBar"}]}]}"#

    func testReadsAFileAndIgnoresWhatItDoesntKnow() throws {
        let r = try read(#"{"schema":1,"name":" Review desk ","author":"Ada","base":"agents","tree":\#(tree),"settings":{"statusBar":false,"evil":"rm -rf"},"script":"open /","future":{"x":1}}"#).get()
        XCTAssertEqual(r.file.name, "Review desk")
        XCTAssertEqual(r.file.author, "Ada")
        XCTAssertEqual(r.file.base, .agents)
        XCTAssertEqual(r.file.tree?.variant(of: .home), "workday")
        XCTAssertEqual(r.file.settings, ["statusBar": .bool(false)])          // only a layout's own parts
        XCTAssertTrue(r.notes.isEmpty)
        // No tree: the base's window.
        XCTAssertNil(try read(#"{"schema":1,"name":"x","base":"terminal"}"#).get().file.tree)
    }

    func testRefusesWhatItCantUseWithTheReason() {
        XCTAssertEqual(read("not json").failure, .unreadable)
        XCTAssertEqual(read(#"{"name":"x","base":"agents"}"#).failure, .schema(0))
        XCTAssertEqual(read(#"{"schema":2,"name":"x","base":"agents"}"#).failure, .schema(2))
        XCTAssertEqual(read(#"{"schema":1,"name":"  ","base":"agents"}"#).failure, .noName)
        XCTAssertEqual(read(#"{"schema":1,"name":"x","base":"review"}"#).failure, .base("review"))
        XCTAssertEqual(read(#"{"schema":1,"name":"x","base":"agents","tree":{"row":[{"block":"agentRail"}]}}"#).failure, .tree(.noWorkArea))
        XCTAssertEqual(read(#"{"schema":1,"name":"x","base":"agents","tree":{"row":[{"block":"clippy"},{"block":"workArea"}]}}"#).failure, .tree(.unknownBlock("clippy")))
        XCTAssertEqual(LayoutFile.read(Data(count: LayoutFile.maxBytes + 1), themes: nil, commands: nil).failure, .tooBig)
        for p: LayoutFile.Problem in [.tooBig, .unreadable, .schema(0), .schema(3), .noName, .base(""), .base("x"), .tree(.noWorkArea)] {
            XCTAssertFalse(p.message.isEmpty)
        }
    }

    func testThemeAndKeysOnlyWhatThisMacHas() throws {
        let r = try read(#"{"schema":1,"name":"x","base":"agents","theme":{"id":"ink","mode":"neon"},"keys":{"cmd.next-tab":"cmd+shift+]","cmd.launch-rockets":"cmd+r","cmd.new-terminal-tab":"not a key ++"}}"#).get()
        XCTAssertEqual(r.file.theme, LayoutFile.Theme(id: "ink", mode: nil))  // an unknown mode is left out
        XCTAssertEqual(r.file.keys, ["cmd.next-tab": "cmd+shift+]"])
        XCTAssertEqual(r.notes.count, 1)
        let other = try read(#"{"schema":1,"name":"x","base":"agents","theme":{"id":"vaporwave"}}"#).get()
        XCTAssertNil(other.file.theme)
        XCTAssertEqual(other.notes.count, 1)
    }

    func testShortcutsInAFileAreModifiersAndOneKey() {
        for ok in ["cmd+t", "cmd+shift+]", "ctrl+cmd+left", "opt+cmd+plus"] { XCTAssertTrue(LayoutFile.isShortcut(ok), ok) }
        for bad in ["t", "cmd+", "not a key ++", "cmd+tt", "hyper+t", "cmd+ "] { XCTAssertFalse(LayoutFile.isShortcut(bad), bad) }
    }

    func testPreviewOnlyAPictureInTheFile() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        XCTAssertEqual(LayoutFile.image(fromDataURL: "data:image/png;base64," + png.base64EncodedString()), png)
        XCTAssertNil(LayoutFile.image(fromDataURL: "https://example.com/x.png"))                       // nothing remote
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/svg+xml;base64,PHN2Zz4="))               // no SVG
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Data("<html>".utf8).base64EncodedString()))
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Data(count: LayoutFile.maxPreviewBytes + 1).base64EncodedString()))
    }

    func testWritesWhatItReads() throws {
        var f = try read(#"{"schema":1,"name":"Review desk","author":"Ada","base":"agents","tree":\#(tree),"settings":{"chat":false}}"#).get().file
        f.theme = .init(id: "grid", mode: "light")
        f.keys = ["cmd.next-tab": "cmd+]"]
        f.preview = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
        let back = try LayoutFile.read(f.data(), themes: themes, commands: commands).get()
        XCTAssertEqual(back.file, f)
        XCTAssertTrue(back.notes.isEmpty)
        XCTAssertNil(try LayoutFile.read(f.data(withPreview: false), themes: themes, commands: commands).get().file.preview)
        XCTAssertEqual(f.fileName, "Review desk.octomux-layout.json")
        // The engine's own form ({"schema":1,"root":…}) reads too.
        let t = try XCTUnwrap(f.tree)
        if case .object(var o) = f.json() { o["tree"] = t.json; XCTAssertEqual(try LayoutFile.read(.object(o), themes: nil, commands: nil).get().file.tree, t) }
    }

    // MARK: Saved layouts

    func testSavedLayoutsResolveAsTheirBaseWithTheirSettingsThenYourChanges() throws {
        let f = try read(#"{"schema":1,"name":"Desk","base":"agents","tree":\#(tree),"settings":{"statusBar":false}}"#).get().file
        let saved = SavedLayouts.adding(f, id: "u1", to: nil)
        XCTAssertEqual(SavedLayouts.parse(saved)["u1"], f)
        var stored = LayoutEdit.chooseUser("u1", base: .agents, in: nil)
        var c = LayoutConfig.resolve(stored, saved: SavedLayouts.parse(saved))
        XCTAssertEqual(c.userId, "u1")
        XCTAssertEqual(c.title, "Desk")
        XCTAssertFalse(c.statusBar)                                           // the file's
        XCTAssertTrue(c.chat)                                                 // the base's
        // Your change goes to the saved layout, not to its base.
        stored = LayoutEdit.flag("chat", false, stored: stored)
        c = LayoutConfig.resolve(stored, saved: SavedLayouts.parse(saved))
        XCTAssertFalse(c.chat)
        XCTAssertTrue(LayoutConfig.resolve(LayoutEdit.choose(.agents, in: stored)).chat)
        XCTAssertTrue(LayoutEdit.isCustomized(stored))
        // Gone (deleted, or not on this Mac): the base.
        XCTAssertNil(LayoutConfig.resolve(stored).userId)
        XCTAssertEqual(LayoutConfig.resolve(stored).preset, .agents)
        let forgot = try XCTUnwrap(LayoutEdit.forget(user: "u1", in: stored))
        XCTAssertNil(LayoutEdit.object(forgot)["user"])
        XCTAssertNil(LayoutEdit.object(LayoutEdit.object(forgot)["custom"])["user:u1"])
    }

    func testSavedLayoutsWindow() throws {
        let own = try read(#"{"schema":1,"name":"A","base":"terminal","tree":\#(tree)}"#).get().file
        let classic = try read(#"{"schema":1,"name":"B","base":"terminal"}"#).get().file
        let engineBase = try read(#"{"schema":1,"name":"C","base":"tasks"}"#).get().file
        var saved = SavedLayouts.adding(own, id: "a", to: nil)
        saved = SavedLayouts.adding(classic, id: "b", to: saved)
        saved = SavedLayouts.adding(engineBase, id: "c", to: saved)
        LayoutCache.reset()
        XCTAssertEqual(LayoutCache.get(LayoutEdit.chooseUser("a", base: .terminal, in: nil), saved: saved).tree, own.tree)   // its own window
        XCTAssertNil(LayoutCache.get(LayoutEdit.chooseUser("b", base: .terminal, in: nil), saved: saved).tree)              // Terminal's: classic
        XCTAssertEqual(LayoutCache.get(LayoutEdit.chooseUser("c", base: .tasks, in: nil), saved: saved).tree, ShellTree.builtIn("tasks"))
        XCTAssertEqual(LayoutCache.get(nil, saved: saved).saved.count, 3)
    }

    func testNamesStayApartAndRemovingLeavesNothing() throws {
        let f = try read(#"{"schema":1,"name":"Desk","base":"agents"}"#).get().file
        let d = SavedLayouts.parse(SavedLayouts.adding(f, id: "u1", to: nil))
        XCTAssertEqual(SavedLayouts.freeName("Desk", in: d), "Desk 2")
        XCTAssertEqual(SavedLayouts.freeName("Other", in: d), "Other")
        XCTAssertNil(SavedLayouts.removing("u1", from: SavedLayouts.adding(f, id: "u1", to: nil)))
        XCTAssertNotEqual(SavedLayouts.newId(), SavedLayouts.newId())
        XCTAssertTrue(SavedLayouts.parse(.object(["bad": .string("x")])).isEmpty)   // an entry that doesn't read is left out
    }

    func testConfigSettingsRoundTrip() {
        var c = LayoutConfig.builtIn(.editor)
        c.statusBar = false
        var back = LayoutConfig.builtIn(.editor)
        LayoutConfig.apply(c.settings, to: &back)
        XCTAssertEqual(back, c)
    }
}
