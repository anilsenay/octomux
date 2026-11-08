import XCTest
@testable import Octomux

/// The traffic lights sit in the middle of the top bar's row, inset from the left as from the top.
final class WindowChromeTests: XCTestCase {
    func testLightsFollowTheTopRow() {
        XCTAssertEqual(WindowChrome.lights(topH: 46).center, 23)   // Ink, the default
        XCTAssertEqual(WindowChrome.lights(topH: 46).x, 16)
        XCTAssertEqual(WindowChrome.lights(topH: 36).center, 18)   // Grid
        XCTAssertEqual(WindowChrome.lights(topH: 48).center, 24)   // Glass
    }

    func testOriginsInTheTitleBar() {
        // A 32 pt title bar (not flipped): the centre 23 below the top is 9 above the bottom; a 14 pt button starts at 2.
        XCTAssertEqual(WindowChrome.origin(0, superHeight: 32, buttonHeight: 14, topH: 46), NSPoint(x: 16, y: 2))
        XCTAssertEqual(WindowChrome.origin(2, superHeight: 32, buttonHeight: 14, topH: 46).x, 56)
        // A title bar too short for the row: the buttons stay inside it.
        XCTAssertEqual(WindowChrome.origin(0, superHeight: 20, buttonHeight: 14, topH: 46).y, 0)
    }
}
