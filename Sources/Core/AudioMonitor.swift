import Foundation
import CoreAudio
import OSLog
import Observation

/// 麦克风保护状态机（Auto / Manual）。
///
/// 职责：settle window、新设备跟踪、self-induced 回调识别、
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

    /// 通知权限被系统拒绝时提示用户去系统设置开启。
    private(set) var notificationDenied = false

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

            if protectionEnabled {
                // 开启即对齐（等同启动策略，不通知）。
                evaluateStartupPolicy()
            } else {
                // Protection OFF：只监控与刷新，不执行任何策略、不学习。
                pendingRestoreNotification = nil
                clearExpectedDefaultSwitch()
            }
        }
    }

    var protectionMode: ProtectionMode {
        didSet {
            guard protectionMode != oldValue else { return }
            preferences.protectionMode = protectionMode
            Self.logger.info("MODE=\(self.protectionMode.rawValue, privacy: .public)")

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
        }
    }

    // MARK: - Dependencies

    private let provider: AudioDeviceProviding
    private let preferences: Preferences
    private let notifier: NotificationPresenting

    // MARK: - Settle State Machine

    /// 时间间隔判断使用 monotonic clock。
    private let clock = ContinuousClock()

    @ObservationIgnored private var lastTopologyChange: ContinuousClock.Instant?

    @ObservationIgnored private var settleTask: Task<Void, Never>?

    @ObservationIgnored private var connectedUIDs: Set<String> = []

    /// 刚接入、尚未确认稳定的新设备。
    /// 设备稳定后自动移出，之后用户主动切换到该设备会被接受。
    @ObservationIgnored private var unsettledNewUIDs: Set<String> = []

    /// MicLock 自己最后一次 set 期望达到的设备 UID，用于识别 self-induced 回调。
    @ObservationIgnored private var expectedDefaultUID: String?

    /// 用于清理始终无法从 CoreAudio 真实状态确认的程序化切换。
    @ObservationIgnored private var expectedSwitchTimeoutTask: Task<Void, Never>?

    private static let expectedSwitchConfirmationTimeout: Duration = .seconds(1.0)

    /// Auto Mode 保护片段：一次设备拓扑变化期间的所有抢麦/恢复共享
    /// 一个 episode，通知最多发一条。
    @ObservationIgnored private var protectionEpisodeActive = false
    @ObservationIgnored private var protectionEpisodeNotified = false

    /// 待确认的恢复通知：set 成功后挂起，确认 current == preferred 才投递。
    @ObservationIgnored private var pendingRestoreNotification: (from: String, to: String, reason: RestoreReason)?

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
            await self?.refreshNotificationAuthorization()
        }

        Self.logger.info("App start mode=\(self.protectionMode.rawValue, privacy: .public) preferred=\(self.preferredMicrophoneUID ?? "nil", privacy: .public)")
    }

    deinit {
        listenerBox.remove()
    }

    /// 安装 CoreAudio 监听并执行启动策略。
    func start() {
        installListeners()
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

    /// 供 UI 层上报非 CoreAudio 错误（如登录启动注册失败）。
    func reportError(_ message: String) {
        lastError = message
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

        // 用户的新选择取代尚未确认的自动恢复，不应沿用旧通知。
        pendingRestoreNotification = nil
        beginExpectedDefaultSwitch(to: device.uid)

        if provider.setInputDevice(uid: device.uid) {
            // setter 成功只代表 CoreAudio 接受了写操作；preferred 可以提交，
            // 但 currentDevice 仍必须来自 provider 的真实读取。
            preferredMicrophoneUID = device.uid
            lastError = nil

            refreshCurrentDevice()
            if finishExpectedDefaultSwitchIfConfirmed() {
                Self.logger.debug(
                    "USER_SELECT confirmed immediately uid=\(device.uid, privacy: .public)"
                )
            }
        } else {
            clearExpectedDefaultSwitch()
            lastError = "Unable to set default input device"
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

    // MARK: - Device List Changed

    /// 设备列表变化（插拔/重连）。
    ///
    /// burst 事件中集合可能重复不变，此时不重置 settle window（幂等）。
    func handleDeviceListChanged() {
        let newDevices = provider.listInputDevices()
        let newUIDs = Set(newDevices.map(\.uid))
        let added = newUIDs.subtracting(connectedUIDs)
        let removed = connectedUIDs.subtracting(newUIDs)

        guard !added.isEmpty || !removed.isEmpty else {
            Self.logger.debug("DEVICE_LIST_CHANGED (no delta)")
            Self.trace("DEVICE_LIST_CHANGED (no delta)")
            refreshCurrentDevice()
            return
        }

        Self.trace("DEVICE_LIST_CHANGED added=\(added) removed=\(removed)")
        unsettledNewUIDs.formUnion(added)
        unsettledNewUIDs.formIntersection(newUIDs)
        connectedUIDs = newUIDs

        devices = Self.sortedDevices(newDevices)
        recordDeviceNames(newDevices)

        Self.logger.info(
            "DEVICE_LIST_CHANGED added=\(String(describing: added), privacy: .public) removed=\(String(describing: removed), privacy: .public)"
        )

        markTopologyUnsettled()

        // 先读取设备列表变化后的真实 default input，再决定是否需要主动恢复。
        refreshCurrentDevice()

        // preferred 设备重新出现：立即恢复（Auto / Manual 都执行）。
        if let preferredUID = preferredMicrophoneUID, added.contains(preferredUID) {
            handlePreferredReconnected()
        }
    }

    private func handlePreferredReconnected() {
        guard protectionEnabled,
              let preferredUID = preferredMicrophoneUID,
              let preferred = devices.first(where: { $0.uid == preferredUID }),
              let current = currentDevice,
              current.uid != preferred.uid
        else { return }

        restorePreferred(from: current, to: preferred, reason: .preferredReconnected)
    }

    // MARK: - Default Input Changed

    /// 默认输入变化回调。每次开始都重新读取真实状态（幂等）。
    func handleDefaultInputChanged() {
        let previous = currentDevice

        refreshCurrentDevice()

        guard let current = currentDevice else { return }

        // MicLock 自己触发的变化：只有真实 current 已达到 expected 才确认成功。
        Self.trace("DEFAULT_INPUT_CHANGED → \(current.name) expected=\(expectedDefaultUID ?? "nil")")
        if expectedDefaultUID != nil {
            if finishExpectedDefaultSwitchIfConfirmed() {
                Self.logger.debug(
                    "DEFAULT_INPUT_CHANGED (self-induced confirmed) → \(current.name, privacy: .public)"
                )
            } else {
                // CoreAudio 可能先发出中间 callback；在 expected 仍未确认时，
                // 不把中间状态误判为新的外部抢麦，也不重复 setter。
                Self.logger.debug(
                    "DEFAULT_INPUT_CHANGED while waiting expected target; current=\(current.name, privacy: .public)"
                )
            }
            return
        }

        Self.logger.info(
            "DEFAULT_INPUT_CHANGED \(previous?.name ?? "nil", privacy: .public) → \(current.name, privacy: .public) mode=\(self.protectionMode.rawValue, privacy: .public)"
        )

        guard protectionEnabled else { return }

        guard let preferredUID = preferredMicrophoneUID else {
            // 未设置 preferred：学习当前设备。
            preferredMicrophoneUID = current.uid
            return
        }

        // 已经是 preferred：无事可做（幂等，避免 Listener 循环）。
        if current.uid == preferredUID { return }

        guard let preferred = devices.first(where: { $0.uid == preferredUID }) else {
            // preferred 离线：保留 UID，不 fallback，也不学习系统 fallback 设备。
            Self.logger.info(
                "PREFERRED_OFFLINE keep=\(preferredUID, privacy: .public) current=\(current.name, privacy: .public)"
            )
            return
        }

        switch protectionMode {
        case .manual:
            restorePreferred(from: current, to: preferred, reason: .manualLock)

        case .auto:
            let settled = isTopologySettled()
            let isNew = unsettledNewUIDs.contains(current.uid)
            Self.trace("auto: settled=\(settled) isNew=\(isNew) unsettledNew=\(unsettledNewUIDs) lastTopologyChange=\(lastTopologyChange != nil)")
            Self.logger.info(
                "mode=auto settled=\(settled, privacy: .public) newDevice=\(isNew, privacy: .public)"
            )

            if !settled || isNew {
                // 设备接入/断开的不稳定窗口内的变化 → 系统抢麦，立即恢复。
                Self.trace("decision=restore reason=\(!settled ? "topology-unsettled" : "new-device")")
                restorePreferred(from: current, to: preferred, reason: .automaticHijack)
            } else {
                // 设备已稳定 + 非新设备 + 非 self-induced → 用户主动切换，接受。
                preferredMicrophoneUID = current.uid
                Self.trace("decision=accept reason=user-initiated → \(current.name)")
                Self.logger.info(
                    "decision=accept reason=user-initiated preferred=\(current.name, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Restore（统一入口）

    /// 唯一的恢复路径：检查在调用方，写入在统一处。
    private func restorePreferred(
        from current: AudioInputDevice,
        to preferred: AudioInputDevice,
        reason: RestoreReason
    ) {
        guard protectionEnabled else { return }

        beginExpectedDefaultSwitch(to: preferred.uid)

        let ok = provider.setInputDevice(uid: preferred.uid)

        guard ok else {
            clearExpectedDefaultSwitch()
            pendingRestoreNotification = nil
            lastError = "Unable to set default input device"
            Self.logger.error("RESTORE_FAILURE reason=\(reason, privacy: .public) target=\(preferred.name, privacy: .public)")
            return
        }

        lastError = nil

        // 恢复后重新开启 settle window：
        // 系统/蓝牙子系统可能立刻再次抢麦，直到稳定前继续保护。
        markTopologyUnsettled()

        preparePendingNotification(from: current.name, to: preferred.name, reason: reason)

        // setter 返回成功不等于 CoreAudio 已经切换；重新读取真实 current，
        // 同步生效时可立即确认，异步生效时等待 listener callback。
        refreshCurrentDevice()

        if finishExpectedDefaultSwitchIfConfirmed() {
            Self.logger.info(
                "RESTORE_CONFIRMED \(current.name, privacy: .public) → \(preferred.name, privacy: .public) reason=\(reason, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "RESTORE_PENDING_CONFIRMATION target=\(preferred.name, privacy: .public)"
            )
        }
    }

    // MARK: - Expected Switch Lifecycle

    /// 开始一次由 MicLock 发起的切换，并安排无法确认时的最终清理。
    private func beginExpectedDefaultSwitch(to uid: String) {
        expectedSwitchTimeoutTask?.cancel()
        expectedDefaultUID = uid

        expectedSwitchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.expectedSwitchConfirmationTimeout)

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.expectedDefaultUID == uid else { return }

            // timeout 到达时最后再读一次真实 CoreAudio 状态。
            self.refreshCurrentDevice()

            if self.finishExpectedDefaultSwitchIfConfirmed() {
                Self.logger.debug(
                    "EXPECTED_SWITCH confirmed on timeout recheck uid=\(uid, privacy: .public)"
                )
                return
            }

            self.expectedDefaultUID = nil
            self.expectedSwitchTimeoutTask = nil
            self.pendingRestoreNotification = nil
            self.lastError = "Unable to confirm default input device change"

            Self.logger.error("EXPECTED_SWITCH timeout uid=\(uid, privacy: .public)")
        }
    }

    /// 清理 expected 状态；pending restore 通知由调用方按语义单独处理。
    private func clearExpectedDefaultSwitch() {
        expectedDefaultUID = nil
        expectedSwitchTimeoutTask?.cancel()
        expectedSwitchTimeoutTask = nil
    }

    /// 仅在 provider 已经读到目标设备时确认程序化切换。
    @discardableResult
    private func finishExpectedDefaultSwitchIfConfirmed() -> Bool {
        guard let expected = expectedDefaultUID,
              currentDevice?.uid == expected
        else { return false }

        clearExpectedDefaultSwitch()
        completePendingRestoreNotification()
        return true
    }

    // MARK: - Notification 去重

    private func preparePendingNotification(from: String, to: String, reason: RestoreReason) {
        guard notificationsEnabled else { return }
        guard reason != .startup else { return }

        // Auto Mode：一个 protection episode 只通知一次。
        if protectionMode == .auto, protectionEpisodeNotified { return }

        pendingRestoreNotification = (from: from, to: to, reason: reason)
    }

    /// 确认恢复已生效（current == preferred）后才投递挂起的通知。
    private func completePendingRestoreNotification() {
        guard let pending = pendingRestoreNotification else { return }

        guard currentDevice?.uid == preferredMicrophoneUID else { return }

        pendingRestoreNotification = nil

        if protectionMode == .auto {
            protectionEpisodeNotified = true
        }

        guard notificationsEnabled else { return }

        Self.logger.info(
            "NOTIFICATION_SENT \(pending.from, privacy: .public) → \(pending.to, privacy: .public)"
        )

        notifier.presentRestored(from: pending.from, to: pending.to, reason: pending.reason)
    }

    // MARK: - Settle Window

    private func isTopologySettled() -> Bool {
        guard let lastTopologyChange else { return true }
        return lastTopologyChange.duration(to: clock.now) >= .seconds(settleSeconds)
    }

    private func markTopologyUnsettled() {
        Self.trace("TOPOLOGY_UNSETTLED settle=\(settleSeconds)")
        lastTopologyChange = clock.now
        protectionEpisodeActive = true

        settleTask?.cancel()

        let seconds = settleSeconds
        settleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.markTopologySettled()
        }

        Self.logger.debug("TOPOLOGY_UNSETTLED settle=\(seconds, privacy: .public)")
    }

    private func markTopologySettled() {
        guard protectionEpisodeActive else { return }

        // 窗口内没有再出现设备列表事件：所有在线设备视为稳定存在，
        // 之后用户切到“刚接入的设备”应被接受而不是误判抢麦。
        Self.trace("TOPOLOGY_SETTLED")
        unsettledNewUIDs.removeAll()
        protectionEpisodeActive = false
        protectionEpisodeNotified = false
        settleTask = nil

        Self.logger.debug("TOPOLOGY_SETTLED")
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

    private func installListeners() {
        guard !listenersInstalled else { return }

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

            lastError = "Unable to install CoreAudio listeners "
                + "(defaultInput: \(result.defaultInputStatus), "
                + "devices: \(result.devicesStatus))"

            Self.logger.error(
                "listener install failed defaultInput=\(result.defaultInputStatus, privacy: .public) devices=\(result.devicesStatus, privacy: .public)"
            )
            return
        }

        listenersInstalled = true
    }
}
