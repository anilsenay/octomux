import AppKit
import XCTest
@testable import Octomux

final class StatusItemTests: XCTestCase {
    func testPanelCenteredUnderTheIcon() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
        // In the middle of the menu bar: centered.
        XCTAssertEqual(StatusItemController.panelX(icon: NSRect(x: 900, y: 950, width: 30, height: 24), width: 340, screen: screen), 745)
        // Near either edge: kept 6 pt inside.
        XCTAssertEqual(StatusItemController.panelX(icon: NSRect(x: 1480, y: 950, width: 30, height: 24), width: 340, screen: screen), 1166)
        XCTAssertEqual(StatusItemController.panelX(icon: NSRect(x: 10, y: 950, width: 30, height: 24), width: 340, screen: screen), 6)
    }
}
