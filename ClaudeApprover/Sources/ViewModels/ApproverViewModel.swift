import AppKit
import Foundation

/// Main ViewModel coordinating the socket server, request queue, and UI.
@Observable
@MainActor
final class ApproverViewModel {
    let queue = RequestQueue()
    private let server = SocketServer()
    private(set) var isDemoMode = false
    private let notificationService = NotificationService.shared

    /// Whether the approval panel is the key window (keyboard shortcuts active).
    /// Set by AppDelegate via ApprovalPanelController.onKeyWindowChanged.
    var isKeyboardShortcutsActive = false

    /// Tracks request IDs that were cancelled before being enqueued (race condition fix)
    private var earlyCancelledIds: Set<UUID> = []

    /// Sessions where user enabled "Auto-approve file edits" (acceptEdits mode).
    /// Workaround for Claude Code race condition: when mode switch via updatedPermissions
    /// hasn't been applied before the next Edit/Write permission check fires.
    private var autoApproveEditSessions: Set<String> = []

    /// Tool names that are auto-approved in acceptEdits mode
    private static let editToolNames: Set<String> = ["Edit", "Write", "NotebookEdit"]

    func start() async {
        notificationService.requestAuthorization()

        // Wire up the server's onRequest callback
        await server.setOnRequest { [weak self] request in
            let vm = self
            Task { @MainActor in
                vm?.handleIncomingRequest(request)
            }
        }

        // Wire up the server's onCancel callback.
        // Fires when the hook script dies (terminal handled it, session ended, etc.)
        await server.setOnCancel { [weak self] requestId in
            let vm = self
            Task { @MainActor in
                vm?.handleCancelledRequest(requestId)
            }
        }

        // Wire up the server's onCompletion callback.
        // Fires when PostToolUse hook reports tool execution completed.
        // Acts as a safety net: if EOF detection missed the close, this removes the stale request.
        await server.setOnCompletion { [weak self] completion in
            let vm = self
            Task { @MainActor in
                vm?.handleToolCompletion(completion)
            }
        }

        do {
            try await server.start()
        } catch {
            debugLog("Failed to start socket server: \(error)")
        }
    }

    /// デモモード: モックデータを直接キューに投入（SocketServer 不要）
    func loadDemoData() {
        isDemoMode = true
        for request in DemoDataProvider.mockRequests() {
            queue.enqueue(request)
        }
    }

    func shutdown() async {
        await server.shutdown()
    }

    // MARK: - Request Handling

    private func handleIncomingRequest(_ request: PermissionRequest) {
        debugLog("handleIncomingRequest: tool=\(request.toolName) type=\(request.requestType) id=\(request.id) toolUseId=\(request.toolUseId)")
        if let inputKeys = (request.toolInput as NSDictionary).allKeys as? [String] {
            debugLog("  input_keys=\(inputKeys)")
        }

        // Race condition fix: if this request was already cancelled before enqueue, skip it
        if earlyCancelledIds.remove(request.id) != nil {
            debugLog("  skipped enqueue: already cancelled (early cancel)")
            return
        }

        // Auto-approve Edit/Write/NotebookEdit if session has acceptEdits mode active.
        // This works around Claude Code's race condition where updatedPermissions
        // mode switch hasn't been applied before the next permission check fires.
        if autoApproveEditSessions.contains(request.sessionId),
           request.requestType == .toolPermission,
           Self.editToolNames.contains(request.toolName) {
            debugLog("  auto-approved: tool=\(request.toolName) session=\(request.shortSessionId) (acceptEdits mode active)")
            Task {
                await server.resolve(requestId: request.id, decision: .allow)
            }
            return
        }

        queue.enqueue(request)

        // UX: open popover FIRST so the app is active and willPresent sees it as shown.
        // This prevents notification banners from overlaying the popover buttons.
        if let delegate = AppDelegate.shared {
            debugLog("  calling showPopover()")
            delegate.showPopover()
            delegate.playAttentionSound()
            delegate.bounceButton()
            debugLog("  showPopover() completed")
        }

        // Send notification AFTER popover is shown — banners suppressed by willPresent
        // when app is active. When app is inactive, banners are delivered normally.
        notificationService.notify(request: request)

        updateAppDelegate()
    }

