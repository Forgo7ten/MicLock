import Foundation
import ServiceManagement
import OSLog

/// Launch at Login，使用 SMAppService（macOS 13+）。
///
/// 不写 LaunchAgent plist、不修改 ~/Library/LaunchAgents。
/// 状态以 SMAppService.mainApp.status 为唯一事实来源，不做本地持久化。
///
/// 注意：register/unregister 成功返回后，`status` 不会立即更新
/// （底层 BTM 数据库异步落盘），调用方不要把 UI 直接绑定在 status 上，
/// 应乐观更新 UI 后延迟复核。
enum LaunchAtLoginManager {

    /// 登录项的语义状态。
    enum Status {
        /// 已注册并生效。
        case enabled
        /// 已注册但等待用户在系统设置中批准。
        case pendingApproval
        /// 未注册（或不可用）。
        case off
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "lee.miclock.app",
        category: "LaunchAtLogin"
    )

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .pendingApproval
        default:
            return .off
        }
    }

    /// 复选框语义：注册成功（含待批准）视为勾选。
    static var isEnabled: Bool {
        status != .off
    }

    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Self.logger.info("launchAtLogin=\(enabled, privacy: .public)")
        } catch {
            // 例如 ad-hoc 签名/非常规安装路径下注册可能被系统拒绝。
            Self.logger.error(
                "launchAtLogin \(enabled, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
