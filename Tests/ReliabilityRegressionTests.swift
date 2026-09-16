import Foundation
import CoreAudio
import Dispatch

@MainActor
func runReliabilityRegressionTests() async {
    testCoreAudioListenerRollbackFailureNeverRepeatsAddBeforeCleanup()
    testAudioMonitorIgnoresCallbackFromFailedListenerInstall()
    testCoreAudioListenerRemoveIsIdempotentAndAllowsReinstall()
    testCoreAudioListenerLifecycleSerializesConcurrentInstallAndRemove()
    await testListenerRetriesExactlySixTimesThenStopsAutomatically()
    await testListenerRetrySuccessResumesStartupPolicy()
    await testListenerCleanupFailureUsesBoundedRetryBudget()
    await testPartialListenerCallbackIsIgnoredUntilPairIsInstalled()
    await testRetryExhaustionPerformsCleanupOnlyWithoutFreshAdd()
    await testListenerFailureIgnoresRestoreNotificationSwitch()
    testEnablingProtectionDoesNotOwnInitialListenerLifecycle()
    await testProtectionDisplayStateMatrix()
    await testListenerFailurePreservesPersistedProtectionIntent()
    await testExplicitListenerRetryStartsFreshRoundAndAlignsOnSuccess()
    await testExplicitRetryGetsFreshFullBudgetAndNewFailureAlert()
    await testFailedProtectionOffOnRearmsListenerAndAlignsImmediately()
    await testProtectionOnWhileListenerRetryingKeepsSingleInstallAndWriterChain()
    await testNewMonitorRetriesListenerWithPersistedProtectionIntent()
    await testRetryClearsUnsubmittedListenerFailureAlert()
    await testManualNotificationCooldownDoesNotThrottleRestore()
    testProductionListenerCallbackBridgesSynchronouslyToMainActor()
}

private struct PersistenceDefaultsFixture {
    let suite: String
    let defaults: UserDefaults
    let preferences: Preferences
}

private func makePersistenceDefaults(
    preferred: String?,
    mode: ProtectionMode,
    protection: Bool,
    notifications: Bool,
    settle: Double = 1.0
) -> PersistenceDefaultsFixture {
    let suite = "MicLockTests.reliability.persistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    defaults.set(preferred, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set(protection, forKey: Preferences.protectionEnabledKey)
    defaults.set(mode.rawValue, forKey: Preferences.protectionModeKey)
    defaults.set(notifications, forKey: Preferences.notificationsEnabledKey)
    defaults.set(settle, forKey: Preferences.settleSecondsKey)

    return PersistenceDefaultsFixture(
        suite: suite,
        defaults: defaults,
        preferences: Preferences(defaults: defaults)
    )
}

private struct PersistenceMonitorFixture {
    let suite: String
    let defaults: UserDefaults
    let preferences: Preferences
    let monitor: AudioMonitor
    let provider: FakeAudioDeviceProvider
    let notifier: RecordingNotifier
}

@MainActor
private func makePersistenceMonitor(
    devices: [AudioInputDevice],
    current: AudioInputDevice?,
    preferred: String?,
    mode: ProtectionMode = .manual,
    protection: Bool = true,
    notifications: Bool = false,
    authorization: NotificationAuthorizationState = .authorized,
    scheduler: AudioMonitorScheduling? = nil,
    listeners: CoreAudioListening
) -> PersistenceMonitorFixture {
    let persistence = makePersistenceDefaults(
        preferred: preferred,
        mode: mode,
        protection: protection,
        notifications: notifications
    )

    let provider = FakeAudioDeviceProvider()
    provider.devices = devices
    provider.current = current

    let notifier = RecordingNotifier()
    notifier.authorizationState = authorization

    let monitor = AudioMonitor(
        provider: provider,
        preferences: persistence.preferences,
        notifier: notifier,
        scheduler: scheduler,
        listeners: listeners
    )

    return PersistenceMonitorFixture(
        suite: persistence.suite,
        defaults: persistence.defaults,
        preferences: persistence.preferences,
        monitor: monitor,
        provider: provider,
        notifier: notifier
    )
}

