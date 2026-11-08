import XCTest
@testable import Octomux

/// A session that turns unread while you watch it is read at once (no green dot on the agent you are looking at).
final class WatchedReadTests: XCTestCase {
    private func session(_ id: String, unread: Bool, _ a: Activity = .done) -> Session {
        Session(id: id, projectId: "p", kind: .agent, profileId: nil, title: id, customTitle: "", cwd: "/",
                state: .running, activity: a, unread: unread, agentSessionId: nil, createdAt: 0, lastActivityAt: 0,
                exitCode: nil, placement: .tab, command: nil, worktree: nil, transcriptPath: nil, agentTitle: nil)
    }

    func testOnlyTheWatchedSession() {
        let list = [session("a", unread: true), session("b", unread: true)]
        XCTAssertEqual(AppModel.watchedUnread(focused: "a", sessions: list, watching: true), "a")
        XCTAssertNil(AppModel.watchedUnread(focused: "a", sessions: list, watching: false))   // another app in front, Home…
        XCTAssertNil(AppModel.watchedUnread(focused: nil, sessions: list, watching: true))
        XCTAssertNil(AppModel.watchedUnread(focused: "a", sessions: [session("a", unread: false)], watching: true))
        XCTAssertEqual(AppModel.watchedUnread(focused: "b", sessions: [session("b", unread: true, .needsInput)], watching: true), "b")
    }
}
