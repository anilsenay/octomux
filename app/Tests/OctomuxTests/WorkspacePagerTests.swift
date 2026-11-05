import AppKit
import XCTest
@testable import Octomux

/// The sidebar's workspace swipe, fed with synthesized trackpad scroll events.
final class WorkspacePagerTests: XCTestCase {
    private var pager: WorkspacePager!
    private var commits: [Int] = []

    override func setUp() {
        pager = WorkspacePager()
        commits = []
        pager.workspaceCount = { 3 }
        pager.commit = { [unowned self] in self.commits.append($0) }
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

    private func swipe(_ steps: [Int32], dy: Int32 = 0, end: Int64 = 4) -> [Bool] {
        var out = [pager.handle(ev(0, phase: 1))]
        for d in steps { out.append(pager.handle(ev(d, dy, phase: 2))) }
        out.append(pager.handle(ev(0, phase: end)))
        return out
    }

    func testLongSwipeLeftGoesToTheNextWorkspace() {
        _ = pager.handle(ev(0, phase: 1))
        for _ in 0..<3 { _ = pager.handle(ev(-10, phase: 2)) }
        XCTAssertEqual(pager.offset, -30)                       // follows the fingers until release
        _ = pager.handle(ev(0, phase: 8))
        _ = swipe([-25, -25, -25, -2, -1])
        XCTAssertEqual(commits, [1])
        _ = swipe([25, 25, 25, 2, 1])
        XCTAssertEqual(commits, [1, -1])
    }

    func testShortSlowSwipeSpringsBack() {
        _ = swipe([-3, -3, -3, -3, -3, -3, -3, -3, -3, -3])     // 30 pt, slow at the end
        XCTAssertEqual(commits, [])
        XCTAssertEqual(pager.offset, 0)
    }

    func testShortFlickSwitches() {
        _ = swipe([-4, -16, -24])                               // 44 pt but fast
        XCTAssertEqual(commits, [1])
    }

    func testCancelledSwipeNeverSwitches() {
        _ = swipe([-40, -40, -40], end: 8)
        XCTAssertEqual(commits, [])
    }

    func testVerticalScrollPassesThrough() {
        let handled = swipe([2, 1, 3], dy: 20)
        XCTAssertEqual(handled.dropFirst().dropLast(), [false, false, false])
        XCTAssertEqual(pager.offset, 0)
        XCTAssertEqual(commits, [])
    }

    func testMomentumIsIgnored() {
        XCTAssertFalse(pager.handle(ev(-50, phase: 0, momentum: 2)))
        XCTAssertEqual(pager.offset, 0)
    }

    func testDragResistsBeyondAQuarterAndStaysUnderHalf() {
        _ = pager.handle(ev(0, phase: 1))
        for _ in 0..<40 { _ = pager.handle(ev(-20, phase: 2)) }  // 800 pt of travel
        XCTAssertLessThan(abs(pager.offset), pager.width * 0.45)
        XCTAssertGreaterThan(abs(pager.offset), pager.width * 0.3)
    }

    func testOneWorkspaceOnlyBudges() {
        pager.workspaceCount = { 1 }
        _ = pager.handle(ev(0, phase: 1))
        for _ in 0..<10 { _ = pager.handle(ev(-30, phase: 2)) }
        XCTAssertLessThanOrEqual(abs(pager.offset), 40)
        _ = pager.handle(ev(0, phase: 4))
        XCTAssertEqual(commits, [])
    }
}