@MainActor
private func testEnablingProtectionDoesNotOwnInitialListenerLifecycle() {
    test("reliability: enabling protection does not own initial listener lifecycle")

    let listeners = FakeCoreAudioListeners()
    listeners.installResults = [.installed]

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: airpodsMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        notifications: false,
        listeners: listeners
    )

    // Deliberately do not call start(): Toggle must not own initial listener install.
    monitor.protectionEnabled = true

    expect(listeners.installCallCount == 0,
           "Protection Toggle cannot perform the lifecycle's initial listener install")
    expect(monitor.listenerStatus == .notStarted,
           "listener remains notStarted until lifecycle start owns installation")
    expect(provider.setCalls == [builtInMic.uid],
           "existing OFF-to-ON behavior still performs explicit alignment")
}

@MainActor
private func testProtectionDisplayStateMatrix() async {
    test("reliability: display state separates user intent from listener readiness")

    let disabledListeners = FakeCoreAudioListeners()
    disabledListeners.installResults = [.installed]
    let (disabled, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: false,
        notifications: false,
        listeners: disabledListeners
    )
    disabled.start()
    expect(disabled.protectionDisplayState == .disabled,
           "user OFF stays disabled even with a healthy listener")

    let activeListeners = FakeCoreAudioListeners()
    activeListeners.installResults = [.installed]
    let (active, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: true,
        notifications: false,
        listeners: activeListeners
    )
    active.start()
    expect(active.protectionDisplayState == .active,
           "user ON plus installed listener is active")

    let retryClock = ManualAudioMonitorScheduler()
    let retryListeners = FakeCoreAudioListeners()
    retryListeners.installResults = [
        .failed(.defaultInputAdd(OSStatus(-1))),
        .installed
    ]
    let (starting, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: true,
        notifications: false,
        scheduler: retryClock,
        listeners: retryListeners
    )
    starting.start()
    expect(starting.protectionDisplayState == .starting,
           "user ON plus retrying listener is starting")

    let failedClock = ManualAudioMonitorScheduler()
    let failedListeners = FakeCoreAudioListeners()
    failedListeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 7
    )
    let (unavailable, _, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: true,
        notifications: false,
        scheduler: failedClock,
        listeners: failedListeners
    )
    unavailable.start()
    await failedClock.advance(by: .seconds(15.75))
    expect(unavailable.protectionDisplayState == .unavailable,
           "user ON plus exhausted listener round is unavailable")
}

@MainActor
private func testListenerFailurePreservesPersistedProtectionIntent() async {
    test("reliability: listener exhaustion preserves persisted protection intent")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 7
    )

    let fixture = makePersistenceMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }

    fixture.monitor.start()
    await clock.advance(by: .seconds(15.75))

    expect(fixture.monitor.listenerStatus == .failed,
           "listener round exhausts")
    expect(fixture.monitor.protectionEnabled,
           "runtime user intent remains enabled")
    expect(fixture.preferences.protectionEnabled,
           "Preferences user intent remains enabled")
    expect(
        fixture.defaults.object(
            forKey: Preferences.protectionEnabledKey
        ) as? Bool == true,
        "raw UserDefaults user intent remains explicitly enabled"
    )
    expect(fixture.monitor.protectionDisplayState == .unavailable,
           "UI projects unavailable without rewriting user intent")
}

