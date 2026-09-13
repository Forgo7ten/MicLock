import Foundation
import CoreAudio
import OSLog
import Observation

/// AudioMonitor 的单调时钟 / 延迟调度抽象。
/// timer 必须在 `schedule` 返回前完成登记；这样测试时钟可以确定性推进多级 watchdog，
/// 不依赖新建 Task 何时获得执行机会。
@MainActor
protocol AudioMonitorScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol AudioMonitorScheduling: AnyObject {
    var now: ContinuousClock.Instant { get }

    @discardableResult
    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> AudioMonitorScheduledTask
}

@MainActor
final class ContinuousAudioMonitorScheduler: AudioMonitorScheduling {
    private let clock = ContinuousClock()

    var now: ContinuousClock.Instant {
        clock.now
    }

    @discardableResult
    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> AudioMonitorScheduledTask {
        let token = ContinuousScheduledTask()
        token.task = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return token
    }

    @MainActor
    private final class ContinuousScheduledTask: AudioMonitorScheduledTask {
        var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}

/// 麦克风保护状态机（Auto / Manual）。
///
/// 职责：设备拓扑 settle window、self-induced 回调识别、
/// preferred 持久化、统一恢复入口、通知去重。
/// CoreAudio 枚举与读写全部委托给注入的 `AudioDeviceProviding`。
///
/// UI 可见状态经 Observation 框架（@Observable）暴露给 SwiftUI；
/// 其余内部状态用 @ObservationIgnored 排除观测。
@Observable
@MainActor
final class AudioMonitor {

    // Logger 的结构化日志参数是 OSLogMessage，而不是普通 String。
    // 带 privacy 插值的日志必须保持为一个完整的插值字面量；
    // 不要用 `+` 拼接多个日志片段，否则 OSLogMessage 无法使用 String 的 `+` 运算符。
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "lee.miclock.app",
        category: "AudioMonitor"
    )

    /// MICLOCK_DEBUG=1 时把关键决策镜像到 stderr，配合直接运行二进制调试（规格 §14）。
    /// MICLOCK_TRACE_PATH 指定文件时（对 open 启动的 GUI 进程有用）追加写入该文件。
    private static let debugStderr = ProcessInfo.processInfo.environment["MICLOCK_DEBUG"] != nil

    private static let tracePath = ProcessInfo.processInfo.environment["MICLOCK_TRACE_PATH"]

    private static let traceLock = NSLock()

    private static func trace(_ message: String) {
        guard Self.debugStderr || Self.tracePath != nil else { return }
        let line = message + "\n"
        if Self.debugStderr {
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if let path = Self.tracePath {
            Self.traceLock.lock()
            defer { Self.traceLock.unlock() }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - UI State

    private(set) var devices: [AudioInputDevice] = []

    private(set) var currentDevice: AudioInputDevice?

    private(set) var lastError: String?

    /// Protection restore 进入长期 watchdog retry 或 setter 被拒绝时，
    /// 向设置界面暴露结构化状态；事务成功/取消/supersede 后清空。
    private(set) var protectionRetryState: ProtectionRetryState?

    /// CoreAudio 监听基础能力失败；独立于一次性设备操作错误。
    private(set) var listenerError: String?

    /// 输入设备枚举失败；与“成功但没有输入设备”区分。
    private(set) var deviceEnumerationError: String?

    /// 通知权限被系统拒绝时提示用户去系统设置开启。
    private(set) var notificationDenied = false

    /// 最近已经确认生效的关键麦克风事件，最新事件排在最前。
    private(set) var recentAudioEvents: [RecentAudioEvent] = []

    private static let recentAudioEventLimit = 10

    var preferredMicrophoneUID: String? {
        didSet {
            guard preferredMicrophoneUID != oldValue else { return }
            preferences.preferredMicrophoneUID = preferredMicrophoneUID
            Self.logger.info("PREFERRED_CHANGED uid=\(self.preferredMicrophoneUID ?? "nil", privacy: .public)")
        }
    }

    var protectionEnabled: Bool {
        didSet {
            guard protectionEnabled != oldValue else { return }
            preferences.protectionEnabled = protectionEnabled
            Self.logger.info("PROTECTION \(self.protectionEnabled ? "ON" : "OFF", privacy: .public)")

            cancelStableExternalSwitchCandidate()

            if protectionEnabled {
                // 开启即对齐（等同启动策略，不通知）。
                evaluateStartupPolicy()
            } else {
                // Protection OFF：只监控与刷新，不执行任何策略、不学习。
                cancelProgrammaticSwitch()
            }
        }
    }

    var protectionMode: ProtectionMode {
        didSet {
            guard protectionMode != oldValue else { return }
            preferences.protectionMode = protectionMode
            Self.logger.info("MODE=\(self.protectionMode.rawValue, privacy: .public)")

            // 模式切换是新的用户意图：旧模式下尚未确认的程序化切换事务或
            // stable external switch candidate 都不应继续携带旧策略语义。
            cancelStableExternalSwitchCandidate()
            cancelProgrammaticSwitch()

            // auto → manual：保留 preferred，立即执行 manual enforce。
            if protectionMode == .manual {
                evaluateStartupPolicy()
            }
            // manual → auto：保留 preferred，等待后续事件由 Auto 策略判定。
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            preferences.notificationsEnabled = notificationsEnabled

            // 打开通知开关时主动检查 / 请求授权。
            if notificationsEnabled {
                Task { [weak self] in
                    await self?.refreshNotificationAuthorization()
                }
            }
        }
    }

    var settleSeconds: Double {
        didSet {
            let clamped = min(max(settleSeconds, Preferences.settleRange.lowerBound), Preferences.settleRange.upperBound)
            if clamped != settleSeconds {
                settleSeconds = clamped
                return
            }
            preferences.settleSeconds = settleSeconds
            rescheduleActiveSettleEpisodeForConfigurationChange()
            rescheduleStableExternalSwitchCandidateForConfigurationChange()
        }
    }

    // MARK: - Dependencies

    private let provider: AudioDeviceProviding
    private let preferences: Preferences
    private let notifier: NotificationPresenting
    private let scheduler: AudioMonitorScheduling

    // MARK: - Settle State Machine

    /// 时间判断和延迟任务共用同一个 monotonic scheduler，避免状态机出现双时钟。

    private struct SettleEpisode {
        let id: UInt64
        var revision: UInt64
        var lastActivity: ContinuousClock.Instant
        var deadline: ContinuousClock.Instant
        var notificationSent: Bool
    }

    private enum StabilityState {
        case stable
        case settling(SettleEpisode)
    }

    /// Auto Mode 的稳定性状态是策略事实来源；scheduler timer 只负责唤醒，不承载业务状态。
    @ObservationIgnored private var stabilityState: StabilityState = .stable
    @ObservationIgnored private var nextSettleEpisodeID: UInt64 = 0
    @ObservationIgnored private var settleTask: AudioMonitorScheduledTask?

    /// 最近一份“完整且与 current 不矛盾”的可信 topology；策略判断只使用它。
    /// `devices` 则可展示 partial snapshot 中仍可读取的健康设备。
    @ObservationIgnored private var trustedDevices: [AudioInputDevice] = []
    @ObservationIgnored private var connectedUIDs: Set<String> = []

    /// Auto + stable 下观察到的外部 default 变化先进入候选态。
    /// 这只延迟 preferred 的学习，不延迟 currentDevice UI，也不延迟 settling 内的 corrective restore。
    private struct StableExternalSwitchCandidate {
        let id: UInt64
        let oldPreferredUID: String
        let oldPreferredName: String
        let newCurrentUID: String
        let newCurrentName: String
        let startedAt: ContinuousClock.Instant
        var deadline: ContinuousClock.Instant
    }

    @ObservationIgnored private var stableExternalSwitchCandidate: StableExternalSwitchCandidate?
    @ObservationIgnored private var nextStableExternalSwitchCandidateID: UInt64 = 0
    @ObservationIgnored private var stableExternalSwitchCandidateTask: AudioMonitorScheduledTask?

    /// CoreAudio topology 采样失败/矛盾时主动重试；与 settle / switch confirmation 独立。
    @ObservationIgnored private var topologyRecoveryTask: AudioMonitorScheduledTask?
    @ObservationIgnored private var topologyRecoveryAttempt = 0
    /// 初始化阶段设备枚举失败后，第一份可信 topology 必须作为启动基线处理，
    /// 不能把“从空缓存恢复”为普通设备接入事件，也不能丢失 startup restore 语义。
    @ObservationIgnored private var startupTopologyRecoveryPending = false
    private static let topologyRecoveryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    private enum ProgrammaticSwitchOrigin: Equatable {
        case protectionRestore(RestoreReason)
        case trustedUserSelection
    }

    private struct PendingNotification {
        let from: String
        let to: String
        let episodeID: UInt64?
    }

    private struct PendingSwitch {
        let id: UInt64
        let sourceUID: String?
        let targetUID: String
        let origin: ProgrammaticSwitchOrigin
        let fromDeviceName: String?
        let toDeviceName: String
        var notification: PendingNotification?
        var retryAttempt: Int
    }

    private enum ProgrammaticSwitchState {
        case idle
        case awaitingConfirmation(PendingSwitch)
    }

    /// MicLock 自己发起的切换事务；目标、解释事件与通知必须原子地属于同一笔事务。
    @ObservationIgnored private var programmaticSwitchState: ProgrammaticSwitchState = .idle
    @ObservationIgnored private var programmaticSwitchWatchdogTask: AudioMonitorScheduledTask?

    @ObservationIgnored private var nextProgrammaticSwitchID: UInt64 = 0

    /// 只用于重新读取 / 重试，不把“时间经过”本身解释成失败。
    /// 前几次快速自愈，长期异常时指数退避；最后固定 64s 一次，避免无意义地高频 setter。
    private static let programmaticSwitchRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(32),
        .seconds(64),
    ]
    /// 保持原有 UX：完成 0.5/1/2/4s 四档快速重试后开始显示长期 retry 状态，
    /// 但 transaction 不结束，后续 watchdog 继续按 8/16/32/64s 退避。
    private static let programmaticSwitchRetryWarningAttempt = 4
    private static let protectionSwitchRetryingError =
        "Unable to confirm default input change; protection is retrying"
    private static let protectionSwitchSetterRejectedRetryingError =
        "Unable to set default input device; protection will keep retrying"
    private static let userSelectionRetryingError =
        "Unable to confirm default input change; MicLock is retrying"
    private static let userSelectionSetterRejectedRetryingError =
        "Unable to set default input device; MicLock will keep retrying"

    /// 离线 preferred 设备的最近已知名称（跨启动持久化，用于 UI 展示）。
    @ObservationIgnored private var lastKnownDeviceNames: [String: String]

    // MARK: - CoreAudio Listeners

    /// 监听安装/卸载。@unchecked Sendable：字段仅在 start()（主 actor）与
    /// deinit 的 remove()（仅此一次）中写入；deinit 允许访问 Sendable 属性。
    private let listenerBox = ListenerBox()

    @ObservationIgnored private var listenersInstalled = false

    private final class ListenerBox: @unchecked Sendable {

        private let systemObject = AudioObjectID(kAudioObjectSystemObject)

        private var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private var defaultInputListener: AudioObjectPropertyListenerBlock?
        private var devicesListener: AudioObjectPropertyListenerBlock?

        func install(
            onDefaultInputChange: @escaping @MainActor () -> Void,
            onDevicesChange: @escaping @MainActor () -> Void
        ) -> (defaultInputStatus: OSStatus, devicesStatus: OSStatus) {
            let defaultInputListener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in onDefaultInputChange() }
            }
            self.defaultInputListener = defaultInputListener

            let devicesListener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in onDevicesChange() }
            }
            self.devicesListener = devicesListener

