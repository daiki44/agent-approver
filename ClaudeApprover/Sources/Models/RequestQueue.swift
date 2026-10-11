import Foundation

/// Thread-safe queue of pending permission requests.
@Observable
@MainActor
final class RequestQueue {
    private(set) var items: [PermissionRequest] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func enqueue(_ request: PermissionRequest) {
        items.append(request)
    }

    func dequeue(id: UUID) -> PermissionRequest? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    func dequeueByToolUseId(_ toolUseId: String) -> PermissionRequest? {
        guard let index = items.firstIndex(where: { $0.toolUseId == toolUseId }) else { return nil }
        return items.remove(at: index)
    }

    /// Find and remove the oldest QUESTION request matching sessionId and toolName.
    /// Fallback cleanup for AskUserQuestion cards, which the user answers in the terminal
    /// (no toolUseId, no in-GUI resolution). Restricted to `.question` + matching toolName
    /// so a completion can never dequeue a still-pending toolPermission request for the
    /// same session/tool.
    func dequeueQuestionBySessionAndTool(sessionId: String, toolName: String) -> PermissionRequest? {
        guard let index = items.firstIndex(where: {
            $0.requestType == .question
                && $0.sessionId == sessionId
                && $0.toolName == toolName
        }) else { return nil }
        return items.remove(at: index)
    }

    /// Find and remove the oldest toolPermission request matching session, tool, AND input.
    /// Cleans up a card whose tool actually ran (PostToolUse completion) after being approved
    /// OUTSIDE the GUI (phone/remote) — there resolveRequest never fires and the card would
    /// otherwise linger until the 300s hook timeout. Matching on inputSignature (not just
    /// session+tool) prevents an unrelated same-tool completion from dequeuing a different
    /// still-pending request (the prior over-deny bug).
    func dequeueToolPermissionMatching(sessionId: String, toolName: String, inputSignature: String) -> PermissionRequest? {
        guard !inputSignature.isEmpty else { return nil }
        guard let index = items.firstIndex(where: {
            $0.requestType == .toolPermission
                && $0.sessionId == sessionId
                && $0.toolName == toolName
                && $0.inputSignature == inputSignature
        }) else { return nil }
        return items.remove(at: index)
    }

    /// Find and remove EVERY planApproval request of the session.
    /// Plan cards are usually answered in the terminal, and neither a terminal approve nor a
    /// terminal reject can be matched by toolUseId (PermissionRequest carries none). The main
    /// agent cannot run any tool while its plan approval is pending, so a main-agent
    /// completion in the same session means the plan gate has been passed — approved
    /// (ExitPlanMode ran) or rejected (the model resumed planning). All pending plan cards of
    /// that session are therefore stale, not just the oldest one.
    /// Restricted to `.planApproval` so a completion can never dequeue (and wrongly deny) a
    /// still-pending toolPermission or question card.
    func dequeuePlanApprovals(sessionId: String) -> [PermissionRequest] {
        guard !sessionId.isEmpty else { return [] }
        let stale = items.filter { $0.requestType == .planApproval && $0.sessionId == sessionId }
        items.removeAll { $0.requestType == .planApproval && $0.sessionId == sessionId }
        return stale
    }

    func clear() {
        items.removeAll()
    }
}
