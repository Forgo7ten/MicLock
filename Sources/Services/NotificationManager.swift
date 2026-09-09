import Foundation
import UserNotifications
import OSLog

/// UserNotifications 真实实现。
///
/// 授权流程：先读当前状态，`notDetermined` 才调用 `requestAuthorization`
/// 请求弹窗。授权请求必须在 App 完成启动之后发起——App 构造阶段调用
/// 会被系统静默忽略，不会弹出授权框。
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, NotificationPresenting, @unchecked Sendable {

    static let shared = NotificationManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "lee.miclock.app",
        category: "Notification"
    )

    private var activated = false

    private override init() {
        super.init()
    }

    /// 设置 delegate（幂等）。App 启动时调用一次。
    func activate() {
        guard !activated else { return }
        activated = true
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - NotificationPresenting

    func ensureAuthorization() async -> NotificationAuthorizationState {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized

        case .denied:
            return .denied

        case .notDetermined:
            // 此时请求才会真正弹出授权框。
            Self.logger.info("requesting notification authorization")
            _ = try? await center.requestAuthorization(options: [.alert])

            let after = await center.notificationSettings()
            switch after.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return .authorized
            case .denied:
                return .denied
            default:
                return .notDetermined
            }

        @unknown default:
            return .notDetermined
        }
    }

    func presentRestored(from: String, to: String, reason: RestoreReason) {
        let content = UNMutableNotificationContent()

        switch reason {
        case .manualLock:
            content.title = "已恢复锁定麦克风"
        case .automaticHijack:
            content.title = "已阻止麦克风自动切换"
        case .preferredReconnected:
            content.title = "首选麦克风已重新连接"
        case .startup:
            content.title = "MicLock"
        }

        // 不使用通知声音。
        content.body = "\(from) → \(to)"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("notification error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 即使 App 处于 foreground，仍然允许显示右上角 Banner。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
