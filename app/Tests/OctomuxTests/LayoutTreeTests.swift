import XCTest
@testable import Octomux

final class LayoutTreeTests: XCTestCase {
    private func tree(_ s: String) -> Result<ShellTree, ShellTree.Problem> { ShellTree.parse(Data(s.utf8)) }
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    func testBuiltInAgentsTreeReadsAndKeepsTheRules() throws {
        let t = try XCTUnwrap(ShellTree.builtIn("agents"))
        XCTAssertNil(t.problem())
        XCTAssertEqual(Set(t.root.blocks), [.agentRail, .breadcrumb, .home, .workArea, .sidePanel, .statusBar])
        XCTAssertNil(ShellTree.builtIn("terminal"))        // no file: the classic window
    }

    func testEveryBuiltInFileReads() throws {
        let files = try FileManager.default.contentsOfDirectory(at: ShellTree.dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            switch ShellTree.parse(try Data(contentsOf: f)) {
            case .success: break
            case .failure(let p): XCTFail("\(f.lastPathComponent): \(p)")
            }
        }
    }

    func testBrokenTreesAreRejectedWithTheReason() {
        let ok = #"{"block":"workArea"}"#
        XCTAssertEqual(try? tree(#"{"schema":1,"root":\#(ok)}"#).get().root, .block(.workArea))
        XCTAssertEqual(tree("nope").failure, .unreadable)
        XCTAssertEqual(tree(#"{"schema":2,"root":\#(ok)}"#).failure, .schema(2))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"workArea"},{"block":"clippy"}]}}"#).failure, .unknownBlock("clippy"))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"workArea"},{"block":"statusBar"}]}}"#).failure, .placement(.statusBar, "a bar goes in a column"))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"column":[{"block":"workArea"},{"block":"agentRail"}]}}"#).failure, .placement(.agentRail, "a rail goes in a row"))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"agentRail"},{"block":"workArea"}]}}"#).failure, .twice(.agentRail))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"home"}]}}"#).failure, .noWorkArea)
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"agentRail","size":{"fixed":90}},{"block":"workArea"}]}}"#).failure, .tooSmall(.agentRail))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"stack":[{"block":"workArea"},{"block":"sidePanel"}]}}"#).failure, .placement(.sidePanel, "a stack holds main blocks"))
        if case .shape? = tree(#"{"schema":1,"root":{"row":[],"block":"x"}}"#).failure {} else { XCTFail("two kinds in one node") }
    }

    func testUsersTreeOverTheBuiltInAndBrokenOnesFallBack() {
        let mine = json(#"{"schema":1,"root":{"row":[{"block":"workArea"},{"block":"agentRail","size":{"fixed":300}}]}}"#)
        let t = ShellTree.resolve(preset: .agents, custom: ["tree": mine])
        XCTAssertEqual(t?.root.blocks, [.workArea, .agentRail])
        let broken = json(#"{"schema":1,"root":{"block":"home"}}"#)
        XCTAssertEqual(ShellTree.resolve(preset: .agents, custom: ["tree": broken]), ShellTree.builtIn("agents"))
        // A dragged width goes over the built-in; one below the block's minimum is ignored.
        let wide = ShellTree.resolve(preset: .agents, custom: ["sizes": json(#"{"agentRail":320}"#)])
        XCTAssertEqual(wide?.root.size(of: .agentRail), .fixed(320))
        let narrow = ShellTree.resolve(preset: .agents, custom: ["sizes": json(#"{"agentRail":40}"#)])
        XCTAssertEqual(narrow?.root.size(of: .agentRail), .fixed(268))
    }

    func testStackShowsHomeOnlyOnHome() {
        let kids = [ShellChild(node: .block(.home)), ShellChild(node: .block(.workArea))]
        XCTAssertEqual(ShellNode.shown(kids, home: true)?.node, .block(.home))
        XCTAssertEqual(ShellNode.shown(kids, home: false)?.node, .block(.workArea))
    }

    func testOnlyEngineLayoutsGetATreeAndTheResultIsCached() {
        XCTAssertNil(LayoutCache.get(nil).tree)                             // Terminal: classic window
        XCTAssertNil(LayoutCache.get(LayoutEdit.choose(.editor, in: nil)).tree)
        LayoutCache.reset()
        let v = LayoutEdit.choose(.agents, in: nil)
        let before = LayoutCache.misses
        XCTAssertNotNil(LayoutCache.get(v).tree)
        _ = LayoutCache.get(v); _ = LayoutCache.get(v)
        XCTAssertEqual(LayoutCache.misses, before + 1)                       // read once per change
        _ = LayoutCache.get(LayoutEdit.flag("chat", false, stored: v))
        XCTAssertEqual(LayoutCache.misses, before + 2)
    }
}

extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}