@MainActor
private func testExplicitListenerRetryStartsFreshRoundAndAlignsOnSuccess() async {
    test("reliability: explicit listener Retry starts a fresh round and aligns on success")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults =
        Array(
            repeating: .failed(.defaultInputAdd(OSStatus(-1))),
            count: 7
        )
        + [.installed]

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: airpodsMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    await clock.advance(by: .seconds(15.75))

    expect(listeners.installCallCount == 7, "first round uses seven install attempts")
    expect(monitor.listenerStatus == .failed, "first round is exhausted")
    expect(provider.setCalls.isEmpty,
           "startup alignment does not run before listener installation succeeds")

    monitor.retryListenerInstallation()

    expect(listeners.installCallCount == 8,
           "explicit Retry performs one immediate fresh install attempt")
    expect(monitor.listenerStatus == .installed,
           "fresh round can install the listener immediately")
    expect(monitor.protectionEnabled,
           "explicit listener Retry does not change user protection intent")
    expect(monitor.protectionDisplayState == .active,
           "successful listener recovery projects active")
    expect(provider.setCalls == [builtInMic.uid],
           "listener recovery performs fresh startup alignment")
}

@MainActor
private func testExplicitRetryGetsFreshFullBudgetAndNewFailureAlert() async {
    test("reliability: explicit Retry gets a full new budget and a new exhausted-round alert")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 14
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
    await clock.advance(by: .seconds(15.75))

    let firstAlertArrived = await waitUntil {
        notifier.listenerFailureCount == 1
    }
    expect(firstAlertArrived, "first exhausted round submits one reliability alert")

    monitor.retryListenerInstallation()
    expect(listeners.installCallCount == 8,
           "new round starts with one immediate install attempt")

    await clock.advance(by: .seconds(15.75))

    expect(listeners.installCallCount == 14,
           "new round receives all six retry slots")
    expect(monitor.listenerStatus == .failed,
           "second round can independently exhaust")

    let secondAlertArrived = await waitUntil {
        notifier.listenerFailureCount == 2
    }
    expect(secondAlertArrived,
           "second exhausted round submits its own reliability alert")
    expect(notifier.listenerFailureCount == 2,
           "each exhausted round submits at most one reliability alert")
}

@MainActor
private func testFailedProtectionOffOnRearmsListenerAndAlignsImmediately() async {
    test("reliability: failed listener OFF-to-ON persists user choice and rearms")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults =
        Array(
            repeating: .failed(.defaultInputAdd(OSStatus(-1))),
            count: 8
        )
        + [.installed]

    let fixture = makePersistenceMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }

    fixture.monitor.start()
    await clock.advance(by: .seconds(15.75))
    expect(fixture.monitor.listenerStatus == .failed,
           "precondition: first listener round is exhausted")

    fixture.monitor.protectionEnabled = false

    expect(!fixture.monitor.protectionEnabled,
           "runtime intent reflects the explicit OFF")
    expect(!fixture.preferences.protectionEnabled,
           "Preferences persists the explicit OFF")
    expect(
        fixture.defaults.object(
            forKey: Preferences.protectionEnabledKey
        ) as? Bool == false,
        "raw UserDefaults explicitly persists OFF"
    )

    fixture.provider.current = airpodsMic
    fixture.monitor.protectionEnabled = true

    expect(fixture.monitor.protectionEnabled,
           "runtime intent reflects the explicit ON")
    expect(fixture.preferences.protectionEnabled,
           "Preferences persists the explicit ON")
    expect(
        fixture.defaults.object(
            forKey: Preferences.protectionEnabledKey
        ) as? Bool == true,
        "raw UserDefaults explicitly persists ON"
    )
    expect(fixture.provider.setCalls == [builtInMic.uid],
           "OFF-to-ON keeps the existing immediate alignment behavior")
    expect(listeners.installCallCount == 8,
           "failed OFF-to-ON immediately starts one new listener round")
    expect(fixture.monitor.listenerStatus == .retrying(nextAttempt: 1, total: 6),
           "new round initial failure schedules retry 1/6")

    await clock.advance(by: .milliseconds(250))

    expect(listeners.installCallCount == 9,
           "new round performs its first scheduled retry")
    expect(fixture.monitor.listenerStatus == .installed,
           "new round can recover")
    expect(fixture.provider.setCalls == [builtInMic.uid],
           "listener success does not duplicate the already-confirmed alignment")
}

