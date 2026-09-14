import Foundation
import Observation

@MainActor
func runPostRefactorRegressionTests() async {
    testProtectingAutoRestoresDuringPartialSample()
    testProtectingAutoRestoresDuringEnumerationFailure()
    await testProtectingAutoDoesNotTrustPartialRemoval()
    testAvailabilityProjectionIsObservable()
    testUnknownTopologyDoesNotClaimPreferredOffline()
    testOfflineProjectionRequiresLatestValidSample()
    testOfflineFailureClearsOnlyWhenItsTargetReturns()
    testOfflineFailureClearsWhenTargetReconnectsWithoutBecomingCurrent()
}

@MainActor
private func testUnknownTopologyDoesNotClaimPreferredOffline() {
    test("review: unknown topology does not claim preferred is offline")
    let suite = "MicLockTests.unknown-topology.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(usbMic.uid, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set([usbMic.uid: usbMic.name], forKey: Preferences.deviceNamesKey)
    defaults.set(false, forKey: Preferences.protectionEnabledKey)

    let provider = FakeAudioDeviceProvider()
    provider.current = builtInMic
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(
        operation: .enumerateDeviceListData, objectID: nil, status: -1
    )
    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: RecordingNotifier(),
        scheduler: ManualAudioMonitorScheduler()
    )

    expect(monitor.offlinePreferredName == nil, "unknown topology cannot prove the preferred device is offline")

    provider.listInputDevicesError = nil
    provider.current = nil
    provider.devices = []
    monitor.handleDeviceListChanged()

    expect(monitor.offlinePreferredName == usbMic.name, "a trusted empty topology confirms the preferred device is offline")
}

@MainActor
private func testOfflineProjectionRequiresLatestValidSample() {
    test("review: stale trusted topology cannot claim preferred is offline")
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: usbMic.uid, protection: false,
        scheduler: ManualAudioMonitorScheduler()
    )
    provider.devices = [builtInMic]
    monitor.handleDeviceListChanged()
    expect(monitor.offlinePreferredName == usbMic.name, "a complete topology confirms USB is offline")

    provider.devices = [builtInMic, usbMic]
    provider.current = usbMic
    provider.incompleteDeviceIDs = [99]
    monitor.handleDeviceListChanged()

    expect(monitor.devices.contains(where: { $0.uid == usbMic.uid }), "partial UI devices can already include USB")
    expect(monitor.currentDevice?.uid == usbMic.uid, "fresh current can already be USB during a partial sample")
    expect(monitor.deviceEnumerationError != nil, "partial sampling exposes unknown availability")
    expect(monitor.offlinePreferredName == nil, "partial sampling cannot reuse stale topology to claim USB is offline")

    provider.incompleteDeviceIDs = []
    provider.devices = [builtInMic]
    provider.current = builtInMic
    monitor.handleDeviceListChanged()
    expect(monitor.offlinePreferredName == usbMic.name, "a new complete topology may confirm USB is offline again")

    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(
        operation: .enumerateDeviceListData, objectID: nil, status: -1
    )
    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == usbMic.uid, "current can recover USB while enumeration fails")
    expect(monitor.offlinePreferredName == nil, "enumeration failure cannot reuse stale topology to claim USB is offline")
}

@MainActor
private func testProtectingAutoRestoresDuringPartialSample() {
    test("review: established Auto protection survives partial sampling")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .auto, scheduler: clock
    )
    provider.devices.append(airpodsMic)
    monitor.handleDeviceListChanged() // Complete delta establishes protection.
    provider.incompleteDeviceIDs = [usbMic.deviceID]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "partial sample must not suspend established protection")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "fresh target read can confirm despite partial topology")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "partial sample never changes preferred")
    expect(notifier.presentCount == 1, "only a confirmed restore may notify")
}

@MainActor
private func testProtectingAutoRestoresDuringEnumerationFailure() {
    test("review: established Auto protection survives list read failure")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .auto, scheduler: clock
    )
    provider.devices.append(airpodsMic)
    monitor.handleDeviceListChanged()
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(
        operation: .enumerateDeviceListData, objectID: nil, status: -1
    )
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "known protection can use the last trusted target")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "restore follows a fresh observation, not stale cache")
    expect(monitor.deviceEnumerationError != nil, "successful restore does not hide sampling failure")
}

