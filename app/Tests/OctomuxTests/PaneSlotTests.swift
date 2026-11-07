import XCTest
import AppKit
@testable import Octomux

final class PaneSlotTests: XCTestCase {
    func testTheSlotThatArrivedLastKeepsTheTerminals() {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: w.contentLayoutRect)
        w.contentView = root
        let c = PaneContainerView()
        let old = PaneSlotView(c), new = PaneSlotView(c)
        var adopted: [String] = []
        old.onAdopt = { adopted.append("old") }
        new.onAdopt = { adopted.append("new") }
        root.addSubview(old)
        XCTAssertTrue(c.superview === old)
        root.addSubview(new)                                 // a layout switch: the new window's slot appears
        XCTAssertTrue(c.superview === new)
        XCTAssertFalse(old.adopt())                          // the leaving one's update doesn't take it back
        XCTAssertTrue(c.superview === new)
        new.removeFromSuperview()                            // switched back while animating: the one left takes it
        XCTAssertTrue(c.superview === old)
        XCTAssertEqual(adopted, ["old", "new", "old"])
        old.removeFromSuperview()
        let again = PaneSlotView(c)
        root.addSubview(again)
        XCTAssertTrue(c.superview === again)
    }
}
