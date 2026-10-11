import XCTest
@testable import ClaudeApprover

@MainActor
final class ApproverViewModelTests: XCTestCase {
    private func makeRequest(
        tool: String,
        input: [String: Any] = [:],
        session: String = "s1"
    ) -> PermissionRequest {
        PermissionRequest(
            id: UUID(), toolName: tool, toolInput: input,
            toolUseId: "", sessionId: session, cwd: "/tmp", tty: nil,
            receivedAt: Date(), permissionSuggestions: [])
    }

    private func completion(tool: String, session: String = "s1") -> ToolCompletion {
        ToolCompletion(toolUseId: "toolu_x", sessionId: session, toolName: tool, inputSignature: "")
    }

    /// Regression: a plan approved in the terminal fires PostToolUse(ExitPlanMode), which used
    /// to match nothing, leaving the card (and banner) until the 300s hook timeout.
    func testExitPlanModeCompletionDequeuesPlanCard() {
        let viewModel = ApproverViewModel()
        viewModel.queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"]))

        viewModel.handleToolCompletion(completion(tool: "ExitPlanMode"))

        XCTAssertTrue(viewModel.queue.isEmpty)
    }

    /// Regression: a plan rejected in the terminal fires no ExitPlanMode completion; the model
    /// resuming work (any other main-agent tool completing) is the only signal.
    func testOtherToolCompletionDequeuesRejectedPlanCard() {
        let viewModel = ApproverViewModel()
        viewModel.queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"]))

        viewModel.handleToolCompletion(completion(tool: "Read"))

        XCTAssertTrue(viewModel.queue.isEmpty)
    }

    /// The plan sweep must not stop the other strategies: the same completion still cleans up
    /// its own card, while an unrelated pending toolPermission card is never denied.
    func testPlanSweepKeepsUnrelatedPendingToolPermission() {
        let viewModel = ApproverViewModel()
        let pending = makeRequest(tool: "Bash", input: ["command": "rm -rf build"])
        viewModel.queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"]))
        viewModel.queue.enqueue(pending)

        viewModel.handleToolCompletion(completion(tool: "Read"))

        XCTAssertEqual(viewModel.queue.items.map(\.id), [pending.id])
    }

    func testCompletionOfOtherSessionKeepsPlanCard() {
        let viewModel = ApproverViewModel()
        viewModel.queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"], session: "s1"))

        viewModel.handleToolCompletion(completion(tool: "Read", session: "s2"))

        XCTAssertEqual(viewModel.queue.count, 1)
    }
}
