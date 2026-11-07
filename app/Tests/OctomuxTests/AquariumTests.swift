import XCTest
import SwiftUI
@testable import Octomux

final class AquariumTests: XCTestCase {
    private func fish(_ id: String, _ m: AquariumFish.Mood) -> AquariumFish { AquariumFish(id: id, title: id, color: .purple, mood: m) }
    private let size = CGSize(width: 800, height: 400), sprite = CGSize(width: 64, height: 52)

    func testMoods() {
        func s(_ a: Activity, unread: Bool = false, state: SessionState = .running) -> Session {
            Session(id: "s", projectId: "p", kind: .agent, profileId: nil, title: "t", customTitle: "", cwd: "/", state: state, activity: a,
                    unread: unread, agentSessionId: nil, createdAt: 0, lastActivityAt: 0, exitCode: nil, placement: .tab, command: nil,
                    worktree: nil, transcriptPath: nil, agentTitle: nil)
        }
        XCTAssertEqual(AquariumFish.moodOf(s(.working)), .working)
        XCTAssertEqual(AquariumFish.moodOf(s(.needsInput)), .waiting)
        XCTAssertEqual(AquariumFish.moodOf(s(.done)), .finished)
        XCTAssertEqual(AquariumFish.moodOf(s(.idle, unread: true)), .finished)
        XCTAssertEqual(AquariumFish.moodOf(s(.idle)), .idle)
        XCTAssertEqual(AquariumFish.moodOf(s(.error)), .error)
        XCTAssertEqual(AquariumFish.moodOf(s(.working, state: .exited)), .idle)
    }

    func testSleepersRestOnTheSandSwimmersStayInTheWater() {
        let list = [fish("a", .working), fish("b", .finished), fish("c", .waiting)]
        for t in stride(from: 0.0, to: 60, by: 3.7) {
            let w = AquariumMotion.position(list[0], index: 0, count: 3, t: t, size: size, sprite: sprite)
            let f = AquariumMotion.position(list[1], index: 1, count: 3, t: t, size: size, sprite: sprite)
            XCTAssertLessThan(w.y + sprite.height, size.height * 0.82)               // above the sand
            XCTAssertEqual(f.y + sprite.height * 0.55, size.height * 0.82, accuracy: 0.01)   // on it
        }
        XCTAssertEqual(AquariumMotion.seed("x"), AquariumMotion.seed("x"))
        XCTAssertNotEqual(AquariumMotion.seed("x"), AquariumMotion.seed("y"))
    }

    func testClickFindsTheOctopus() {
        let list = [fish("a", .idle), fish("b", .finished)]
        let o = AquariumMotion.position(list[1], index: 1, count: 2, t: 5, size: size, sprite: sprite)
        XCTAssertEqual(AquariumMotion.hit(CGPoint(x: o.x + 10, y: o.y + 10), fish: list, t: 5, size: size, sprite: sprite)?.id, "b")
        XCTAssertNil(AquariumMotion.hit(CGPoint(x: 5, y: 5), fish: list, t: 5, size: size, sprite: sprite))
    }
}
