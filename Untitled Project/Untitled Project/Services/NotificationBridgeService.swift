import Foundation
import UserNotifications
import AppKit

/// Bridges Android notifications to macOS via UNUserNotificationCenter.
/// Supports inline reply actions and automatic OTP code extraction & clipboard copy.
@MainActor
@Observable
final class NotificationBridgeService: NSObject {

    // MARK: - Configuration

    var isOTPAutoCopyEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isOTPAutoCopyEnabled, forKey: "otpAutoCopyEnabled")
        }
    }

    // MARK: - State

    private(set) var recentNotifications: [NotificationRecord] = []
    private let maxRecentNotifications = 50

    /// Callback invoked when user replies to a notification inline.
    var onReply: ((String, String) -> Void)?  // (notificationId, replyText)

    // MARK: - Types

    struct NotificationRecord: Identifiable {
        let id: String
        let appName: String
        let title: String
        let body: String
        let isOTP: Bool
        let otpCode: String?
        let receivedAt: Date
    }

    // MARK: - Private

    private static let otpRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b(\\d{4,8})\\b", options: [])
    }()

    // MARK: - Setup

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                print("[NotificationBridge] Authorization granted")
            } else {
                print("[NotificationBridge] Authorization denied")
            }
        } catch {
            print("[NotificationBridge] Authorization error: \(error)")
        }

        // Register action categories
        setupCategories()

        // Set ourselves as delegate
        center.delegate = self

        // Load persisted OTP setting
        if UserDefaults.standard.object(forKey: "otpAutoCopyEnabled") != nil {
            isOTPAutoCopyEnabled = UserDefaults.standard.bool(forKey: "otpAutoCopyEnabled")
        }
    }

    private func setupCategories() {
        // Reply action for messaging notifications
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )

        let messageCategory = UNNotificationCategory(
            identifier: "ANDROID_MESSAGE",
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )

        // OTP category with copy action
        let copyAction = UNNotificationAction(
            identifier: "COPY_OTP_ACTION",
            title: "Copy OTP",
            options: [.foreground]
        )

        let otpCategory = UNNotificationCategory(
            identifier: "ANDROID_OTP",
            actions: [copyAction],
            intentIdentifiers: [],
            options: []
        )

        // Generic notification category
        let genericCategory = UNNotificationCategory(
            identifier: "ANDROID_NOTIFICATION",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            messageCategory, otpCategory, genericCategory
        ])
    }

    // MARK: - Post Notification

    func postNotification(from payload: NotificationPayload) async {
        let content = UNMutableNotificationContent()
        content.title = "\(payload.appName): \(payload.title)"
        content.body = payload.body
        content.sound = .default
        content.userInfo = [
            "notificationId": payload.id,
            "appName": payload.appName
        ]

        // Set appropriate category
        if payload.isOTP, let otp = payload.otpCode ?? extractOTP(from: payload.body) {
            content.categoryIdentifier = "ANDROID_OTP"
            content.userInfo["otpCode"] = otp

            // Auto-copy OTP if enabled
            if isOTPAutoCopyEnabled {
                copyToClipboard(otp)
                content.subtitle = "OTP \(otp) copied to clipboard"
            }
        } else {
            content.categoryIdentifier = "ANDROID_MESSAGE"
        }

        let request = UNNotificationRequest(
            identifier: payload.id,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[NotificationBridge] Failed to post: \(error)")
        }

        // Track in recent list
        let record = NotificationRecord(
            id: payload.id,
            appName: payload.appName,
            title: payload.title,
            body: payload.body,
            isOTP: payload.isOTP,
            otpCode: payload.otpCode ?? extractOTP(from: payload.body),
            receivedAt: Date()
        )

        recentNotifications.insert(record, at: 0)
        if recentNotifications.count > maxRecentNotifications {
            recentNotifications = Array(recentNotifications.prefix(maxRecentNotifications))
        }
    }

    // MARK: - OTP Extraction

    private func extractOTP(from text: String) -> String? {
        guard let regex = Self.otpRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        guard let otpRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[otpRange])
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationBridgeService: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let notificationId = userInfo["notificationId"] as? String ?? ""

        switch response.actionIdentifier {
        case "REPLY_ACTION":
            if let textResponse = response as? UNTextInputNotificationResponse {
                let replyText = textResponse.userText
                await MainActor.run {
                    onReply?(notificationId, replyText)
                }
            }

        case "COPY_OTP_ACTION":
            if let otp = userInfo["otpCode"] as? String {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(otp, forType: .string)
                }
            }

        default:
            break
        }
    }
}
