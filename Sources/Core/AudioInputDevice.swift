import CoreAudio

/// 输入设备的稳定模型。
///
/// `uid` 是 CoreAudio Device UID，跨插拔稳定，用于持久化；
/// `deviceID` 只在当前运行期有效，仅用于运行时 CoreAudio 操作，绝不持久化；
/// `name` 在 HAL 名称暂时不可读时可以是 UI fallback，只有 `nameIsResolved`
/// 为 true 的名称才适合写入跨启动的 last-known-name 缓存。
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let deviceID: AudioDeviceID
    let name: String
    let transportType: UInt32
    let nameIsResolved: Bool

    init(
        uid: String,
        deviceID: AudioDeviceID,
        name: String,
        transportType: UInt32,
        nameIsResolved: Bool = true
    ) {
        self.uid = uid
        self.deviceID = deviceID
        self.name = name
        self.transportType = transportType
        self.nameIsResolved = nameIsResolved
    }

    var id: String { uid }

    /// 不允许通过名字判断内置麦克风，只看 TransportType。
    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}
