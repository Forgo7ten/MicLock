import Foundation
import CoreAudio

/// CoreAudio HAL 的真实实现：设备枚举、UID/名称/传输类型查询、默认输入读写。
///
/// 只操作 `kAudioHardwarePropertyDefaultInputDevice`，
/// 绝不触碰任何输出设备属性。
final class LiveAudioDeviceProvider: AudioDeviceProviding {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    init() {}

    // MARK: - AudioDeviceProviding

    func listInputDevices() -> [AudioInputDevice] {
        allDevices().compactMap { deviceID -> AudioInputDevice? in
            guard hasInputStreams(deviceID) else { return nil }
            guard let uid = deviceUID(deviceID) else { return nil }

            return AudioInputDevice(
                uid: uid,
                deviceID: deviceID,
                name: deviceName(deviceID) ?? "Unknown (\(deviceID))",
                transportType: transportType(deviceID) ?? 0
            )
        }
    }

    func currentInputDevice() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID() else { return nil }

        guard let uid = deviceUID(deviceID) else { return nil }

        return AudioInputDevice(
            uid: uid,
            deviceID: deviceID,
            name: deviceName(deviceID) ?? "Unknown",
            transportType: transportType(deviceID) ?? 0
        )
    }

    func setInputDevice(uid: String) -> Bool {
        let target = allDevices().first { deviceUID($0) == uid }

        guard let deviceID = target else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value = deviceID

        return AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        ) == noErr
    }

    // MARK: - CoreAudio Helpers

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)

        guard status == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)

        status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, baseAddress)
        }

        guard status == noErr else { return [] }

        return devices
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)

        return status == noErr && size > 0
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)

        guard status == noErr else { return nil }

        return value as String
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)

        guard status == noErr else { return nil }

        return value as String
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)

        guard status == noErr else { return nil }

        return value
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)

        guard status == noErr else { return nil }

        return deviceID
    }
}
