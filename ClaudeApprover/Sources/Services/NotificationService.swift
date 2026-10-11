import AppKit
import Foundation
import UserNotifications

/// Manages native macOS notifications for incoming permission requests.
/// Gracefully handles cases where UNUserNotificationCenter is unavailable
/// (e.g., when running outside a proper .app bundle).
/// @unchecked Sendable: center is set once in init() and only read thereafter.
/// NSObject conformance prevents automatic Sendable synthesis.
final class NotificationService: NSObject, @unchecked Sendable {
    static let shared = NotificationService()
    private var center: UNUserNotificationCenter?

    private override init() {
        super.init()
        // UNUserNotificationCenter requires a proper app bundle.
        // Lazily attempt to get it; if it fails, notifications are disabled.
        do {
            let c = try Self.getCenter()
            self.center = c
            c.delegate = self
            writeLog("Notification center initialized successfully")
        } catch {
            writeLog("Notifications unavailable: \(error.localizedDescription)")
        }
    }

    private static func getCenter() throws -> UNUserNotificationCenter {
        // Check if we have a valid bundle identifier (required for notifications).
        // A bundle id alone is not enough: processes like xctest have one but are not an
        // .app, and UNUserNotificationCenter.current() raises there.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            throw NotificationError.noBundleIdentifier
        }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                self?.writeLog("Authorization error: \(error.localizedDescription)")
            }
            self?.writeLog("Authorization result: granted=\(granted)")
        }

        // Register notification categories
        let permissionCategory = UNNotificationCategory(
            identifier: "PERMISSION_REQUEST",
            actions: [],
            intentIdentifiers: []
        )
        center?.setNotificationCategories([permissionCategory])
    }

    /// Remove all delivered notification banners from Notification Center.
    /// Called when the popover opens to prevent lingering banners from overlaying buttons.
    func removeAllDelivered() {
        center?.removeAllDeliveredNotifications()
    }

    /// Remove a specific delivered notification by request ID.
    /// Called when a request is resolved or cancelled (e.g. handled in terminal).
    func removeDelivered(requestId: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [requestId.uuidString])
    }

    func notify(request: PermissionRequest) {
        guard let center else {
            writeLog("notify: center is nil, skipping notification for \(request.toolName)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude Approver"
        content.sound = .default
        content.categoryIdentifier = "PERMISSION_REQUEST"

        switch request.requestType {
        case .toolPermission:
            content.subtitle = request.toolName
            content.body = request.displayCommand
        case .question:
            content.subtitle = "Claude has a question"
            content.body = request.questionText ?? request.displayCommand
        case .planApproval:
            content.subtitle = "Plan needs approval"
            content.body = String((request.planText ?? request.displayCommand).prefix(200))
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let notifRequest = UNNotificationRequest(
            identifier: request.id.uuidString,
            content: content,
            trigger: trigger
        )
        center.add(notifRequest) { [weak self] error in
            if let error {
                self?.writeLog("Failed to add notification: \(error.localizedDescription)")
            } else {
                self?.writeLog("Notification added for \(request.toolName) (id: \(request.id.uuidString))")
            }
        }
    }

    // MARK: - File-based logging

    private func writeLog(_ message: String) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeApprover")
        let logPath = logDir.appendingPathComponent("notification.log")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [NotificationService] \(message)\n"

        // Ensure log directory exists
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

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
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Suppress banners only when the popover is visible AND the app is frontmost.
        // When the user is in another app, the popover is not visible even if "shown",
        // so we must deliver banners to notify them of new requests.
        let shouldSuppress = await MainActor.run {
            guard let delegate = AppDelegate.shared else { return false }
            return delegate.isPopoverShown && NSApp.isActive
        }
        if shouldSuppress {
            return []
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Permission request notification — activate Approver
        await MainActor.run {
            if let delegate = AppDelegate.shared {
                delegate.showPopover()
            }
        }
    }
}

private enum NotificationError: LocalizedError {
    case noBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .noBundleIdentifier:
            return "No bundle identifier - run as .app bundle for notifications"
        }
    }
}
