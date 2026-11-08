import XCTest
import ImageIO
import UniformTypeIdentifiers
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
        XCTAssertEqual(try read(#"{"schema":1,"name":"x","base":"editor"}"#).get().file.base, .terminal)   // a layout this version dropped
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

    func testAFileCantTakeAwayKeysOrTakeTheMacsOwn() throws {
        let cmds: Set<String> = ["cmd.new-terminal-tab", "cmd.next-tab", "cmd.quit", "cmd.close-tab", "cmd.settings"]
        let r = try LayoutFile.read(Data(#"{"schema":1,"name":"x","base":"agents","keys":{"cmd.next-tab":"","cmd.quit":"cmd+q","cmd.close-tab":"CMD+W","cmd.settings":"cmd+,","cmd.new-terminal-tab":"cmd+shift+n"}}"#.utf8), themes: nil, commands: cmds).get()
        XCTAssertEqual(r.file.keys, ["cmd.new-terminal-tab": "cmd+shift+n"])
        XCTAssertEqual(r.notes.count, 1)
        XCTAssertTrue(r.notes[0].hasPrefix("4 shortcuts"))
        for k in ["cmd+q", "cmd+w", "cmd+h", "opt+cmd+h", "cmd+m", "cmd+,", "cmd+`"] { XCTAssertTrue(LayoutFile.isReserved(k), k) }
        XCTAssertFalse(LayoutFile.isReserved("cmd+shift+w"))
    }

    func testAFilesShortcutOnAKeyInUseIsLeftOut() {
        let current: [String: Shortcut] = ["cmd.new-terminal-tab": Shortcut(string: "cmd+t")!, "cmd.next-tab": Shortcut(string: "cmd+shift+]")!,
                                           "cmd.split-right": Shortcut(string: "cmd+d")!]
        // ⌘T is New Terminal Tab's: refused. ⌘D moves to next-tab while split-right keeps it: refused. ⌘⇧] is freed by
        // next-tab moving, so another command may have it.
        let k = LayoutFile.usableKeys(["cmd.next-tab": "cmd+d", "cmd.zoom": "cmd+t", "cmd.focus": "cmd+shift+]", "cmd.free": "cmd+shift+y"], current: current)
        XCTAssertEqual(k.use, ["cmd.focus": "cmd+shift+]", "cmd.free": "cmd+shift+y"])
        XCTAssertEqual(k.clash, ["cmd.next-tab": "cmd.split-right", "cmd.zoom": "cmd.new-terminal-tab"])
        // Two of the file's commands on one key: neither.
        let both = LayoutFile.usableKeys(["cmd.a": "cmd+shift+k", "cmd.b": "cmd+shift+k"], current: [:])
        XCTAssertTrue(both.use.isEmpty)
        XCTAssertEqual(both.clash, ["cmd.a": "cmd.b", "cmd.b": "cmd.a"])
        // Moving a command to its own key again is no clash.
        XCTAssertEqual(LayoutFile.usableKeys(["cmd.new-terminal-tab": "cmd+t"], current: current).use, ["cmd.new-terminal-tab": "cmd+t"])
    }

    func testShortcutsInAFileAreModifiersAndOneKey() {
        for ok in ["cmd+t", "cmd+shift+]", "ctrl+cmd+left", "opt+cmd+plus"] { XCTAssertTrue(LayoutFile.isShortcut(ok), ok) }
        for bad in ["t", "cmd+", "not a key ++", "cmd+tt", "hyper+t", "cmd+ "] { XCTAssertFalse(LayoutFile.isShortcut(bad), bad) }
    }

    /// A real PNG of that many pixels (blank: it packs into a few bytes whatever its size).
    static func png(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testPreviewOnlyAPictureInTheFile() {
        let png = Self.png(40, 30)
        XCTAssertEqual(LayoutFile.image(fromDataURL: "data:image/png;base64," + png.base64EncodedString()), png)
        XCTAssertNil(LayoutFile.image(fromDataURL: "https://example.com/x.png"))                       // nothing remote
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/svg+xml;base64,PHN2Zz4="))               // no SVG
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Data("<html>".utf8).base64EncodedString()))
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Data(count: LayoutFile.maxPreviewBytes + 1).base64EncodedString()))
        // Small files that would unpack into a huge picture, and bytes that only start like a PNG.
        let bomb = Self.png(LayoutFile.maxPreviewSide + 1, 8)
        XCTAssertLessThan(bomb.count, LayoutFile.maxPreviewBytes)
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + bomb.base64EncodedString()))
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Self.png(4096, 4096).base64EncodedString()))   // 16.7 MP
        XCTAssertNotNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Self.png(2880, 1800).base64EncodedString()))  // a Retina window
        XCTAssertNil(LayoutFile.image(fromDataURL: "data:image/png;base64," + Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()))
    }

    func testWritesWhatItReads() throws {
        var f = try read(#"{"schema":1,"name":"Review desk","author":"Ada","base":"agents","tree":\#(tree),"settings":{"chat":false}}"#).get().file
        f.theme = .init(id: "grid", mode: "light")
        f.keys = ["cmd.next-tab": "cmd+]"]
        f.preview = Self.png(16, 10)
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
        let saved = SavedLayouts.adding(f, id: "u0000000a", to: nil)
        XCTAssertEqual(SavedLayouts.parse(saved)["u0000000a"], f)
        var stored = LayoutEdit.chooseUser("u0000000a", base: .agents, in: nil)
        var c = LayoutConfig.resolve(stored, saved: SavedLayouts.parse(saved))
        XCTAssertEqual(c.userId, "u0000000a")
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
        let forgot = try XCTUnwrap(LayoutEdit.forget(user: "u0000000a", in: stored))
        XCTAssertNil(LayoutEdit.object(forgot)["user"])
        XCTAssertNil(LayoutEdit.object(LayoutEdit.object(forgot)["custom"])["user:u0000000a"])
    }

    func testASavedLayoutThatIsGoneTakesNoChanges() throws {
        let f = try read(#"{"schema":1,"name":"Desk","base":"agents","tree":\#(tree)}"#).get().file
        let saved = SavedLayouts.adding(f, id: "u0000000a", to: nil)
        let stored = LayoutEdit.chooseUser("u0000000a", base: .agents, in: nil)
        XCTAssertEqual(LayoutEdit.withoutMissingUser(stored, saved: saved), stored)
        let gone = try XCTUnwrap(LayoutEdit.withoutMissingUser(stored, saved: nil))
        XCTAssertNil(LayoutEdit.object(gone)["user"])
        XCTAssertEqual(LayoutEdit.activeKey(LayoutEdit.object(gone)), "agents")          // edits go to the base
        XCTAssertEqual(LayoutCache.get(gone, saved: nil).tree, ShellTree.builtIn("agents"))
        LayoutCache.reset()
    }

    func testSavedLayoutsWindow() throws {
        let own = try read(#"{"schema":1,"name":"A","base":"terminal","tree":\#(tree)}"#).get().file
        let classic = try read(#"{"schema":1,"name":"B","base":"terminal"}"#).get().file
        let engineBase = try read(#"{"schema":1,"name":"C","base":"tasks"}"#).get().file
        var saved = SavedLayouts.adding(own, id: "u000000aa", to: nil)
        saved = SavedLayouts.adding(classic, id: "u000000bb", to: saved)
        saved = SavedLayouts.adding(engineBase, id: "u000000cc", to: saved)
        LayoutCache.reset()
        XCTAssertEqual(LayoutCache.get(LayoutEdit.chooseUser("u000000aa", base: .terminal, in: nil), saved: saved).tree, own.tree)   // its own window
        XCTAssertEqual(LayoutCache.get(LayoutEdit.chooseUser("u000000bb", base: .terminal, in: nil), saved: saved).tree, ShellTree.builtIn("terminal"))   // its base's
        XCTAssertEqual(LayoutCache.get(LayoutEdit.chooseUser("u000000cc", base: .tasks, in: nil), saved: saved).tree, ShellTree.builtIn("tasks"))
        XCTAssertEqual(LayoutCache.get(nil, saved: saved).saved.count, 3)
    }

    func testNamesStayApartAndRemovingLeavesNothing() throws {
        let f = try read(#"{"schema":1,"name":"Desk","base":"agents"}"#).get().file
        let d = SavedLayouts.parse(SavedLayouts.adding(f, id: "u0000000a", to: nil))
        XCTAssertEqual(SavedLayouts.freeName("Desk", in: d), "Desk 2")
        XCTAssertEqual(SavedLayouts.freeName("Other", in: d), "Other")
        XCTAssertNil(SavedLayouts.removing("u0000000a", from: SavedLayouts.adding(f, id: "u0000000a", to: nil)))
        XCTAssertNotEqual(SavedLayouts.newId(), SavedLayouts.newId())
        XCTAssertTrue(SavedLayouts.parse(.object(["bad": .string("x")])).isEmpty)   // an entry that doesn't read is left out
    }

    func testIdsNeverNameAPathOutOfThePicturesFolder() throws {
        let f = try read(#"{"schema":1,"name":"Desk","base":"agents"}"#).get().file
        for bad in ["../../evil", "u1234567/", "U0000000A", "u0000000g", "u000000000", "", "/tmp/x"] {
            XCTAssertFalse(SavedLayouts.isId(bad), bad)
            XCTAssertNil(SavedLayouts.previewURL(bad), bad)
            XCTAssertTrue(SavedLayouts.parse(SavedLayouts.adding(f, id: bad, to: nil)).isEmpty, bad)   // a hand-edited entry is left out
        }
        let id = SavedLayouts.newId()
        XCTAssertTrue(SavedLayouts.isId(id))
        XCTAssertEqual(SavedLayouts.previewURL(id)?.deletingLastPathComponent().lastPathComponent, "layout-previews")
        XCTAssertNotEqual(SavedLayouts.newId(unusedIn: [id: f]), id)
    }

    func testConfigSettingsRoundTrip() {
        var c = LayoutConfig.builtIn(.agents)
        c.statusBar = false
        var back = LayoutConfig.builtIn(.agents)
        LayoutConfig.apply(c.settings, to: &back)
        XCTAssertEqual(back, c)
    }
}
