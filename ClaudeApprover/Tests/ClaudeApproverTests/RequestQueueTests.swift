import XCTest
@testable import ClaudeApprover

@MainActor
final class RequestQueueTests: XCTestCase {
    private func makeRequest(
        tool: String,
        input: [String: Any] = [:],
        session: String = "s1",
        toolUseId: String = ""
    ) -> PermissionRequest {
        PermissionRequest(
            id: UUID(), toolName: tool, toolInput: input,
            toolUseId: toolUseId, sessionId: session, cwd: "/tmp", tty: nil,
            receivedAt: Date(), permissionSuggestions: [])
    }

    // MARK: - dequeueQuestionBySessionAndTool

    /// Regression: a completion for a different command must never dequeue (= deny) a still-pending toolPermission card.
    func testQuestionFallbackNeverDequeuesPendingToolPermission() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "Bash", input: ["command": "rm -rf build"]))

        let dequeued = queue.dequeueQuestionBySessionAndTool(sessionId: "s1", toolName: "Bash")

        XCTAssertNil(dequeued)
        XCTAssertEqual(queue.count, 1)
    }

    func testQuestionFallbackDequeuesOldestMatchingQuestion() {
        let queue = RequestQueue()
        let first = makeRequest(tool: "AskUserQuestion", input: ["question": "A"])
        let second = makeRequest(tool: "AskUserQuestion", input: ["question": "B"])
        queue.enqueue(first)
        queue.enqueue(second)

        XCTAssertEqual(queue.dequeueQuestionBySessionAndTool(sessionId: "s1", toolName: "AskUserQuestion")?.id, first.id)
        XCTAssertEqual(queue.items.map(\.id), [second.id])
    }

    func testQuestionFallbackIgnoresOtherSession() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "AskUserQuestion", session: "s2"))

        XCTAssertNil(queue.dequeueQuestionBySessionAndTool(sessionId: "s1", toolName: "AskUserQuestion"))
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - dequeueToolPermissionMatching

    func testToolPermissionMatchingRequiresSameInput() {
        let queue = RequestQueue()
        let target = makeRequest(tool: "Bash", input: ["command": "ls", "description": "list"])
        let other = makeRequest(tool: "Bash", input: ["command": "rm -rf build"])
        queue.enqueue(other)
        queue.enqueue(target)

        // Matches the same input even when the key order differs
        let signature = PermissionRequest.canonicalSignature(["description": "list", "command": "ls"])
        let dequeued = queue.dequeueToolPermissionMatching(
            sessionId: "s1", toolName: "Bash", inputSignature: signature)

        XCTAssertEqual(dequeued?.id, target.id)
        XCTAssertEqual(queue.items.map(\.id), [other.id])
    }

    func testToolPermissionMatchingDoesNotDequeueDifferentInput() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "Bash", input: ["command": "rm -rf build"]))

        let signature = PermissionRequest.canonicalSignature(["command": "ls"])
        XCTAssertNil(queue.dequeueToolPermissionMatching(
            sessionId: "s1", toolName: "Bash", inputSignature: signature))
        XCTAssertEqual(queue.count, 1)
    }

    func testToolPermissionMatchingIgnoresEmptySignature() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "Bash", input: [:]))

        XCTAssertNil(queue.dequeueToolPermissionMatching(
            sessionId: "s1", toolName: "Bash", inputSignature: ""))
        XCTAssertEqual(queue.count, 1)
    }

    func testToolPermissionMatchingIgnoresQuestionRequests() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "AskUserQuestion", input: ["question": "A"]))

        let signature = PermissionRequest.canonicalSignature(["question": "A"])
        XCTAssertNil(queue.dequeueToolPermissionMatching(
            sessionId: "s1", toolName: "AskUserQuestion", inputSignature: signature))
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - dequeuePlanApprovals

    /// Regression: a plan approved/rejected in the terminal used to leave its card lingering
    /// until the 300s hook timeout. Every pending plan card of the session is stale once a
    /// main-agent completion arrives, so all of them (not just the oldest) must go.
    func testPlanApprovalsDequeuesAllPlanCardsOfSession() {
        let queue = RequestQueue()
        let stale = makeRequest(tool: "ExitPlanMode", input: ["plan": "old"])
        let current = makeRequest(tool: "ExitPlanMode", input: ["plan": "new"])
        queue.enqueue(stale)
        queue.enqueue(current)

        let dequeued = queue.dequeuePlanApprovals(sessionId: "s1")

        XCTAssertEqual(dequeued.map(\.id), [stale.id, current.id])
        XCTAssertTrue(queue.isEmpty)
    }

    /// Only plan cards are swept: a pending toolPermission/question card of the same session
    /// must survive (dequeuing it would wrongly deny it).
    func testPlanApprovalsNeverDequeuesToolPermissionOrQuestion() {
        let queue = RequestQueue()
        let bash = makeRequest(tool: "Bash", input: ["command": "ls"])
        let question = makeRequest(tool: "AskUserQuestion", input: ["question": "A"])
        let plan = makeRequest(tool: "ExitPlanMode", input: ["plan": "p"])
        queue.enqueue(bash)
        queue.enqueue(question)
        queue.enqueue(plan)

        let dequeued = queue.dequeuePlanApprovals(sessionId: "s1")

        XCTAssertEqual(dequeued.map(\.id), [plan.id])
        XCTAssertEqual(queue.items.map(\.id), [bash.id, question.id])
    }

    func testPlanApprovalsIgnoresOtherSession() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"], session: "s2"))

        XCTAssertTrue(queue.dequeuePlanApprovals(sessionId: "s1").isEmpty)
        XCTAssertEqual(queue.count, 1)
    }

    /// A request/completion without a session id cannot be correlated, so nothing is swept.
    func testPlanApprovalsIgnoresEmptySessionId() {
        let queue = RequestQueue()
        queue.enqueue(makeRequest(tool: "ExitPlanMode", input: ["plan": "p"], session: ""))

        XCTAssertTrue(queue.dequeuePlanApprovals(sessionId: "").isEmpty)
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - canonicalSignature

    func testCanonicalSignatureIsKeyOrderIndependent() {
        XCTAssertEqual(
            PermissionRequest.canonicalSignature(["a": 1, "b": 2]),
            PermissionRequest.canonicalSignature(["b": 2, "a": 1]))
    }

    func testCanonicalSignatureOfInvalidJSONObjectIsEmpty() {
        XCTAssertEqual(PermissionRequest.canonicalSignature(["date": Date()]), "")
    }
}