@MainActor
private func testProtectingAutoDoesNotTrustPartialRemoval() async {
    test("review: partial loss is unknown, complete loss cancels protection retry")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .auto, scheduler: clock
    )
    provider.devices.append(airpodsMic)
    monitor.handleDeviceListChanged()
    provider.devices = [airpodsMic]
    provider.incompleteDeviceIDs = [builtInMic.deviceID]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "attempt last trusted target; provider resolves actual availability")
    expect(monitor.protectionRetryState == .setterRejected, "failed attempt retains explicit protection retry")
    provider.incompleteDeviceIDs = []
    monitor.handleDeviceListChanged()
    let callsAfterCompleteLoss = provider.setCalls.count
    await clock.advance(by: .seconds(120))
    expect(provider.setCalls.count == callsAfterCompleteLoss, "complete target loss cancels all future writes")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "offline preference is preserved")
}

private final class ReviewChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    func mark() { lock.lock(); defer { lock.unlock() }; storage = true }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor
private func testAvailabilityProjectionIsObservable() {
    test("review: availability-only view observes trusted topology")
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: usbMic.uid, protection: false, scheduler: ManualAudioMonitorScheduler()
    )
    let removed = ReviewChangeFlag()
    withObservationTracking {
        _ = monitor.isPreferredMicrophoneAvailable
        _ = monitor.offlinePreferredName
    } onChange: { removed.mark() }
    provider.devices = [builtInMic]
    monitor.handleDeviceListChanged()
    expect(removed.changed, "availability projection invalidates when only trusted topology changes")
    expect(monitor.offlinePreferredName == usbMic.name, "offline projection shows the retained name")

    let added = ReviewChangeFlag()
    withObservationTracking {
        _ = monitor.offlinePreferredName
    } onChange: { added.mark() }
    provider.devices.append(usbMic)
    monitor.handleDeviceListChanged()
    expect(added.changed, "offline-only projection invalidates when target returns")
    expect(monitor.offlinePreferredName == nil, "online target clears the offline label")
}

@MainActor
private func testOfflineFailureClearsOnlyWhenItsTargetReturns() {
    test("review: target-offline error clears on fresh target observation")
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .manual, scheduler: ManualAudioMonitorScheduler()
    )
    provider.applySetImmediately = false
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    provider.devices = [usbMic, airpodsMic]
    monitor.handleDeviceListChanged()
    expect(monitor.lastError == "Target input device is no longer available", "complete target loss reports failure")
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(monitor.lastError != nil, "unrelated fresh current must not clear target failure")
    let writes = provider.setCalls.count
    provider.devices.append(builtInMic)
    provider.current = builtInMic
    monitor.handleDeviceListChanged()
    expect(monitor.lastError == nil, "fresh observation of the failed target clears stale offline error")
    expect(provider.setCalls.count == writes, "already-current reconnected target needs no redundant write")
}

@MainActor
private func testOfflineFailureClearsWhenTargetReconnectsWithoutBecomingCurrent() {
    test("review: target-offline error clears when complete topology proves target returned")
    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic, airpodsMic], current: usbMic,
        preferred: usbMic.uid, mode: .manual, scheduler: ManualAudioMonitorScheduler()
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [usbMic.uid], "Manual starts one restore to the USB preferred target")

    provider.devices = [airpodsMic]
    monitor.handleDeviceListChanged()
    expect(
        monitor.lastError == "Target input device is no longer available",
        "complete topology records the disappeared USB target"
    )

    monitor.protectionEnabled = false
    let writes = provider.setCalls.count
    provider.devices = [airpodsMic, usbMic]
    monitor.handleDeviceListChanged()

    expect(monitor.currentDevice?.uid == airpodsMic.uid, "USB can reconnect without becoming current")
    expect(monitor.lastError == nil, "complete topology clears the stale USB offline failure")
    expect(provider.setCalls.count == writes, "disabled protection does not restore merely because USB returned")
}
