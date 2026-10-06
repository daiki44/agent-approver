import Foundation

/// Risk level for a permission request, derived from heuristic pattern matching.
enum RiskLevel: String, Sendable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: return "⚠ High Risk"
        case .medium: return "● Medium"
        case .low: return "○ Low Risk"
        }
    }
}

/// A permission request received from a Claude Code Hook.
struct PermissionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    let toolInput: [String: Any]
    let toolUseId: String
    let sessionId: String
    let cwd: String
    let tty: String?
    let receivedAt: Date
    let permissionSuggestions: [[String: Any]]

    /// Request type for contextual UX
    var requestType: RequestType {
        RequestType.classify(toolName: toolName)
    }

    /// Canonical (sorted-key JSON) signature of toolInput. Used to correlate a PostToolUse
    /// completion to this request when the request carries no toolUseId — e.g. to clean up a
    /// card that was approved outside the GUI (phone/remote).
    var inputSignature: String {
        Self.canonicalSignature(toolInput)
    }

    static func canonicalSignature(_ input: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    /// Question text for AskUserQuestion requests.
    /// Supports both `question` (string) and `questions` (array of objects) formats.
    var questionText: String? {
        guard requestType == .question else { return nil }
        // Direct `question` key (string)
        if let q = toolInput["question"] as? String {
            return q
        }
        // `questions` array format: [{"question": "...", "options": [...]}]
        if let questions = toolInput["questions"] as? [[String: Any]],
           let first = questions.first,
           let q = first["question"] as? String {
            return q
        }
        // `questions` as plain string
        if let q = toolInput["questions"] as? String {
            return q
        }
        return toolInput["prompt"] as? String
    }

    /// Options for AskUserQuestion requests.
    /// Supports both `options` (top-level) and `questions[0].options` formats.
    var questionOptions: [String]? {
        guard requestType == .question else { return nil }
        // Direct `options` key
        if let opts = toolInput["options"] as? [String] {
            return opts
        }
        // `questions` array format: [{"question": "...", "options": [...]}]
        if let questions = toolInput["questions"] as? [[String: Any]],
           let first = questions.first,
           let opts = first["options"] as? [String] {
            return opts
        }
        return nil
    }

    /// Plan text for ExitPlanMode requests
    var planText: String? {
        guard requestType == .planApproval else { return nil }
        return toolInput["plan"] as? String
            ?? toolInput["content"] as? String
    }

    /// Pre-approved tool calls shown in plan approval UI
    var allowedPrompts: [(tool: String, prompt: String)]? {
        guard requestType == .planApproval else { return nil }
        guard let prompts = toolInput["allowedPrompts"] as? [[String: Any]] else { return nil }
        return prompts.compactMap { dict in
            guard let tool = dict["tool"] as? String,
                  let prompt = dict["prompt"] as? String else { return nil }
            return (tool: tool, prompt: prompt)
        }
    }

    /// Human-readable command summary
    var displayCommand: String {
        if let command = toolInput["command"] as? String {
            return command
        }
        if let filePath = toolInput["file_path"] as? String {
            return filePath
        }
        if let pattern = toolInput["pattern"] as? String {
            return pattern
        }
        // Fallback: show first string value or tool name
        for (_, value) in toolInput {
            if let str = value as? String, !str.isEmpty {
                return String(str.prefix(120))
            }
        }
        return toolName
    }

    /// Short project name from cwd
    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// SF Symbol name for the tool type
    var iconName: String {
        switch requestType {
        case .question: return "questionmark.bubble"
        case .planApproval: return "doc.text.magnifyingglass"
        case .toolPermission:
            switch toolName {
            case "Bash": return "terminal"
            case "Write": return "doc.badge.plus"
            case "Edit": return "pencil"
            case "Read": return "doc.text"
            case "Glob", "Grep": return "magnifyingglass"
            default:
                if toolName.hasPrefix("mcp__") { return "network" }
                return "lock.shield"
            }
        }
    }

    /// Relative time string
    var timeAgo: String {
        let interval = Date().timeIntervalSince(receivedAt)
        if interval < 60 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    /// Heuristic risk level based on command patterns
    var riskLevel: RiskLevel {
        let cmd = displayCommand.lowercased()
        let highRiskPatterns = ["rm ", "rm -", "git push", "git reset", "drop ", "delete ", "curl ", "wget "]
        let mediumRiskPatterns = ["git commit", "npm install", "pip install", "brew ", "chmod ", "chown "]
        if highRiskPatterns.contains(where: { cmd.contains($0) }) { return .high }
        if mediumRiskPatterns.contains(where: { cmd.contains($0) }) { return .medium }
        return .low
    }

    // MARK: - Edit Tool Properties

    /// Whether this is an Edit tool request
    var isEditTool: Bool { toolName == "Edit" }

    /// Whether this is a Write tool request
    var isWriteTool: Bool { toolName == "Write" }

    /// File path for Edit/Write operations
    var editFilePath: String? {
        toolInput["file_path"] as? String
    }

    /// Short file name for display
    var editFileName: String? {
        guard let path = editFilePath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Old string being replaced (Edit tool)
    var editOldString: String? {
        guard isEditTool else { return nil }
        return toolInput["old_string"] as? String
    }

    /// New string to replace with (Edit tool)
    var editNewString: String? {
        guard isEditTool else { return nil }
        return toolInput["new_string"] as? String
    }

    /// Whether replace_all is enabled (Edit tool)
    var editReplaceAll: Bool {
        guard isEditTool else { return false }
        return toolInput["replace_all"] as? Bool ?? false
    }

    /// Content being written (Write tool)
    var writeContent: String? {
        guard isWriteTool else { return nil }
        return toolInput["content"] as? String
    }

    /// Shortened path with ~ for home directory
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    /// First 8 chars of session ID for compact display
    var shortSessionId: String {
        String(sessionId.prefix(8))
    }

    // MARK: - Equatable (ignore toolInput since [String: Any] isn't Equatable)
    static func == (lhs: PermissionRequest, rhs: PermissionRequest) -> Bool {
        lhs.id == rhs.id
    }
}
