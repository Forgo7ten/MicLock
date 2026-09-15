import Foundation
import CoreAudio

// MARK: - Fakes

/// 测试用设备提供者：完全内存态，记录 setter 调用。
final class FakeAudioDeviceProvider: AudioDeviceProviding {

    var devices: [AudioInputDevice] = []
    var current: AudioInputDevice?

    /// 每次 setInputDevice 的 uid 参数序列。
    private(set) var setCalls: [String] = []

    /// 强制让 setter 返回失败。
    var forceSetFailure = false

    /// setter 成功后是否立即反映到 current。
    /// 关闭后由测试手动模拟稍后的 CoreAudio 状态传播。
    var applySetImmediately = true

    /// 模拟 setter 返回后，fresh confirmation read 已先观察到另一个设备。
    var currentAfterSetOverride: AudioInputDevice?

    /// 模拟设备枚举失败；nil 表示枚举成功（即使 devices == [] 也属于成功空列表）。
    var listInputDevicesError: Error?

    /// 模拟单个 HAL object 的关键属性读取失败；非空时返回 partial snapshot。
    var incompleteDeviceIDs: [AudioDeviceID] = []

    /// 模拟默认输入读取失败；失败时不能把 monitor 最后一次可信 current 覆盖成 nil。
    var currentInputDeviceError: Error?

    func listInputDevices() throws -> AudioInputDeviceSnapshot {
        if let listInputDevicesError {
            throw listInputDevicesError
        }
        return AudioInputDeviceSnapshot(
            devices: devices,
            incompleteDeviceIDs: incompleteDeviceIDs,
            issues: []
        )
    }

    func currentInputDevice() throws -> AudioInputDevice? {
        if let currentInputDeviceError {
            throw currentInputDeviceError
        }
        return current
    }

    func setInputDevice(uid: String) throws {
        setCalls.append(uid)

        if forceSetFailure {
            throw AudioDeviceProviderError.coreAudio(
                operation: .setDefaultInputDevice,
                objectID: nil,
                status: -1
            )
        }

        guard let device = devices.first(where: { $0.uid == uid }) else {
            throw AudioDeviceProviderError.targetDeviceNotFound(uid: uid)
        }

        if let currentAfterSetOverride {
            current = currentAfterSetOverride
        } else if applySetImmediately {
            current = device
        }
    }
}

final class FakeCoreAudioListeners: CoreAudioListening, @unchecked Sendable {
    var installResults: [CoreAudioListenerInstallResult] = [.installed]
    var retainCallbacksOnFailure = false
    var retainCallbacksOnRemove = false

    private(set) var installCallCount = 0
    private(set) var removeCallCount = 0

    private var onDefaultInputChange: (@MainActor () -> Void)?
    private var onDevicesChange: (@MainActor () -> Void)?

    func install(
        onDefaultInputChange: @escaping @MainActor () -> Void,
        onDevicesChange: @escaping @MainActor () -> Void
    ) -> CoreAudioListenerInstallResult {
        installCallCount += 1
        precondition(!installResults.isEmpty)
        let index = min(installCallCount - 1, installResults.count - 1)
        let result = installResults[index]

        if result == .installed || retainCallbacksOnFailure {
            self.onDefaultInputChange = onDefaultInputChange
            self.onDevicesChange = onDevicesChange
        }

        return result
    }

    func remove() {
        removeCallCount += 1
        guard !retainCallbacksOnRemove else { return }
        onDefaultInputChange = nil
        onDevicesChange = nil
    }

    @MainActor
    func fireDefaultInputChange() {
        onDefaultInputChange?()
    }

    @MainActor
    func fireDevicesChange() {
        onDevicesChange?()
    }
}

final class FakeCoreAudioListenerBackend: CoreAudioListenerBackend {
    var defaultAddResults: [OSStatus] = [noErr]
    var devicesAddResults: [OSStatus] = [noErr]
    var defaultRemoveResults: [OSStatus] = [noErr]
    var devicesRemoveResults: [OSStatus] = [noErr]

    private(set) var defaultAddCount = 0
    private(set) var devicesAddCount = 0
    private(set) var defaultRemoveCount = 0
    private(set) var devicesRemoveCount = 0

    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    var hasRetainedDefaultListener: Bool { defaultListener != nil }
    var hasRetainedDevicesListener: Bool { devicesListener != nil }

    private func result(_ values: [OSStatus], _ index: Int) -> OSStatus {
        values[min(index, values.count - 1)]
    }

    func addDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let status = result(defaultAddResults, defaultAddCount)
        defaultAddCount += 1
        if status == noErr { defaultListener = listener }
        return status
    }

    func addDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let status = result(devicesAddResults, devicesAddCount)
        devicesAddCount += 1
        if status == noErr { devicesListener = listener }
        return status
    }

    func removeDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let status = result(defaultRemoveResults, defaultRemoveCount)
        defaultRemoveCount += 1
        if status == noErr { defaultListener = nil }
        return status
    }

    func removeDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let status = result(devicesRemoveResults, devicesRemoveCount)
        devicesRemoveCount += 1
        if status == noErr { devicesListener = nil }
        return status
    }

    @MainActor
    func fireDefaultInputChange() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) { pointer in
            defaultListener?(1, pointer)
        }
    }

    @MainActor
    func fireDevicesChange() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) { pointer in
            devicesListener?(1, pointer)
        }
    }
}

/// 测试用通知器：记录投递次数。
/// @unchecked Sendable：仅在测试的主 actor 上使用。
final class RecordingNotifier: NotificationPresenting, @unchecked Sendable {

