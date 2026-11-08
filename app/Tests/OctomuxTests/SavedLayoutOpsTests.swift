import XCTest
@testable import Octomux

/// The saved layouts' operations on the model (settings stay in the test's model: no daemon in unit tests).
final class SavedLayoutOpsTests: XCTestCase {
    private var saved: (JSONValue?, JSONValue?) = (nil, nil)
    override func setUp() {
        let m = AppModel.shared
        XCTAssertTrue(DaemonClient.isolated)
        saved = (m.layoutStored, m.savedLayoutsStored)
        m.setSettingLocally(AppModel.layoutKey, nil, scope: "global")
        m.setSettingLocally(SavedLayouts.key, nil, scope: "global")
    }
    override func tearDown() {
        let m = AppModel.shared
        m.setSettingLocally(AppModel.layoutKey, saved.0, scope: "global")
        m.setSettingLocally(SavedLayouts.key, saved.1, scope: "global")
        LayoutCache.reset()
    }

    func testSaveDuplicateExportDelete() throws {
        let m = AppModel.shared
        m.chooseLayout(.agents)
        m.chooseHome(.workday)
        let id = m.saveLayoutAsNew(name: "Desk")
        XCTAssertEqual(m.savedLayouts[id]?.name, "Desk")
        XCTAssertEqual(m.savedLayouts[id]?.base, .agents)
        XCTAssertEqual(m.savedLayouts[id]?.tree, ShellTree.builtIn("agents"))    // the window as it was
        XCTAssertEqual(m.savedLayouts[id]?.settings["home"], .string("workday"))  // and its Home
        XCTAssertEqual(m.layout.userId, id)                                      // in use
        XCTAssertEqual(m.shellHomeVariant, "workday")

        let copy = try XCTUnwrap(m.duplicateSavedLayout(id))
        XCTAssertEqual(m.savedLayouts[copy]?.name, "Desk 2")
        XCTAssertEqual(SavedLayouts.sorted(m.savedLayouts).map(\.file.name), ["Desk", "Desk 2"])
        XCTAssertNil(m.duplicateSavedLayout("u99999999"))

        let out = m.layoutFileForExport(copy, includeTheme: false, includeKeys: false)
        XCTAssertEqual(out.name, "Desk 2")
        XCTAssertNil(out.theme)
        XCTAssertTrue(out.keys.isEmpty)
        XCTAssertEqual(try LayoutFile.read(out.data(), themes: nil, commands: nil).get().file.tree, out.tree)

        m.deleteSavedLayout(id)                                                  // the one in use: back to its base
        XCTAssertNil(m.savedLayouts[id])
        XCTAssertNil(m.layout.userId)
        XCTAssertEqual(m.layout.preset, .agents)
        XCTAssertEqual(m.savedLayouts.count, 1)
    }

    func testImportedLayoutAddsUnderAFreeName() throws {
        let m = AppModel.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".octomux-layout.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"schema":1,"name":"Focus","base":"minimal","keys":{"cmd.x":"cmd+shift+x"}}"#.utf8).write(to: url)
        let r = try LayoutImport.read(url, model: m).get()
        let a = m.addLayout(r.file, use: false)
        let b = m.addLayout(r.file, use: true)
        XCTAssertEqual(SavedLayouts.sorted(m.savedLayouts).map(\.file.name), ["Focus", "Focus 2"])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(m.layout.userId, b)
        XCTAssertEqual(m.layout.preset, .terminal)                     // Minimal is gone: a file made with it opens on Terminal
        // Too big on disk: refused before it is read.
        try Data(count: LayoutFile.maxBytes + 1).write(to: url)
        XCTAssertEqual(LayoutImport.read(url, model: m).failure, .tooBig)
    }

    func testFileNamesHaveNoPathInThem() throws {
        var f = LayoutFile(name: "a/b:c\\d", base: .agents)
        XCTAssertEqual(f.fileName, "a-b-c-d.octomux-layout.json")
        f.name = "Desk"
        XCTAssertEqual(f.fileName, "Desk.octomux-layout.json")
    }
}