    /// Remove a request that was cancelled (handled in terminal or hook died).
    /// If the request hasn't been enqueued yet (race condition), record it for early skip.
    private func handleCancelledRequest(_ requestId: UUID) {
        if queue.dequeue(id: requestId) != nil {
            debugLog("handleCancelledRequest: dequeued id=\(requestId)")
            notificationService.removeDelivered(requestId: requestId)
            updateAppDelegate()
        } else {
            debugLog("handleCancelledRequest: early cancel id=\(requestId)")
            earlyCancelledIds.insert(requestId)
        }
    }

    /// Remove a request whose tool execution has completed (PostToolUse safety net).
    /// Idempotent: if the request was already removed by EOF detection or user action, this is a no-op.
    ///
    /// Matching strategy:
    /// 0. Plan cards (ExitPlanMode): any completion in the session sweeps them, independently of
    ///    the strategies below — see `RequestQueue.dequeuePlanApprovals`. Cleaned up via
    ///    passthrough, so a rare false positive only drops the GUI card (the terminal dialog
    ///    stays usable) and can never wrongly deny.
    /// 1. Exact match by toolUseId — safe for any request type.
    /// 2. Fallback for QUESTION requests only (AskUserQuestion). Questions are answered in
    ///    the terminal (answers can't be injected via hooks), so they carry no toolUseId and
    ///    are never resolved in the GUI — a PostToolUse completion is their only automatic
    ///    cleanup. The fallback is restricted to `.question` + matching toolName so a
    ///    completion can NEVER dequeue (and wrongly deny) a still-pending toolPermission
    ///    request for the same tool/session — the bug that made the GUI "unresponsive".
    func handleToolCompletion(_ completion: ToolCompletion) {
        // 0. Stale plan cards of this session (answered in the terminal). Not an early return:
        //    the same completion may also clean up a card below.
        let stalePlans = queue.dequeuePlanApprovals(sessionId: completion.sessionId)
        for request in stalePlans {
            cleanupCompleted(request, completion, viaPassthrough: true)
        }
        // 1. Exact toolUseId match — safe for any request type.
        if !completion.toolUseId.isEmpty,
           let request = queue.dequeueByToolUseId(completion.toolUseId) {
            cleanupCompleted(request, completion, viaPassthrough: false)
            return
        }
        // 2. Question fallback (AskUserQuestion answered in the terminal).
        if !completion.sessionId.isEmpty,
           let request = queue.dequeueQuestionBySessionAndTool(
               sessionId: completion.sessionId, toolName: completion.toolName) {
            cleanupCompleted(request, completion, viaPassthrough: false)
            return
        }
        // 3. toolPermission approved OUTSIDE the GUI (phone/remote): the tool ran, so a
        //    completion arrived, but resolveRequest never fired and the card would linger
        //    until the 300s hook timeout. Match by session+tool+input (input prevents
        //    dequeuing a different still-pending request) and clean up via passthrough so a
        //    rare duplicate-command collision can never wrongly deny.
        if !completion.sessionId.isEmpty,
           let request = queue.dequeueToolPermissionMatching(
               sessionId: completion.sessionId,
               toolName: completion.toolName,
               inputSignature: completion.inputSignature) {
            cleanupCompleted(request, completion, viaPassthrough: true)
            return
        }
        guard stalePlans.isEmpty else { return }
        debugLog("handleToolCompletion: no-op (no match) tool=\(completion.toolName) session=\(completion.sessionId.prefix(8))")
    }

    private func cleanupCompleted(_ request: PermissionRequest, _ completion: ToolCompletion, viaPassthrough: Bool) {
        debugLog("handleToolCompletion: dequeued id=\(request.id) tool=\(completion.toolName) session=\(completion.sessionId.prefix(8)) passthrough=\(viaPassthrough)")
        notificationService.removeDelivered(requestId: request.id)
        Task {
            if viaPassthrough {
                await server.passthroughAndNotify(request.id)
            } else {
                await server.cancelAndNotify(request.id)
            }
        }
        updateAppDelegate()
    }

    // MARK: - User Actions

    func allow(requestId: UUID) {
        resolveRequest(requestId: requestId, decision: .allow)
    }

    func deny(requestId: UUID) {
        resolveRequest(requestId: requestId, decision: .deny)
    }

    func denyWithMessage(requestId: UUID, message: String) {
        resolveRequest(requestId: requestId, decision: .denyWith(message: message))
    }

