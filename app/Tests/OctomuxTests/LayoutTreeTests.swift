import XCTest
@testable import Octomux

final class LayoutTreeTests: XCTestCase {
    private func tree(_ s: String) -> Result<ShellTree, ShellTree.Problem> { ShellTree.parse(Data(s.utf8)) }
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    func testBuiltInAgentsTreeReadsAndKeepsTheRules() throws {
        let t = try XCTUnwrap(ShellTree.builtIn("agents"))
        XCTAssertNil(t.problem())
        XCTAssertEqual(Set(t.root.blocks), [.agentRail, .breadcrumb, .home, .workArea, .sidePanel, .statusBar])
        XCTAssertTrue(LayoutCache.engine.contains(.terminal))    // drawn by the engine, the same as the classic window
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
        XCTAssertEqual(LayoutCache.get(nil).tree, ShellTree.builtIn("terminal"))   // nothing stored: Terminal's tree
        XCTAssertNotNil(LayoutCache.get(LayoutEdit.choose(.editor, in: nil)).tree)   // phase 2: on the engine
        LayoutCache.reset()
        let v = LayoutEdit.choose(.agents, in: nil)
        let before = LayoutCache.misses
        XCTAssertNotNil(LayoutCache.get(v).tree)
        _ = LayoutCache.get(v); _ = LayoutCache.get(v)
        XCTAssertEqual(LayoutCache.misses, before + 1)                       // read once per change
        _ = LayoutCache.get(LayoutEdit.flag("chat", false, stored: v))
        XCTAssertEqual(LayoutCache.misses, before + 2)
    }

    // MARK: Phase 2 blocks

