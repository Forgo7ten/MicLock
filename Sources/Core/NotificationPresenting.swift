/// 通知权限状态（避免 Core 层直接依赖 UserNotifications 类型）。
enum NotificationAuthorizationState {
    case notDetermined
    case denied
    case authorized
}

/// 通知投递抽象：AudioMonitor 只依赖本协议，测试注入记录型 Fake。
/// Sendable：实例跨 await 传递给非隔离的 async 授权请求。
protocol NotificationPresenting: AnyObject, Sendable {
    /// 投递一条“恢复”通知。
    func presentRestored(from: String, to: String, reason: RestoreReason)

    /// 检查（必要时请求）通知授权。
    func ensureAuthorization() async -> NotificationAuthorizationState
}