    func alwaysAllow(requestId: UUID, permissions: [[String: Any]]) {
        // Track session for client-side auto-approve if setMode/acceptEdits
        if let request = queue.items.first(where: { $0.id == requestId }),
           !request.sessionId.isEmpty,
           permissions.contains(where: { Self.isSetModeAcceptEdits($0) }) {
            autoApproveEditSessions.insert(request.sessionId)
            trimAutoApproveEditSessions()
            debugLog("alwaysAllow: acceptEdits mode enabled for session=\(request.shortSessionId)")
        }
        resolveRequest(requestId: requestId, decision: .allowWith(permissions: permissions))
    }

    /// Dismiss a request without sending a response (passthrough).
    /// Used for "Go to Terminal" — lets Claude Code handle the tool normally.
    func dismiss(requestId: UUID) {
        debugLog("dismiss: id=\(requestId) (passthrough)")
        resolveRequest(requestId: requestId, decision: .passthrough)
    }

    /// Dismiss a question and switch focus to the terminal.
    func goToTerminalForQuestion(requestId: UUID) {
        debugLog("goToTerminalForQuestion: id=\(requestId)")
        let tty = queue.items.first(where: { $0.id == requestId })?.tty
        resolveRequest(requestId: requestId, decision: .passthrough)
        // Activate terminal FIRST, then close popover to avoid macOS restoring
        // focus to the previously-active app (e.g. Slack) during orderOut.
        TerminalNavigator.navigate(tty: tty)
        if let delegate = AppDelegate.shared {
            delegate.closePopover()
        }
    }

    func approvePlan(requestId: UUID, mode: PlanApprovalMode) {
        debugLog("approvePlan: id=\(requestId) mode=\(mode.label)")
        resolveRequest(requestId: requestId, decision: .allowPlan(mode: mode))
    }

    func allowAll() {
        let items = queue.items
        queue.clear()
        if !isDemoMode {
            for item in items {
                Task {
                    await server.resolve(requestId: item.id, decision: .allow)
                }
            }
        }
        updateAppDelegate()
    }

    func denyAll() {
        let items = queue.items
        queue.clear()
        if !isDemoMode {
            for item in items {
                Task {
                    await server.resolve(requestId: item.id, decision: .deny)
                }
            }
        }
        updateAppDelegate()
    }

    private func resolveRequest(requestId: UUID, decision: DecisionResponse) {
        guard let request = queue.dequeue(id: requestId) else { return }
        debugLog("resolveRequest: id=\(requestId) behavior=\(decision.behavior) message=\(decision.message ?? "nil") toolUseId='\(request.toolUseId)'")
        notificationService.removeDelivered(requestId: requestId)

        if !isDemoMode {
            Task {
                await server.resolve(requestId: requestId, decision: decision)
            }
        }
        updateAppDelegate()
    }

    // MARK: - Badge

    private func updateAppDelegate() {
        guard let delegate = AppDelegate.shared else { return }
        updateBadge()

        // Auto-close popover when all requests have been handled
        // (skip in demo mode — user is taking screenshots)
        if queue.isEmpty && !isDemoMode {
            delegate.closePopover()
        }
    }

    private func updateBadge() {
        guard let delegate = AppDelegate.shared else { return }
        delegate.updateBadge(count: queue.count)
    }

    // MARK: - Auto-Approve Helpers

    /// Check if a permission suggestion is a setMode/acceptEdits request
    private static func isSetModeAcceptEdits(_ suggestion: [String: Any]) -> Bool {
        suggestion["type"] as? String == "setMode"
            && suggestion["mode"] as? String == "acceptEdits"
    }

    private func trimAutoApproveEditSessions() {
        if autoApproveEditSessions.count > 50 {
            autoApproveEditSessions.removeAll()
        }
    }

    // MARK: - Debug Logging

    private func debugLog(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/approver_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [ViewModel] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logPath)
            }
        }
    }
}

// MARK: - SocketServer helpers to set callbacks from MainActor

extension SocketServer {
    func setOnRequest(_ handler: @escaping @Sendable (PermissionRequest) -> Void) {
        self.onRequest = handler
    }

    func setOnCancel(_ handler: @escaping @Sendable (UUID) -> Void) {
        self.onCancel = handler
    }

    func setOnCompletion(_ handler: @escaping @Sendable (ToolCompletion) -> Void) {
        self.onCompletion = handler
    }
}
