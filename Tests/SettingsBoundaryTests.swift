import Foundation
import CoreAudio

/// Deliberately ignores cancellation when returning a reply, to verify that
/// AudioMonitor also rejects stale replies rather than trusting the service.
private actor GatedAuthorizationNotifier: NotificationPresenting {
    private var count = 0
    private var pending: [Int: CheckedContinuation<NotificationAuthorizationState, Never>] = [:]
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var finished: [Int: Bool] = [:]
    private var completionWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var passiveAuthorizationState: NotificationAuthorizationState = .authorized
    private var passiveReadCount = 0

    nonisolated func presentRestored(from: String, to: String, reason: RestoreReason) {}
    nonisolated func presentListenerFailure() {}

    func ensureAuthorization() async -> NotificationAuthorizationState {
        count += 1
        let request = count
        let state = await withCheckedContinuation { continuation in
            pending[request] = continuation
            entered.removeValue(forKey: request)?.resume()
        }
        let cancelled = Task.isCancelled
        finished[request] = cancelled
        completionWaiters.removeValue(forKey: request)?.resume(returning: cancelled)
        return state
    }

    func currentAuthorizationState() async -> NotificationAuthorizationState {
        passiveReadCount += 1
        return passiveAuthorizationState
    }

    func waitForRequest(_ request: Int) async {
        if pending[request] != nil { return }
        await withCheckedContinuation { entered[request] = $0 }
    }
    func reply(_ request: Int, _ state: NotificationAuthorizationState) {
        pending.removeValue(forKey: request)?.resume(returning: state)
    }
    func cancellationAtCompletion(_ request: Int) async -> Bool {
        if let cancelled = finished[request] { return cancelled }
        return await withCheckedContinuation { completionWaiters[request] = $0 }
    }
    func passiveReadCountValue() -> Int { passiveReadCount }
    func setPassiveAuthorizationState(_ state: NotificationAuthorizationState) {
        passiveAuthorizationState = state
    }
}

