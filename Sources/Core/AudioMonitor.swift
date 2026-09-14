import Foundation
import CoreAudio
import Observation

/// Coordinates observations, Auto policy and one logical write command.
/// A wake-up is never itself evidence of an external device change.
@Observable
@MainActor
final class AudioMonitor {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var currentDevice: AudioInputDevice?
    private(set) var listenerError: String?
    // Compatibility name for existing UI; also covers invalid joint samples.
    private(set) var deviceEnumerationError: String?
    private(set) var notificationDenied = false
    private(set) var recentAudioEvents: [RecentAudioEvent] = []

    var lastError: String? { writer.failure?.message }
    var protectionRetryState: ProtectionRetryState? { writer.retryState }

    var preferredMicrophoneUID: String? {
        didSet {
            guard preferredMicrophoneUID != oldValue else { return }
            preferences.preferredMicrophoneUID = preferredMicrophoneUID
            cancelCandidate()
            cancelMissingDefaultInputRecovery()
            AudioMonitorDiagnostics.trace("PREFERRED_CHANGED uid=\(preferredMicrophoneUID ?? "nil")")
        }
    }

    var protectionEnabled: Bool {
        didSet {
            guard protectionEnabled != oldValue else { return }
            preferences.protectionEnabled = protectionEnabled
            cancelSupersededWork()
            // Auto topology windows remain meaningful while enforcement is off:
            // enabling protection during a recent window must still catch a
            // delayed system default-input switch.
            if protectionEnabled { evaluateStartupPolicy() }
        }
    }

    var protectionMode: ProtectionMode {
        didSet {
            guard protectionMode != oldValue else { return }
            preferences.protectionMode = protectionMode
            cancelSupersededWork()
            policy.reset()
            if protectionMode == .manual {
                // Manual mode is an explicit alignment request.
                evaluateStartupPolicy()
            } else if protectionEnabled {
                // Auto only re-enters ordinary policy after superseding old
                // Manual work. This is NOT an alignment request: a stable
                // non-nil mismatch still needs real change evidence, while a
                // trusted nil current may start missing-default debounce.
                reconcile()
            }
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            preferences.notificationsEnabled = notificationsEnabled
            scheduleNotificationAuthorization()
        }
    }

    private var configuredSettleSeconds: Double
    var settleSeconds: Double {
        get { configuredSettleSeconds }
        set {
            // Expire using the OLD duration before extending configuration, so
            // an already expired protection window cannot be resurrected.
            _ = policy.isProtecting(at: scheduler.now, interval: settleInterval)
            configuredSettleSeconds = Preferences.clamp(newValue)
            preferences.settleSeconds = configuredSettleSeconds
            scheduleCandidate()
            scheduleMissingDefaultInputRecovery()
        }
    }

    private let provider: AudioDeviceProviding
    private let preferences: Preferences
    private let notifier: NotificationPresenting
    private let scheduler: AudioMonitorScheduling
    private let listeners = CoreAudioListeners()

    // Writer is intentionally observable: UI error/retry projections depend on it.
    private var writer = DefaultInputWriter()
    @ObservationIgnored private var policy = AutoPolicy()
    // nil is an unknown baseline, [] is a successfully sampled empty topology.
    private var trustedDevices: [AudioInputDevice]?
    @ObservationIgnored private var currentRevision: UInt64 = 0
    private var hasSuccessfulCurrentObservation = false
    @ObservationIgnored private var alignmentRequested = false
    @ObservationIgnored private var listenersInstalled = false
    @ObservationIgnored private var lastKnownDeviceNames: [String: String]
    // Notification submission is independently throttled, not rebound to Auto.
    @ObservationIgnored private var lastAutoNotificationAt: ContinuousClock.Instant?
    @ObservationIgnored private var candidateTask: AudioMonitorScheduledTask?
    @ObservationIgnored private var missingDefaultInputSince: ContinuousClock.Instant?
    @ObservationIgnored private var missingDefaultInputTask: AudioMonitorScheduledTask?
    @ObservationIgnored private var watchdogTask: AudioMonitorScheduledTask?
    @ObservationIgnored private var recoveryTask: AudioMonitorScheduledTask?
    @ObservationIgnored private var recoveryAttempt = 0
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?

