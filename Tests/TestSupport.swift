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

    func listInputDevices() -> [AudioInputDevice] {
        devices
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
    authorization: NotificationAuthorizationState = .authorized
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
        notifier: notifier
    )

    return (monitor, provider, notifier)
}

/// 等待 settle window 到期（settleSeconds 最小 1.0，等待 1.4s 保证 task 完成）。
func waitPastSettleWindow() async {
    try? await Task.sleep(for: .seconds(1.4))
}
