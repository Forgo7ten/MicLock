import Foundation
import CoreAudio

final class CoreAudioListeners: @unchecked Sendable {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    func install(
        onDefaultInputChange: @escaping @MainActor () -> Void,
        onDevicesChange: @escaping @MainActor () -> Void
    ) -> (defaultInputStatus: OSStatus, devicesStatus: OSStatus) {
        let defaultInputListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onDefaultInputChange() }
        }
        self.defaultInputListener = defaultInputListener

        let devicesListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onDevicesChange() }
        }
        self.devicesListener = devicesListener

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultInputAddress,
            DispatchQueue.main,
            defaultInputListener
        )

        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &devicesAddress,
            DispatchQueue.main,
            devicesListener
        )

        // Auto Mode 同时依赖默认输入和设备拓扑事件。
        // 任一 listener 安装失败时回滚全部监听，避免进入部分可用状态。
        if defaultStatus != noErr || devicesStatus != noErr {
            remove()
        }

        return (defaultStatus, devicesStatus)
    }

    func remove() {
        if let listener = defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &defaultInputAddress,
                DispatchQueue.main,
                listener
            )
        }

        if let listener = devicesListener {
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &devicesAddress,
                DispatchQueue.main,
                listener
            )
        }

        defaultInputListener = nil
        devicesListener = nil
    }
}
