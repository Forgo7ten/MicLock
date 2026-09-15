import Foundation
import CoreAudio

enum CoreAudioListenerInstallFailure: Equatable {
    case defaultInputAdd(OSStatus)
    case devicesAdd(OSStatus)
    case cleanup(OSStatus)
}

enum CoreAudioListenerInstallResult: Equatable {
    case installed
    case failed(CoreAudioListenerInstallFailure)
}

enum CoreAudioListenerStatus: Equatable {
    case notStarted
    case retrying(nextAttempt: Int, total: Int)
    case installed
    case failed

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

protocol CoreAudioListening: AnyObject, Sendable {
    func install(
        onDefaultInputChange: @escaping @MainActor () -> Void,
        onDevicesChange: @escaping @MainActor () -> Void
    ) -> CoreAudioListenerInstallResult

    func remove()
}

/// A successful registration must deliver callbacks on a main-queue / MainActor-
/// compatible execution context, matching `SystemCoreAudioListenerBackend`.
protocol CoreAudioListenerBackend: AnyObject {
    func addDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func addDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func removeDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func removeDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

final class SystemCoreAudioListenerBackend: CoreAudioListenerBackend {
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

    func addDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultInputAddress,
            DispatchQueue.main,
            listener
        )
    }

    func addDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            systemObject,
            &devicesAddress,
            DispatchQueue.main,
            listener
        )
    }

    func removeDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &defaultInputAddress,
            DispatchQueue.main,
            listener
        )
    }

    func removeDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &devicesAddress,
            DispatchQueue.main,
            listener
        )
    }
}

final class CoreAudioListeners: CoreAudioListening, @unchecked Sendable {
    private let backend: CoreAudioListenerBackend

    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var fullyInstalled = false

    init(backend: CoreAudioListenerBackend = SystemCoreAudioListenerBackend()) {
        self.backend = backend
    }

    /// Successfully removed blocks are cleared immediately. Failed removals retain
    /// the exact block identity so a later cleanup can satisfy CoreAudio's contract.
    private func cleanupRetainedListeners() -> OSStatus? {
        var firstError: OSStatus?

        if let listener = defaultInputListener {
            let status = backend.removeDefaultInputListener(listener)
            if status == noErr {
                defaultInputListener = nil
            } else if firstError == nil {
                firstError = status
            }
        }

        if let listener = devicesListener {
            let status = backend.removeDevicesListener(listener)
            if status == noErr {
                devicesListener = nil
            } else if firstError == nil {
                firstError = status
            }
        }

        return firstError
    }

    func install(
        onDefaultInputChange: @escaping @MainActor () -> Void,
        onDevicesChange: @escaping @MainActor () -> Void
    ) -> CoreAudioListenerInstallResult {
        if fullyInstalled { return .installed }

        // Never create a new registration until every retained partial
        // registration has been proven removed.
        if defaultInputListener != nil || devicesListener != nil {
            if let status = cleanupRetainedListeners() {
                return .failed(.cleanup(status))
            }
        }

        let defaultBlock: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                onDefaultInputChange()
            }
        }

        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                onDevicesChange()
            }
        }

        let defaultStatus = backend.addDefaultInputListener(defaultBlock)
        guard defaultStatus == noErr else {
            return .failed(.defaultInputAdd(defaultStatus))
        }

        defaultInputListener = defaultBlock

        let devicesStatus = backend.addDevicesListener(devicesBlock)
        guard devicesStatus == noErr else {
            if let cleanupStatus = cleanupRetainedListeners() {
                return .failed(.cleanup(cleanupStatus))
            }
            return .failed(.devicesAdd(devicesStatus))
        }

        devicesListener = devicesBlock
        fullyInstalled = true
        return .installed
    }

    func remove() {
        fullyInstalled = false
        _ = cleanupRetainedListeners()
    }
}
