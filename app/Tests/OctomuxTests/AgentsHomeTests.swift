import XCTest
@testable import Octomux

final class AgentsHomeTests: XCTestCase {
    private func item(_ k: ChatItem.Kind, _ text: String = "", tool: String = "", detail: String = "", result: String? = "ok", input: String = "") -> ChatItem {
        ChatItem(id: UUID().uuidString, kind: k, text: text, tool: tool, detail: detail, result: result, input: input)
    }

    func testDigestOfATurnWaitingForPermission() {
        let items = [item(.user, "old"), item(.assistant, "earlier"), item(.user, "Fix it"),
                     item(.tool, tool: "Read", detail: "a.rs"), item(.tool, tool: "Edit", detail: "/x/src/holder.rs"),
                     item(.tool, tool: "Edit", detail: "/x/src/holder.rs"), item(.assistant, "Tests **pass**.\nReady to push."),
                     item(.tool, tool: "Bash", detail: "git push", result: nil)]
        let d = AgentDigests.digest(items, waiting: true)
        XCTAssertEqual(d.summary, "Tests pass. Ready to push.")
        XCTAssertEqual(d.pending, .permission("Bash(git push)"))
        XCTAssertEqual(d.steps, "Read 1 file · Edited 1 file · Ran 1 command")
        XCTAssertEqual(d.files, ["holder.rs"])
        XCTAssertNil(AgentDigests.digest(items, waiting: false).pending, "not waiting: nothing to answer")
    }

    func testDigestReadsAQuestion() {
        let q = #"{"questions":[{"question":"Which file?","options":[{"label":"a.rs"},{"label":"b.rs"}]}]}"#
        let d = AgentDigests.digest([item(.user, "go"), item(.tool, tool: "AskUserQuestion", result: nil, input: q)], waiting: true)
        XCTAssertEqual(d.pending, .question("Which file?", ["a.rs", "b.rs"]))
    }
}