@MainActor
func runSettingsBoundaryTests() async {
    test("settings: empty persisted UID is not an offline preference")
    let suite = "MicLockTests.review.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    defaults.set("", forKey: Preferences.preferredMicrophoneUIDKey)
    expect(preferences.preferredMicrophoneUID == nil, "empty UID is treated as missing")
    preferences.preferredMicrophoneUID = ""
    expect(defaults.string(forKey: Preferences.preferredMicrophoneUIDKey) == nil, "empty UID is not persisted")
    preferences.preferredMicrophoneUID = " opaque uid "
    expect(preferences.preferredMicrophoneUID == " opaque uid ", "nonempty opaque UIDs are not trimmed or rewritten")
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        preferences.settleSeconds = invalid
        expect(preferences.settleSeconds == 2, "nonfinite duration gets the documented default")
    }
    preferences.preferredMicrophoneUID = nil
    preferences.notificationsEnabled = true
    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic]
    provider.current = builtInMic
    let notifier = GatedAuthorizationNotifier()
    let monitor = AudioMonitor(provider: provider, preferences: preferences, notifier: notifier,
                               scheduler: ManualAudioMonitorScheduler())

    test("settings: cancelled authorization cannot overwrite visible state")
    let oldRequest = Task { @MainActor in await monitor.refreshNotificationAuthorization() }
    await notifier.waitForRequest(1)
    oldRequest.cancel()
    await notifier.reply(1, .denied)
    await oldRequest.value
    expect(!monitor.notificationDenied, "cancelled response is ignored even if the service returns denied")

    test("settings: disabling notifications cancels an in-flight owner task")
    monitor.notificationsEnabled = false
    monitor.notificationsEnabled = true
    await notifier.waitForRequest(2)
    monitor.notificationsEnabled = false
    await notifier.reply(2, .denied)
    let wasCancelled = await notifier.cancellationAtCompletion(2)
    expect(wasCancelled, "notification switch cancels the owned authorization task")
    expect(!monitor.notificationDenied, "disabled notifications do not accept a stale denied reply")

    test("settings: a current noncancelled request still updates authorization")
    // A separate monitor has no owned toggle task outstanding. This test waits
    // for its explicit Task.value rather than depending on executor ordering.
    preferences.notificationsEnabled = true
    let freshNotifier = GatedAuthorizationNotifier()
    let freshMonitor = AudioMonitor(provider: provider, preferences: preferences, notifier: freshNotifier,
                                    scheduler: ManualAudioMonitorScheduler())
    let fresh = Task { @MainActor in await freshMonitor.refreshNotificationAuthorization() }
    await freshNotifier.waitForRequest(1)
    await freshNotifier.reply(1, .denied)
    await fresh.value
    expect(freshMonitor.notificationDenied, "a live request can still display denial")

    test("settings: passive sync clears stale denied state after System Settings changes")
    let (passiveMonitor, _, passiveNotifier) = makeMonitor(
        devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid,
        protection: false, notifications: true,
        scheduler: ManualAudioMonitorScheduler()
    )
    passiveNotifier.authorizationState = .denied
    await passiveMonitor.syncNotificationAuthorizationState()
    expect(passiveMonitor.notificationDenied, "denied system state is visible")
    passiveNotifier.authorizationState = .authorized
    await passiveMonitor.syncNotificationAuthorizationState()
    expect(!passiveMonitor.notificationDenied,
           "returning from System Settings clears stale denial")

    test("settings: passive sync is skipped when restore notifications are off and no fault is pending")
    let (offMonitor, _, offNotifier) = makeMonitor(
        devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid,
        protection: false, notifications: false,
        scheduler: ManualAudioMonitorScheduler()
    )
    offNotifier.authorizationState = .denied
    await offMonitor.syncNotificationAuthorizationState()
    expect(offNotifier.passiveAuthorizationReadCount == 0,
           "no authorization need means no passive system read")
    expect(!offMonitor.notificationDenied,
           "denied warning stays hidden without an authorization need")

    test("settings: pending listener fault keeps passive authorization sync active")
    let faultClock = ManualAudioMonitorScheduler()
    let faultListeners = FakeCoreAudioListeners()
    faultListeners.installResults = Array(
        repeating: .failed(.defaultInputAdd(OSStatus(-1))),
        count: 5
    )
    let (faultMonitor, _, faultNotifier) = makeMonitor(
        devices: [builtInMic], current: builtInMic, preferred: builtInMic.uid,
        protection: false, notifications: false, authorization: .denied,
        scheduler: faultClock, listeners: faultListeners
    )
    faultMonitor.start()
    await faultClock.advance(by: .seconds(3.75))
    let denialApplied = await waitUntil { faultMonitor.notificationDenied }
    expect(denialApplied, "terminal listener fault exposes denied authorization guidance")
    expect(faultNotifier.listenerFailureCount == 0,
           "denied authorization cannot submit the pending fault alert")

    let readsBeforeFaultSync = faultNotifier.passiveAuthorizationReadCount
    await faultMonitor.syncNotificationAuthorizationState()
    expect(faultNotifier.passiveAuthorizationReadCount == readsBeforeFaultSync + 1,
           "pending fault permits a passive read while restore notifications are off")

    faultNotifier.authorizationState = .authorized
    await faultMonitor.syncNotificationAuthorizationState()
    expect(!faultMonitor.notificationDenied,
           "authorized passive state clears fault authorization guidance")
    expect(faultNotifier.listenerFailureCount == 1,
           "authorized passive state submits the pending fault alert once")
    await faultMonitor.syncNotificationAuthorizationState()
    expect(faultNotifier.listenerFailureCount == 1,
           "submitted fault alert cannot be duplicated by later passive sync")

    test("settings: active authorization owner defers and preserves passive sync")
    preferences.notificationsEnabled = true
    let deferredNotifier = GatedAuthorizationNotifier()
    let deferredMonitor = AudioMonitor(
        provider: provider,
        preferences: preferences,
        notifier: deferredNotifier,
        scheduler: ManualAudioMonitorScheduler()
    )

    await deferredNotifier.setPassiveAuthorizationState(.denied)
    await deferredMonitor.syncNotificationAuthorizationState()
    expect(deferredMonitor.notificationDenied,
           "precondition: denied warning is visible")

    let active = Task { @MainActor in
        await deferredMonitor.refreshNotificationAuthorization()
    }
    await deferredNotifier.waitForRequest(1)

    await deferredNotifier.setPassiveAuthorizationState(.authorized)
    let readsBeforeDeferred = await deferredNotifier.passiveReadCountValue()
    await deferredMonitor.syncNotificationAuthorizationState()
    expect(await deferredNotifier.passiveReadCountValue() == readsBeforeDeferred,
           "passive sync does not compete with an active authorization owner")

    await deferredNotifier.reply(1, .denied)
    await active.value

    let converged = await waitUntil { !deferredMonitor.notificationDenied }
    let readsAfterDeferred = await deferredNotifier.passiveReadCountValue()
    expect(converged && readsAfterDeferred == readsBeforeDeferred + 1,
           "deferred passive sync runs exactly once and wins over the stale active reply")
}
