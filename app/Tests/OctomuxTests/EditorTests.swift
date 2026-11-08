import XCTest
@testable import Octomux

final class EditorTests: XCTestCase {
    func testChangeMarksFromHunks() {
        let diff = """
        diff --git a/f b/f
        @@ -0,0 +1,2 @@
        +new
        +new
        @@ -5,2 +7,3 @@
        -a
        -b
        +x
        +y
        +z
        @@ -10 +12 @@
        -c
        +d
        @@ -20,3 +24,0 @@
        """
        let m = ChangeMarks.parse(diff)
        XCTAssertEqual(m.added, [1, 2, 9])
        XCTAssertEqual(m.modified, [7, 8, 12])
        XCTAssertEqual(m.deleted, [24])
        XCTAssertTrue(ChangeMarks.parse("").isEmpty)
    }

    func testChangeMarksReadsGitAndUntrackedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octomux-marks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func git(_ a: [String]) { _ = SinceLooked.run(["-c", "user.email=t@t", "-c", "user.name=t"] + a, in: dir) }
        git(["init", "-q"])
        try "a\nb\nc\n".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-qm", "i"])
        try "a\nB\nc\nd\n".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        try "1\n2\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        let m = ChangeMarks.read(dir, "f.txt")
        XCTAssertEqual(m.modified, [2]); XCTAssertEqual(m.added, [4])
        XCTAssertEqual(ChangeMarks.read(dir, "new.txt").added, [1, 2])
    }

    private func tool(_ name: String, _ detail: String) -> ChatItem { ChatItem(id: UUID().uuidString, kind: .tool, text: "", tool: name, detail: detail) }

    func testTouchedFilesOfTheCurrentTurn() {
        let items = [
            ChatItem(id: "u0", kind: .user, text: "old"), tool("Edit", "/w/old.swift"),
            ChatItem(id: "u1", kind: .user, text: "now"),
            tool("Read", "/w/a.swift"), tool("Grep", "TODO"), tool("Read", "/w/b.swift"), tool("Edit", "/w/b.swift"),
            tool("Write", "/w/c.swift"), tool("Read", "/elsewhere/x.md"),
        ]
        let t = TouchedFile.from(items, workPath: "/w")
        XCTAssertEqual(t.map(\.path), ["b.swift", "c.swift", "a.swift", "/elsewhere/x.md"])
        XCTAssertEqual(t.map(\.how), [.modified, .modified, .read, .read])
    }

    func testNoteText() {
        XCTAssertEqual(AppModel.noteText(" Use a guard here \n", path: "a/b.swift", from: 3, to: 4, excerpt: "if x {\n}"),
                       "Use a guard here\n\na/b.swift:3-4\n```\nif x {\n}\n```")
        XCTAssertTrue(AppModel.noteText("n", path: "r.md", from: 1, to: 1, excerpt: "```x```").contains("r.md:1\n~~~"))
    }

    func testTheAgentColumnDoesntRepeatTheWorkArea() {
        XCTAssertTrue(SideAgentColumn.showsTwice("a", focused: "a", docInFront: false, picked: nil))
        XCTAssertFalse(SideAgentColumn.showsTwice("a", focused: "a", docInFront: true, picked: nil))    // a file in front: beside it
        XCTAssertFalse(SideAgentColumn.showsTwice("a", focused: "b", docInFront: false, picked: nil))
        XCTAssertFalse(SideAgentColumn.showsTwice("a", focused: "a", docInFront: false, picked: "a"))   // you pinned it here
        XCTAssertEqual(AppModel.sideAgentWidths.lowerBound, 320)
    }

    func testTerminalKeepsTheEditorsPartsOff() {
        let t = LayoutConfig.builtIn(.terminal)
        XCTAssertFalse(t.sideChat)
        XCTAssertEqual(t.shown(.views), [])
        let v = LayoutEdit.flag("sideChat", true, stored: LayoutEdit.choose(.terminal, in: nil))
        XCTAssertTrue(LayoutConfig.resolve(v).sideChat)   // any layout can have the agent beside it
    }
}
