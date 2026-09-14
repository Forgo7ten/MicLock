import Foundation

/// Deliberately ignores cancellation when returning a reply, to verify that
/// AudioMonitor also rejects stale replies rather than trusting the service.
private actor GatedAuthorizationNotifier: NotificationPresenting {
    private var count = 0
    private var pending: [Int: CheckedContinuation<NotificationAuthorizationState, Never>] = [:]
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var finished: [Int: Bool] = [:]
    private var completionWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    nonisolated func presentRestored(from: String, to: String, reason: RestoreReason) {}

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
}
