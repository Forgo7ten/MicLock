import Foundation
import Observation

@MainActor
func runStateMachineAcceptanceTests() async {
    await acceptancePolicyWindow()
    await acceptancePendingAndConfirmation()
    await acceptanceStartupAndReconnect()
    await acceptanceSelectionLifecycle()
    await acceptanceNotificationsAndConfiguration()
    await acceptanceObservationProjection()
    await acceptanceManualEventMatrix()
}

@MainActor
private func acceptancePolicyWindow() async {
    test("acceptance: Auto window expires lazily and does not revive on configuration changes")
    let clock = ManualAudioMonitorScheduler()
    let (m, p, _) = makeMonitor(devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid, scheduler: clock)
    p.devices = [builtInMic, usbMic]
    m.handleDeviceListChanged()
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(p.setCalls == [builtInMic.uid], "topology-window switch is restored immediately")
    await clock.advance(by: .seconds(2))
    m.settleSeconds = 30
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(p.setCalls.count == 1, "increasing duration cannot revive an expired protection window")
    await clock.advance(by: .seconds(29))
    expect(m.preferredMicrophoneUID == builtInMic.uid, "candidate uses configured duration")
    await clock.advance(by: .seconds(1))
    expect(m.preferredMicrophoneUID == usbMic.uid, "candidate commits at its deadline")

    test("acceptance: accepted retry does not extend topology window")
    let c = ManualAudioMonitorScheduler()
    let (m2, p2, _) = makeMonitor(devices: [builtInMic, usbMic], current: builtInMic, preferred: builtInMic.uid, scheduler: c)
    p2.applySetImmediately = false
    p2.devices.append(airpodsMic)
    p2.current = airpodsMic
    m2.handleDeviceListChanged()
    await c.advance(by: .milliseconds(1200))
    // Existing source/third-current escape is preserved. The retry at 0.5s
    // must not silently extend the topology window to 1.5s.
    p2.current = usbMic
    m2.handleDefaultInputChanged()
    expect(p2.setCalls.count == 2, "new third current after the original window does not trigger another restore")
    await c.advance(by: .seconds(1))
    expect(m2.preferredMicrophoneUID == usbMic.uid, "superseding real external change gets its own candidate")
}