    private(set) var presentCount = 0
    private(set) var listenerFailureCount = 0
    private(set) var passiveAuthorizationReadCount = 0
    private(set) var messages: [String] = []

    var authorizationState: NotificationAuthorizationState = .authorized

    func presentRestored(from: String, to: String, reason: RestoreReason) {
        presentCount += 1
        messages.append("\(reason): \(from) → \(to)")
    }

    func presentListenerFailure() {
        listenerFailureCount += 1
    }

    func ensureAuthorization() async -> NotificationAuthorizationState {
        authorizationState
    }

    func currentAuthorizationState() async -> NotificationAuthorizationState {
        passiveAuthorizationReadCount += 1
        return authorizationState
    }
}

/// 手动推进的单调 scheduler。`schedule()` 同步登记 action，因此状态机在函数返回前
/// 已经拥有确定的下一档 timer；`advance()` 可在一次调用中按 deadline 顺序跑完整条重试链。
@MainActor
final class ManualAudioMonitorScheduler: AudioMonitorScheduling {

    private struct ScheduledAction {
        let deadline: ContinuousClock.Instant
        let sequence: UInt64
        let action: @MainActor () -> Void
    }

    private(set) var now: ContinuousClock.Instant = ContinuousClock().now
    private var scheduledActions: [UUID: ScheduledAction] = [:]
    private var nextSequence: UInt64 = 0

    @discardableResult
    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> AudioMonitorScheduledTask {
        let id = UUID()
        nextSequence &+= 1

        let requestedDeadline = now.advanced(by: delay)
        let deadline = requestedDeadline < now ? now : requestedDeadline
        scheduledActions[id] = ScheduledAction(
            deadline: deadline,
            sequence: nextSequence,
            action: action
        )

        return ManualScheduledTask(id: id, scheduler: self)
    }

    /// 推进到目标单调时间。action 在执行前先从队列移除；action 内同步注册的下一档
    /// timer 会立刻进入同一队列，因此只要 deadline 仍不晚于 target，就在本轮继续执行。
    func advance(by duration: Duration) async {
        let target = now.advanced(by: duration)

        while let next = nextScheduledAction(),
              next.scheduled.deadline <= target
        {
            now = next.scheduled.deadline
            scheduledActions.removeValue(forKey: next.id)
            next.scheduled.action()
        }

        now = target
    }

    private func nextScheduledAction() -> (id: UUID, scheduled: ScheduledAction)? {
        scheduledActions.min { lhs, rhs in
            if lhs.value.deadline != rhs.value.deadline {
                return lhs.value.deadline < rhs.value.deadline
            }
            return lhs.value.sequence < rhs.value.sequence
        }
        .map { (id: $0.key, scheduled: $0.value) }
    }

    private func cancel(_ id: UUID) {
        scheduledActions.removeValue(forKey: id)
    }

    @MainActor
    private final class ManualScheduledTask: AudioMonitorScheduledTask {
        let id: UUID
        weak var scheduler: ManualAudioMonitorScheduler?

        init(id: UUID, scheduler: ManualAudioMonitorScheduler) {
            self.id = id
            self.scheduler = scheduler
        }

        func cancel() {
            scheduler?.cancel(id)
            scheduler = nil
        }
    }
}

// MARK: - Fixtures

func makeDevice(
    _ uid: String,
    name: String,
    id: UInt32,
    transport: UInt32 = kAudioDeviceTransportTypeBuiltIn
) -> AudioInputDevice {
    AudioInputDevice(
        uid: uid,
        deviceID: AudioDeviceID(id),
        name: name,
        transportType: transport
    )
}

let builtInMic = makeDevice("BuiltIn", name: "MacBook Microphone", id: 1)
let airpodsMic = makeDevice("AirPods", name: "AirPods", id: 2, transport: 0)
let usbMic = makeDevice("USB", name: "USB Microphone", id: 3, transport: 0)

// MARK: - Monitor Factory

@MainActor
func makeMonitor(
    devices: [AudioInputDevice],
    current: AudioInputDevice?,
    preferred: String?,
    mode: ProtectionMode = .auto,
    protection: Bool = true,
    settle: Double = 1.0,
    notifications: Bool = true,
    authorization: NotificationAuthorizationState = .authorized,
    scheduler: AudioMonitorScheduling? = nil,
    listeners: CoreAudioListening? = nil
) -> (monitor: AudioMonitor, provider: FakeAudioDeviceProvider, notifier: RecordingNotifier) {
    let suite = "MicLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    defaults.set(preferred, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set(protection, forKey: Preferences.protectionEnabledKey)
    defaults.set(mode.rawValue, forKey: Preferences.protectionModeKey)
    defaults.set(notifications, forKey: Preferences.notificationsEnabledKey)
    defaults.set(settle, forKey: Preferences.settleSecondsKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = devices
    provider.current = current

    let notifier = RecordingNotifier()
    notifier.authorizationState = authorization

    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: notifier,
        scheduler: scheduler,
        listeners: listeners ?? CoreAudioListeners()
    )

    return (monitor, provider, notifier)
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(5),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !condition() {
        if Task.isCancelled || clock.now >= deadline { return false }
        try? await Task.sleep(for: pollInterval)
    }
    return true
}

/// 等待 settle window 到期（settleSeconds 最小 1.0，等待 1.4s 保证 task 完成）。
func waitPastSettleWindow() async {
    try? await Task.sleep(for: .seconds(1.4))
}

/// 等待 stable external switch candidate 分类窗口结束。
/// candidate 复用 settleSeconds；测试默认 settle=1s，因此等待 1.4s。
func waitPastStableExternalSwitchClassification() async {
    try? await Task.sleep(for: .seconds(1.4))
}