@MainActor
private func testProtectionOnWhileListenerRetryingKeepsSingleInstallAndWriterChain() async {
    test("reliability: protection ON during listener retry keeps one install and writer chain")

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
        protection: false,
        notifications: false,
        scheduler: clock,
        listeners: listeners
    )
    provider.applySetImmediately = false

    monitor.start()

    expect(listeners.installCallCount == 1,
           "initial listener attempt is the only install owner")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 1, total: 6),
           "listener is waiting for retry 1/6")
    expect(provider.setCalls.isEmpty,
           "Protection OFF performs no startup alignment")

    monitor.protectionEnabled = true

    expect(listeners.installCallCount == 1,
           "Protection ON does not create a parallel listener install")
    expect(provider.setCalls == [builtInMic.uid],
           "explicit OFF-to-ON still performs immediate alignment")

    await clock.advance(by: .milliseconds(250))

    expect(listeners.installCallCount == 2,
           "the original listener retry chain owns the successful install")
    expect(monitor.listenerStatus == .installed,
           "the original listener retry chain recovers")
    expect(provider.setCalls == [builtInMic.uid],
           "listener recovery reconcile does not duplicate the pending writer")

    await clock.advance(by: .milliseconds(250))

    expect(provider.setCalls.count == 2,
           "the single original 500ms writer watchdog performs exactly one retry")
}

@MainActor
private func testNewMonitorRetriesListenerWithPersistedProtectionIntent() async {
    test("reliability: a new monitor retries listener while persisted intent stays enabled")

    let firstClock = ManualAudioMonitorScheduler()
    let firstListeners = FakeCoreAudioListeners()
    firstListeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 7
    )

    let first = makePersistenceMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        notifications: false,
        scheduler: firstClock,
        listeners: firstListeners
    )
    defer {
        first.defaults.removePersistentDomain(forName: first.suite)
    }

    first.monitor.start()
    await firstClock.advance(by: .seconds(15.75))

    expect(first.monitor.listenerStatus == .failed,
           "first monitor exhausts its process-local listener round")
    expect(first.preferences.protectionEnabled,
           "first monitor failure leaves persisted intent enabled")
    expect(
        first.defaults.object(
            forKey: Preferences.protectionEnabledKey
        ) as? Bool == true,
        "raw UserDefaults remains enabled for the next monitor"
    )

    let secondProvider = FakeAudioDeviceProvider()
    secondProvider.devices = [builtInMic, airpodsMic]
    secondProvider.current = airpodsMic

    let secondListeners = FakeCoreAudioListeners()
    secondListeners.installResults = [.installed]

    let secondMonitor = AudioMonitor(
        provider: secondProvider,
        preferences: first.preferences,
        notifier: RecordingNotifier(),
        scheduler: ManualAudioMonitorScheduler(),
        listeners: secondListeners
    )

    secondMonitor.start()

    expect(secondMonitor.protectionEnabled,
           "new monitor reloads the persisted enabled intent")
    expect(secondListeners.installCallCount == 1,
           "new monitor gets a new listener installation round")
    expect(secondMonitor.listenerStatus == .installed,
           "new monitor can install the listener")
    expect(secondMonitor.protectionDisplayState == .active,
           "new monitor projects active after listener installation")
    expect(secondProvider.setCalls == [builtInMic.uid],
           "new monitor performs fresh startup alignment")
}

