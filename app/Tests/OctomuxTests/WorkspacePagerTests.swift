import AppKit
import XCTest
@testable import Octomux

/// The sidebar's workspace paging, fed with synthesized trackpad scroll events.
final class WorkspacePagerTests: XCTestCase {
    private var pager: WorkspacePager!
    private var current = "a"
    private var selected: [String] = []

    override func setUp() {
        pager = WorkspacePager()
        current = "a"
        selected = []
        pager.animated = false
        pager.workspaceIds = { ["a", "b", "c"] }
        pager.currentId = { [unowned self] in self.current }
        pager.select = { [unowned self] in self.selected.append($0); self.current = $0 }
    }

    /// A continuous (trackpad) scroll event; phase 1 began, 2 changed, 4 ended, 8 cancelled.
    private func ev(_ dx: Int32, _ dy: Int32 = 0, phase: Int64, momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        return NSEvent(cgEvent: cg)!
    }

    private func drag(_ steps: [Int32], dy: Int32 = 0) -> [Bool] {
        var out = [pager.handle(ev(0, phase: 1))]
        for d in steps { out.append(pager.handle(ev(d, dy, phase: 2))) }
        return out
    }

    private func swipe(_ steps: [Int32], dy: Int32 = 0, end: Int64 = 4) -> [Bool] {
        var out = drag(steps, dy: dy)
        out.append(pager.handle(ev(0, phase: end)))
        return out
    }

    /// Slow steps: no flick, so only the distance decides.
    private func slow(_ total: Int, _ sign: Int32) -> [Int32] { Array(repeating: 5 * sign, count: total / 5) }

    func testDraggingShowsTheNeighborAndBlendsColorAroundTheMiddle() {
        _ = drag(Array(repeating: -5, count: 4))
        XCTAssertEqual(pager.target, "b")                        // fingers left → the next workspace comes in
        XCTAssertEqual(pager.offset, -20)                         // one to one with the fingers
        XCTAssertEqual(pager.colorBlend, 0)                       // color still the current workspace's
        let half = Int(pager.width / 2) / 5 - 4
        for _ in 0..<half { _ = pager.handle(ev(-5, phase: 2)) }  // same gesture, to about the middle
        XCTAssertGreaterThan(pager.colorBlend, 0.3)
        XCTAssertLessThan(pager.colorBlend, 0.7)
        _ = pager.handle(ev(0, phase: 8))
        XCTAssertEqual(pager.colorBlend, 0)                       // springs back with the color
    }

    func testPastTheCommitPointSwitches() {
        _ = swipe(slow(Int(pager.width * 0.5), -1))
        XCTAssertEqual(selected, ["b"])
        XCTAssertEqual(pager.offset, 0)
        XCTAssertNil(pager.target)
        _ = swipe(slow(Int(pager.width * 0.5), 1))              // and back
        XCTAssertEqual(selected, ["b", "a"])
    }

    func testShortOfTheCommitPointSpringsBack() {
        _ = swipe(slow(Int(pager.width * 0.3), -1))
        XCTAssertEqual(selected, [])
        XCTAssertEqual(pager.offset, 0)
        XCTAssertNil(pager.target)
    }

    func testFlickSwitchesEarly() {
        _ = swipe([-4, -16, -24])                                 // 44 pt but fast
        XCTAssertEqual(selected, ["b"])
    }

    func testWrapsAroundBackwards() {
        _ = swipe(slow(Int(pager.width * 0.5), 1))              // fingers right → previous, wraps to the last
        XCTAssertEqual(selected, ["c"])
    }

    func testChangingDirectionMidSwipeChangesTheNeighbor() {
        _ = drag([-10, -10])
        XCTAssertEqual(pager.target, "b")
        _ = drag([30])
        XCTAssertEqual(pager.target, "c")
        _ = pager.handle(ev(0, phase: 8))
    }

    func testCancelledSwipeNeverSwitches() {
        _ = swipe(slow(Int(pager.width * 0.8), -1), end: 8)
        XCTAssertEqual(selected, [])
        XCTAssertEqual(pager.offset, 0)
    }

    func testVerticalScrollPassesThrough() {
        let handled = swipe([2, 1, 3], dy: 20)
        XCTAssertEqual(handled.dropFirst().dropLast(), [false, false, false])
        XCTAssertEqual(pager.offset, 0)
        XCTAssertEqual(selected, [])
    }

    func testMomentumIsIgnored() {
        XCTAssertFalse(pager.handle(ev(-50, phase: 0, momentum: 2)))
        XCTAssertEqual(pager.offset, 0)
    }

    func testOffsetStopsAtAFullPage() {
        _ = drag(Array(repeating: -40, count: 30))
        XCTAssertEqual(pager.offset, -pager.width)
        _ = pager.handle(ev(0, phase: 8))
    }

    func testOneWorkspaceOnlyBudges() {
        pager.workspaceIds = { ["a"] }
        _ = drag(Array(repeating: -30, count: 10))
        XCTAssertNil(pager.target)
        XCTAssertLessThanOrEqual(abs(pager.offset), 40)
        _ = pager.handle(ev(0, phase: 4))
        XCTAssertEqual(selected, [])
    }

    func testStepsAndJumps() {
        pager.slide(1)
        XCTAssertEqual(selected, ["b"])
        pager.go(to: "a")
        XCTAssertEqual(selected, ["b", "a"])
        pager.go(to: "a")                                         // already there
        XCTAssertEqual(selected, ["b", "a"])
    }
}
