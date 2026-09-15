import Foundation
import CoreAudio

@MainActor
func runReliabilityRegressionTests() async {
    testCoreAudioListenerRollbackFailureNeverRepeatsAddBeforeCleanup()
    testAudioMonitorIgnoresCallbackFromFailedListenerInstall()
    testCoreAudioListenerRemoveIsIdempotentAndAllowsReinstall()
    await testListenerRetriesExactlyFourTimesThenStops()
    await testListenerRetrySuccessResumesStartupPolicy()
    await testListenerCleanupFailureUsesBoundedRetryBudget()
    await testPartialListenerCallbackIsIgnoredUntilPairIsInstalled()
    await testTerminalFailurePerformsCleanupOnlyWithoutFreshAdd()
    await testListenerFailureIgnoresRestoreNotificationSwitch()
    await testManualNotificationCooldownDoesNotThrottleRestore()
    testProductionListenerCallbackBridgesSynchronouslyToMainActor()
}

@MainActor
private func testCoreAudioListenerRollbackFailureNeverRepeatsAddBeforeCleanup() {
    test("reliability: listener rollback failure blocks new Add until cleanup succeeds")

    let backend = FakeCoreAudioListenerBackend()
    backend.defaultAddResults = [noErr, noErr]
    backend.devicesAddResults = [OSStatus(-2), noErr]
    backend.defaultRemoveResults = [OSStatus(-3), OSStatus(-3), noErr]

    let listeners = CoreAudioListeners(backend: backend)

    let first = listeners.install(onDefaultInputChange: {}, onDevicesChange: {})
    expect(first == .failed(.cleanup(OSStatus(-3))), "failed rollback is surfaced as cleanup failure")
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "first attempt performs one pair of Adds")

    let second = listeners.install(onDefaultInputChange: {}, onDevicesChange: {})
    expect(second == .failed(.cleanup(OSStatus(-3))), "next attempt retries cleanup")
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "cleanup failure performs zero new Adds")

    let third = listeners.install(onDefaultInputChange: {}, onDevicesChange: {})
    expect(third == .installed, "cleanup recovery can continue to a fresh install")
    expect(backend.defaultAddCount == 2 && backend.devicesAddCount == 2,
           "fresh Adds happen only after retained registration is removed")
}

@MainActor
private func testAudioMonitorIgnoresCallbackFromFailedListenerInstall() {
    test("reliability: failed listener install cannot drive AudioMonitor policy")

    let listeners = FakeCoreAudioListeners()
    listeners.retainCallbacksOnFailure = true
    listeners.installResults = [.failed(.cleanup(OSStatus(-3)))]

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        listeners: listeners
    )

    monitor.start()
    provider.current = airpodsMic
    listeners.fireDefaultInputChange()

    expect(provider.setCalls.isEmpty,
           "callback retained by a failed/partial install is ignored before a full pair is healthy")
}

@MainActor
private func testCoreAudioListenerRemoveIsIdempotentAndAllowsReinstall() {
    test("reliability: listener remove is idempotent and allows reinstall")

    let backend = FakeCoreAudioListenerBackend()
    let listeners = CoreAudioListeners(backend: backend)

    expect(
        listeners.install(onDefaultInputChange: {}, onDevicesChange: {}) == .installed,
        "initial listener pair installs"
    )

    listeners.remove()
    listeners.remove()

    expect(backend.defaultRemoveCount == 1, "repeated remove does not remove default listener twice")
    expect(backend.devicesRemoveCount == 1, "repeated remove does not remove devices listener twice")

    expect(
        listeners.install(onDefaultInputChange: {}, onDevicesChange: {}) == .installed,
        "listener pair can be installed again after a clean remove"
    )
    expect(backend.defaultAddCount == 2, "reinstall performs exactly one new default Add")
    expect(backend.devicesAddCount == 2, "reinstall performs exactly one new devices Add")

    listeners.remove()
    expect(backend.defaultRemoveCount == 2, "final remove releases the reinstalled default listener exactly once")
    expect(backend.devicesRemoveCount == 2, "final remove releases the reinstalled devices listener exactly once")
}

@MainActor
private func testListenerRetriesExactlyFourTimesThenStops() async {
    test("reliability: listener install retries exactly four times then stops")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.retainCallbacksOnFailure = true
    listeners.retainCallbacksOnRemove = true
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 5
    )

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    expect(listeners.installCallCount == 1, "initial install is immediate")

    await clock.advance(by: .seconds(3.75))

    expect(listeners.installCallCount == 5, "initial plus exactly four retries")
    expect(monitor.listenerStatus == .failed, "retry budget ends in terminal failure")

    provider.current = airpodsMic
    listeners.fireDefaultInputChange()
    expect(provider.setCalls.isEmpty,
           "callback retained after failed terminal cleanup cannot drive policy")

    let failureNotificationArrived = await waitUntil {
        notifier.listenerFailureCount == 1
    }
    expect(failureNotificationArrived,
           "terminal failure notification arrives within the test deadline")
    expect(notifier.listenerFailureCount == 1,
           "terminal failure submits at most one failure notification")

    await clock.advance(by: .seconds(120))
    monitor.start()

    expect(listeners.installCallCount == 5, "failed state cannot restart the retry budget")
    expect(notifier.listenerFailureCount == 1, "failure notification is not duplicated")
}