@MainActor
private func testRetryClearsUnsubmittedListenerFailureAlert() async {
    test("reliability: Retry clears an obsolete unsubmitted listener failure alert")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults =
        Array(
            repeating: .failed(.defaultInputAdd(OSStatus(-1))),
            count: 7
        )
        + [.installed]

    let (monitor, _, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        protection: true,
        notifications: false,
        authorization: .denied,
        scheduler: clock,
        listeners: listeners
    )

    monitor.start()
    await clock.advance(by: .seconds(15.75))

    let denialApplied = await waitUntil {
        monitor.notificationDenied
    }
    expect(denialApplied,
           "exhausted round exposes denied authorization guidance")
    expect(notifier.listenerFailureCount == 0,
           "denied authorization leaves the listener fault unsubmitted")

    monitor.retryListenerInstallation()

    expect(monitor.listenerStatus == .installed,
           "explicit Retry recovers the listener")
    expect(!monitor.notificationDenied,
           "obsolete fault-only denied guidance is cleared")

    notifier.authorizationState = .authorized
    await monitor.syncNotificationAuthorizationState()

    expect(notifier.listenerFailureCount == 0,
           "the obsolete listener fault cannot be submitted after recovery")
}

private final class BlockingCoreAudioListenerBackend: CoreAudioListenerBackend {
    let firstDefaultAddEntered = DispatchSemaphore(value: 0)
    let releaseFirstDefaultAdd = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var defaultAddStorage = 0
    private var devicesAddStorage = 0
    private var defaultRemoveStorage = 0
    private var devicesRemoveStorage = 0

    var defaultRemoveCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return defaultRemoveStorage
    }

    var devicesRemoveCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return devicesRemoveStorage
    }

    func addDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        stateLock.lock()
        defaultAddStorage += 1
        let isFirstAdd = defaultAddStorage == 1
        stateLock.unlock()

        if isFirstAdd {
            firstDefaultAddEntered.signal()
            releaseFirstDefaultAdd.wait()
        }
        return noErr
    }

    func addDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        stateLock.lock()
        devicesAddStorage += 1
        stateLock.unlock()
        return noErr
    }

    func removeDefaultInputListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        stateLock.lock()
        defaultRemoveStorage += 1
        stateLock.unlock()
        return noErr
    }

    func removeDevicesListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        stateLock.lock()
        devicesRemoveStorage += 1
        stateLock.unlock()
        return noErr
    }
}

