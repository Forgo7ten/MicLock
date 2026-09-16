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

    private static func authorizationState(
        from status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    func currentAuthorizationState() async -> NotificationAuthorizationState {
        guard !Task.isCancelled else { return .notDetermined }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !Task.isCancelled else { return .notDetermined }
        return Self.authorizationState(from: settings.authorizationStatus)
    }

    func ensureAuthorization() async -> NotificationAuthorizationState {
        guard !Task.isCancelled else { return .notDetermined }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        // The switch may have been turned off while this read was suspended.
        // Once requestAuthorization is actually issued, its system dialog cannot
        // be withdrawn; cancellation only prevents issuing a stale request.
        guard !Task.isCancelled else { return .notDetermined }

        switch Self.authorizationState(from: settings.authorizationStatus) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            // 此时请求才会真正弹出授权框。
            Self.logger.info("requesting notification authorization")
            _ = try? await center.requestAuthorization(options: [.alert])

            guard !Task.isCancelled else { return .notDetermined }
            let after = await center.notificationSettings()
            return Self.authorizationState(from: after.authorizationStatus)
        }
    }

    func presentRestored(from: String, to: String, reason: RestoreReason) {
        let content = UNMutableNotificationContent()

        switch reason {
        case .manualLock:
            content.title = "已恢复锁定麦克风"
        case .automaticHijack:
            content.title = "已阻止麦克风自动切换"
        case .missingDefaultInput:
            content.title = "已恢复默认麦克风"
        case .preferredReconnected:
            content.title = "首选麦克风已重新连接"
        case .startup:
            content.title = "MicLock"
        }

        // 不使用通知声音。
        content.body = "\(from) → \(to)"

        submit(content)
    }

    func presentListenerFailure() {
        let content = UNMutableNotificationContent()
        content.title = "MicLock 监听异常"
        content.body = "CoreAudio 监听连续安装失败，本轮自动重试已停止。请打开 MicLock 查看状态；可点击“重新尝试”，或重启 App 后再次尝试。"
        submit(content)
    }

    private func submit(_ content: UNMutableNotificationContent) {
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