    func testNewBlocksKnowWhereTheyGo() {
        XCTAssertEqual(ShellBlock.tasksRail.kind, .rail)
        XCTAssertEqual(ShellBlock.taskDetail.kind, .rail)
        XCTAssertEqual(ShellBlock.sideAgent.kind, .rail)
        XCTAssertEqual(ShellBlock.aquariumStrip.kind, .bar)
        for b in ShellBlock.allCases where b.kind == .rail { XCTAssertGreaterThanOrEqual(b.defaultWidth, b.minSize, "\(b)") }
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"workArea"},{"block":"aquariumStrip"}]}}"#).failure, .placement(.aquariumStrip, "a bar goes in a column"))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"column":[{"block":"workArea"},{"block":"taskDetail"}]}}"#).failure, .placement(.taskDetail, "a rail goes in a row"))
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"sideAgent","size":{"fixed":200}},{"block":"workArea"}]}}"#).failure, .tooSmall(.sideAgent))
        // One list per window: ⌘1…9 steps through one.
        XCTAssertEqual(tree(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"block":"tasksRail"},{"block":"workArea"}]}}"#).failure, .twoLists)
    }

    func testWorkdayIsTheAgentsWindowWithItsOwnHome() throws {
        let w = try XCTUnwrap(ShellTree.builtIn("workday"))
        XCTAssertEqual(w.nav, .agents)
        XCTAssertEqual(w.variant(of: .home), "workday")
        XCTAssertNil(try XCTUnwrap(ShellTree.builtIn("agents")).variant(of: .home))
        XCTAssertNotNil(LayoutCache.get(LayoutEdit.choose(.workday, in: nil)).tree)
    }

    func testClassicLayoutsOnTheEngineKeepTheirParts() throws {
        for (name, extra) in [("minimal", ShellBlock.sideAgent), ("editor", .sideAgent), ("aquarium", .aquariumStrip)] {
            let t = try XCTUnwrap(ShellTree.builtIn(name), name)
            XCTAssertEqual(t.nav, .tabs, name)                               // tabs, as before: ⌘T is a new tab
            for b in [ShellBlock.projectTree, .tabStrip, .workArea, .sidePanel, .statusBar, extra] { XCTAssertTrue(t.has(b), "\(name) \(b)") }
        }
        // Each child of a container keeps one identity while blocks come and go.
        let keys = try XCTUnwrap(ShellTree.builtIn("aquarium")).root.blocks.map { ShellChild(node: .block($0)).key }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testTasksIsAWindowOfItsOwn() throws {
        let t = try XCTUnwrap(ShellTree.builtIn("tasks"))
        XCTAssertEqual(t.nav, .tasks)
        XCTAssertTrue(t.has(.taskDetail) && t.has(.breadcrumb) && !t.has(.tabStrip) && !t.has(.home))
        XCTAssertEqual(LayoutCache.get(nil).tree, ShellTree.builtIn("terminal"))   // nothing stored: Terminal's tree
    }

    func testVariantsReadUnknownOnesAsTheFirst() throws {
        let w = try tree(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"stack":[{"block":"home","variant":"workday"},{"block":"workArea"}]}]}}"#).get()
        XCTAssertEqual(w.variant(of: .home), "workday")
        let u = try tree(#"{"schema":1,"root":{"row":[{"block":"agentRail"},{"stack":[{"block":"home","variant":"garden"},{"block":"workArea"}]}]}}"#).get()
        XCTAssertNil(u.variant(of: .home))                                   // a later version's variant: today's Home
        let x = try tree(#"{"schema":1,"root":{"column":[{"block":"workArea","variant":"x"}]}}"#).get()
        XCTAssertNil(x.variant(of: .workArea))                               // a block without variants
    }

    func testWindowNavFollowsItsList() throws {
        XCTAssertEqual(try XCTUnwrap(ShellTree.builtIn("agents")).nav, .agents)
        XCTAssertEqual(try tree(#"{"schema":1,"root":{"row":[{"block":"tasksRail"},{"block":"workArea"}]}}"#).get().nav, .tasks)
        XCTAssertEqual(try tree(#"{"schema":1,"root":{"column":[{"block":"tabStrip"},{"block":"workArea"}]}}"#).get().nav, .tabs)
    }

    func testTreeWritesBackToTheSameTree() throws {
        let src = #"{"schema":1,"root":{"row":[{"block":"agentRail","size":{"fixed":300}},{"column":[{"block":"breadcrumb"},{"stack":[{"block":"home","variant":"workday"},{"block":"workArea"}],"size":{"flex":2}},{"block":"aquariumStrip","size":{"min":150}}]}]}}"#
        let t = try tree(src).get()
        XCTAssertEqual(try ShellTree.parse(t.json).get(), t)
        XCTAssertEqual(try ShellTree.parse(t.json).get().variant(of: .home), "workday")
    }

    func testFilesCantAskForTheImpossible() throws {
        // Numbers too big for an Int are "no schema", not a crash.
        for n in ["1e300", "-1e300", "1.5", "9223372036854775808"] {
            XCTAssertEqual(tree(#"{"schema":\#(n),"root":{"block":"workArea"}}"#).failure, .schema(0), n)
            XCTAssertEqual(LayoutFile.read(Data(#"{"schema":\#(n),"name":"x","base":"agents"}"#.utf8), themes: nil, commands: nil).failure, .schema(0), n)
        }
        // Sizes within what a screen has.
        let t = try tree(#"{"schema":1,"root":{"row":[{"block":"agentRail","size":{"fixed":1e300}},{"block":"workArea","size":{"flex":1e300}},{"block":"sidePanel","size":{"min":1e9}}]}}"#).get()
        guard case .row(let kids) = t.root else { return XCTFail() }
        XCTAssertEqual(kids.map(\.size), [.fixed(ShellTree.maxPoints), .flex(ShellTree.maxFlex), .min(ShellTree.maxPoints)])
        let custom: [String: JSONValue] = ["sizes": json(#"{"agentRail":1e300}"#)]
        if case .row(let k)? = ShellTree.resolve(preset: .agents, custom: custom)?.root { XCTAssertEqual(k.first?.size, .fixed(ShellTree.maxPoints)) } else { XCTFail() }
        // Deep or huge trees are refused before anything is drawn.
        var deep = #"{"block":"workArea"}"#
        for _ in 0..<ShellTree.maxDepth { deep = #"{"stack":[\#(deep)]}"# }
        if case .shape? = tree(#"{"schema":1,"root":\#(deep)}"#).failure {} else { XCTFail("too deep") }
        let wide = (0..<ShellTree.maxNodes).map { _ in #"{"row":[{"stack":[{"block":"workArea"}]}]}"# }.joined(separator: ",")
        if case .shape? = tree(#"{"schema":1,"root":{"column":[\#(wide)]}}"#).failure {} else { XCTFail("too many nodes") }
    }

    func testProblemsHaveAMessage() {
        let all: [ShellTree.Problem] = [.unreadable, .schema(0), .schema(2), .unknownBlock("x"), .shape("y"), .twice(.home),
                                        .placement(.home, "z"), .tooSmall(.agentRail), .noWorkArea, .twoLists]
        for p in all { XCTAssertFalse(p.message.isEmpty) }
        XCTAssertTrue(ShellTree.Problem.unknownBlock("clippy").message.contains("clippy"))
    }
}

extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}
