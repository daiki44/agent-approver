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
