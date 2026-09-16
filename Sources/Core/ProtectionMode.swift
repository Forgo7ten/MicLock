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
    case missingDefaultInput
    case preferredReconnected
    case startup
}

/// Protection restore 长时间未完成时暴露给设置界面的结构化状态。
/// 不复用 `lastError` 文本，避免 UI 依赖错误字符串解析。
enum ProtectionRetryState: Equatable {
    /// CoreAudio 接受了 setter，但真实 default input 仍未到达 target。
    case awaitingConfirmation

    /// 最近一次 setter 请求本身被 CoreAudio 拒绝；watchdog 仍会继续退避重试。
    case setterRejected
}

/// 用户保护配置与 CoreAudio listener readiness 的 UI 投影。
///
/// 只用于菜单栏 / Settings 展示；不参与 AutoPolicy、Writer 或 provider
/// 决策，也不代表 preferred 在线、采样成功或 writer 已确认。
enum ProtectionDisplayState: Equatable {
    case disabled
    case starting
    case active
    case unavailable

    var accessibilityLabelText: String {
        switch self {
        case .disabled:
            return "麦克风保护已关闭"
        case .starting:
            return "麦克风保护监听正在启动"
        case .active:
            return "麦克风保护已开启"
        case .unavailable:
            return "麦克风保护监听当前不可用"
        }
    }
}

/// listener 相关展示文案集中在 ProtectionMode.swift；
/// AudioMonitor 只暴露 projection，不复制展示 switch。
extension CoreAudioListenerStatus {
    var protectionDisplayStateWhenEnabled: ProtectionDisplayState {
        switch self {
        case .notStarted, .retrying:
            return .starting
        case .installed:
            return .active
        case .failed:
            return .unavailable
        }
    }

    var presentationText: (summary: String?, detail: String?) {
        switch self {
        case .installed:
            return (nil, nil)
        case .notStarted:
            return (
                "CoreAudio 监听尚未就绪",
                "正在建立 CoreAudio 事件监听；完成前设备变化无法被持续监测。"
            )
        case .retrying(let nextAttempt, let total):
            return (
                "CoreAudio 监听异常 · 正在重试 \(nextAttempt)/\(total)",
                "正在重新建立 CoreAudio 事件监听；完成前设备变化无法被持续监测。"
            )
        case .failed:
            return (
                "CoreAudio 监听异常 · 本轮自动重试已停止",
                "CoreAudio 事件监听未能建立，本轮自动重试已经停止。可以立即重新尝试，或重启 MicLock 后再次尝试。"
            )
        }
    }
}

extension CoreAudioListenerInstallFailure {
    var message: String {
        switch self {
        case .defaultInputAdd(let status):
            return "Unable to install CoreAudio default-input listener (status: \(status))"
        case .devicesAdd(let status):
            return "Unable to install CoreAudio devices listener (status: \(status))"
        case .cleanup(let status):
            return "Unable to clean up a partial CoreAudio listener registration (status: \(status))"
        }
    }
}

/// 最近一次已经确认生效的关键麦克风事件。
struct RecentAudioEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case selectedInMicLock
        case acceptedUserSwitch
        case restored(RestoreReason)
    }

    let id = UUID()
    let kind: Kind
    let fromDeviceName: String?
    let toDeviceName: String
    let occurredAt: Date

    var titleText: String {
        switch kind {
        case .selectedInMicLock:
            return "用户选择麦克风"
        case .acceptedUserSwitch:
            return "接受外部切换"
        case .restored(.manualLock):
            return "已恢复首选麦克风"
        case .restored(.automaticHijack):
            return "已阻止自动抢麦"
        case .restored(.missingDefaultInput):
            return "已恢复默认麦克风"
        case .restored(.preferredReconnected):
            return "首选麦克风重新连接"
        case .restored(.startup):
            return "已对齐首选麦克风"
        }
    }

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
        case .restored(.missingDefaultInput):
            return "系统持续没有默认输入，首选麦克风仍在线，因此恢复为该设备"
        case .restored(.preferredReconnected):
            return "首选麦克风重新连接，因此恢复为该设备"
        case .restored(.startup):
            return "启动、重新开启保护、CoreAudio 监听恢复或切换到 Manual Mode 时对齐到首选麦克风"
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
        case .missingDefaultInput: return "missing-default-input"
        case .preferredReconnected: return "preferred-reconnected"
        case .startup: return "startup"
        }
    }
}
