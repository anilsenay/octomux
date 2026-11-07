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

final class AquariumRowsTests: XCTestCase {
    func testManyOctopusesMakeTwoRowsAndCountsRead() {
        let size = CGSize(width: 1000, height: 400), sprite = CGSize(width: 48, height: 39)
        let fish = (0..<10).map { AquariumFish(id: "f\($0)", title: "f\($0)", color: .purple, mood: .idle) }
        let ys = Set(fish.indices.map { Int(AquariumMotion.position(fish[$0], index: $0, count: 10, t: 0, size: size, sprite: sprite).y.rounded()) })
        XCTAssertEqual(ys.count, 2)                                    // front and back row
        let xs = fish.indices.map { AquariumMotion.position(fish[$0], index: $0, count: 10, t: 0, size: size, sprite: sprite).x }
        XCTAssertEqual(Set(xs.map { Int($0) }).count, 10)              // nobody on top of another
        XCTAssertEqual(AquariumHeader.counts([.working, .waiting, .idle, .finished]), "1 swimming · 1 needs you · 2 resting")
        XCTAssertEqual(AquariumHeader.counts([.waiting, .error]), "2 need you")
    }
}

final class AquariumFramesTests: XCTestCase {
    func testSwimsInFrontOneFrameASecondBehind() {
        XCTAssertEqual(AquariumView.frameInterval(style: .strip, active: true), 1.0 / 12)
        XCTAssertEqual(AquariumView.frameInterval(style: .full, active: true), 1.0 / 12)
        XCTAssertEqual(AquariumView.frameInterval(style: .backdrop, active: true), 1.0 / 8)
        for st in [AquariumView.Style.strip, .full, .backdrop] { XCTAssertEqual(AquariumView.frameInterval(style: st, active: false), 1.0) }
    }

    func testRestsWhenNobodyIsAround() {
        XCTAssertTrue(AquariumView.isLively(active: true, idleSeconds: 5, sinceMoodChange: 600))     // you're at it
        XCTAssertTrue(AquariumView.isLively(active: true, idleSeconds: 600, sinceMoodChange: 3))     // an agent just changed
        XCTAssertFalse(AquariumView.isLively(active: true, idleSeconds: 31, sinceMoodChange: 31))    // nobody around: rests
        XCTAssertFalse(AquariumView.isLively(active: false, idleSeconds: 0, sinceMoodChange: 0))     // behind other apps
    }
}
