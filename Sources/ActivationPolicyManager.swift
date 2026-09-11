import AppKit
import OSLog

/// 动态 Activation Policy：MicLock 平时以 .accessory 常驻菜单栏，
/// 打开普通窗口（当前只有 Settings）时临时升级为 .regular，
/// 所有 regular demand 结束后切回 .accessory。
///
/// 两个正交状态（不能合并）：
///
/// - window identity：我认识哪个 NSWindow 承担哪个角色。close 后保留
///   ——SwiftUI 重开 Settings 时复用同一 NSWindow，且 WindowAccessor 不会
///   重跑，丢掉 identity 就无法识别重开的窗口
/// - regular demand：现在哪个角色要求 App 保持 .regular。由用户意图
///   （打开）与 NSWindow.willCloseNotification（关闭）驱动
///
/// policy 只跟随 demand，不跟随窗口物化进度：openSettings() 没有
/// success/failure 回调，窗口出现耗时只反映系统状态，不能用来推断
/// Scene 生命周期，因此没有基于超时的降级逻辑。
@MainActor
final class ActivationPolicyManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "lee.miclock.app",
        category: "ActivationPolicy"
    )

    /// 要求 .regular 的窗口角色。未来新增 Main Window / 日志窗口时扩展。
    enum RegularWindowRole {
        case settings
    }

    /// 角色对应的 NSWindow identity（weak；SwiftUI 拥有窗口所有权）。
    private var windowIdentities: [RegularWindowRole: WeakWindowBox] = [:]

    /// 当前要求 .regular 的角色集合。
    private var regularDemands: Set<RegularWindowRole> = []

    private var willCloseObserver: NSObjectProtocol?
    private var didBecomeKeyObserver: NSObjectProtocol?

    /// 诊断 generation（仅日志，不参与 policy 决策）：
    /// 每次打开请求自增 openGeneration；known identity 的窗口成为
    /// key 时同步 presentedGeneration。identity 永久保留的设计下，
    /// 「窗口对象存在」不能代表「本次请求已展示」，须逐次对比。
    private var settingsOpenGeneration: UInt64 = 0
    private var settingsPresentedGeneration: UInt64 = 0

    /// AppDelegate 启动时显式挂载 observer，生命周期清晰对应 stop()。
    func start() {
        guard willCloseObserver == nil, didBecomeKeyObserver == nil else { return }

        // queue: nil：block 在 posting thread 上同步执行（Apple 对
        // queue == nil 的明确保证）。NSWindow 是 @MainActor 类型，
        // willClose 在主线程 post，assumeIsolated 安全。
        // 不能用 queue: .main 或 Task { @MainActor }：都会引入一次
        // 异步排队跳转，把「收到通知」与「处理通知」拆成两个时刻，
        // stale 的 willClose 可能在新的 beginOpeningSettings 之后执行，
        // 错误移除新 demand。
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else {
                return
            }

            MainActor.assumeIsolated {
                self?.handleWindowWillClose(window)
            }
        }

        // 诊断信号，不涉及 policy 正确性；为生命周期语义一致同样用 nil。
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else {
                return
            }

            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey(window)
            }
        }
    }

    /// 与 start() 对应，由 AppDelegate.applicationWillTerminate 调用；
    /// 不写 deinit 清理（Swift 6 下 nonisolated deinit 不能访问
    /// MainActor 隔离属性，与 MicLockAppDelegate 的处理一致）。
    func stop() {
        for observer in [willCloseObserver, didBecomeKeyObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        willCloseObserver = nil
        didBecomeKeyObserver = nil
    }

    /// 用户请求打开 Settings：demand 先行，policy 跟随意图而非窗口。
    /// 请求后窗口物化可能需要数秒（实测 1.9–2.3s），期间保持 .regular。
    /// 返回 false 表示 .regular 切换失败，调用方不应继续 openSettings()。
    ///
    /// 已知取舍：openSettings() 真正失败（窗口始终未展示）时 demand
    /// 不会自动结束，.regular / Dock 会保留到用户再次操作（重开设置
    /// 或退出）为止——openSettings 没有 success/failure 回调，无法把
    /// 「窗口迟迟未出现」与「系统慢」区分开，自动降级会重新引入
    /// 时序竞态，故不做；5s 的 didBecomeKey 日志用于事后排查。
    @discardableResult
    func beginOpeningSettings() -> Bool {
        // 每次打开请求开启新的窗口周期，也恢复一次 accessory 切换重试预算。
        accessoryRetryCount = 0
        regularDemands.insert(.settings)

        settingsOpenGeneration &+= 1
        let generation = settingsOpenGeneration

        guard switchToRegular() else {
            regularDemands.remove(.settings)
            return false
        }

        // Settings 已处于 key 状态时（重开已打开的窗口），不会再次产生
        // didBecomeKeyNotification——它只在状态变为 key 时发送。
        if let window = windowIdentities[.settings]?.window,
           window.isKeyWindow
        {
            settingsPresentedGeneration = generation
        }

        NSApp.activate()

        Self.logger.debug("ENTER_REGULAR")

        monitorPendingSettingsPresentation(generation: generation)

        return true
    }

    /// WindowAccessor 第一次物化 Settings NSWindow 时调用。
    /// 只登记 identity，不创建 demand——demand 只能由用户打开意图
    /// （beginOpeningSettings）创建。SwiftUI 重开复用同一窗口时不会
    /// 重跑，但 close 后 identity 一直保留；SwiftUI 真正销毁旧窗口换
    /// 新窗口时，WindowProbeView.viewDidMoveToWindow 会覆盖。
    func registerSettingsWindow(_ window: NSWindow) {
        let isNewIdentity = windowIdentities[.settings]?.window !== window
        if isNewIdentity {
            windowIdentities[.settings] = WeakWindowBox(window: window)
        }

        // didBecomeKey 可能早于本注册到达（SwiftUI：创建窗口 → 成为
        // key → 才跑 viewDidMoveToWindow），notification 已错过且不会
        // 补发；注册时凭 isKeyWindow 补偿本次请求的展示状态。
        if regularDemands.contains(.settings),
           window.isKeyWindow
        {
            settingsPresentedGeneration = settingsOpenGeneration
        }

        if isNewIdentity {
            Self.logger.debug("REGISTER_WINDOW")
        }
    }

    private func handleWindowWillClose(_ window: NSWindow) {
        // 反查 identity 找到对应角色；找不到（未识别的内部窗口）忽略。
        let roles = windowIdentities
            .filter { $0.value.window === window }
            .map(\.key)

        guard !roles.isEmpty else {
            return
        }

        for role in roles {
            // 只结束 demand，identity 保留：SwiftUI 可能复用同一 NSWindow。
            regularDemands.remove(role)
        }

        Self.logger.debug("WINDOW_WILL_CLOSE")

        // willClose 发生在关闭流程中而非完全消失后；
        // 延迟一轮 main queue 让窗口先完成 close，减少
        // 关闭动画异常 / 焦点跳变 / Dock 切换过早的风险。
        // 用户若在间隙快速重开，重开路径会先 insert demand，
        // isEmpty 检查天然挡住这次 stale 降级。
        DispatchQueue.main.async { [weak self] in
            self?.leaveWindowModeIfPossible()
        }
    }

    /// 剩余重试次数：setActivationPolicy(.accessory) 失败多为瞬态，
    /// 下一轮 main queue 重试一次；不做无限重试。
    private var accessoryRetryCount = 0

    private func leaveWindowModeIfPossible() {
        guard regularDemands.isEmpty else {
            return
        }

        guard NSApp.activationPolicy() != .accessory else {
            return
        }

        guard NSApp.setActivationPolicy(.accessory) else {
            Self.logger.error("Failed to enter accessory activation policy")

            guard accessoryRetryCount < 1 else {
                Self.logger.error("Give up retrying accessory policy; Dock stays visible until next window cycle")
                return
            }

            accessoryRetryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.leaveWindowModeIfPossible()
            }
            return
        }

        accessoryRetryCount = 0
        Self.logger.debug("RETURN_ACCESSORY")
    }

    private func switchToRegular() -> Bool {
        guard NSApp.activationPolicy() != .regular else {
            return true
        }

        guard NSApp.setActivationPolicy(.regular) else {
            Self.logger.error("Failed to enter regular activation policy")
            return false
        }

        return true
    }

    /// known identity 的窗口成为 key：本次请求视为已展示。
    /// 仅更新诊断 generation，不参与 .regular / .accessory 决策。
    private func handleWindowDidBecomeKey(_ window: NSWindow) {
        guard regularDemands.contains(.settings),
              window === windowIdentities[.settings]?.window
        else {
            return
        }

        settingsPresentedGeneration = settingsOpenGeneration
    }

    /// 仅监控：openSettings() 没有 success/failure 回调，5 秒后本次
    /// 请求仍未展示只能说明「可能慢或失败」，记录 warning 供排查，
    /// 绝不据此修改 activation policy。
    private func monitorPendingSettingsPresentation(generation: UInt64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))

            guard let self else { return }

            // 只诊断最新一次打开请求；旧请求的 monitor 到期即丢弃。
            guard self.settingsOpenGeneration == generation else {
                return
            }

            guard self.regularDemands.contains(.settings) else {
                return
            }

            guard self.settingsPresentedGeneration != generation else {
                return
            }

            Self.logger.warning("Settings did not become key within 5s")
        }
    }
}

/// NSWindow 的 weak 包装，供 identity 表按 role 存放。
@MainActor
private final class WeakWindowBox {
    weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }
}
