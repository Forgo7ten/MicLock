import Foundation
import CoreAudio

/// CoreAudio HAL 的真实实现：设备枚举、UID/名称/传输类型查询、默认输入读写。
///
/// 只操作 `kAudioHardwarePropertyDefaultInputDevice`，
/// 绝不触碰任何输出设备属性。
final class LiveAudioDeviceProvider: AudioDeviceProviding {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let access: CoreAudioPropertyAccess

    init(access: CoreAudioPropertyAccess = .live) {
        self.access = access
    }

    // MARK: - AudioDeviceProviding

    func listInputDevices() throws -> AudioInputDeviceSnapshot {
        let deviceIDs = try allDevices()
        var inputDevices: [AudioInputDevice] = []
        var incompleteDeviceIDs: [AudioDeviceID] = []
        var issues: [AudioDeviceProviderError] = []

        for deviceID in deviceIDs {
            do {
                guard try hasInputStreams(deviceID) else { continue }
                let uid = try requiredDeviceUID(deviceID)
                inputDevices.append(AudioInputDevice(
                    uid: uid,
                    deviceID: deviceID,
                    name: deviceName(deviceID) ?? "Unknown (\(deviceID))",
                    transportType: transportType(deviceID) ?? 0
                ))
            } catch let error as AudioDeviceProviderError {
                // 单个 HAL object 读失败时保留其余健康设备给 UI/诊断；
                // 策略层会根据 incompleteDeviceIDs 冻结 removal/offline/Auto learning。
                incompleteDeviceIDs.append(deviceID)
                issues.append(error)
            }
        }

        return AudioInputDeviceSnapshot(
            devices: inputDevices,
            incompleteDeviceIDs: incompleteDeviceIDs,
            issues: issues
        )
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
        let status = access.setData(
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
        var status = access.getSize(systemObject, &address, 0, nil, &size)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .enumerateDeviceListSize,
                objectID: systemObject,
                status: status
            )
        }

        let stride = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard size % stride == 0 else {
            throw invalid(.enumerateDeviceListSize, systemObject, "unaligned device list size")
        }
        let capacity = size
        let count = Int(size / stride)
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)

        status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return access.getData(systemObject, &address, 0, nil, &size, baseAddress)
        }

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .enumerateDeviceListData,
                objectID: systemObject,
                status: status
            )
        }

        // ioDataSize is an output too: hot-unplug can shrink the list between
        // getSize and getData. Never treat the unused zero-filled tail as IDs.
        guard size <= capacity, size % stride == 0 else {
            throw invalid(.enumerateDeviceListData, systemObject, "invalid returned device list size")
        }
        return Array(devices.prefix(Int(size / stride)))
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = access.getSize(deviceID, &address, 0, nil, &size)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryInputStreams,
                objectID: deviceID,
                status: status
            )
        }

        guard size % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else {
            throw invalid(.queryInputStreams, deviceID, "unaligned input stream list size")
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
            access.getData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryDeviceUID, objectID: deviceID, status: status
            )
        }
        // UID and Name properties return caller-owned CF objects (+1).
        // Consume that ownership even if the successful result is malformed.
        let object = value?.takeRetainedValue()
        guard size == UInt32(MemoryLayout<CFTypeRef?>.size), let object else {
            throw invalid(.queryDeviceUID, deviceID, "missing UID or wrong result size")
        }
        let uid = object as String
        guard !uid.isEmpty else {
            throw invalid(.queryDeviceUID, deviceID, "empty UID")
        }
        return uid
    }

    private func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        guard !uid.isEmpty else {
            throw invalid(.translateDeviceUID, systemObject, "empty requested UID")
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Resolve afresh for EVERY write. UID translation avoids enumerating
        // unrelated devices, and does not assume a cached AudioDeviceID is live.
        var qualifier = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            access.getData(systemObject, &address, UInt32(MemoryLayout<CFString>.size),
                           pointer, &size, &deviceID)
        }
        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .translateDeviceUID, objectID: systemObject, status: status
            )
        }
        guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw invalid(.translateDeviceUID, systemObject, "wrong device ID size")
        }
        guard deviceID != kAudioObjectUnknown else {
            throw AudioDeviceProviderError.targetDeviceNotFound(uid: uid)
        }
        return deviceID
    }

    private func invalid(
        _ operation: AudioDeviceProviderOperation, _ objectID: AudioObjectID, _ detail: String
    ) -> AudioDeviceProviderError {
        .invalidPropertyData(operation: operation, objectID: objectID, detail: detail)
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
            access.getData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }

        let object = value?.takeRetainedValue()
        guard size == UInt32(MemoryLayout<CFTypeRef?>.size) else { return nil }
        return object as String?
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = access.getData(deviceID, &address, 0, nil, &size, &value)

        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size) else { return nil }

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

        let status = access.getData(systemObject, &address, 0, nil, &size, &deviceID)

        guard status == noErr else {
            throw AudioDeviceProviderError.coreAudio(
                operation: .queryDefaultInputDevice,
                objectID: systemObject,
                status: status
            )
        }

        guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw invalid(.queryDefaultInputDevice, systemObject, "wrong device ID size")
        }
        guard deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