@MainActor
private func testCoreAudioListenerLifecycleSerializesConcurrentInstallAndRemove() {
    test("reliability: listener lifecycle serializes concurrent install and remove")

    let backend = BlockingCoreAudioListenerBackend()
    let listeners = CoreAudioListeners(backend: backend)
    let installFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        _ = listeners.install(onDefaultInputChange: {}, onDevicesChange: {})
        installFinished.signal()
    }

    expect(
        backend.firstDefaultAddEntered.wait(timeout: .now() + 1) == .success,
        "background install reaches the blocking default-input Add"
    )

    let release = backend.releaseFirstDefaultAdd
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(50)) {
        release.signal()
    }

    // With serialized lifecycle state this waits for install to finish, then
    // removes the newly installed pair. Without serialization remove returns
    // while the Add is blocked and the later install escapes cleanup.
    listeners.remove()

    expect(
        installFinished.wait(timeout: .now() + 1) == .success,
        "background install completes after the blocked Add is released"
    )
    expect(backend.defaultRemoveCount == 1,
           "concurrent remove cleans the installed default listener exactly once")
    expect(backend.devicesRemoveCount == 1,
           "concurrent remove cleans the installed devices listener exactly once")

    listeners.remove()
    expect(backend.defaultRemoveCount == 1 && backend.devicesRemoveCount == 1,
           "a second remove remains idempotent after the serialized race")
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
private func testListenerRetriesExactlySixTimesThenStopsAutomatically() async {
    test("reliability: listener install retries exactly six times then stops automatically")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.retainCallbacksOnFailure = true
    listeners.retainCallbacksOnRemove = true
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 7
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
    expect(monitor.listenerStatus == .retrying(nextAttempt: 1, total: 6),
           "first failure schedules retry slot 1/6")

    await clock.advance(by: .milliseconds(250))
    expect(listeners.installCallCount == 2, "retry #1 runs after 250ms")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 2, total: 6),
           "retry #2 is scheduled")

    await clock.advance(by: .milliseconds(500))
    expect(listeners.installCallCount == 3, "retry #2 runs after 500ms")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 3, total: 6),
           "retry #3 is scheduled")

    await clock.advance(by: .seconds(1))
    expect(listeners.installCallCount == 4, "retry #3 runs after 1s")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 4, total: 6),
           "retry #4 is scheduled")

    await clock.advance(by: .seconds(2))
    expect(listeners.installCallCount == 5, "retry #4 runs after 2s")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 5, total: 6),
           "retry #5 is scheduled")

    await clock.advance(by: .seconds(4))
    expect(listeners.installCallCount == 6, "retry #5 runs after 4s")
    expect(monitor.listenerStatus == .retrying(nextAttempt: 6, total: 6),
           "retry #6 is scheduled")

    await clock.advance(by: .seconds(8))
    expect(listeners.installCallCount == 7, "retry #6 runs after 8s")
    expect(monitor.listenerStatus == .failed,
           "seventh failed install exhausts the current round")

    provider.current = airpodsMic
    listeners.fireDefaultInputChange()
    expect(provider.setCalls.isEmpty,
           "callback retained after exhausted cleanup cannot drive policy")

    let failureNotificationArrived = await waitUntil {
        notifier.listenerFailureCount == 1
    }
    expect(failureNotificationArrived,
           "exhausted-round notification arrives within the test deadline")
    expect(notifier.listenerFailureCount == 1,
           "one exhausted round submits at most one failure notification")

    await clock.advance(by: .seconds(120))
    monitor.start()

    expect(listeners.installCallCount == 7,
           "ordinary start cannot reopen an exhausted listener round")
    expect(notifier.listenerFailureCount == 1,
           "ordinary start cannot duplicate the exhausted-round notification")
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
        count: 7
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
    await clock.advance(by: .seconds(15.75))

    expect(listeners.installCallCount == 7,
           "cleanup failure uses only initial plus six recovery slots")
    expect(monitor.listenerStatus == .failed,
           "cleanup failure exhausts the same bounded listener round")
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
    expect(monitor.listenerStatus == .retrying(nextAttempt: 1, total: 6),
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
private func testRetryExhaustionPerformsCleanupOnlyWithoutFreshAdd() async {
    test("reliability: exhausted listener round performs cleanup only")

    let clock = ManualAudioMonitorScheduler()
    let backend = FakeCoreAudioListenerBackend()
    backend.defaultAddResults = [noErr]
    backend.devicesAddResults = [OSStatus(-2)]
    backend.defaultRemoveResults = [
        OSStatus(-3), OSStatus(-3), OSStatus(-3), OSStatus(-3),
        OSStatus(-3), OSStatus(-3), OSStatus(-3), noErr
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
    await clock.advance(by: .seconds(15.75))

    expect(monitor.listenerStatus == .failed,
           "retry budget exhausts the current round")
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "cleanup-only retries and final cleanup never perform fresh Adds")
    expect(backend.defaultRemoveCount == 8,
           "exhaustion performs one final best-effort cleanup after seven failed cleanup attempts")
    expect(!backend.hasRetainedDefaultListener,
           "successful exhaustion cleanup releases the retained default listener")

    await clock.advance(by: .seconds(120))
    monitor.start()
    expect(backend.defaultAddCount == 1 && backend.devicesAddCount == 1,
           "ordinary start never reopens an exhausted install round")
}

@MainActor
private func testListenerFailureIgnoresRestoreNotificationSwitch() async {
    test("reliability: listener failure ignores restore notification switch")

    let clock = ManualAudioMonitorScheduler()
    let listeners = FakeCoreAudioListeners()
    listeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 7
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
    await clock.advance(by: .seconds(15.75))

    expect(monitor.listenerStatus == .failed, "exhausted listener round remains visible")
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