    private static let recoveryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
        .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(64)
    ]
    private var settleInterval: Duration { .seconds(configuredSettleSeconds) }
    private var preferredDevice: AudioInputDevice? {
        trustedDevices?.first { $0.uid == preferredMicrophoneUID }
    }
    var currentDeviceName: String {
        if let currentDevice {
            return currentDevice.name
        }
        return hasSuccessfulCurrentObservation ? "无默认输入" : "Unknown"
    }
    var isPreferredMicrophoneAvailable: Bool { preferredDevice != nil }
    var offlinePreferredName: String? {
        guard deviceEnumerationError == nil,
              let trustedDevices,
              let uid = preferredMicrophoneUID,
              !trustedDevices.contains(where: { $0.uid == uid }) else { return nil }
        return lastKnownDeviceNames[uid] ?? "Unknown device"
    }

    init(
        provider: AudioDeviceProviding,
        preferences: Preferences,
        notifier: NotificationPresenting,
        scheduler: AudioMonitorScheduling? = nil
    ) {
        self.provider = provider
        self.preferences = preferences
        self.notifier = notifier
        self.scheduler = scheduler ?? ContinuousAudioMonitorScheduler()
        preferredMicrophoneUID = preferences.preferredMicrophoneUID
        protectionEnabled = preferences.protectionEnabled
        protectionMode = preferences.protectionMode
        notificationsEnabled = preferences.notificationsEnabled
        configuredSettleSeconds = preferences.settleSeconds
        lastKnownDeviceNames = preferences.lastKnownDeviceNames
        // Initial observation seeds UI/current/topology baseline and refreshes
        // resolved device names, but must not initialize Preferred or recover.
        // start() resamples after listeners are installed.
        _ = sample(scheduleRecovery: false, allowPreferredInitialization: false)
    }

    deinit {
        listeners.remove()
        authorizationTask?.cancel()
    }

    static func live() -> AudioMonitor {
        AudioMonitor(provider: LiveAudioDeviceProvider(), preferences: Preferences(), notifier: NotificationManager.shared)
    }

    func start() {
        if !listenersInstalled {
            let result = listeners.install(
                onDefaultInputChange: { [weak self] in self?.handleDefaultInputChanged() },
                onDevicesChange: { [weak self] in self?.handleDeviceListChanged() }
            )
            guard result.defaultInputStatus == noErr, result.devicesStatus == noErr else {
                listenerError = "Unable to install CoreAudio listeners (defaultInput: \(result.defaultInputStatus), devices: \(result.devicesStatus))"
                return
            }
            listenersInstalled = true
            listenerError = nil
            scheduleNotificationAuthorization(after: .milliseconds(500))
        }
        evaluateStartupPolicy()
    }

    /// Also used by tests without installing real HAL listeners.
    func evaluateStartupPolicy() {
        alignmentRequested = true
        reconcile()
    }

    func handleDeviceListChanged() { reconcile() }
    func handleDefaultInputChanged() { reconcile() }

    // MARK: - Observations

    private struct CurrentObservation {
        let device: AudioInputDevice?
        let changed: Bool
    }
    private struct Sample {
        let observation: CurrentObservation?
        let valid: Bool
        let added: Set<String>
    }

    /// All successful current reads advance the SAME baseline, including reads
    /// made by a setter/watchdog. Those reads do not automatically start learning.
    private func readCurrent() throws -> CurrentObservation {
        let device = try provider.currentInputDevice()
        hasSuccessfulCurrentObservation = true
        let changed = currentRevision != 0 && device?.uid != currentDevice?.uid
        if changed || currentRevision == 0 { currentRevision &+= 1 }
        currentDevice = device
        policy.observedRevision(currentRevision)
        return CurrentObservation(device: device, changed: changed)
    }

    private func sample(
        scheduleRecovery: Bool = true,
        allowPreferredInitialization: Bool = true
    ) -> Sample {
        let observation: CurrentObservation?
        var errorMessage: String?
        do {
            observation = try readCurrent()
        } catch {
            observation = nil
            errorMessage = "Unable to read current input device"
            logProviderError(error)
        }

        let snapshot: AudioInputDeviceSnapshot?
        do {
            snapshot = try provider.listInputDevices()
            if let snapshot {
                devices = Self.sortedDevices(snapshot.devices)
                recordDeviceNames(devices)
                if !snapshot.isComplete {
                    for issue in snapshot.issues { logProviderError(issue) }
                    errorMessage = errorMessage ?? "Some input device properties are temporarily unreadable"
                }
            }
        } catch {
            snapshot = nil
            errorMessage = errorMessage ?? "Unable to enumerate input devices"
            logProviderError(error)
        }

        if let current = observation?.device, let snapshot, snapshot.isComplete,
           !snapshot.devices.contains(where: { $0.uid == current.uid }) {
            errorMessage = errorMessage ?? "CoreAudio input device state is temporarily inconsistent"
        }
        guard errorMessage == nil, let observation, let snapshot else {
            deviceEnumerationError = errorMessage
            // Unknown intervals never contribute to continuous confirmation.
            policy.interruptSampling()
            candidateTask?.cancel()
            candidateTask = nil
            cancelMissingDefaultInputRecovery()
            if scheduleRecovery { scheduleRecoverySample() }
            return Sample(observation: observation, valid: false, added: [])
        }

        deviceEnumerationError = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempt = 0
        let firstBaseline = trustedDevices == nil
        let oldUIDs = Set((trustedDevices ?? []).map(\.uid))
        let newUIDs = Set(snapshot.devices.map(\.uid))
        // A complete topology proves availability independently of which device
        // is currently selected. Clear only a stale target-offline UI failure.
        writer.clearTargetOfflineFailureIfAvailable(in: newUIDs)
        let added = firstBaseline ? [] : newUIDs.subtracting(oldUIDs)
        let topologyChanged = !firstBaseline && newUIDs != oldUIDs
        trustedDevices = devices
        if topologyChanged && protectionMode == .auto { beginProtectionWindow() }

        // Revisit an initially empty (but valid) baseline too; no special
        // startup-recovery initialization branch is needed.
        if allowPreferredInitialization, preferredMicrophoneUID == nil {
            preferredMicrophoneUID = devices.first(where: \.isBuiltIn)?.uid ?? observation.device?.uid
        }
        return Sample(observation: observation, valid: true, added: added)
    }

    private func reconcile(watchdog: Bool = false) {
        let entryRequest = writer.pending
        if entryRequest != nil { cancelMissingDefaultInputRecovery() }
        let state = sample()
        AudioMonitorDiagnostics.trace("RECONCILE revision=\(currentRevision) changed=\(state.observation?.changed ?? false) valid=\(state.valid) current=\(currentDevice?.uid ?? "nil") preferred=\(preferredMicrophoneUID ?? "nil") pending=\(writer.pending?.target.uid ?? "nil") watchdog=\(watchdog)")
        let needsAlignment = state.valid && alignmentRequested
        if state.valid { alignmentRequested = false }

        guard let observation = state.observation else {
            // UI selections retain a bounded lifetime even when reads fail.
            if watchdog, entryRequest?.origin == .trustedSelection { retryWrite() }
            return
        }

        if let completed = writer.observe(observation.device) {
            finishWrite(completed)
            return
        }

        if state.valid, let pending = writer.pending,
           trustedDevices?.contains(where: { $0.uid == pending.target.uid }) == false {
            writer.targetDisappeared()
            cancelWatchdog()
        }

        var hasEligibleChangeEvidence = entryRequest == nil && observation.changed
        if let pending = writer.pending {
            // Preserve the existing protection third-state escape: a genuinely
            // different current can supersede the old source-based restore.
            // This is a product heuristic, NOT proof of who wrote the property.
            if case .protection = pending.origin,
               let current = observation.device,
               (pending.sourceUID == nil || current.uid != pending.sourceUID) {
                cancelWrite()
                // The request began at sourceUID. Reaching a non-target current
                // proves a change during its lifetime even if submitWrite()'s
                // confirmation read was the first observer of that change.
                hasEligibleChangeEvidence = true
            } else {
                if watchdog {
                    // A retry performs its own fresh current read. If it actually
                    // submitted a write (and may have synchronously confirmed it),
                    // this outer reconciliation must not continue with the stale
                    // pre-retry observation and issue a duplicate restore.
                    if retryWrite() { return }
                } else {
                    scheduleWatchdog()
                }
                if writer.pending != nil { return }
                // The only fallthrough is a Trusted selection expiring without
                // another write. That expiry is NOT external-switch evidence.
                hasEligibleChangeEvidence = false
            }
        }

        guard protectionEnabled, let preferred = preferredDevice else {
            cancelCandidate()
            cancelMissingDefaultInputRecovery()
            return
        }
        if observation.device?.uid == preferred.uid {
            cancelCandidate()
            cancelMissingDefaultInputRecovery()
            return
        }

        if needsAlignment {
            restore(preferred, reason: .startup)
            return
        }
        if state.valid, state.added.contains(preferred.uid) {
            restore(preferred, reason: .preferredReconnected)
            return
        }
        if protectionMode == .manual {
            restore(preferred, reason: .manualLock)
            return
        }

        let protecting = policy.isProtecting(at: scheduler.now, interval: settleInterval)
        // An established window is already a protection decision. As in Manual,
        // a fresh current mismatch may restore the last trusted target even if
        // THIS topology sample is incomplete. The provider resolves the target
        // afresh; only a complete sample can establish removal or new topology.
        if protecting {
            restore(preferred, reason: .automaticHijack)
            return
        }
        if let current = observation.device {
            cancelMissingDefaultInputRecovery()
            // Unknown topology cannot establish a new protection window or learn a
            // preference. Preserve genuine change evidence across the blind interval.
            if hasEligibleChangeEvidence {
                policy.beginCandidate(
                    target: current, preferred: preferred, revision: currentRevision,
                    validAt: state.valid ? scheduler.now : nil
                )
            }
            guard state.valid else { return }
            confirmOrScheduleCandidate(current: current, preferred: preferred)
            return
        }
        guard state.valid else { return }
        cancelCandidate()
        confirmOrScheduleMissingDefaultInput(preferred: preferred)
    }

    // MARK: - Auto policy phase

    private func beginProtectionWindow() {
        cancelCandidate()
        cancelMissingDefaultInputRecovery()
        policy.protect(at: scheduler.now)
    }

    private func cancelCandidate() {
        policy.cancelCandidate()
        candidateTask?.cancel()
        candidateTask = nil
    }

    /// New user intent supersedes deferred alignment, candidate classification,
    /// missing-default debounce and logical writes, but not sampling recovery or
    /// an Auto protection window.
    private func cancelSupersededWork() {
        alignmentRequested = false
        cancelCandidate()
        cancelMissingDefaultInputRecovery()
        cancelWrite()
    }

    private func confirmOrScheduleCandidate(current: AudioInputDevice?, preferred: AudioInputDevice) {
        guard let candidate = policy.candidate else { return }
        guard candidate.revision == currentRevision,
              candidate.preferredUID == preferred.uid,
              candidate.target.uid == current?.uid else {
            cancelCandidate()
            return
        }
        policy.resumeCandidate(at: scheduler.now)
        if let deadline = policy.candidateDeadline(interval: settleInterval), scheduler.now >= deadline {
            cancelCandidate()
            preferredMicrophoneUID = candidate.target.uid
            // A timed-out command is resolved by the newly accepted preference.
            writer.clearFailure()
            recordEvent(kind: .acceptedUserSwitch, from: candidate.preferredName, to: current?.name ?? candidate.target.name)
        } else {
            scheduleCandidate()
        }
    }

    private func scheduleCandidate() {
        candidateTask?.cancel()
        candidateTask = nil
        guard let candidate = policy.candidate,
              let deadline = policy.candidateDeadline(interval: settleInterval) else { return }
        candidateTask = scheduler.schedule(after: scheduler.now.duration(to: deadline)) { [weak self] in
            guard let self, self.policy.candidate?.revision == candidate.revision,
                  self.policy.candidateDeadline(interval: self.settleInterval) == deadline else { return }
            self.candidateTask = nil
            self.reconcile()
        }
    }

    // MARK: - Missing default-input debounce

    private func confirmOrScheduleMissingDefaultInput(preferred: AudioInputDevice) {
        if missingDefaultInputSince == nil {
            missingDefaultInputSince = scheduler.now
        }
        guard let since = missingDefaultInputSince else { return }
        let deadline = since.advanced(by: settleInterval)
        if scheduler.now >= deadline {
            cancelMissingDefaultInputRecovery()
            restore(preferred, reason: .missingDefaultInput)
        } else {
            scheduleMissingDefaultInputRecovery()
        }
    }

    private func scheduleMissingDefaultInputRecovery() {
        missingDefaultInputTask?.cancel()
        missingDefaultInputTask = nil
        guard let since = missingDefaultInputSince else { return }
        let deadline = since.advanced(by: settleInterval)
        missingDefaultInputTask = scheduler.schedule(after: scheduler.now.duration(to: deadline)) { [weak self] in
            guard let self, let activeSince = self.missingDefaultInputSince,
                  activeSince == since,
                  activeSince.advanced(by: self.settleInterval) == deadline else { return }
            self.missingDefaultInputTask = nil
            self.reconcile()
        }
    }

    private func cancelMissingDefaultInputRecovery() {
        missingDefaultInputTask?.cancel()
        missingDefaultInputTask = nil
        missingDefaultInputSince = nil
    }

    // MARK: - One write path, two bounded/persistent retry policies

    private enum WriteSubmissionResult {
        case continueNormally
        case trustedSelectionRejected
    }

    func selectDevice(_ device: AudioInputDevice) {
        cancelSupersededWork()
        let fresh: CurrentObservation?
        do { fresh = try readCurrent() }
        catch {
            fresh = nil
            deviceEnumerationError = "Unable to read current input device"
            logProviderError(error)
            scheduleRecoverySample()
        }
        if let fresh, fresh.device?.uid == device.uid {
            let oldPreferred = preferredMicrophoneUID
            let from = oldPreferred.flatMap { lastKnownDeviceNames[$0] }
            preferredMicrophoneUID = device.uid
            writer.clearFailure()
            if oldPreferred != device.uid {
                recordEvent(kind: .selectedInMicLock, from: from, to: device.name)
            }
            return
        }
        writer.begin(target: device, source: fresh?.device, origin: .trustedSelection, shouldNotify: false)
        if case .trustedSelectionRejected = submitWrite(initial: true) {
            // The failed Trusted command no longer owns the current state.
            // Re-run ordinary policy without reviving superseded alignment.
            reconcile()
        }
    }

    private func restore(_ preferred: AudioInputDevice, reason: RestoreReason) {
        cancelCandidate()
        cancelMissingDefaultInputRecovery()
        cancelWrite()
        writer.begin(
            target: preferred, source: currentDevice, origin: .protection(reason),
            shouldNotify: notificationsEnabled && reason != .startup
        )
        submitWrite(initial: true)
    }

    @discardableResult
    private func submitWrite(initial: Bool) -> WriteSubmissionResult {
        guard let request = writer.pending else { return .continueNormally }
        let accepted: Bool
        do {
            try provider.setInputDevice(uid: request.target.uid)
            accepted = true
        } catch {
            accepted = false
            logProviderError(error)
        }
        writer.submitted(accepted: accepted, initial: initial)
        AudioMonitorDiagnostics.trace("WRITE_SUBMIT id=\(request.id) target=\(request.target.uid) attempt=\(request.retryAttempt) accepted=\(accepted)")

        if !accepted, initial, request.origin == .trustedSelection {
            return .trustedSelectionRejected
        }

        // Retain existing UX: only an accepted explicit selection changes the
        // stored preference; real current and success events still need a read.
        if accepted && initial && request.origin == .trustedSelection {
            preferredMicrophoneUID = request.target.uid
        }
        guard writer.pending != nil else { return .continueNormally }
        do {
            let observation = try readCurrent()
            if let completed = writer.observe(observation.device) {
                finishWrite(completed)
                return .continueNormally
            }
        } catch {
            deviceEnumerationError = "Unable to read current input device"
            policy.interruptSampling()
            logProviderError(error)
            scheduleRecoverySample()
        }
        // Crucially, accepted writes/retries do NOT extend the Auto window.
        scheduleWatchdog()
        return .continueNormally
    }

    /// Returns true only when this watchdog actually submitted another HAL write.
    /// A Trusted selection may instead expire here without submitting anything;
    /// callers may then continue policy evaluation using the fresh pre-expiry sample.
    @discardableResult
    private func retryWrite() -> Bool {
        guard writer.prepareRetry() != nil else {
            cancelWatchdog()
            return false
        }
        submitWrite(initial: false)
        return true
    }

    private func finishWrite(_ request: DefaultInputWriter.Request) {
        AudioMonitorDiagnostics.trace("WRITE_CONFIRMED id=\(request.id) target=\(request.target.uid)")
        cancelWatchdog()
        let kind: RecentAudioEvent.Kind
        switch request.origin {
        case .trustedSelection:
            kind = .selectedInMicLock
        case .protection(let reason):
            kind = .restored(reason)
            // A confirmed restore starts one fresh protection window. Repeated
            // rejections/acceptances alone do not keep moving its deadline.
            if protectionMode == .auto { beginProtectionWindow() }
        }
        recordEvent(kind: kind, from: request.fromName, to: request.target.name)
        guard request.shouldNotify, notificationsEnabled,
              case .protection(let reason) = request.origin else { return }
        if protectionMode == .auto {
            if let last = lastAutoNotificationAt, scheduler.now < last.advanced(by: settleInterval) { return }
            lastAutoNotificationAt = scheduler.now
        }
        // Means "submitted to notifier", not "a banner was visibly displayed".
        notifier.presentRestored(from: request.fromName ?? "Unknown", to: request.target.name, reason: reason)
    }

    private func scheduleWatchdog() {
        guard watchdogTask == nil, let pending = writer.pending, let delay = writer.retryDelay else { return }
        watchdogTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.writer.pending?.id == pending.id else { return }
            self.watchdogTask = nil
            self.reconcile(watchdog: true)
        }
    }
    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }
    private func cancelWrite() {
        cancelWatchdog()
        writer.cancel()
    }

    private func scheduleRecoverySample() {
        guard recoveryTask == nil else { return }
        let index = min(recoveryAttempt, Self.recoveryDelays.count - 1)
        recoveryAttempt = min(index + 1, Self.recoveryDelays.count - 1)
        recoveryTask = scheduler.schedule(after: Self.recoveryDelays[index]) { [weak self] in
            guard let self else { return }
            self.recoveryTask = nil
            self.reconcile()
        }
    }

    // MARK: - Presentation and diagnostics

    private func scheduleNotificationAuthorization(after delay: Duration = .zero) {
        authorizationTask?.cancel()
        authorizationTask = nil
        guard notificationsEnabled else { return }
        authorizationTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.refreshNotificationAuthorization()
        }
    }

    func refreshNotificationAuthorization() async {
        guard notificationsEnabled, !Task.isCancelled else { return }
        let state = await notifier.ensureAuthorization()
        guard notificationsEnabled, !Task.isCancelled else { return }
        notificationDenied = state == .denied
    }

    private func recordEvent(kind: RecentAudioEvent.Kind, from: String?, to: String) {
        recentAudioEvents.insert(RecentAudioEvent(kind: kind, fromDeviceName: from, toDeviceName: to, occurredAt: Date()), at: 0)
        if recentAudioEvents.count > 10 { recentAudioEvents.removeLast(recentAudioEvents.count - 10) }
        AudioMonitorDiagnostics.trace("AUDIO_EVENT from=\(from ?? "nil") to=\(to) kind=\(kind)")
    }

    private func recordDeviceNames(_ devices: [AudioInputDevice]) {
        var changed = false
        for device in devices
            where device.nameIsResolved
                && lastKnownDeviceNames[device.uid] != device.name
        {
            lastKnownDeviceNames[device.uid] = device.name
            changed = true
        }
        if changed { preferences.lastKnownDeviceNames = lastKnownDeviceNames }
    }

    private static func sortedDevices(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    private func logProviderError(_ error: Error) {
        AudioMonitorDiagnostics.logger.error("CoreAudio provider: \(String(describing: error), privacy: .public)")
        AudioMonitorDiagnostics.trace("PROVIDER_ERROR \(error)")
    }
}