@MainActor
private func acceptancePendingAndConfirmation() async {
    test("acceptance: synchronous watchdog confirmation cannot reuse stale observation")
    let staleClock = ManualAudioMonitorScheduler()
    let (staleMonitor, staleProvider, staleNotifier) = makeMonitor(
        devices: [builtInMic, airpodsMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .manual, scheduler: staleClock
    )
    staleProvider.forceSetFailure = true
    staleProvider.current = airpodsMic
    staleMonitor.handleDefaultInputChanged()
    expect(staleProvider.setCalls.count == 1, "initial rejected restore is submitted once")
    staleProvider.forceSetFailure = false
    await staleClock.advance(by: .milliseconds(500))
    expect(staleProvider.setCalls.count == 2, "successful watchdog retry is not followed by a stale duplicate restore")
    expect(staleNotifier.presentCount == 1, "one confirmed watchdog retry emits one notification")

    test("acceptance: Auto re-hijack after watchdog confirmation gets exactly one restore")
    let reHijackClock = ManualAudioMonitorScheduler()
    let (reHijackMonitor, reHijackProvider, _) = makeMonitor(
        devices: [builtInMic], current: builtInMic,
        preferred: builtInMic.uid, mode: .auto, settle: 1.0, scheduler: reHijackClock
    )
    reHijackProvider.applySetImmediately = false
    reHijackProvider.devices = [builtInMic, airpodsMic]
    reHijackProvider.current = airpodsMic
    reHijackMonitor.handleDeviceListChanged()
    await reHijackClock.advance(by: .seconds(1.5))
    expect(reHijackProvider.setCalls.count == 3, "unconfirmed restore retries at 0.5s and 1.5s")
    reHijackProvider.applySetImmediately = true
    await reHijackClock.advance(by: .seconds(2))
    expect(reHijackProvider.setCalls.count == 4, "confirming retry does not issue a duplicate restore from stale state")
    reHijackProvider.current = airpodsMic
    reHijackMonitor.handleDefaultInputChanged()
    expect(reHijackProvider.setCalls.count == 5, "immediate re-hijack is corrected exactly once")
    expect(reHijackMonitor.currentDevice?.uid == builtInMic.uid, "re-hijack returns to preferred")
    for mode in [ProtectionMode.manual, .auto] {
        test("acceptance: delayed \(mode) restoration, rejection, backoff, confirmation")
        let c = ManualAudioMonitorScheduler()
        let (m, p, n) = makeMonitor(devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid, mode: mode, scheduler: c)
        p.applySetImmediately = false
        p.forceSetFailure = true
        p.devices.append(usbMic)
        p.current = usbMic
        m.handleDeviceListChanged()
        expect(m.protectionRetryState == .setterRejected, "setter rejection remains retryable")
        expect(n.presentCount == 0 && m.recentAudioEvents.isEmpty, "accepted or rejected request is not a success")
        p.forceSetFailure = false
        await c.advance(by: .milliseconds(500))
        expect(m.protectionRetryState == nil, "accepted fast retry clears stale rejection")
        await c.advance(by: .seconds(7))
        expect(p.setCalls.count == 5, "0.5/1/2/4 second retry schedule")
        expect(m.protectionRetryState == .awaitingConfirmation, "long pending exposes retry status")
        await c.advance(by: .seconds(180))
        expect(p.setCalls.count == 9, "protection reaches capped 64-second backoff")
        expect(m.preferredMicrophoneUID == builtInMic.uid, "time alone never learns stuck source")
        p.current = builtInMic
        m.handleDefaultInputChanged()
        expect(m.lastError == nil && m.protectionRetryState == nil, "confirmation clears retry state")
        expect(n.presentCount == 1 && m.recentAudioEvents.count == 1, "one success event on fresh target")
        p.applySetImmediately = true
        p.current = usbMic
        m.handleDefaultInputChanged()
        expect(m.currentDevice?.uid == builtInMic.uid, "immediate re-hijack after late confirmation is restored")
        expect(n.presentCount == (mode == .auto ? 1 : 2), "Auto submission cooldown is independent of writer")
    }
}

@MainActor
private func acceptanceStartupAndReconnect() async {
    for mode in [ProtectionMode.manual, .auto] {
        test("acceptance: offline/reconnect in \(mode)")
        let c = ManualAudioMonitorScheduler()
        let (m, p, n) = makeMonitor(devices: [builtInMic], current: builtInMic, preferred: usbMic.uid, mode: mode, scheduler: c)
        m.handleDeviceListChanged()
        await c.advance(by: .seconds(5))
        expect(m.preferredMicrophoneUID == usbMic.uid && p.setCalls.isEmpty, "offline preferred is retained without writes")
        p.devices.append(usbMic)
        m.handleDeviceListChanged()
        expect(p.setCalls == [usbMic.uid], "reconnection restores preferred")
        expect(m.recentAudioEvents.first?.kind == .restored(.preferredReconnected), "reconnect reason preserved in both modes")
        expect(n.presentCount == 1, "confirmed reconnect notifies")
    }
    test("acceptance: full empty topology ends an active command")
    let c = ManualAudioMonitorScheduler()
    let (m, p, _) = makeMonitor(devices: [builtInMic, usbMic], current: builtInMic, preferred: builtInMic.uid, mode: .manual, scheduler: c)
    p.applySetImmediately = false
    p.current = usbMic
    m.handleDefaultInputChanged()
    p.devices = []
    p.current = nil
    m.handleDeviceListChanged()
    await c.advance(by: .seconds(130))
    expect(p.setCalls.count == 1 && m.currentDevice == nil, "target disappearance cancels retries even with nil current")
    expect(m.lastError == "Target input device is no longer available", "offline failure is visible")
}

@MainActor
private func acceptanceSelectionLifecycle() async {
    test("acceptance: latest logical selection, stale callback, timeout and late success")
    let c = ManualAudioMonitorScheduler()
    let (m, p, _) = makeMonitor(devices: [builtInMic, usbMic, airpodsMic], current: builtInMic, preferred: builtInMic.uid, protection: false, scheduler: c)
    p.applySetImmediately = false
    m.selectDevice(usbMic)
    m.selectDevice(airpodsMic)
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(m.recentAudioEvents.isEmpty, "old target cannot confirm latest command")
    await c.advance(by: .seconds(1))
    expect(p.setCalls == [usbMic.uid, airpodsMic.uid, airpodsMic.uid], "only latest target receives the single fast retry")
    expect(m.lastError == "Unable to confirm default input change", "trusted command has a bounded lifetime")
    await c.advance(by: .seconds(130))
    expect(p.setCalls.count == 3, "expired trusted selection does not retry indefinitely")
    p.current = airpodsMic
    m.handleDefaultInputChanged()
    expect(m.lastError == nil, "late actual success clears timeout")
    m.selectDevice(airpodsMic)
    expect(p.setCalls.count == 3, "already-current preferred is a no-op")
    p.forceSetFailure = true
    m.selectDevice(builtInMic)
    expect(m.preferredMicrophoneUID == airpodsMic.uid, "rejected explicit setter keeps previous preferred")

    test("acceptance: Manual resumes protection after trusted timeout")
    let c2 = ManualAudioMonitorScheduler()
    let (m2, p2, _) = makeMonitor(devices: [builtInMic, usbMic], current: builtInMic, preferred: builtInMic.uid, mode: .manual, scheduler: c2)
    p2.applySetImmediately = false
    m2.selectDevice(usbMic)
    await c2.advance(by: .seconds(1))
    expect(p2.setCalls.count == 3, "Manual starts a protection command after bounded selection expires")
}

@MainActor
private func acceptanceNotificationsAndConfiguration() async {
    test("acceptance: notifications disabled at confirmation do not consume cooldown")
    let c = ManualAudioMonitorScheduler()
    let (m, p, n) = makeMonitor(devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid, scheduler: c)
    p.applySetImmediately = false
    p.devices.append(usbMic)
    p.current = usbMic
    m.handleDeviceListChanged()
    m.notificationsEnabled = false
    p.current = builtInMic
    m.handleDefaultInputChanged()
    expect(n.presentCount == 0, "switching off suppresses pending notification")
    m.notificationsEnabled = true
    p.applySetImmediately = true
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(n.presentCount == 1, "next confirmed recovery may submit")
    m.settleSeconds = 30
    await c.advance(by: .seconds(2))
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(n.presentCount == 1, "configured cooldown uses latest interval")
    m.settleSeconds = .nan
    expect(m.settleSeconds == 2, "non-finite input cannot create invalid Duration")
    m.settleSeconds = 0
    expect(m.settleSeconds == 1, "lower bound enforced")
    m.settleSeconds = 100
    expect(m.settleSeconds == 30, "upper bound enforced")
}

@MainActor
private func acceptanceObservationProjection() async {
    test("acceptance: writer error/retry projections remain Observable")
    let c = ManualAudioMonitorScheduler()
    let (m, p, _) = makeMonitor(devices: [builtInMic, usbMic], current: builtInMic, preferred: builtInMic.uid, mode: .manual, scheduler: c)
    // The callback is @Sendable; a lock-protected box avoids actor assumptions.
    let changed = AcceptanceFlag()
    withObservationTracking {
        _ = m.lastError
        _ = m.protectionRetryState
    } onChange: {
        changed.set()
    }
    p.forceSetFailure = true
    p.current = usbMic
    m.handleDefaultInputChanged()
    expect(changed.value, "writer mutation invalidates UI projections")
}

private final class AcceptanceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
private func acceptanceManualEventMatrix() async {
    test("acceptance: deterministic Manual/disabled event matrix")
    // Repeated values, changing callback order and real topology reordering.
    for enabled in [true, false] {
        let c = ManualAudioMonitorScheduler()
        let (m, p, _) = makeMonitor(devices: [builtInMic, usbMic, airpodsMic], current: builtInMic, preferred: builtInMic.uid, mode: .manual, protection: enabled, scheduler: c)
        for i in 0..<60 {
            p.current = [builtInMic, usbMic, airpodsMic][i % 3]
            let before = p.setCalls.count
            if i % 2 == 0 { p.devices.reverse(); m.handleDeviceListChanged() }
            else { m.handleDefaultInputChanged() }
            expect(m.preferredMicrophoneUID == builtInMic.uid, "Manual or disabled never learns external current")
            if enabled { expect(m.currentDevice?.uid == builtInMic.uid, "available preferred is enforced") }
            else { expect(p.setCalls.count == before, "disabled protection performs no corrective write") }
            let count = p.setCalls.count
            m.handleDefaultInputChanged()
            expect(p.setCalls.count == count, "duplicate wake is idempotent")
        }
        expect(m.recentAudioEvents.count <= 10, "event history remains bounded")
    }
}
