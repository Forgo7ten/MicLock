import CoreAudio

/// 输入设备的稳定模型。
///
/// `uid` 是 CoreAudio Device UID，跨插拔稳定，用于持久化；
/// `deviceID` 只在当前运行期有效，仅用于运行时 CoreAudio 操作，绝不持久化。
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let deviceID: AudioDeviceID
    let name: String
    let transportType: UInt32

    var id: String { uid }

    /// 不允许通过名字判断内置麦克风，只看 TransportType。
    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}
