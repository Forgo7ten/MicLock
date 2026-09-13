import Foundation
import CoreAudio
import OSLog
import Observation

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

    /// CoreAudio 监听基础能力失败；独立于一次性设备操作错误。
    private(set) var listenerError: String?

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
        }
    }

    // MARK: - Dependencies

    private let provider: AudioDeviceProviding
    private let preferences: Preferences
    private let notifier: NotificationPresenting

    // MARK: - Settle State Machine

    /// 时间间隔判断使用 monotonic clock。
    private let clock = ContinuousClock()

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

    /// Auto Mode 的稳定性状态是策略事实来源；Task 只负责唤醒，不承载业务状态。
    @ObservationIgnored private var stabilityState: StabilityState = .stable
    @ObservationIgnored private var nextSettleEpisodeID: UInt64 = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    @ObservationIgnored private var connectedUIDs: Set<String> = []

    /// Auto + stable 下观察到的外部 default 变化先进入候选态。
    /// 这只延迟 preferred 的学习，不延迟 currentDevice UI，也不延迟 settling 内的 corrective restore。
    private struct StableExternalSwitchCandidate {
        let id: UInt64
        let oldPreferredUID: String
        let oldPreferredName: String
        let newCurrentUID: String
        let newCurrentName: String
    }

    @ObservationIgnored private var stableExternalSwitchCandidate: StableExternalSwitchCandidate?
    @ObservationIgnored private var nextStableExternalSwitchCandidateID: UInt64 = 0
    @ObservationIgnored private var stableExternalSwitchCandidateTask: Task<Void, Never>?

    /// 仅用于等待分阶段 HAL 属性变化收敛；不是 restore delay，也不是程序化切换 timeout。
    private static let stableExternalSwitchClassificationDelay: Duration = .milliseconds(200)

    private struct PendingEventDraft {
        let kind: RecentAudioEvent.Kind
        let fromDeviceName: String?
        let toDeviceName: String
    }

    private struct PendingNotification {
        let from: String
        let to: String
        let reason: RestoreReason
        let episodeID: UInt64?
    }

    private struct PendingSwitch {
        let id: UInt64
        let sourceUID: String?
        let targetUID: String
        let event: PendingEventDraft
        let notification: PendingNotification?
    }

    private enum ProgrammaticSwitchState {
        case idle
        case awaitingConfirmation(PendingSwitch)
    }

    /// MicLock 自己发起的切换事务；目标、解释事件与通知必须原子地属于同一笔事务。
    @ObservationIgnored private var programmaticSwitchState: ProgrammaticSwitchState = .idle

    @ObservationIgnored private var nextProgrammaticSwitchID: UInt64 = 0

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
        notifier: NotificationPresenting
    ) {
        self.provider = provider
        self.preferences = preferences
        self.notifier = notifier

        preferredMicrophoneUID = preferences.preferredMicrophoneUID
        protectionEnabled = preferences.protectionEnabled
        protectionMode = preferences.protectionMode
        notificationsEnabled = preferences.notificationsEnabled
        settleSeconds = preferences.settleSeconds
        lastKnownDeviceNames = preferences.lastKnownDeviceNames

        refreshDeviceList(initial: true)

        // 首次运行：默认选择内置麦克风。
        if preferredMicrophoneUID == nil {
            let preferred = devices.first { $0.isBuiltIn } ?? currentDevice
            if let preferred {
                preferredMicrophoneUID = preferred.uid
                preferences.preferredMicrophoneUID = preferred.uid
            }
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
              !devices.contains(where: { $0.uid == uid })
        else { return nil }

        return lastKnownDeviceNames[uid] ?? "Unknown device"
    }

    var isPreferredMicrophoneAvailable: Bool {
        guard let uid = preferredMicrophoneUID else { return false }
        return devices.contains { $0.uid == uid }
    }

    /// 用户在 MicLock UI 主动选择设备：Trusted User Action。
    ///
    /// 不受 settle window 限制，setter 成功后提交 preferred 并切换。
    func selectDevice(_ device: AudioInputDevice) {
        Self.logger.info("USER_SELECT \(device.name, privacy: .public)")

        let transactionID = beginProgrammaticSwitch(
            to: device.uid,
            event: PendingEventDraft(
                kind: .selectedInMicLock,
                fromDeviceName: currentDevice?.name,
                toDeviceName: device.name
            ),
            notification: nil
        )

        if provider.setInputDevice(uid: device.uid) {
            // setter 成功只代表 CoreAudio 接受了写操作；preferred 可以提交，
            // 但 currentDevice 仍必须来自 provider 的真实读取。
            preferredMicrophoneUID = device.uid
            lastError = nil

            refreshCurrentDevice()
            if finishProgrammaticSwitchIfConfirmed() {
                Self.logger.debug(
                    "USER_SELECT confirmed immediately uid=\(device.uid, privacy: .public)"
                )
            }
        } else {
            failProgrammaticSwitch(
                id: transactionID,
                error: "Unable to set default input device"
            )
            Self.logger.error("USER_SELECT failed uid=\(device.uid, privacy: .public)")
        }
    }

    /// 启动 / 切换模式 / 开启保护时的对齐：
    /// protection 开且 preferred 在线且 current != preferred → 恢复（不通知）。
    func evaluateStartupPolicy() {
        guard protectionEnabled,
              let preferredUID = preferredMicrophoneUID,
              let preferred = devices.first(where: { $0.uid == preferredUID }),
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
        let newDevices = provider.listInputDevices()
        let newCurrent = provider.currentInputDevice()
        let newUIDs = Set(newDevices.map(\.uid))
        let added = newUIDs.subtracting(connectedUIDs)
        let removed = connectedUIDs.subtracting(newUIDs)
        let topologyChanged = !added.isEmpty || !removed.isEmpty

        // 1. topology 永远先于 default-input policy 更新。
        devices = Self.sortedDevices(newDevices)
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

        // 2. 使用同一份 CoreAudio snapshot 更新真实 current。
        currentDevice = newCurrent

        // target 是否仍在线不依赖 current 存在；即使所有输入设备都消失，
        // 也要先用这个明确事实结束不可达的 pending transaction。
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

        guard let current = currentDevice else { return }

        // 3. MicLock 自己触发的变化优先于 Auto / Manual policy。
        // PendingSwitch 不再因为固定时间到点而失败，只根据可观察事实推进：
        // target 出现 => 成功；第三个 current => 被外部变化取代；仍是 source => 等待。
        if case .awaitingConfirmation(let pending) = programmaticSwitchState {
            Self.trace(
                "CORE_AUDIO_RECONCILE current=\(current.name) source=\(pending.sourceUID ?? "nil") target=\(pending.targetUID)"
            )

            if finishProgrammaticSwitchIfConfirmed() {
                Self.logger.debug(
                    "PROGRAMMATIC_SWITCH confirmed → \(current.name, privacy: .public)"
                )
                return
            }

            if let sourceUID = pending.sourceUID,
               current.uid != sourceUID
            {
                cancelProgrammaticSwitch()
                Self.logger.info(
                    "PROGRAMMATIC_SWITCH superseded id=\(pending.id, privacy: .public) current=\(current.uid, privacy: .public)"
                )
                // current 既不是 source 也不是 target，说明出现了新的外部事实；
                // 放弃旧事务并让下面的 policy 对这个 snapshot 重新分类。
            } else {
                Self.logger.debug(
                    "PROGRAMMATIC_SWITCH still pending current=\(current.name, privacy: .public) target=\(pending.targetUID, privacy: .public)"
                )
                return
            }
        }

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
           let preferred = devices.first(where: { $0.uid == preferredUID }),
           current.uid != preferred.uid
        {
            restorePreferred(from: current, to: preferred, reason: .preferredReconnected)
            return
        }

        if current.uid == preferredUID {
            cancelStableExternalSwitchCandidate()
            return
        }

        guard let preferred = devices.first(where: { $0.uid == preferredUID }) else {
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
                      candidate.newCurrentUID == current.uid
            {
                commitStableExternalSwitchCandidate(candidate)
            } else {
                beginStableExternalSwitchCandidate(from: preferred, to: current)
            }
        }
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
            return
        }

        cancelStableExternalSwitchCandidate()

        nextStableExternalSwitchCandidateID &+= 1
        let candidate = StableExternalSwitchCandidate(
            id: nextStableExternalSwitchCandidateID,
            oldPreferredUID: preferred.uid,
            oldPreferredName: preferred.name,
            newCurrentUID: current.uid,
            newCurrentName: current.name
        )
        stableExternalSwitchCandidate = candidate

        Self.trace(
            "STABLE_EXTERNAL_SWITCH_CANDIDATE id=\(candidate.id) from=\(preferred.name) to=\(current.name)"
        )
        Self.logger.debug(
            "STABLE_EXTERNAL_SWITCH_CANDIDATE id=\(candidate.id, privacy: .public) from=\(preferred.uid, privacy: .public) to=\(current.uid, privacy: .public)"
        )

        stableExternalSwitchCandidateTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stableExternalSwitchClassificationDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.stableExternalSwitchCandidate?.id == candidate.id else { return }
            self.reconcileCoreAudioState(trigger: .stableExternalSwitchConfirmation)
        }
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
            event: PendingEventDraft(
                kind: .restored(reason),
                fromDeviceName: current.name,
                toDeviceName: preferred.name
            ),
            notification: pendingNotificationForRestore(
                from: current.name,
                to: preferred.name,
                reason: reason
            )
        )

        let ok = provider.setInputDevice(uid: preferred.uid)

        guard ok else {
            failProgrammaticSwitch(
                id: transactionID,
                error: "Unable to set default input device"
            )
            Self.logger.error("RESTORE_FAILURE reason=\(reason, privacy: .public) target=\(preferred.name, privacy: .public)")
            return
        }

        lastError = nil

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
        }
    }

    // MARK: - Programmatic Switch Transaction

    /// 开始一笔由 MicLock 发起的切换事务。新事务会原子地取代旧事务，
    /// 因此 source / target / Recent Event / notification 不会跨两次操作串线。
    ///
    /// 事务不设置固定确认超时：HAL 何时真正反映 setter 没有时间保证。
    /// 后续由完整 CoreAudio snapshot 的可观察事实确认、取消或 supersede。
    @discardableResult
    private func beginProgrammaticSwitch(
        to uid: String,
        event: PendingEventDraft,
        notification: PendingNotification?
    ) -> UInt64 {
        cancelStableExternalSwitchCandidate()
        nextProgrammaticSwitchID &+= 1
        let id = nextProgrammaticSwitchID
        let pending = PendingSwitch(
            id: id,
            sourceUID: currentDevice?.uid,
            targetUID: uid,
            event: event,
            notification: notification
        )
        programmaticSwitchState = .awaitingConfirmation(pending)
        return id
    }

    private func cancelProgrammaticSwitch() {
        programmaticSwitchState = .idle
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
        guard case .awaitingConfirmation(let pending) = programmaticSwitchState,
              currentDevice?.uid == pending.targetUID
        else { return false }

        cancelProgrammaticSwitch()

        // Recent Event 的时间是确认时间，而不是 setter 请求时间。
        recordRecentAudioEvent(RecentAudioEvent(
            kind: pending.event.kind,
            fromDeviceName: pending.event.fromDeviceName,
            toDeviceName: pending.event.toDeviceName,
            occurredAt: Date()
        ))

        commitNotification(pending.notification)
        return true
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
                reason: reason,
                episodeID: episode.id
            )
        }

        return PendingNotification(
            from: from,
            to: to,
            reason: reason,
            episodeID: nil
        )
    }

    private func commitNotification(_ pending: PendingNotification?) {
        guard let pending else { return }

        // 用户可能在事务确认前关闭通知；没有真正发送就不能消耗
        // 当前 settle episode 的 notificationSent 去重额度。
        guard notificationsEnabled else { return }

        // Auto notification 只修改创建它的 episode；旧事务晚到的 confirmation
        // 绝不能把一个更新的 episode 标记成已通知。
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

        notifier.presentRestored(from: pending.from, to: pending.to, reason: pending.reason)
    }

    // MARK: - Stability State Machine

    /// 返回当前拓扑是否稳定；timer 尚未获得执行机会但 deadline 已过时，
    /// 这里也会同步完成状态转换，确保决策只依赖一个事实来源。
    private func isTopologySettled() -> Bool {
        switch stabilityState {
        case .stable:
            return true

        case .settling(let episode):
            guard clock.now >= episode.deadline else { return false }
            finishSettleEpisode(id: episode.id, revision: episode.revision)
            return true
        }
    }

    /// 真实拓扑变化或一次 corrective restore 都会使拓扑进入/继续 settling。
    /// 已存在 episode 时只延长同一 episode，保留 notificationSent。
    private func markTopologyUnsettled() {
        let now = clock.now
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

        if clock.now >= episode.deadline {
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

        let delay = clock.now.duration(to: episode.deadline)
        settleTask = Task { [weak self] in
            guard let self else { return }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self.finishSettleEpisode(id: episode.id, revision: episode.revision)
        }
    }

    private func finishSettleEpisode(id: UInt64, revision: UInt64) {
        guard case .settling(let episode) = stabilityState,
              episode.id == id,
              episode.revision == revision,
              clock.now >= episode.deadline
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
        let newDevices = provider.listInputDevices()

        devices = Self.sortedDevices(newDevices)
        connectedUIDs = Set(newDevices.map(\.uid))

        recordDeviceNames(newDevices)

        // 初始枚举：所有现存设备视为稳定，不开 settle window。
        if !initial, connectedUIDs.isEmpty {
            Self.logger.debug("DEVICE_LIST_EMPTY")
        }

        refreshCurrentDevice()
    }

    private func refreshCurrentDevice() {
        currentDevice = provider.currentInputDevice()
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
