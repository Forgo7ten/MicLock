import Foundation

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
enum RestoreReason: Equatable {
    case manualLock
    case automaticHijack
    case preferredReconnected
    case startup
}

/// 最近一次已经确认生效的关键麦克风操作。
struct RecentAudioAction: Equatable {
    enum Kind: Equatable {
        case selectedInMicLock
        case acceptedUserSwitch
        case restored(RestoreReason)
    }

    let kind: Kind
    let fromDeviceName: String?
    let toDeviceName: String
    let occurredAt: Date

    var reasonText: String {
        switch kind {
        case .selectedInMicLock:
            return "你在 MicLock 中主动选择了该麦克风"
        case .acceptedUserSwitch:
            return "设备已稳定，Auto Mode 将这次切换视为用户操作并接受"
        case .restored(.manualLock):
            return "Manual Mode 检测到外部切换，因此恢复首选麦克风"
        case .restored(.automaticHijack):
            return "设备仍处于稳定窗口内，Auto Mode 将这次切换视为系统抢麦并恢复"
        case .restored(.preferredReconnected):
            return "首选麦克风重新连接，因此恢复为该设备"
        case .restored(.startup):
            return "启动、重新开启保护或切换到 Manual Mode 时对齐到首选麦克风"
        }
    }

    var transitionText: String {
        guard let fromDeviceName, fromDeviceName != toDeviceName else { return toDeviceName }
        return "\(fromDeviceName) → \(toDeviceName)"
    }
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
