import XCTest
@testable import Octomux

final class SplitSizingTests: XCTestCase {
    let div: CGFloat = 8

    /// Widths of the panes along a row of `.right` splits (sizes as `fit` hands them down).
    private func widths(_ n: PaneNode, _ w: CGFloat) -> [CGFloat] {
        guard case .split(let d, let r, let a, let b) = n, d == .right else { return [w] }
        let total = w - div, first = total * CGFloat(r)
        return widths(a, first) + widths(b, total - first)
    }

    private func splitRight(_ layout: PaneNode, _ target: String, _ new: String, width: CGFloat = 1023) -> PaneNode? {
        SplitSizing.layout(splitting: target, dir: .right, in: layout, size: CGSize(width: width, height: 744), divider: div, newId: new)
    }

    func testRepeatedSplitsShareTheRowEqually() {
        var l = PaneNode.leaf(sessionId: "1")
        var last = "1"
        for i in 2...6 {
            l = splitRight(l, last, "\(i)")!
            last = "\(i)"
            let ws = widths(l, 1023)
            XCTAssertEqual(ws.count, i)
            for w in ws { XCTAssertEqual(w, ws[0], accuracy: 0.5, "\(ws)") }
        }
        // A seventh pane would be under 160 pt wide: refused.
        XCTAssertNil(splitRight(l, last, "7"))
    }

    func testOtherDirectionKeepsItsRatioUntilTheRowNeedsRoom() {
        // left | (top / bottom)
        let l = PaneNode.split(dir: .right, ratio: 0.5, a: .leaf(sessionId: "L"),
                               b: .split(dir: .down, ratio: 0.5, a: .leaf(sessionId: "T"), b: .leaf(sessionId: "B")))
        let two = splitRight(l, "T", "T2")!
        guard case .split(_, let r2, _, _) = two else { return XCTFail() }
        XCTAssertEqual(r2, 0.5, accuracy: 0.001, "the left pane stays at half")
        var row = two, last = "T2"
        for i in 3...4 { row = splitRight(row, last, "T\(i)")!; last = "T\(i)" }
        guard case .split(_, let r4, _, .split(_, _, let topRow, _)) = row else { return XCTFail() }
        XCTAssertLessThan(r4, 0.5, "a full top row squeezes the left pane")
        let ws = widths(topRow, (1023 - div) * CGFloat(1 - r4))
        for w in ws { XCTAssertGreaterThanOrEqual(w, SplitSizing.minWidth - 0.5) }
    }

    func testEqualizeEvensEveryRowAndColumn() {
        // A broken tab: L | ((T1 | T2 | T3) / (B1 | B2)) with odd shares everywhere.
        let top = PaneNode.split(dir: .right, ratio: 0.7, a: .split(dir: .right, ratio: 0.1, a: .leaf(sessionId: "T1"), b: .leaf(sessionId: "T2")),
                                 b: .leaf(sessionId: "T3"))
        let bottom = PaneNode.split(dir: .right, ratio: 0.15, a: .leaf(sessionId: "B1"), b: .leaf(sessionId: "B2"))
        let l = PaneNode.split(dir: .right, ratio: 0.8, a: .leaf(sessionId: "L"), b: .split(dir: .down, ratio: 0.2, a: top, b: bottom))
        let e = SplitSizing.equalized(l, size: CGSize(width: 1023, height: 744), divider: div)
        guard case .split(_, let root, _, .split(_, let column, let t, let b)) = e else { return XCTFail() }
        XCTAssertEqual(root, 0.5, accuracy: 0.01)
        XCTAssertEqual(column, 0.5, accuracy: 0.01)
        let right = (1023 - div) * CGFloat(1 - root)
        for row in [t, b] {
            let ws = widths(row, right)
            for w in ws { XCTAssertEqual(w, ws[0], accuracy: 0.5, "\(ws)") }
        }
        XCTAssertEqual(widths(t, right).count, 3)
    }

    func testRatiosArePreOrder() {
        let l = PaneNode.split(dir: .right, ratio: 0.3, a: .split(dir: .down, ratio: 0.6, a: .leaf(sessionId: "a"), b: .leaf(sessionId: "b")),
                               b: .leaf(sessionId: "c"))
        XCTAssertEqual(SplitSizing.ratios(l), [0.3, 0.6])
    }
}