            let defaultStatus = AudioObjectAddPropertyListenerBlock(
                systemObject,
                &defaultInputAddress,
                DispatchQueue.main,
                defaultInputListener
            )

            let devicesStatus = AudioObjectAddPropertyListenerBlock(
                systemObject,
                &devicesAddress,
                DispatchQueue.main,
                devicesListener
            )

            // Auto Mode 同时依赖默认输入和设备拓扑事件。
            // 任一 listener 安装失败时回滚全部监听，避免进入部分可用状态。
            if defaultStatus != noErr || devicesStatus != noErr {
                remove()
            }

            return (defaultStatus, devicesStatus)
        }

        func remove() {
            if let listener = defaultInputListener {
                AudioObjectRemovePropertyListenerBlock(
                    systemObject,
                    &defaultInputAddress,
                    DispatchQueue.main,
                    listener
                )
            }

            if let listener = devicesListener {
                AudioObjectRemovePropertyListenerBlock(
                    systemObject,
                    &devicesAddress,
                    DispatchQueue.main,
                    listener
                )
            }

            defaultInputListener = nil
            devicesListener = nil
        }
    }

    // MARK: - Init
    //
    // 启动顺序：load preferences → enumerate devices → read current。
    // listeners 与启动策略评估在 start() 中执行。

    init(
        provider: AudioDeviceProviding,
        preferences: Preferences,
        notifier: NotificationPresenting,
        scheduler: AudioMonitorScheduling? = nil
    ) {
        self.provider = provider
        self.preferences = preferences
        self.notifier = notifier
        self.scheduler = scheduler ?? ContinuousAudioMonitorScheduler()

        preferredMicrophoneUID = preferences.preferredMicrophoneUID
        protectionEnabled = preferences.protectionEnabled
        protectionMode = preferences.protectionMode
        notificationsEnabled = preferences.notificationsEnabled
        settleSeconds = preferences.settleSeconds
        lastKnownDeviceNames = preferences.lastKnownDeviceNames

        refreshDeviceList(initial: true)

        // 首次运行只使用可信 startup baseline 初始化 preferred。
        // 初始 topology 枚举失败/跨属性不一致时，等待 startup recovery 的第一份可信快照，
        // 避免把瞬时 fallback current 永久持久化为首选设备。
        if !startupTopologyRecoveryPending {
            initializeFirstRunPreferredIfNeeded(
                devices: devices,
                current: currentDevice
            )
        }

        // 权限检查必须在 App 完成启动之后进行：
        // App 构造阶段调用 requestAuthorization 会被系统静默忽略（不弹窗）。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))

            guard let self,
                  self.notificationsEnabled
            else {
                return
            }

            await self.refreshNotificationAuthorization()
        }

        Self.logger.info("App start mode=\(self.protectionMode.rawValue, privacy: .public) preferred=\(self.preferredMicrophoneUID ?? "nil", privacy: .public)")
    }

    deinit {
        listenerBox.remove()
    }

    /// 安装 CoreAudio 监听并执行启动策略。
    func start() {
        guard installListeners() else {
            return
        }

        evaluateStartupPolicy()
    }

    /// 真实依赖链的便捷构造。
    static func live() -> AudioMonitor {
        AudioMonitor(
            provider: LiveAudioDeviceProvider(),
            preferences: Preferences(),
            notifier: NotificationManager.shared
        )
    }

    // MARK: - Public

    var currentDeviceName: String {
        currentDevice?.name ?? "Unknown"
    }

    /// 离线 preferred 的展示名（nil = preferred 在线或未选择）。
    var offlinePreferredName: String? {
        guard let uid = preferredMicrophoneUID,
              !connectedUIDs.contains(uid)
        else { return nil }

        return lastKnownDeviceNames[uid] ?? "Unknown device"
    }

    var isPreferredMicrophoneAvailable: Bool {
        guard let uid = preferredMicrophoneUID else { return false }
        return connectedUIDs.contains(uid)
    }

    /// 用户在 MicLock UI 主动选择设备：Trusted User Action。
    ///
    /// 不受 settle window 限制，setter 成功后提交 preferred 并切换。
    func selectDevice(_ device: AudioInputDevice) {
        Self.logger.info("USER_SELECT \(device.name, privacy: .public)")

        // 先重新读取真实 current；只有 fresh read 明确证明 target 已经生效时，
        // 才能绕过 setter。读取失败时 currentDevice 只是缓存，不能拿它当成功事实。
        if refreshCurrentDevice(), currentDevice?.uid == device.uid {
            cancelStableExternalSwitchCandidate()
            cancelProgrammaticSwitch()

            let previousPreferredUID = preferredMicrophoneUID
            guard previousPreferredUID != device.uid else {
                lastError = nil
                Self.logger.debug(
                    "USER_SELECT no-op already current/preferred uid=\(device.uid, privacy: .public)"
                )
                return
            }

            let previousPreferredName = previousPreferredUID.flatMap { uid in
                trustedDevices.first(where: { $0.uid == uid })?.name
                    ?? lastKnownDeviceNames[uid]
            }

            preferredMicrophoneUID = device.uid
            lastError = nil
            recordRecentAudioEvent(RecentAudioEvent(
                kind: .selectedInMicLock,
                fromDeviceName: previousPreferredName,
                toDeviceName: device.name,
                occurredAt: Date()
            ))
            Self.logger.info(
                "USER_SELECT already current; preferred updated uid=\(device.uid, privacy: .public)"
            )
            return
        }

        let transactionID = beginProgrammaticSwitch(
            to: device.uid,
            origin: .trustedUserSelection,
            fromDeviceName: currentDevice?.name,
            toDeviceName: device.name,
            notification: nil
        )

        do {
            try provider.setInputDevice(uid: device.uid)

            // setter 成功只代表 CoreAudio 接受了写操作；preferred 可以提交，
            // 但 currentDevice 仍必须来自 provider 的真实读取。
            preferredMicrophoneUID = device.uid
            lastError = nil

            refreshCurrentDevice()
            if finishProgrammaticSwitchIfConfirmed() {
                Self.logger.debug(
                    "USER_SELECT confirmed immediately uid=\(device.uid, privacy: .public)"
                )
            } else if case .awaitingConfirmation(let pending) = programmaticSwitchState {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
        } catch {
            failProgrammaticSwitch(
                id: transactionID,
                error: "Unable to set default input device"
            )
            Self.logger.error(
                "USER_SELECT failed uid=\(device.uid, privacy: .public) providerError=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// 启动 / 切换模式 / 开启保护时的对齐：
    /// protection 开且 preferred 在线且 current != preferred → 恢复（不通知）。
    func evaluateStartupPolicy() {
        // init 阶段不启动异步 recovery；等 start() 安装完 listeners 后由这里接手。
        // 测试也可直接调用本方法模拟“listeners 已就绪”的启动阶段。
        if startupTopologyRecoveryPending {
            scheduleTopologySampleRecovery()
            return
        }

        guard protectionEnabled,
              let preferredUID = preferredMicrophoneUID,
              let preferred = trustedDevices.first(where: { $0.uid == preferredUID }),
              let current = currentDevice,
              current.uid != preferred.uid
        else { return }

        restorePreferred(from: current, to: preferred, reason: .startup)
    }

    // MARK: - CoreAudio Reconciliation

    private enum CoreAudioWakeReason: String {
        case devices
        case defaultInput
        case stableExternalSwitchConfirmation
        case startupRecovery
        case topologyRecovery
        case programmaticSwitchWatchdog
    }

    /// 两个 CoreAudio listener 都只作为 wake-up 信号。
    /// 每次回调都重新读取完整设备列表 + 默认输入快照，并固定按：
    /// topology delta → current → pending transaction → policy 的顺序收敛。
    /// 因此不依赖 Devices / DefaultInput 两个独立 property callback 的到达顺序。
    func handleDeviceListChanged() {
        reconcileCoreAudioState(trigger: .devices)
    }

    func handleDefaultInputChanged() {
        reconcileCoreAudioState(trigger: .defaultInput)
    }

    private func reconcileCoreAudioState(trigger: CoreAudioWakeReason) {
        let previous = currentDevice
        let newCurrent: AudioInputDevice?

        do {
            newCurrent = try provider.currentInputDevice()
            currentDevice = newCurrent
        } catch {
            markTopologySampleInvalid(
                message: "Unable to read current input device",
                trigger: trigger
            )
            Self.logger.error(
                "CURRENT_INPUT_READ_FAILED trigger=\(trigger.rawValue, privacy: .public) providerError=\(String(describing: error), privacy: .public)"
            )
            return
        }

        // current == target 是独立于 topology 的充分成功证据。即使本轮设备枚举失败，
        // 也必须先完成 transaction，避免已经成功的切换永久停在 pending。
        let confirmedProgrammaticSwitch = finishProgrammaticSwitchIfConfirmed()
        if confirmedProgrammaticSwitch {
            Self.logger.debug("PROGRAMMATIC_SWITCH confirmed from current state")
        }

        let snapshot: AudioInputDeviceSnapshot
        do {
            snapshot = try provider.listInputDevices()
        } catch {
            markTopologySampleInvalid(
                message: "Unable to enumerate input devices",
                trigger: trigger
            )

            if confirmedProgrammaticSwitch { return }
            if reconcilePendingSwitchUsingCurrentOnly(trigger: trigger) { return }
            reconcileWithoutTrustedTopology(previous: previous, current: newCurrent)
            return
        }

        let newDevices = snapshot.devices

        // partial snapshot 仍可服务 UI/诊断，但绝不能推进 removal / target-offline / Auto learning。
        // 策略事实继续使用 trustedDevices / connectedUIDs 的最后一份完整快照。
        devices = Self.sortedDevices(newDevices)
        recordDeviceNames(newDevices)

        if !snapshot.isComplete {
            markTopologySampleInvalid(
                message: "Some input device properties are temporarily unreadable",
                trigger: trigger
            )
            Self.logger.error(
                "CORE_AUDIO_RECONCILE partial topology trigger=\(trigger.rawValue, privacy: .public) incompleteDeviceIDs=\(String(describing: snapshot.incompleteDeviceIDs), privacy: .public) issues=\(String(describing: snapshot.issues), privacy: .public)"
            )

            if confirmedProgrammaticSwitch { return }
            if reconcilePendingSwitchUsingCurrentOnly(trigger: trigger) { return }
            reconcileWithoutTrustedTopology(previous: previous, current: newCurrent)
            return
        }

        let newUIDs = Set(newDevices.map(\.uid))

        // DefaultInput 与 Devices 不是原子事务。current 指向一个本轮 devices 中不存在的 UID
        // 时，这一轮跨属性采样自相矛盾：可以更新 UI current，但不能据此做 topology removal、
        // pending target offline 或 Auto preferred 学习等不可逆判定。
        if let newCurrent,
           !newUIDs.contains(newCurrent.uid)
        {
            markTopologySampleInvalid(
                message: "CoreAudio input device state is temporarily inconsistent",
                trigger: trigger
            )

            if confirmedProgrammaticSwitch { return }
            if reconcilePendingSwitchUsingCurrentOnly(trigger: trigger) { return }
            reconcileWithoutTrustedTopology(previous: previous, current: newCurrent)
            return
        }

        // 初始化枚举失败后，第一份可信快照是“启动基线”，不是一次真实 topology delta。
        // 否则 connectedUIDs 仍为空会把所有设备误判为 added，进而把 startup 对齐记录成
        // preferredReconnected / automaticHijack，并可能错误发送通知。
        if startupTopologyRecoveryPending {
            clearTopologySampleRecovery()
            deviceEnumerationError = nil

            devices = Self.sortedDevices(newDevices)
            trustedDevices = devices
            connectedUIDs = newUIDs
            recordDeviceNames(newDevices)
            startupTopologyRecoveryPending = false

            initializeFirstRunPreferredIfNeeded(
                devices: devices,
                current: currentDevice
            )

            Self.trace("STARTUP_TOPOLOGY_RECOVERED devices=\(newUIDs)")
            Self.logger.info(
                "STARTUP_TOPOLOGY_RECOVERED devices=\(String(describing: newUIDs), privacy: .public)"
            )

            if confirmedProgrammaticSwitch { return }

            if case .awaitingConfirmation(let pending) = programmaticSwitchState,
               !connectedUIDs.contains(pending.targetUID)
            {
                failProgrammaticSwitch(
                    id: pending.id,
                    error: "Target input device is no longer available"
                )
            }

            if reconcilePendingSwitchUsingCurrentOnly(trigger: trigger) { return }
            evaluateStartupPolicy()
            return
        }

        clearTopologySampleRecovery()
        deviceEnumerationError = nil

        let added = newUIDs.subtracting(connectedUIDs)
        let removed = connectedUIDs.subtracting(newUIDs)
        let topologyChanged = !added.isEmpty || !removed.isEmpty

        // 只有完整且跨属性一致的 topology sample 才能更新策略事实。
        devices = Self.sortedDevices(newDevices)
        trustedDevices = devices
        connectedUIDs = newUIDs
        recordDeviceNames(newDevices)

        if topologyChanged {
            cancelStableExternalSwitchCandidate()
            Self.trace(
                "CORE_AUDIO_RECONCILE trigger=\(trigger.rawValue) added=\(added) removed=\(removed)"
            )
            Self.logger.info(
                "CORE_AUDIO_RECONCILE trigger=\(trigger.rawValue, privacy: .public) added=\(String(describing: added), privacy: .public) removed=\(String(describing: removed), privacy: .public)"
            )
            markTopologyUnsettled()
        } else if trigger == .devices {
            Self.logger.debug("DEVICE_LIST_CHANGED (no delta)")
            Self.trace("DEVICE_LIST_CHANGED (no delta)")
        }

        // transaction 已经由 current==target 确认；topology 仍然完成刷新，但不再运行 policy。
        if confirmedProgrammaticSwitch { return }

        // target disappearance 只能使用有效且一致的 topology 作为证据。
        if case .awaitingConfirmation(let pending) = programmaticSwitchState,
           !connectedUIDs.contains(pending.targetUID)
        {
            failProgrammaticSwitch(
                id: pending.id,
                error: "Target input device is no longer available"
            )
            Self.logger.error(
                "PROGRAMMATIC_SWITCH target disappeared id=\(pending.id, privacy: .public) uid=\(pending.targetUID, privacy: .public)"
            )
        }

        if reconcilePendingSwitchUsingCurrentOnly(trigger: trigger) { return }
        guard let current = currentDevice else { return }

        Self.trace(
            "CORE_AUDIO_RECONCILE trigger=\(trigger.rawValue) current=\(current.name) pendingTarget=nil"
        )
        Self.logger.info(
            "DEFAULT_INPUT_STATE \(previous?.name ?? "nil", privacy: .public) → \(current.name, privacy: .public) mode=\(self.protectionMode.rawValue, privacy: .public)"
        )

        guard protectionEnabled else { return }

        guard let preferredUID = preferredMicrophoneUID else {
            preferredMicrophoneUID = current.uid
            return
        }

        // preferred 设备重新出现：无论 Auto / Manual 都立即恢复。
        if added.contains(preferredUID),
           let preferred = trustedDevices.first(where: { $0.uid == preferredUID }),
           current.uid != preferred.uid
        {
            restorePreferred(from: current, to: preferred, reason: .preferredReconnected)
            return
        }

        if current.uid == preferredUID {
            cancelStableExternalSwitchCandidate()
            return
        }

        guard let preferred = trustedDevices.first(where: { $0.uid == preferredUID }) else {
            cancelStableExternalSwitchCandidate()
            Self.logger.info(
                "PREFERRED_OFFLINE keep=\(preferredUID, privacy: .public) current=\(current.name, privacy: .public)"
            )
            return
        }

        switch protectionMode {
        case .manual:
            cancelStableExternalSwitchCandidate()
            restorePreferred(from: current, to: preferred, reason: .manualLock)

        case .auto:
            let settled = isTopologySettled()
            Self.trace("auto: settled=\(settled)")
            Self.logger.info("mode=auto settled=\(settled, privacy: .public)")

            if !settled {
                cancelStableExternalSwitchCandidate()
                Self.trace("decision=restore reason=topology-unsettled")
                restorePreferred(from: current, to: preferred, reason: .automaticHijack)
            } else if trigger == .stableExternalSwitchConfirmation,
                      let candidate = stableExternalSwitchCandidate,
                      candidate.oldPreferredUID == preferredUID,
                      candidate.newCurrentUID == current.uid,
                      connectedUIDs.contains(candidate.newCurrentUID)
            {
                commitStableExternalSwitchCandidate(candidate)
            } else {
                beginStableExternalSwitchCandidate(from: preferred, to: current)
            }
        }
    }

    /// 在 topology 不可信时，只执行不依赖新 topology 的确定性动作。
    /// Manual 可以使用上一份有效设备表继续严格恢复；Auto 不做 preferred 学习/抢麦分类。
    private func reconcileWithoutTrustedTopology(
        previous: AudioInputDevice?,
        current: AudioInputDevice?
    ) {
        guard let current else { return }

        Self.trace(
            "CORE_AUDIO_DEGRADED \(previous?.name ?? "nil") -> \(current.name) mode=\(protectionMode.rawValue)"
        )
        Self.logger.info(
            "CORE_AUDIO_DEGRADED current=\(current.name, privacy: .public) mode=\(self.protectionMode.rawValue, privacy: .public)"
        )

        guard protectionEnabled,
              let preferredUID = preferredMicrophoneUID
        else { return }

        if current.uid == preferredUID {
            cancelStableExternalSwitchCandidate()
            return
        }

        guard protectionMode == .manual,
              let preferred = trustedDevices.first(where: { $0.uid == preferredUID })
        else {
            // Auto 需要可信 topology 才能做不可逆分类；等待 recovery retry。
            return
        }

        cancelStableExternalSwitchCandidate()
        restorePreferred(from: current, to: preferred, reason: .manualLock)
    }

    /// PendingSwitch 的 current-only 语义：target 已在调用方通过 current==target 确认。
    /// Protection restore 的第三状态可视为更新外部事实；Trusted User Selection 则继续
    /// 保留最新显式用户意图，直到 target confirmed / offline / 被新用户动作取代。
    @discardableResult
    private func reconcilePendingSwitchUsingCurrentOnly(trigger: CoreAudioWakeReason) -> Bool {
        guard case .awaitingConfirmation(let pending) = programmaticSwitchState else {
            return false
        }

        guard let current = currentDevice else {
            if trigger == .programmaticSwitchWatchdog {
                retryProgrammaticSwitch(pending)
            } else {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
            return true
        }

        Self.trace(
            "PROGRAMMATIC_SWITCH current-only current=\(current.name) source=\(pending.sourceUID ?? "nil") target=\(pending.targetUID)"
        )

        if let sourceUID = pending.sourceUID,
           current.uid == sourceUID
        {
            if trigger == .programmaticSwitchWatchdog {
                retryProgrammaticSwitch(pending)
            } else {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
            return true
        }

        // 最新一次 MicLock 明确选择的优先级高于更早程序化写入的延迟回声。
        // Trusted User Selection 只有 target confirmed、可信 topology 证明 target offline，
        // 或新的用户动作/模式变化才能结束；第三状态只继续向最新 target 收敛。
        if case .trustedUserSelection = pending.origin {
            if trigger == .programmaticSwitchWatchdog {
                retryProgrammaticSwitch(pending)
            } else {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
            Self.logger.info(
                "PROGRAMMATIC_SWITCH trusted selection retained id=\(pending.id, privacy: .public) current=\(current.uid, privacy: .public) target=\(pending.targetUID, privacy: .public)"
            )
            return true
        }

        // Protection restore 没有覆盖后续外部事实的资格：第三状态仍可 supersede。
        cancelProgrammaticSwitch()
        Self.logger.info(
            "PROGRAMMATIC_SWITCH superseded id=\(pending.id, privacy: .public) current=\(current.uid, privacy: .public)"
        )
        return false
    }

    private func markTopologySampleInvalid(message: String, trigger: CoreAudioWakeReason) {
        deviceEnumerationError = message
        Self.trace("CORE_AUDIO_RECONCILE invalid-topology trigger=\(trigger.rawValue) error=\(message)")
        Self.logger.error(
            "CORE_AUDIO_RECONCILE invalid topology trigger=\(trigger.rawValue, privacy: .public) error=\(message, privacy: .public)"
        )
        scheduleTopologySampleRecovery()
    }

    private func scheduleTopologySampleRecovery() {
        guard topologyRecoveryTask == nil else { return }

        let index = min(topologyRecoveryAttempt, Self.topologyRecoveryDelays.count - 1)
        let delay = Self.topologyRecoveryDelays[index]
        let trigger: CoreAudioWakeReason = startupTopologyRecoveryPending
            ? .startupRecovery
            : .topologyRecovery
        topologyRecoveryAttempt += 1
        topologyRecoveryTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.topologyRecoveryTask = nil
            self.reconcileCoreAudioState(trigger: trigger)
        }
    }

    private func clearTopologySampleRecovery() {
        topologyRecoveryTask?.cancel()
        topologyRecoveryTask = nil
        topologyRecoveryAttempt = 0
    }

    // MARK: - Stable External Switch Candidate

    private func beginStableExternalSwitchCandidate(
        from preferred: AudioInputDevice,
        to current: AudioInputDevice
    ) {
        if let candidate = stableExternalSwitchCandidate,
           candidate.oldPreferredUID == preferred.uid,
           candidate.newCurrentUID == current.uid
        {
            if stableExternalSwitchCandidateTask == nil {
                scheduleStableExternalSwitchCandidateConfirmation(candidate)
            }
            return
        }

        cancelStableExternalSwitchCandidate()

        nextStableExternalSwitchCandidateID &+= 1
        let now = scheduler.now
        let candidate = StableExternalSwitchCandidate(
            id: nextStableExternalSwitchCandidateID,
            oldPreferredUID: preferred.uid,
            oldPreferredName: preferred.name,
            newCurrentUID: current.uid,
            newCurrentName: current.name,
            startedAt: now,
            deadline: now.advanced(by: .seconds(settleSeconds))
        )
        stableExternalSwitchCandidate = candidate

        Self.trace(
            "STABLE_EXTERNAL_SWITCH_CANDIDATE id=\(candidate.id) from=\(preferred.name) to=\(current.name)"
        )
        Self.logger.debug(
            "STABLE_EXTERNAL_SWITCH_CANDIDATE id=\(candidate.id, privacy: .public) from=\(preferred.uid, privacy: .public) to=\(current.uid, privacy: .public)"
        )

        scheduleStableExternalSwitchCandidateConfirmation(candidate)
    }

    private func scheduleStableExternalSwitchCandidateConfirmation(
        _ candidate: StableExternalSwitchCandidate
    ) {
        stableExternalSwitchCandidateTask?.cancel()
        let delay = scheduler.now.duration(to: candidate.deadline)
        stableExternalSwitchCandidateTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }

            // 标记本次 timer 已消费；如果此次确认因无效 topology sample 无法完成，
            // 后续同 candidate 的 wake-up 可以重新安排一次确认。
            self.stableExternalSwitchCandidateTask = nil

            guard self.stableExternalSwitchCandidate?.id == candidate.id else { return }
            self.reconcileCoreAudioState(trigger: .stableExternalSwitchConfirmation)
        }
    }

    private func rescheduleStableExternalSwitchCandidateForConfigurationChange() {
        guard var candidate = stableExternalSwitchCandidate else { return }

        candidate.deadline = candidate.startedAt.advanced(by: .seconds(settleSeconds))
        stableExternalSwitchCandidate = candidate
        scheduleStableExternalSwitchCandidateConfirmation(candidate)
    }

    private func commitStableExternalSwitchCandidate(
        _ candidate: StableExternalSwitchCandidate
    ) {
        guard stableExternalSwitchCandidate?.id == candidate.id else { return }

        cancelStableExternalSwitchCandidate()
        preferredMicrophoneUID = candidate.newCurrentUID
        recordRecentAudioEvent(RecentAudioEvent(
            kind: .acceptedUserSwitch,
            fromDeviceName: candidate.oldPreferredName,
            toDeviceName: candidate.newCurrentName,
            occurredAt: Date()
        ))

        Self.trace(
            "decision=accept reason=stable-external-switch-confirmed → \(candidate.newCurrentName)"
        )
        Self.logger.info(
            "decision=accept reason=stable-external-switch-confirmed preferred=\(candidate.newCurrentName, privacy: .public)"
        )
    }

    private func cancelStableExternalSwitchCandidate() {
        stableExternalSwitchCandidate = nil
        stableExternalSwitchCandidateTask?.cancel()
        stableExternalSwitchCandidateTask = nil
    }

    // MARK: - Restore（统一入口）

    /// 唯一的恢复路径：检查在调用方，写入在统一处。
    private func restorePreferred(
        from current: AudioInputDevice,
        to preferred: AudioInputDevice,
        reason: RestoreReason
    ) {
        guard protectionEnabled else { return }

        let transactionID = beginProgrammaticSwitch(
            to: preferred.uid,
            origin: .protectionRestore(reason),
            fromDeviceName: current.name,
            toDeviceName: preferred.name,
            notification: pendingNotificationForRestore(
                from: current.name,
                to: preferred.name,
                reason: reason
            )
        )

        do {
            try provider.setInputDevice(uid: preferred.uid)
        } catch {
            // Protection restore 与一次性的 UI 选择不同：目标仍在线时，一次 setter 失败
            // 只说明本次请求没有完成，不足以放弃保护。保留 PendingSwitch，让 watchdog
            // 继续退避重试；具体 lookup / HAL / OSStatus 原因保留在结构化日志中。
            lastError = Self.protectionSwitchSetterRejectedRetryingError
            protectionRetryState = .setterRejected
            Self.logger.error(
                "RESTORE_SETTER_REJECTED_RETRYING reason=\(reason, privacy: .public) target=\(preferred.name, privacy: .public) providerError=\(String(describing: error), privacy: .public)"
            )
            if case .awaitingConfirmation(let pending) = programmaticSwitchState,
               pending.id == transactionID
            {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
            return
        }

        if lastError != Self.protectionSwitchRetryingError {
            lastError = nil
        }

        // 恢复后重新开启 settle window：
        // 系统/蓝牙子系统可能立刻再次抢麦，直到稳定前继续保护。
        markTopologyUnsettled()

        // setter 返回成功不等于 CoreAudio 已经切换；重新读取真实 current，
        // 同步生效时可立即确认，异步生效时等待 listener callback。
        refreshCurrentDevice()

        if finishProgrammaticSwitchIfConfirmed() {
            Self.logger.info(
                "RESTORE_CONFIRMED \(current.name, privacy: .public) → \(preferred.name, privacy: .public) reason=\(reason, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "RESTORE_PENDING_CONFIRMATION target=\(preferred.name, privacy: .public)"
            )
            if case .awaitingConfirmation(let pending) = programmaticSwitchState {
                scheduleProgrammaticSwitchWatchdog(for: pending)
            }
        }
    }

    // MARK: - Programmatic Switch Transaction

    /// 开始一笔由 MicLock 发起的切换事务。新事务会原子地取代旧事务，
    /// 因此 source / target / Recent Event / notification 不会跨两次操作串线。
    ///
    /// 事务不设置固定确认超时：HAL 何时真正反映 setter 没有时间保证。
    /// 时间只用于 watchdog recheck/retry；成功/失败仍由可靠可观察事实决定。
    @discardableResult
    private func beginProgrammaticSwitch(
        to uid: String,
        origin: ProgrammaticSwitchOrigin,
        fromDeviceName: String?,
        toDeviceName: String,
        notification: PendingNotification?
    ) -> UInt64 {
        cancelStableExternalSwitchCandidate()
        // 新 MicLock 动作属于更高优先级事实：完整 supersede 旧事务，
        // 同时清理旧事务留下的 retrying UI 状态。
        cancelProgrammaticSwitch()
        nextProgrammaticSwitchID &+= 1
        let id = nextProgrammaticSwitchID
        let pending = PendingSwitch(
            id: id,
            sourceUID: currentDevice?.uid,
            targetUID: uid,
            origin: origin,
            fromDeviceName: fromDeviceName,
            toDeviceName: toDeviceName,
            notification: notification,
            retryAttempt: 0
        )
        programmaticSwitchState = .awaitingConfirmation(pending)
        return id
    }

    private func cancelProgrammaticSwitch() {
        programmaticSwitchState = .idle
        programmaticSwitchWatchdogTask?.cancel()
        programmaticSwitchWatchdogTask = nil
        protectionRetryState = nil

        // retrying 文案只描述当前仍存活的程序化事务。事务被明确取消、
        // supersede、切模式或关闭保护后，保护/用户选择两类瞬态错误都不能残留。
        if lastError == Self.protectionSwitchRetryingError
            || lastError == Self.protectionSwitchSetterRejectedRetryingError
            || lastError == Self.userSelectionRetryingError
            || lastError == Self.userSelectionSetterRejectedRetryingError
        {
            lastError = nil
        }
    }

    private func failProgrammaticSwitch(id: UInt64, error: String) {
        guard case .awaitingConfirmation(let pending) = programmaticSwitchState,
              pending.id == id
        else { return }

        cancelProgrammaticSwitch()
        lastError = error
    }

    /// 仅在 provider 已经读到本事务目标设备时确认程序化切换。
    @discardableResult
    private func finishProgrammaticSwitchIfConfirmed() -> Bool {
        guard case .awaitingConfirmation(var pending) = programmaticSwitchState,
              currentDevice?.uid == pending.targetUID
        else { return false }

        // Auto 下 protection restore 的“真实确认”本身也是 protection activity。
        // 某个更早已 accepted 的 setter 可能在旧 settle episode 结束后才真正反映到 HAL；
        // 如果确认时仍保持 stable，紧接着的再次抢麦会被误分类为稳定外部切换。
        // 因此从真实 target confirmation 时刻重新锚定 settle，并把既有 notification
        // 迁移到当前 episode；Trusted User Selection 不参与 protection settle。
        if case .protectionRestore = pending.origin,
           protectionMode == .auto
        {
            markTopologyUnsettled()
            rebindPendingNotificationToCurrentEpisode(&pending)
        }

        cancelProgrammaticSwitch()
        lastError = nil

        // Recent Event 的时间是确认时间，而不是 setter 请求时间；
        // 事件语义只从 transaction origin 推导，避免 origin/event kind 双写不一致。
        let eventKind: RecentAudioEvent.Kind
        switch pending.origin {
        case .trustedUserSelection:
            eventKind = .selectedInMicLock
        case .protectionRestore(let reason):
            eventKind = .restored(reason)
        }

        recordRecentAudioEvent(RecentAudioEvent(
            kind: eventKind,
            fromDeviceName: pending.fromDeviceName,
            toDeviceName: pending.toDeviceName,
            occurredAt: Date()
        ))

        commitNotification(pending.notification, origin: pending.origin)
        return true
    }

    private func scheduleProgrammaticSwitchWatchdog(for pending: PendingSwitch) {
        guard programmaticSwitchWatchdogTask == nil else { return }

        let index = min(pending.retryAttempt, Self.programmaticSwitchRetryDelays.count - 1)
        let delay = Self.programmaticSwitchRetryDelays[index]
        let transactionID = pending.id
        programmaticSwitchWatchdogTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            guard case .awaitingConfirmation(let currentPending) = self.programmaticSwitchState,
                  currentPending.id == transactionID
            else { return }

            self.programmaticSwitchWatchdogTask = nil
            self.reconcileCoreAudioState(trigger: .programmaticSwitchWatchdog)
        }
    }

    private func retryProgrammaticSwitch(_ pending: PendingSwitch) {
        guard case .awaitingConfirmation(var currentPending) = programmaticSwitchState,
              currentPending.id == pending.id
        else { return }

        // retryAttempt 表示退避阶段而非无限增长的总次数。到达最后一档后保持在
        // capped 64s 间隔继续主动重试，直到出现确认/离线/supersede 等明确事实。
        if currentPending.retryAttempt < Self.programmaticSwitchRetryDelays.count {
            currentPending.retryAttempt += 1
        }
        programmaticSwitchState = .awaitingConfirmation(currentPending)

        let accepted: Bool
        let setterError: Error?
        do {
            try provider.setInputDevice(uid: currentPending.targetUID)
            accepted = true
            setterError = nil
        } catch {
            accepted = false
            setterError = error
        }

        // 只有 protection restore 被 CoreAudio 接受时才重新开启/延长 settle。
        // Trusted User Action 不制造 protection episode。若 transaction 本来就携带
        // Auto notification，则把它迁移到新的/延长后的当前 episode；nil 绝不补造。
        if accepted,
           case .protectionRestore = currentPending.origin
        {
            markProtectionRetryAccepted(&currentPending)
            // confirmation 必须读取更新后的 notification metadata。
            programmaticSwitchState = .awaitingConfirmation(currentPending)
        }

        refreshCurrentDevice()

        if finishProgrammaticSwitchIfConfirmed() {
            Self.logger.info(
                "PROGRAMMATIC_SWITCH retry confirmed id=\(currentPending.id, privacy: .public) attempt=\(currentPending.retryAttempt, privacy: .public)"
            )
            return
        }

        let setterErrorDescription = setterError.map { String(describing: $0) } ?? "none"
        Self.logger.warning(
            "PROGRAMMATIC_SWITCH retry id=\(currentPending.id, privacy: .public) attempt=\(currentPending.retryAttempt, privacy: .public) setterAccepted=\(accepted, privacy: .public) providerError=\(setterErrorDescription, privacy: .public)"
        )

        updateProgrammaticSwitchRetryStatus(
            for: currentPending,
            setterAccepted: accepted
        )

        if case .awaitingConfirmation(let stillPending) = programmaticSwitchState,
           stillPending.id == currentPending.id
        {
            scheduleProgrammaticSwitchWatchdog(for: stillPending)
        }
    }

    private func markProtectionRetryAccepted(_ pending: inout PendingSwitch) {
        markTopologyUnsettled()

        guard protectionMode == .auto else { return }
        rebindPendingNotificationToCurrentEpisode(&pending)
    }

    private func rebindPendingNotificationToCurrentEpisode(_ pending: inout PendingSwitch) {
        guard let notification = pending.notification,
              case .settling(let episode) = stabilityState
        else { return }

        pending.notification = PendingNotification(
            from: notification.from,
            to: notification.to,
            episodeID: episode.id
        )
    }

    private func updateProgrammaticSwitchRetryStatus(
        for pending: PendingSwitch,
        setterAccepted: Bool
    ) {
        switch pending.origin {
        case .protectionRestore:
            if !setterAccepted {
                lastError = Self.protectionSwitchSetterRejectedRetryingError
                protectionRetryState = .setterRejected
            } else if pending.retryAttempt >= Self.programmaticSwitchRetryWarningAttempt {
                // 时间经过本身既不能宣告 HAL failure，也不能把仍停留在 source 的状态
                // 重新交给 Auto 分类，否则会把原本正在抵抗的 hijack 反向学习为 preferred。
                lastError = Self.protectionSwitchRetryingError
                protectionRetryState = .awaitingConfirmation
            } else if lastError == Self.protectionSwitchSetterRejectedRetryingError {
                // 上一次 retry 被拒绝，但这次请求已重新被接受；在进入长期 retry 阶段前，
                // 不再保留已经过时的“setter rejected”状态。
                lastError = nil
                protectionRetryState = nil
            }

        case .trustedUserSelection:
            // 用户显式选择可以继续复用 watchdog，但它不是 protection 行为：
            // 不触碰 ProtectionRetryState，只提供中性的操作状态文案。
            if !setterAccepted {
                lastError = Self.userSelectionSetterRejectedRetryingError
            } else if pending.retryAttempt >= Self.programmaticSwitchRetryWarningAttempt {
                lastError = Self.userSelectionRetryingError
            } else if lastError == Self.userSelectionSetterRejectedRetryingError {
                lastError = nil
            }
        }
    }

    private func recordRecentAudioEvent(_ event: RecentAudioEvent) {
        recentAudioEvents.insert(event, at: 0)
        if recentAudioEvents.count > Self.recentAudioEventLimit {
            recentAudioEvents.removeLast(recentAudioEvents.count - Self.recentAudioEventLimit)
        }
    }

    // MARK: - Notification 去重

    private func pendingNotificationForRestore(
        from: String,
        to: String,
        reason: RestoreReason
    ) -> PendingNotification? {
        guard notificationsEnabled else { return nil }
        guard reason != .startup else { return nil }

        if protectionMode == .auto,
           case .settling(let episode) = stabilityState
        {
            guard !episode.notificationSent else { return nil }
            return PendingNotification(
                from: from,
                to: to,
                episodeID: episode.id
            )
        }

        return PendingNotification(
            from: from,
            to: to,
            episodeID: nil
        )
    }

    private func commitNotification(
        _ pending: PendingNotification?,
        origin: ProgrammaticSwitchOrigin
    ) {
        guard let pending else { return }
        guard case .protectionRestore(let reason) = origin else { return }

        // 用户可能在事务确认前关闭通知；没有真正发送就不能消耗
        // 当前 settle episode 的 notificationSent 去重额度。
        guard notificationsEnabled else { return }

        // Auto notification 只修改它当前绑定的 episode。watchdog accepted retry
        // 若开启了新的 episode，会先 rebind PendingNotification，再进入这里。
        if let episodeID = pending.episodeID,
           case .settling(var episode) = stabilityState,
           episode.id == episodeID
        {
            guard !episode.notificationSent else { return }
            episode.notificationSent = true
            stabilityState = .settling(episode)
        }

        Self.logger.info(
            "NOTIFICATION_SENT \(pending.from, privacy: .public) → \(pending.to, privacy: .public)"
        )

        notifier.presentRestored(from: pending.from, to: pending.to, reason: reason)
    }

    // MARK: - Stability State Machine

    /// 返回当前拓扑是否稳定；timer 尚未获得执行机会但 deadline 已过时，
    /// 这里也会同步完成状态转换，确保决策只依赖一个事实来源。
    private func isTopologySettled() -> Bool {
        switch stabilityState {
        case .stable:
            return true

        case .settling(let episode):
            guard scheduler.now >= episode.deadline else { return false }
            finishSettleEpisode(id: episode.id, revision: episode.revision)
            return true
        }
    }

    /// 真实拓扑变化或一次 corrective restore 都会使拓扑进入/继续 settling。
    /// 已存在 episode 时只延长同一 episode，保留 notificationSent。
    private func markTopologyUnsettled() {
        let now = scheduler.now
        let deadline = now.advanced(by: .seconds(settleSeconds))
        let episode: SettleEpisode

        switch stabilityState {
        case .stable:
            nextSettleEpisodeID &+= 1
            episode = SettleEpisode(
                id: nextSettleEpisodeID,
                revision: 1,
                lastActivity: now,
                deadline: deadline,
                notificationSent: false
            )

        case .settling(var current):
            current.revision &+= 1
            current.lastActivity = now
            current.deadline = deadline
            episode = current
        }

        stabilityState = .settling(episode)
        scheduleSettleTask(for: episode)

        Self.trace(
            "TOPOLOGY_SETTLING episode=\(episode.id) revision=\(episode.revision) settle=\(settleSeconds)"
        )
        Self.logger.debug(
            "TOPOLOGY_SETTLING episode=\(episode.id, privacy: .public) revision=\(episode.revision, privacy: .public) settle=\(self.settleSeconds, privacy: .public)"
        )
    }

    /// settleSeconds 在 episode 运行中修改时，以最后一次 activity 为基点立即生效。
    private func rescheduleActiveSettleEpisodeForConfigurationChange() {
        guard case .settling(var episode) = stabilityState else { return }

        episode.revision &+= 1
        episode.deadline = episode.lastActivity.advanced(by: .seconds(settleSeconds))

        if scheduler.now >= episode.deadline {
            stabilityState = .settling(episode)
            finishSettleEpisode(id: episode.id, revision: episode.revision)
            return
        }

        stabilityState = .settling(episode)
        scheduleSettleTask(for: episode)

        Self.trace(
            "TOPOLOGY_SETTLING_RESCHEDULE episode=\(episode.id) revision=\(episode.revision) settle=\(settleSeconds)"
        )
    }

    private func scheduleSettleTask(for episode: SettleEpisode) {
        settleTask?.cancel()

        let delay = scheduler.now.duration(to: episode.deadline)
        settleTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.finishSettleEpisode(id: episode.id, revision: episode.revision)
        }
    }

    private func finishSettleEpisode(id: UInt64, revision: UInt64) {
        guard case .settling(let episode) = stabilityState,
              episode.id == id,
              episode.revision == revision,
              scheduler.now >= episode.deadline
        else { return }

        stabilityState = .stable
        settleTask?.cancel()
        settleTask = nil

        Self.trace("TOPOLOGY_STABLE episode=\(id) revision=\(revision)")
        Self.logger.debug(
            "TOPOLOGY_STABLE episode=\(id, privacy: .public) revision=\(revision, privacy: .public)"
        )
    }

    // MARK: - Notification Authorization

    /// 检查（必要时请求）通知授权，并更新 UI 提示状态。
    func refreshNotificationAuthorization() async {
        let state = await notifier.ensureAuthorization()
        notificationDenied = (state == .denied)

        Self.logger.info(
            "NOTIFICATION_AUTH status=\(state == .authorized ? "authorized" : state == .denied ? "denied" : "notDetermined", privacy: .public)"
        )
    }

    // MARK: - Refresh

    private func refreshDeviceList(initial: Bool = false) {
        let snapshot: AudioInputDeviceSnapshot
        do {
            snapshot = try provider.listInputDevices()
        } catch {
            deviceEnumerationError = "Unable to enumerate input devices"
            if initial {
                startupTopologyRecoveryPending = true
            }
            Self.logger.error(
                "DEVICE_LIST enumeration failed providerError=\(String(describing: error), privacy: .public)"
            )
            _ = refreshCurrentDevice(scheduleRecoveryOnFailure: !initial)
            return
        }

        let newDevices = snapshot.devices
        devices = Self.sortedDevices(newDevices)
        recordDeviceNames(newDevices)

        if !snapshot.isComplete {
            deviceEnumerationError = "Some input device properties are temporarily unreadable"
            if initial {
                startupTopologyRecoveryPending = true
            }
            Self.logger.error(
                "DEVICE_LIST partial snapshot incompleteDeviceIDs=\(String(describing: snapshot.incompleteDeviceIDs), privacy: .public) issues=\(String(describing: snapshot.issues), privacy: .public)"
            )
            _ = refreshCurrentDevice(scheduleRecoveryOnFailure: !initial)
            return
        }

        deviceEnumerationError = nil

        guard refreshCurrentDevice(scheduleRecoveryOnFailure: !initial) else {
            if initial {
                startupTopologyRecoveryPending = true
            }
            return
        }

        let newCurrent = currentDevice
        let newUIDs = Set(newDevices.map(\.uid))

        // Devices / DefaultInput 不是原子 snapshot。首次启动时如果 current 不在本轮
        // devices 中，不把这份联合采样当作可信 baseline；等 start() 后主动 recovery。
        if initial,
           let newCurrent,
           !newUIDs.contains(newCurrent.uid)
        {
            startupTopologyRecoveryPending = true
            deviceEnumerationError = "CoreAudio input device state is temporarily inconsistent"
            Self.logger.error("DEVICE_LIST initial topology inconsistent")
            return
        }

        trustedDevices = devices
        connectedUIDs = newUIDs

        // 初始枚举：所有现存设备视为稳定，不开 settle window。
        if !initial, connectedUIDs.isEmpty {
            Self.logger.debug("DEVICE_LIST_EMPTY")
        }
    }

    /// Fresh install 的 preferred 只从可信 topology 初始化：优先内置麦克风；
    /// 没有内置设备时，只有 current 本身也属于这份 topology 才允许 fallback。
    private func initializeFirstRunPreferredIfNeeded(
        devices: [AudioInputDevice],
        current: AudioInputDevice?
    ) {
        guard preferredMicrophoneUID == nil else { return }

        if let builtIn = devices.first(where: \.isBuiltIn) {
            preferredMicrophoneUID = builtIn.uid
            return
        }

        guard let current,
              devices.contains(where: { $0.uid == current.uid })
        else { return }

        preferredMicrophoneUID = current.uid
    }

    /// 读取真实默认输入。失败时保留最后一次可信 current；调用方可选择安排 recovery。
    @discardableResult
    private func refreshCurrentDevice(scheduleRecoveryOnFailure: Bool = true) -> Bool {
        do {
            currentDevice = try provider.currentInputDevice()
            return true
        } catch {
            deviceEnumerationError = "Unable to read current input device"
            Self.logger.error(
                "CURRENT_INPUT_READ_FAILED providerError=\(String(describing: error), privacy: .public)"
            )
            if scheduleRecoveryOnFailure {
                scheduleTopologySampleRecovery()
            }
            return false
        }
    }

    /// 更新并持久化最近已知设备名，离线设备在 UI 上仍可显示可读名字。
    private func recordDeviceNames(_ newDevices: [AudioInputDevice]) {
        var changed = false

        for device in newDevices where lastKnownDeviceNames[device.uid] != device.name {
            lastKnownDeviceNames[device.uid] = device.name
            changed = true
        }

        if changed {
            preferences.lastKnownDeviceNames = lastKnownDeviceNames
        }
    }

    private static func sortedDevices(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.sorted {
            if $0.isBuiltIn != $1.isBuiltIn {
                return $0.isBuiltIn
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Listener Installation

    @discardableResult
    private func installListeners() -> Bool {
        guard !listenersInstalled else { return true }

        let result = listenerBox.install(
            onDefaultInputChange: { [weak self] in
                self?.handleDefaultInputChanged()
            },
            onDevicesChange: { [weak self] in
                self?.handleDeviceListChanged()
            }
        )

        guard result.defaultInputStatus == noErr,
              result.devicesStatus == noErr
        else {
            listenersInstalled = false

            listenerError = "Unable to install CoreAudio listeners "
                + "(defaultInput: \(result.defaultInputStatus), "
                + "devices: \(result.devicesStatus))"

            Self.logger.error(
                "listener install failed defaultInput=\(result.defaultInputStatus, privacy: .public) devices=\(result.devicesStatus, privacy: .public)"
            )
            return false
        }

        listenersInstalled = true
        listenerError = nil
        return true
    }
}
