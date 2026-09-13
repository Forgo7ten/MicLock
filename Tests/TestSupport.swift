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

    /// 模拟设备枚举失败；nil 表示枚举成功（即使 devices == [] 也属于成功空列表）。
    var listInputDevicesError: Error?

    func listInputDevices() throws -> [AudioInputDevice] {
        if let listInputDevicesError {
            throw listInputDevicesError
        }
        return devices
    }

    func currentInputDevice() -> AudioInputDevice? {
        current
    }

    @discardableResult
    func setInputDevice(uid: String) -> Bool {
        setCalls.append(uid)

        guard !forceSetFailure else {
            return false
        }

        guard let device = devices.first(where: { $0.uid == uid }) else {
            return false
        }

        if applySetImmediately {
            current = device
        }

        return true
    }
}

/// 测试用通知器：记录投递次数。
/// @unchecked Sendable：仅在测试的主 actor 上使用。
final class RecordingNotifier: NotificationPresenting, @unchecked Sendable {

    private(set) var presentCount = 0
    private(set) var messages: [String] = []

    var authorizationState: NotificationAuthorizationState = .authorized

    func presentRestored(from: String, to: String, reason: RestoreReason) {
        presentCount += 1
        messages.append("\(reason): \(from) → \(to)")
    }

    func ensureAuthorization() async -> NotificationAuthorizationState {
        authorizationState
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
    scheduler: AudioMonitorScheduling? = nil
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
        scheduler: scheduler
    )

    return (monitor, provider, notifier)
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