@MainActor
private func testListenerRetrySuccessResumesStartupPolicy() async {
    test("reliability: listener recovery resumes startup alignment")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = [
        .failed(.defaultInputAdd(OSStatus(-1))),
        .installed
    ]

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: airpodsMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    expect(provider.setCalls.isEmpty, "failed listener install cannot run startup alignment")

    await clock.advance(by: .milliseconds(250))

    expect(monitor.listenerStatus == .installed, "first retry recovers the listener pair")
    expect(provider.setCalls == [builtInMic.uid],
           "startup alignment starts only after listener installation succeeds")
}

@MainActor
private func testListenerCleanupFailureUsesBoundedRetryBudget() async {
    test("reliability: listener cleanup failure remains bounded")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = Array(
        repeating: .failed(.cleanup(OSStatus(-3))),
        count: 5
    )

    let (monitor, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: false,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    await clock.advance(by: .seconds(3.75))

    expect(listeners.installCallCount == 5,
           "cleanup failure uses only initial plus four recovery slots")
    expect(monitor.listenerStatus == .failed,
           "cleanup failure reaches the same terminal state")
}

@MainActor
private func testPartialListenerCallbackIsIgnoredUntilPairIsInstalled() async {
    test("reliability: partial listener callback is ignored until listener pair is installed")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.retainCallbacksOnFailure = true
    listeners.installResults = [
        .failed(.cleanup(OSStatus(-3))),
        .installed
    ]

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    expect(monitor.listenerStatus == .retrying(nextAttempt: 1, total: 4),
           "failed install enters retrying state")

    provider.current = airpodsMic
    listeners.fireDefaultInputChange()
    expect(provider.setCalls.isEmpty,
           "callback from partial registration cannot run Manual protection")

    provider.current = builtInMic
    await clock.advance(by: .milliseconds(250))
    expect(monitor.listenerStatus == .installed, "listener pair becomes healthy on retry")
    expect(provider.setCalls.isEmpty, "healthy startup state requires no restore")

    provider.current = airpodsMic
    listeners.fireDefaultInputChange()
    expect(provider.setCalls == [builtInMic.uid],
           "same callback path becomes active only after the full pair is installed")
}

@MainActor
private func testTerminalFailurePerformsCleanupOnlyWithoutFreshAdd() async {
    test("reliability: terminal listener failure performs cleanup only")

    let clock = ManualAudioMonitorScheduler()
    let backend = FakeCoreAudioListenerBackend()
    backend.defaultAddResults = [noErr]
    backend.devicesAddResults = [OSStatus(-2)]
    backend.defaultRemoveResults = [
        OSStatus(-3), OSStatus(-3), OSStatus(-3),
        OSStatus(-3), OSStatus(-3), noErr
    ]

    let listeners = CoreAudioListeners(backend: backend)
    let (monitor, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: false,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    await clock.advance(by: .seconds(3.75))

    expect(monitor.listenerStatus == .failed, "retry budget ends in terminal state")
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "cleanup-only retries and terminal cleanup never perform fresh Adds")
    expect(backend.defaultRemoveCount == 6,
           "terminal path performs one final best-effort cleanup after five failed cleanup attempts")
    expect(!backend.hasRetainedDefaultListener,
           "successful terminal cleanup releases the retained default listener")

    await clock.advance(by: .seconds(120))
    monitor.start()
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "terminal state never reopens install budget")
}

@MainActor
private func testListenerFailureIgnoresRestoreNotificationSwitch() async {
    test("reliability: listener failure ignores restore notification switch")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 5
    )

    let (monitor, _, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: false,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    await clock.advance(by: .seconds(3.75))

    expect(monitor.listenerStatus == .failed, "terminal listener failure remains visible")
    let arrived = await waitUntil { notifier.listenerFailureCount == 1 }
    expect(arrived,
           "listener reliability alert is delivered even when restore notifications are disabled")
    expect(notifier.presentCount == 0, "restore-notification switch remains off")
}

@MainActor
private func testManualNotificationCooldownDoesNotThrottleRestore() async {
    test("reliability: Manual notification cooldown never throttles restore")

    let clock = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        scheduler: clock
    )

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.count == 2, "both hijacks are restored immediately")
    expect(notifier.presentCount == 1, "second notification is suppressed")
    expect(
        monitor.recentAudioEvents.filter { $0.kind == .restored(.manualLock) }.count == 2,
        "Recent Events remain unthrottled"
    )

    await clock.advance(by: .seconds(10))

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.count == 3, "Manual remains strict after the cooldown")
    expect(notifier.presentCount == 2, "exact 10-second boundary permits a new notification")
    expect(
        monitor.recentAudioEvents.filter { $0.kind == .restored(.manualLock) }.count == 3,
        "third restore also records an unthrottled Recent Event"
    )
}

@MainActor
private func testProductionListenerCallbackBridgesSynchronouslyToMainActor() {
    test("reliability: production listener callback bridges synchronously to MainActor")

    let backend = FakeCoreAudioListenerBackend()
    let listeners = CoreAudioListeners(backend: backend)
    var defaultCount = 0
    var devicesCount = 0

    let result = listeners.install(
        onDefaultInputChange: { defaultCount += 1 },
        onDevicesChange: { devicesCount += 1 }
    )
    expect(result == .installed, "test listener pair installs")

    backend.fireDefaultInputChange()
    expect(defaultCount == 1, "default callback reaches MainActor before fire returns")
    expect(devicesCount == 0, "default callback does not invoke devices handler")

    backend.fireDevicesChange()
    expect(devicesCount == 1, "devices callback reaches MainActor before fire returns")
}
