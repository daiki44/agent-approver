import Foundation

/// Unix Domain Socket server that receives permission requests from Hook scripts
/// and resolves them when the user makes a decision in the UI.
///
/// Architecture: All blocking I/O (accept, recv, send) runs on GCD threads,
/// NOT on the actor executor. Only state mutations (pendingHandlers, onRequest)
/// are actor-isolated and accessed via `await`.
actor SocketServer {
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false

    /// Pending continuations keyed by request_id, resolved when user decides
    private var pendingHandlers: [UUID: CheckedContinuation<DecisionResponse, Never>] = [:]

    /// Callback when a new permission request arrives
    var onRequest: (@Sendable (PermissionRequest) -> Void)?

    /// Callback when a request is cancelled (hook script died / terminal handled it)
    var onCancel: (@Sendable (UUID) -> Void)?

    /// Callback when a tool execution completes (PostToolUse hook notification)
    var onCompletion: (@Sendable (ToolCompletion) -> Void)?

    init() {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeApprover")
        self.socketPath = supportDir.appendingPathComponent("claude-approver.sock").path
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else {
            debugLog("Already running, skipping start")
            return
        }

        debugLog("Starting... socketPath=\(socketPath)")

        // Ensure directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Restrict socket directory access to current user only
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir
        )

        // Remove stale socket file
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
            debugLog("Removed stale socket")
        }

        // Create socket
        serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr)
                    .assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw SocketError.bindFailed(errno: errno)
        }

        // Listen
        guard Darwin.listen(serverFD, 16) == 0 else {
            Darwin.close(serverFD)
            throw SocketError.listenFailed(errno: errno)
        }

        isRunning = true
        debugLog("Listening on \(socketPath)")

        // Start accept loop on GCD (NOT on actor executor)
        let fd = serverFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
    }

    func shutdown() {
        isRunning = false

        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Deny all pending requests
        let handlers = pendingHandlers
        pendingHandlers.removeAll()
        for (_, continuation) in handlers {
            continuation.resume(returning: .deny)
        }
    }

    // MARK: - Actor-isolated state accessors

    func storeContinuation(_ id: UUID, _ continuation: CheckedContinuation<DecisionResponse, Never>) {
        pendingHandlers[id] = continuation
    }

    /// Called by ViewModel when user taps Allow/Deny
    func resolve(requestId: UUID, decision: DecisionResponse) {
        guard let continuation = pendingHandlers.removeValue(forKey: requestId) else {
            debugLog("WARNING: resolve() continuation not found for \(requestId)")
            return
        }
        continuation.resume(returning: decision)
    }

    /// Cancel a pending request and notify UI to remove it from queue
    func cancelAndNotify(_ id: UUID) {
        if let cont = pendingHandlers.removeValue(forKey: id) {
            cont.resume(returning: .deny)
        } else {
            debugLog("WARNING: cancelAndNotify() continuation not found for \(id)")
        }
        onCancel?(id)
    }

    /// Clean up a request that was resolved OUTSIDE the GUI (e.g. approved on phone/remote),
    /// detected via its PostToolUse completion. Resumes the orphaned hook with passthrough so
    /// it can never wrongly deny a still-pending request (unlike cancelAndNotify, which denies),
    /// then notifies the UI to remove the card.
    func passthroughAndNotify(_ id: UUID) {
        if let cont = pendingHandlers.removeValue(forKey: id) {
            cont.resume(returning: .passthrough)
        }
        onCancel?(id)
    }

    func getOnRequest() -> (@Sendable (PermissionRequest) -> Void)? {
        onRequest
    }

    func getOnCompletion() -> (@Sendable (ToolCompletion) -> Void)? {
        onCompletion
    }

    // MARK: - Accept Loop (runs on GCD, NOT on actor)

    nonisolated private func acceptLoop(serverFD: Int32) {
        while true {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            if clientFD < 0 { break }

            // Handle each connection on its own GCD thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    return
                }
                self.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection Handling (runs on GCD, NOT on actor)

    nonisolated private func handleConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }

        // Read 4-byte length header
        guard let header = readExact(fd: fd, count: 4) else { return }
        let bodyLen = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard bodyLen > 0, bodyLen < 1_000_000 else { return }

        // Read JSON body
        guard let body = readExact(fd: fd, count: Int(bodyLen)),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }

        // Dispatch by message type
        let messageType = json["type"] as? String
        if messageType == "completion" {
            handleCompletionMessage(json)
            return
        }

        // Permission request flow: requires request_id
        guard let requestIdStr = json["request_id"] as? String,
              let requestId = UUID(uuidString: requestIdStr)
        else { return }

        // Parse into PermissionRequest
        let request = PermissionRequest(
            id: requestId,
            toolName: json["tool_name"] as? String ?? "Unknown",
            toolInput: json["tool_input"] as? [String: Any] ?? [:],
            toolUseId: json["tool_use_id"] as? String ?? "",
            sessionId: json["session_id"] as? String ?? "",
            cwd: json["cwd"] as? String ?? "",
            tty: json["tty"] as? String,
            receivedAt: Date(),
            permissionSuggestions: json["permission_suggestions"] as? [[String: Any]] ?? []
        )

        // Bridge blocking GCD thread to Swift concurrency
        let semaphore = DispatchSemaphore(value: 0)
        let decisionBox = UnsafeSendableBox<DecisionResponse>(.deny)
        let cancelledBox = UnsafeSendableBox<Bool>(false)

        // Store continuation FIRST, then notify UI.
        // This guarantees pendingHandlers[requestId] exists before the user
        // can see and interact with the request, preventing the race condition
        // where resolve() runs before storeContinuation() completes.
        Task { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }

            let callback = await self.getOnRequest()

            let result = await withCheckedContinuation { (continuation: CheckedContinuation<DecisionResponse, Never>) in
                Task {
                    await self.storeContinuation(requestId, continuation)
                    callback?(request)
                }
            }
            decisionBox.value = result
            semaphore.signal()
        }

        // Monitor socket for remote close (hook script died / terminal handled it).
        // When the hook process is killed or exits, the kernel closes the socket,
        // and DispatchSource fires so we can clean up the request from the queue.
        //
        // Both monitorSource and timerSource detect remote close independently.
        // cancelledBox prevents double-signal: the first to detect cancels the other.
        let monitorSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        let timerSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

        monitorSource.setEventHandler { [weak self] in
            guard !cancelledBox.value else { return }
            var buf = UInt8(0)
            let n = Darwin.recv(fd, &buf, 1, Int32(MSG_PEEK))
            if n <= 0 {
                cancelledBox.value = true
                timerSource.cancel()
                Task { [weak self] in
                    await self?.cancelAndNotify(requestId)
                }
                semaphore.signal()
            }
        }
        monitorSource.resume()

        // Timer-based polling as a secondary detection mechanism.
        // DispatchSource.makeReadSource may not reliably fire for FIN on UDS,
        // so we poll every 0.5 seconds with a non-blocking MSG_PEEK recv.
        timerSource.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timerSource.setEventHandler { [weak self] in
            guard !cancelledBox.value else { return }
            var buf = UInt8(0)
            let n = Darwin.recv(fd, &buf, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            if n == 0 {
                // FIN received — remote end closed gracefully
                cancelledBox.value = true
                monitorSource.cancel()
                Task { [weak self] in
                    await self?.cancelAndNotify(requestId)
                }
                semaphore.signal()
            } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                // Connection broken
                cancelledBox.value = true
                monitorSource.cancel()
                Task { [weak self] in
                    await self?.cancelAndNotify(requestId)
                }
                semaphore.signal()
            }
            // EAGAIN/EWOULDBLOCK = socket alive, no data — continue polling
        }
        timerSource.resume()

        // Block this GCD thread until: user decision, remote close, or timeout
        let waitResult = semaphore.wait(timeout: .now() + 300)
        monitorSource.cancel()
        timerSource.cancel()

        if cancelledBox.value {
            // Connection already closed — no response to send
            return
        }

        if waitResult == .timedOut {
            decisionBox.value = .deny
            Task { [weak self] in
                await self?.cancelAndNotify(requestId)
            }
        }

        let decision = decisionBox.value

        // Passthrough: close connection without sending a response.
        // Hook script receives EOF → returns None → exits with code 1 → passthrough.
        if decision.behavior == "passthrough" {
            return
        }

        // Send response back to Hook — extended format with message/updatedPermissions
        var response = decision.toJSON()
        response["request_id"] = requestIdStr
        guard let responseData = try? JSONSerialization.data(withJSONObject: response) else { return }

        var lengthHeader = UInt32(responseData.count).bigEndian
        let headerData = Data(bytes: &lengthHeader, count: 4)

        _ = headerData.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress!, 4, 0)
        }
        _ = responseData.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress!, responseData.count, 0)
        }
    }

    // MARK: - Completion Message (fire-and-forget from PostToolUse hook)

    nonisolated private func handleCompletionMessage(_ json: [String: Any]) {
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let completion = ToolCompletion(
            toolUseId: json["tool_use_id"] as? String ?? "",
            sessionId: json["session_id"] as? String ?? "",
            toolName: json["tool_name"] as? String ?? "",
            inputSignature: PermissionRequest.canonicalSignature(toolInput)
        )
        debugLog("handleCompletionMessage: tool=\(completion.toolName) session=\(completion.sessionId.prefix(8)) tool_use_id=\(completion.toolUseId)")
        Task { [weak self] in
            guard let callback = await self?.getOnCompletion() else { return }
            callback(completion)
        }
    }

    // MARK: - Debug Logging

    nonisolated private func debugLog(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/approver_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [SocketServer] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
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

    // MARK: - I/O Helpers

    nonisolated private func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var totalRead = 0
        while totalRead < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.recv(fd, ptr.baseAddress!.advanced(by: totalRead), count - totalRead, 0)
            }
            if n <= 0 { return nil }
            totalRead += n
        }
        return buffer
    }
}

// MARK: - Sendable Box

/// Thread-unsafe box that allows mutating a captured value across concurrency boundaries.
/// Safety is guaranteed by the caller via DispatchSemaphore synchronization.
private final class UnsafeSendableBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Tool Completion

struct ToolCompletion: Sendable {
    let toolUseId: String
    let sessionId: String
    let toolName: String
    let inputSignature: String
}

// MARK: - Errors

enum SocketError: Error, LocalizedError {
    case createFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .createFailed(let e): return "Socket create failed: \(String(cString: strerror(e)))"
        case .bindFailed(let e): return "Socket bind failed: \(String(cString: strerror(e)))"
        case .listenFailed(let e): return "Socket listen failed: \(String(cString: strerror(e)))"
        }
    }
}
