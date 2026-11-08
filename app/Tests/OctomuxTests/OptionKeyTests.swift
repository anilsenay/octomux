import AppKit
import GhosttyKit
import XCTest
@testable import Octomux

/// Option counts as used for a key's text only when it changed the character: Option+Backspace stays Alt+Backspace
/// (a word in Claude Code's kitty keyboard mode), Option+Q stays the character it types.
final class OptionKeyTests: XCTestCase {
    func testOptionUsedOnlyWhenItChangesTheCharacter() {
        let opt: NSEvent.ModifierFlags = [.option]
        XCTAssertEqual(GhosttyInput.consumed(opt, withOption: "\u{7f}", withoutOption: "\u{7f}"), [])        // Backspace
        XCTAssertEqual(GhosttyInput.consumed(opt, withOption: "@", withoutOption: "q"), [.option])           // Option+Q (TR)
        XCTAssertEqual(GhosttyInput.consumed([.option, .shift], withOption: "\r", withoutOption: "\r"), [.shift])
        XCTAssertEqual(GhosttyInput.consumed([.option, .control], withOption: nil, withoutOption: nil), [.option])   // unknown: as before
        XCTAssertEqual(GhosttyInput.consumed([.shift], withOption: nil, withoutOption: nil), [.shift])
    }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testRealKeyEvents() {
        // Backspace (51) with Option: Alt is reported, not consumed.
        let bs = GhosttyInput.keyEvent(key(51, "\u{7f}", [.option]), action: GHOSTTY_ACTION_PRESS, translationMods: [.option])
        XCTAssertNotEqual(bs.mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertEqual(bs.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        // Q (12) with Option makes another character on every layout: Option stays consumed (it types the character).
        let q = GhosttyInput.keyEvent(key(12, "q", [.option]), action: GHOSTTY_ACTION_PRESS, translationMods: [.option])
        XCTAssertNotEqual(q.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        // Without Option nothing changes.
        let plain = GhosttyInput.keyEvent(key(51, "\u{7f}", []), action: GHOSTTY_ACTION_PRESS, translationMods: [])
        XCTAssertEqual(plain.consumed_mods.rawValue, 0)
    }
}
