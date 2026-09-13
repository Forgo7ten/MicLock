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

    func listInputDevices() throws -> [AudioInputDevice] {
        try allDevices().compactMap { deviceID -> AudioInputDevice? in
            guard try hasInputStreams(deviceID) else { return nil }
            let uid = try requiredDeviceUID(deviceID)

            return AudioInputDevice(
                uid: uid,
                deviceID: deviceID,
                name: deviceName(deviceID) ?? "Unknown (\(deviceID))",
                transportType: transportType(deviceID) ?? 0
            )
        }
    }

    func currentInputDevice() throws -> AudioInputDevice? {
        guard let deviceID = try defaultInputDeviceID() else { return nil }
        let uid = try requiredDeviceUID(deviceID)

        return AudioInputDevice(
            uid: uid,
            deviceID: deviceID,
            name: deviceName(deviceID) ?? "Unknown",
            transportType: transportType(deviceID) ?? 0
        )
    }

    func setInputDevice(uid: String) throws {
        let deviceID = try resolveDeviceID(uid: uid)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value = deviceID
        let status = AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        )

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .setDefaultInputDevice,
                objectID: systemObject,
                status: status
            )
        }
    }

    // MARK: - CoreAudio Helpers

    private func allDevices() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .enumerateDeviceListSize,
                objectID: systemObject,
                status: status
            )
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)

        status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, baseAddress)
        }

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .enumerateDeviceListData,
                objectID: systemObject,
                status: status
            )
        }

        return devices
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryInputStreams,
                objectID: deviceID,
                status: status
            )
        }

        return size > 0
    }

    private func requiredDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr,
              let uid = value?.takeUnretainedValue() as String?
        else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryDeviceUID,
                objectID: deviceID,
                status: status
            )
        }

        return uid
    }

    private func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        let deviceIDs = try allDevices()
        var incompleteDeviceIDs: [AudioDeviceID] = []

        for deviceID in deviceIDs {
            do {
                if try requiredDeviceUID(deviceID) == uid {
                    return deviceID
                }
            } catch {
                incompleteDeviceIDs.append(deviceID)
            }
        }

        if !incompleteDeviceIDs.isEmpty {
            throw AudioDeviceProviderError.targetDeviceLookupIncomplete(
                uid: uid,
                incompleteDeviceIDs: incompleteDeviceIDs
            )
        }

        throw AudioDeviceProviderError.targetDeviceNotFound(uid: uid)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }

        return value?.takeUnretainedValue() as String?
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

    private func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryDefaultInputDevice,
                objectID: systemObject,
                status: status
            )
        }

        guard deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
