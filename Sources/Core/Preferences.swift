import Foundation

/// UserDefaults 配置读写。
///
/// 持久化只保存 Device UID，不保存 AudioDeviceID。
struct Preferences {

    static let preferredMicrophoneUIDKey = "preferredMicrophoneUID"
    static let protectionEnabledKey = "protectionEnabled"
    static let protectionModeKey = "protectionMode"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let settleSecondsKey = "settleSeconds"

    /// 设备 UID → 最近已知名称（离线设备在 UI 上仍可显示可读名字）。
    static let deviceNamesKey = "lastKnownDeviceNames"

    /// settleSeconds 合法范围。
    static let settleRange: ClosedRange<Double> = 1...30

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Preferences.settleSecondsKey: 2.0,
            Preferences.notificationsEnabledKey: true,
        ])
    }

    // MARK: - Accessors

    var preferredMicrophoneUID: String? {
        get { defaults.string(forKey: Preferences.preferredMicrophoneUIDKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Preferences.preferredMicrophoneUIDKey)
            } else {
                defaults.removeObject(forKey: Preferences.preferredMicrophoneUIDKey)
            }
        }
    }

    var protectionEnabled: Bool {
        get { defaults.bool(forKey: Preferences.protectionEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Preferences.protectionEnabledKey) }
    }

    var protectionMode: ProtectionMode {
        get {
            guard let raw = defaults.string(forKey: Preferences.protectionModeKey) else {
                // 未设置（全新安装）默认 auto。
                return .auto
            }
            // 未知值读作 manual（安全默认）。
            return ProtectionMode(rawValue: raw) ?? .manual
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Preferences.protectionModeKey) }
    }

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Preferences.notificationsEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Preferences.notificationsEnabledKey) }
    }

    var settleSeconds: Double {
        get {
            Preferences.clamp(defaults.double(forKey: Preferences.settleSecondsKey))
        }
        nonmutating set {
            defaults.set(
                Preferences.clamp(newValue),
                forKey: Preferences.settleSecondsKey
            )
        }
    }

    var lastKnownDeviceNames: [String: String] {
        get {
            defaults.dictionary(forKey: Preferences.deviceNamesKey) as? [String: String] ?? [:]
        }
        nonmutating set {
            defaults.set(newValue, forKey: Preferences.deviceNamesKey)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, Preferences.settleRange.lowerBound), Preferences.settleRange.upperBound)
    }
}
