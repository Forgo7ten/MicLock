import CoreAudio

/// CoreAudio 失败发生的具体阶段；用于保留底层 OSStatus，而不是把不同失败都压成 nil / false。
enum AudioDeviceProviderOperation: String {
    case enumerateDeviceListSize
    case enumerateDeviceListData
    case queryInputStreams
    case queryDeviceUID
    case queryDefaultInputDevice
    case setDefaultInputDevice
}

enum AudioDeviceProviderError: Error, CustomStringConvertible {
    case coreAudio(
        operation: AudioDeviceProviderOperation,
        objectID: AudioObjectID?,
        status: OSStatus
    )
    case targetDeviceNotFound(uid: String)
    case targetDeviceLookupIncomplete(uid: String, incompleteDeviceIDs: [AudioDeviceID])

    var description: String {
        switch self {
        case .coreAudio(let operation, let objectID, let status):
            let object = objectID.map { String($0) } ?? "system"
            return "\(operation.rawValue) failed (object=\(object), OSStatus=\(status))"
        case .targetDeviceNotFound(let uid):
            return "target device not found (uid=\(uid))"
        case .targetDeviceLookupIncomplete(let uid, let incompleteDeviceIDs):
            return "target lookup incomplete (uid=\(uid), unreadableDeviceIDs=\(incompleteDeviceIDs))"
        }
    }
}

/// CoreAudio 访问抽象：策略层只依赖本协议，测试注入 Fake 实现。
protocol AudioDeviceProviding: AnyObject {
    /// 当前所有输入设备。失败与“成功但列表为空”必须区分。
    func listInputDevices() throws -> [AudioInputDevice]

    /// 当前默认输入设备。只有 CoreAudio 明确返回 kAudioObjectUnknown 时才返回 nil；
    /// property read / UID read 失败必须抛错。
    func currentInputDevice() throws -> AudioInputDevice?

    /// 按 Device UID 设置默认输入设备。保留 lookup / HAL 写入失败的具体错误。
    func setInputDevice(uid: String) throws
}
