import Foundation

// Black-box contract tests: no private state, no wall-clock sleeps.
// This first commit intentionally fails on 9b076a5. Apply the refactor next.
@MainActor
func runStateMachineRegressionTests() async {
    await regressionUnchangedWakeAfterTrustedTimeout()
    await regressionRecoveryAfterTrustedTimeout()
    await regressionCandidateInterruptedByPartialTopology()
    await regressionCandidateRestartsAfterBlindInterval()
    await regressionRealChangeAfterTrustedTimeout()
    await regressionChangedCurrentDiscoveredByRecovery()
    regressionStartupUsesFreshObservation()
    regressionPreferredInitializationWaitsForStartup()
    regressionPartialTopologyDelaysPreferredInitialization()
    regressionFirstUsableTopologyAfterEmptyStartup()
    await regressionPartialTopologyCannotConfirmFromCache()
    await regressionCancelledWatchdogCannotWrite()
}

@MainActor
private func regressionUnchangedWakeAfterTrustedTimeout() async {
    test("regression: unchanged wake after trusted timeout is not a switch")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await clock.advance(by: .seconds(1))
    monitor.handleDeviceListChanged()  // same topology AND same current
    monitor.handleDefaultInputChanged()  // duplicated HAL notification
    await clock.advance(by: .seconds(3))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "unchanged A must not overwrite explicitly selected B")
    expect(!monitor.recentAudioEvents.contains { $0.kind == .acceptedUserSwitch }, "no fabricated external switch")
}

@MainActor
private func regressionRecoveryAfterTrustedTimeout() async {
    test("regression: recovery wake after trusted timeout cannot learn old current")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice, objectID: nil, status: -1
    )
    await clock.advance(by: .seconds(1))
    provider.currentInputDeviceError = nil
    await clock.advance(by: .seconds(5))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "recovery observing unchanged A preserves preferred B")
    expect(provider.setCalls.count == 2, "Auto trusted command stays bounded")
}

@MainActor
private func regressionCandidateInterruptedByPartialTopology() async {
    test("regression: B-C-B during partial topology restarts classification")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .milliseconds(800))
    provider.incompleteDeviceIDs = [99]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .milliseconds(100))
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    provider.incompleteDeviceIDs = []
    monitor.handleDeviceListChanged()
    await clock.advance(by: .milliseconds(200))
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "old B deadline must not confirm the new B observation")
    await clock.advance(by: .seconds(1))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "a full valid window eventually accepts B")
}

@MainActor
private func regressionCandidateRestartsAfterBlindInterval() async {
    test("regression: current read failure breaks candidate continuity")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .milliseconds(800))
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice, objectID: nil, status: -1
    )
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .milliseconds(400))
    provider.currentInputDeviceError = nil
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .milliseconds(100))
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "blind interval cannot count towards stable confirmation")
    await clock.advance(by: .seconds(1))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "read recovery restarts, rather than strands, an eligible candidate")
}

@MainActor
private func regressionRealChangeAfterTrustedTimeout() async {
    test("regression: real new current after timeout remains learnable")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await clock.advance(by: .seconds(1))
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    await clock.advance(by: .seconds(1))
    expect(monitor.preferredMicrophoneUID == airpodsMic.uid, "new A-to-C evidence is accepted after its own window")
}

@MainActor
private func regressionChangedCurrentDiscoveredByRecovery() async {
    test("regression: timer may discover a real change, but cannot invent one")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice, objectID: nil, status: -1
    )
    monitor.handleDefaultInputChanged()
    provider.currentInputDeviceError = nil
    provider.current = usbMic
    await clock.advance(by: .seconds(2))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "real changed UID, not callback type, supplies evidence")
}

@MainActor
private func regressionStartupUsesFreshObservation() {
    test("regression: startup alignment resamples after initial observation")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, scheduler: clock
    )
    provider.current = usbMic  // before listeners/startup alignment
    monitor.evaluateStartupPolicy()
    expect(provider.setCalls == [builtInMic.uid], "startup must not use stale cached current")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "startup restores persisted preferred")
}

@MainActor
private func regressionPreferredInitializationWaitsForStartup() {
    test("regression: preferred initialization waits for fresh startup topology")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic], current: usbMic,
        preferred: nil, scheduler: clock
    )
    expect(monitor.preferredMicrophoneUID == nil, "pre-listener UI snapshot must not persist a preferred device")

    provider.devices = [builtInMic, usbMic]
    provider.current = usbMic
    monitor.evaluateStartupPolicy()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "fresh startup topology must still apply built-in-first initialization")
    expect(provider.setCalls == [builtInMic.uid], "startup alignment uses the newly initialized built-in preferred")
}

@MainActor
private func regressionPartialTopologyDelaysPreferredInitialization() {
    test("regression: partial topology delays preferred initialization")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic], current: usbMic,
        preferred: nil, scheduler: clock
    )
    expect(monitor.preferredMicrophoneUID == nil, "pre-listener snapshot has no policy side effect")

    // Simulate a built-in device whose critical TransportType is temporarily
    // unreadable: LiveAudioDeviceProvider omits it and marks the snapshot partial.
    provider.devices = [usbMic]
    provider.incompleteDeviceIDs = [builtInMic.deviceID]
    monitor.evaluateStartupPolicy()
    expect(monitor.preferredMicrophoneUID == nil, "partial startup topology cannot initialize preferred")
    expect(provider.setCalls.isEmpty, "partial startup topology cannot align to a guessed target")

    provider.devices = [builtInMic, usbMic]
    provider.incompleteDeviceIDs = []
    monitor.handleDeviceListChanged()
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "built-in is initialized only after topology becomes complete")
    expect(provider.setCalls == [builtInMic.uid], "pending startup alignment uses the recovered built-in preferred")
}

@MainActor
private func regressionFirstUsableTopologyAfterEmptyStartup() {
    test("regression: empty first snapshot does not end preferred initialization")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [], current: nil, preferred: nil, protection: false,
        scheduler: clock
    )
    provider.devices = [builtInMic, usbMic]
    provider.current = usbMic
    monitor.handleDeviceListChanged()
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "first usable baseline still prefers built-in while protection is off")
    expect(provider.setCalls.isEmpty, "initialization does not enable protection")
}

@MainActor
private func regressionPartialTopologyCannotConfirmFromCache() async {
    test("regression: fresh current confirms independently, cached current never does")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .manual, scheduler: clock
    )
    provider.applySetImmediately = false
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice, objectID: nil, status: -1
    )
    provider.incompleteDeviceIDs = [99]
    provider.current = builtInMic
    await clock.advance(by: .seconds(1))
    expect(monitor.recentAudioEvents.isEmpty, "failed current read cannot confirm a request")
    expect(notifier.presentCount == 0, "no notification before fresh confirmation")
    provider.currentInputDeviceError = nil
    monitor.handleDefaultInputChanged()
    expect(monitor.recentAudioEvents.count == 1, "fresh target confirms even with partial topology")
    expect(notifier.presentCount == 1, "one confirmed restore notification")
}

@MainActor
private func regressionCancelledWatchdogCannotWrite() async {
    test("regression: disabling protection cancels pending retry")
    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .manual, scheduler: clock
    )
    provider.applySetImmediately = false
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    monitor.protectionEnabled = false
    await clock.advance(by: .seconds(130))
    expect(provider.setCalls == [builtInMic.uid], "cancelled restore never retries")
}
