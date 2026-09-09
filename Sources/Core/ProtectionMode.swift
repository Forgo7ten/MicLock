/// 保护模式。
///
/// - `manual`: 严格锁定，任何外部切换立即恢复 preferred。
/// - `auto`: 阻止设备接入/断开期间系统抢麦；设备稳定后的外部切换
///   视为用户意图，接受并保存为新的 preferred。
enum ProtectionMode: String, Codable, CaseIterable {
    case auto
    case manual
}

/// 恢复动作的触发来源，用于日志、通知文案与测试断言。
enum RestoreReason {
    /// Manual Mode 检测到外部切换，执行恢复。
    case manualLock
    /// Auto Mode 判定为设备接入引起的系统抢麦，执行恢复。
    case automaticHijack
    /// Preferred 设备重新上线，执行恢复。
    case preferredReconnected
    /// 启动 / 开启保护时的对齐恢复，不通知。
    case startup
}

extension RestoreReason: CustomStringConvertible {
    var description: String {
        switch self {
        case .manualLock: return "manual-lock"
        case .automaticHijack: return "automatic-hijack"
        case .preferredReconnected: return "preferred-reconnected"
        case .startup: return "startup"
        }
    }
}
