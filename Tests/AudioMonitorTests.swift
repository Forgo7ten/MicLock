import Foundation

// 每个测试函数对应设计文档的一个场景。
// 通过直接调用 monitor.handleDefaultInputChanged() /
// monitor.handleDeviceListChanged() 模拟 CoreAudio 回调。

@MainActor
func runAllTests() async {
    await testManualSchedulerRunsChainedTimersDeterministically()
    testM1_ManualRestore()
    testM2_PreferredOffline()
    testM3_TrustedUserSelection()
    testUserSelectionFailureDoesNotPersistPreferred()
    testSelectingAlreadyCurrentDeviceBypassesSetter()
    testSelectingAlreadyCurrentPreferredDeviceIsNoOp()
    testSelectingCachedCurrentAfterReadFailureStillUsesSetter()
    await testAcceptedSelectionDoesNotConfirmFromCachedCurrentAfterReadFailure()
    testRestoreImmediateConfirmation()
    testRestoreWaitsForRealConfirmation()
    await testRestoreSetterRejectionKeepsRetrying()
    await testProtectionRetryStatusTransitionsAfterSetterRejection()
    await testDelayedConfirmationBeyondLegacyTimeoutSucceeds()
    testPendingSwitchFailsWhenTargetDisappears()
    testPendingSwitchFailsWhenTargetDisappearsAndCurrentIsNil()
    await testNilSourceTrustedSelectionDoesNotInferExternalProvenance()
    testTrustedSelectionLatestWinsImmediately()
    await testLateSupersededTrustedCallbackDoesNotCancelLatest()
    testRapidTrustedSelectionsTrackOnlyLatestTransaction()
    await testTrustedSelectionExpiresAfterSingleFastRetry()
    await testTrustedTimeoutDoesNotCreateAutoExternalSwitchCandidate()
    await testLateTrustedSuccessClearsConfirmationError()
    await testRealExternalSwitchAfterTrustedTimeoutIsAccepted()
    await testTrustedTimeoutStillFallsThroughToManualProtection()
    await testTrustedSelectionExpirySurvivesCurrentReadFailure()
    await testNilSourcePendingSwitchWatchdogRetriesWithoutCurrent()
    testEnumerationFailureDoesNotApplyEmptyTopology()
    testPartialTopologyUpdatesUIButFreezesPolicyFacts()
    testPendingSwitchConfirmsWhenEnumerationFailsButCurrentReachedTarget()
    testManualRestoresWhenEnumerationFails()
    await testPendingSwitchWatchdogRetriesStuckSource()
    await testPendingSwitchWatchdogDoesNotLearnSourceAfterRetryThreshold()
    await testProtectionRetryConfirmationReopensProtectionWindow()
    await testDelayedProtectionConfirmationReopensProtectionWindow()
    await testTrustedSelectionRetryNeverExposesProtectionState()
    await testCandidateRecoversAfterEnumerationFailure()
    await testPreferredRemovalBeyondLegacyCandidateDelay()
    await testCurrentMissingFromTopologyIsInconclusive()
    testPendingRestoreIsAtomicallySupersededByModeChange()
    testIntermediateCallbackWhileExpectedDoesNotRestoreAgain()
    testA1_NewDeviceHijack()
    testA1_DefaultCallbackBeforeDeviceAddedCallback()
    testPreferredRemoval_DefaultCallbackBeforeDeviceListCallback()
    await testPreferredRemoval_DefaultPropertyChangesBeforeDevicesProperty()
    await testA2_SettledUserSwitch()
    await testA2_RecentEventUsesOldPreferredAfterNoDeltaDeviceCallback()
    testA3_ManualSwitchInsideProtectionWindow()
    await testA4_NewDeviceSettlesThenAccepted()
    testBurst()
    testNotificationCooldownStartsOnlyWhenActuallySubmitted()
    await testSettleConfigurationChangeExtendsProtectionAndNotificationCooldown()
    testPreferredReconnect()
    testPreferredReconnectAlreadyCurrentDoesNotSetAgain()
    testUserSelectionInsideProtectionWindow()
    testProtectionOff()
    testStartupEnforce()
    await testStartupCurrentReadFailureRecoversWithoutExternalCallback()
    await testRuntimeCurrentReadFailurePreservesLastTrustedCurrent()
    await testStartupEnumerationFailureRecoversWithoutExternalCallback()
    await testFreshInstallEnumerationFailurePrefersBuiltInOverCurrent()
    await testFreshInstallEnumerationFailureWithNilCurrentPrefersBuiltIn()
    testIdempotentCallbacks()
    testFirstRunDefaultSelection()
    testDeviceNamePersistence()
    testPreferencesFreshInstall()
    testPreferencesSettleClamp()
    await testRecentEventsKeepLatestTen()
}

// MARK: - Test Scheduler

/// Manual scheduler 的核心契约：schedule 返回前 timer 已登记；action 内新建的下一档
/// timer 必须能在同一次 advance 中按原 deadline 继续执行，取消也必须同步生效。
@MainActor
private func testManualSchedulerRunsChainedTimersDeterministically() async {
    test("manual scheduler runs chained timers deterministically")

    let scheduler = ManualAudioMonitorScheduler()
    var events: [Int] = []

    scheduler.schedule(after: .milliseconds(500)) {
        events.append(1)
        scheduler.schedule(after: .seconds(1)) {
            events.append(2)
        }
    }

    expect(events.isEmpty, "scheduling does not execute actions before time advances")
    await scheduler.advance(by: .seconds(1.5))
    expect(events == [1, 2], "one advance executes synchronously chained timers at 0.5s and 1.5s")

    let cancelled = scheduler.schedule(after: .milliseconds(100)) {
        events.append(3)
    }
    cancelled.cancel()
    await scheduler.advance(by: .milliseconds(100))
    expect(events == [1, 2], "cancel removes a scheduled action before it can run")
}

// MARK: - Manual Mode (§57)

/// M1：Manual 下外部切到 AirPods → 立即恢复 BuiltIn，setter 一次。
@MainActor
private func testM1_ManualRestore() {
    test("M1 manual restore")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "restore setter called once for BuiltIn")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred unchanged")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current restored to BuiltIn")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "recent event records manual restore")
}

/// M2：preferred 离线，系统 fallback → 不 setter、不学习、保留 preferred。
@MainActor
private func testM2_PreferredOffline() {
    test("M2 preferred offline")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: usbMic.uid,
        mode: .manual
    )

    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "no setter call while preferred offline")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred UID preserved")
}

/// M3：用户在 MicLock UI 选择 USB → 立即生效，后续回调视为 self-induced。
@MainActor
private func testM3_TrustedUserSelection() {
    test("M3 trusted user selection")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    monitor.selectDevice(usbMic)

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred = USB")
    expect(provider.setCalls == [usbMic.uid], "setter called for USB")
    expect(monitor.currentDevice?.uid == usbMic.uid, "current = USB")
    expect(monitor.recentAudioEvents.first?.kind == .selectedInMicLock, "recent event records trusted selection")

    // CoreAudio 对 MicLock 自己的 set 产生一次回调：
    // 不得再次 restore、不得误判用户切换。
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [usbMic.uid], "self-induced callback does not trigger setter")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred unchanged by self-induced callback")
}

/// setter 失败时，用户选择不得覆盖原有 preferred。
@MainActor
private func testUserSelectionFailureDoesNotPersistPreferred() {
    test("user selection failure keeps old preferred")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.forceSetFailure = true
    monitor.selectDevice(usbMic)

    expect(provider.setCalls == [usbMic.uid], "setter attempted exactly once")
    expect(
        monitor.preferredMicrophoneUID == builtInMic.uid,
        "preferred remains old device when setter fails"
    )
    expect(
        monitor.currentDevice?.uid == builtInMic.uid,
        "current remains real previous device"
    )
    expect(monitor.lastError != nil, "selection failure surfaces an error")
    expect(monitor.recentAudioEvents.isEmpty, "failed selection is not recorded")
}

/// 系统已经真实使用 USB，但 preferred 仍是 BuiltIn 时，用户点击当前 USB 是明确意图。
/// 不应再依赖 setter；即使 setter 被配置为失败，也要直接把 preferred 更新为 USB。
@MainActor
private func testSelectingAlreadyCurrentDeviceBypassesSetter() {
    test("selecting already-current device bypasses setter")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false
    )

    provider.forceSetFailure = true
    monitor.selectDevice(usbMic)

    expect(provider.setCalls.isEmpty, "fresh current confirmation bypasses setter")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "explicit current-device selection updates preferred")
    expect(monitor.currentDevice?.uid == usbMic.uid, "current remains the confirmed USB device")
    expect(monitor.lastError == nil, "no setter error is surfaced when no setter is needed")
    expect(monitor.recentAudioEvents.count == 1, "real preferred change records one trusted action")
    expect(monitor.recentAudioEvents.first?.kind == .selectedInMicLock, "event records trusted selection")
    expect(monitor.recentAudioEvents.first?.fromDeviceName == builtInMic.name, "event describes previous preferred instead of USB -> USB")
}

/// current == target == preferred 时点击当前设备是纯 no-op：不 setter，也不制造 USB -> USB Recent Event。
@MainActor
private func testSelectingAlreadyCurrentPreferredDeviceIsNoOp() {
    test("selecting already-current preferred device is no-op")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: usbMic.uid,
        mode: .manual
    )

    provider.forceSetFailure = true
    monitor.selectDevice(usbMic)

    expect(provider.setCalls.isEmpty, "already-current preferred target does not call setter")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred remains unchanged")
    expect(monitor.recentAudioEvents.isEmpty, "no meaningless same-device event is recorded")
    expect(monitor.lastError == nil, "no-op remains error-free")
}

/// fresh current 读取失败时，缓存 current 即使恰好等于 target 也不能作为成功证据。
/// 此时仍应走正常 setter 路径；这里强制 setter 失败来证明没有错误地 bypass。
@MainActor
private func testSelectingCachedCurrentAfterReadFailureStillUsesSetter() {
    test("selecting cached current after read failure still uses setter")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice,
        objectID: nil,
        status: -1
    )
    provider.forceSetFailure = true
    monitor.selectDevice(usbMic)

    expect(provider.setCalls == [usbMic.uid], "failed fresh read does not bypass setter using cached current")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "failed setter does not persist target preferred")
    expect(monitor.lastError == "Unable to set default input device", "setter failure remains visible")
    expect(monitor.recentAudioEvents.isEmpty, "unconfirmed selection is not recorded")
}

/// setter 已被接受后，如果第二次 current read 仍失败，缓存的 target 不能被误当成确认。
/// 读取恢复后主动 recovery 只更新 fresh observation；真正到 watchdog 时仍必须再次尝试 target。
@MainActor
private func testAcceptedSelectionDoesNotConfirmFromCachedCurrentAfterReadFailure() async {
    test("accepted selection does not confirm from cached current after read failure")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    // monitor 最后一次可信 cache 是 USB，但真实 CoreAudio 已经变成 BuiltIn。
    provider.current = builtInMic
    provider.applySetImmediately = false
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice,
        objectID: nil,
        status: -1
    )

    monitor.selectDevice(usbMic)

    expect(provider.setCalls == [usbMic.uid], "setter is accepted once despite both current reads failing")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "accepted trusted action may persist preferred before confirmation")
    expect(monitor.currentDevice?.uid == usbMic.uid, "failed reads preserve the stale USB cache")
    expect(monitor.recentAudioEvents.isEmpty, "stale cached target must not confirm the transaction")

    // 读取恢复；250ms topology recovery 会先观察到真实 BuiltIn，但这是主动 re-read，
    // 不是新的外部 callback。500ms watchdog 到达时必须再次 setter USB。
    provider.currentInputDeviceError = nil
    await scheduler.advance(by: .milliseconds(500))

    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "watchdog retries USB after fresh observation shows BuiltIn")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "fresh observation replaces the stale cache")
    expect(monitor.recentAudioEvents.isEmpty, "transaction remains unconfirmed while actual current is BuiltIn")
}

/// setter 立即反映真实状态时，恢复仍应立即确认并通知。
@MainActor
private func testRestoreImmediateConfirmation() {
    test("restore confirms immediately when provider reflects target")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "setter called once")
    expect(
        monitor.currentDevice?.uid == builtInMic.uid,
        "real provider state is reread immediately"
    )
    expect(notifier.presentCount == 1, "notification follows immediate confirmation")
}

/// setter 成功但 CoreAudio 尚未切换时，不得伪造 current 或提前通知。
@MainActor
private func testRestoreWaitsForRealConfirmation() {
    test("restore waits for real CoreAudio confirmation")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "MicLock requested preferred restore")
    expect(
        monitor.currentDevice?.uid == airpodsMic.uid,
        "monitor does not fabricate current before confirmation"
    )
    expect(notifier.presentCount == 0, "no notification before actual confirmation")
    expect(monitor.recentAudioEvents.isEmpty, "no recent event before actual confirmation")

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "confirmed current is preferred")
    expect(notifier.presentCount == 1, "notification sent after real confirmation")
    expect(provider.setCalls == [builtInMic.uid], "confirmation does not trigger another setter")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "recent event is committed with confirmation")
}

/// Protection restore 的 setter 被拒绝时，不应像一次性的 UI 选择那样立即放弃。
/// 只要 target 仍在线且没有更高优先级事实，watchdog 应继续 retry，并在后续成功时正常确认。
@MainActor
private func testRestoreSetterRejectionKeepsRetrying() async {
    test("restore setter rejection keeps retrying")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        scheduler: scheduler
    )

    provider.forceSetFailure = true
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "initial restore request is attempted once")
    expect(monitor.currentDevice?.uid == airpodsMic.uid, "rejected setter does not fabricate current")
    expect(
        monitor.lastError == "Unable to set default input device; protection will keep retrying",
        "UI distinguishes a rejected setter from accepted-but-unconfirmed state"
    )
    expect(monitor.protectionRetryState == .setterRejected, "settings exposes rejected-setter retry state")
    expect(monitor.recentAudioEvents.isEmpty, "rejected restore has no success event")
    expect(notifier.presentCount == 0, "rejected restore has no notification")

    provider.forceSetFailure = false
    await scheduler.advance(by: .milliseconds(500))

    expect(provider.setCalls.count == 2, "exactly one watchdog task performs the first retry")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "later accepted retry reaches the preferred target")
    expect(monitor.lastError == nil, "successful retry clears retrying error")
    expect(monitor.protectionRetryState == nil, "successful retry clears settings retry state")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "later retry commits the original restore event")
    expect(notifier.presentCount == 1, "notification is sent only after the restore is confirmed")
}

/// Protection retry 的结构化状态必须跟随“最近一次 setter 的事实”变化：
/// rejected → 后续 accepted 但尚未进入长期阶段时清掉旧 rejected；
/// 完成四档 fast retry 后仍未确认才进入 awaitingConfirmation。
@MainActor
private func testProtectionRetryStatusTransitionsAfterSetterRejection() async {
    test("protection retry status transitions after setter rejection")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    provider.forceSetFailure = true
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(monitor.protectionRetryState == .setterRejected, "initial rejected restore exposes setterRejected")

    provider.forceSetFailure = false
    await scheduler.advance(by: .milliseconds(500))

    expect(provider.setCalls.count == 2, "first watchdog retry is accepted but remains unconfirmed")
    expect(monitor.protectionRetryState == nil, "accepted fast retry clears stale setterRejected state")
    expect(monitor.lastError == nil, "accepted fast retry clears stale rejected-setter wording")

    await scheduler.advance(by: .seconds(7))

    expect(provider.setCalls.count == 5, "four fast retries complete before long-backoff stage")
    expect(monitor.protectionRetryState == .awaitingConfirmation, "long unconfirmed protection retry exposes awaitingConfirmation")
    expect(
        monitor.lastError == "Unable to confirm default input change; protection is retrying",
        "long retry uses protection-specific wording"
    )
}

/// HAL 没有承诺 setter 必须在固定时间内反映到真实 default。
/// 超过旧的 1 秒阈值后才确认，事务仍应成功，不产生伪失败。
@MainActor
private func testDelayedConfirmationBeyondLegacyTimeoutSucceeds() async {
    test("delayed confirmation beyond legacy timeout succeeds")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "restore request remains pending")
    expect(monitor.lastError == nil, "pending restore has no false error")

    // 等待超过旧实现的 1 秒 confirmation timeout。
    try? await Task.sleep(for: .seconds(1.4))

    expect(monitor.lastError == nil, "elapsed time alone does not fail the transaction")
    expect(monitor.recentAudioEvents.isEmpty, "unconfirmed transaction still has no success event")
    expect(notifier.presentCount == 0, "unconfirmed transaction still has no notification")

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "late HAL state confirms target")
    expect(monitor.lastError == nil, "late confirmation remains successful")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "late confirmation commits recent event")
    expect(notifier.presentCount == 1, "late confirmation sends notification")
}

/// pending 期间 target 离线属于明确失败证据，不需要等待时间阈值。
@MainActor
private func testPendingSwitchFailsWhenTargetDisappears() {
    test("pending switch fails when target disappears")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "restore starts pending")

    provider.devices = [airpodsMic]
    provider.current = airpodsMic
    monitor.handleDeviceListChanged()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "offline target remains preferred")
    expect(monitor.lastError == "Target input device is no longer available", "target disappearance fails pending transaction")
    expect(monitor.recentAudioEvents.isEmpty, "failed pending transaction has no success event")
    expect(notifier.presentCount == 0, "failed pending transaction has no notification")
}

/// target 与 current 同时消失时，也必须先用 topology 事实结束 pending；
/// 不能因为 current == nil 提前 return 而留下悬挂事务。
@MainActor
private func testPendingSwitchFailsWhenTargetDisappearsAndCurrentIsNil() {
    test("pending switch fails when target disappears and current is nil")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    provider.devices = []
    provider.current = nil
    monitor.handleDeviceListChanged()

    expect(monitor.currentDevice == nil, "full snapshot records no current input")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred UID remains preserved")
    expect(monitor.lastError == "Target input device is no longer available", "target disappearance resolves pending even without current")
    expect(monitor.recentAudioEvents.isEmpty, "no false success event when all devices disappear")
    expect(notifier.presentCount == 0, "no notification when pending target disappears")
}

/// source/current provenance 对 Trusted latest-wins 没有 correctness 含义。
/// 非 target callback 只更新 UI；短生命周期结束前不会因此取消最新 MicLock target。
@MainActor
private func testNilSourceTrustedSelectionDoesNotInferExternalProvenance() async {
    test("nil-source trusted selection does not infer external provenance")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic, airpodsMic],
        current: nil,
        preferred: nil,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == airpodsMic.uid, "non-target callback still updates visible current")
    expect(provider.setCalls == [usbMic.uid], "callback itself neither cancels nor rewrites the latest trusted target")
    expect(monitor.recentAudioEvents.isEmpty, "non-target callback cannot confirm trusted selection")

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "trusted watchdog retries the latest target once")
}

/// Trusted User Selection 使用 latest-wins：新点击立即 supersede 旧 transaction，
/// 不等待旧 target confirm/offline，也不存在 queued intent。
@MainActor
private func testTrustedSelectionLatestWinsImmediately() {
    test("trusted selection latest wins immediately")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    monitor.selectDevice(airpodsMic)

    expect(provider.setCalls == [usbMic.uid, airpodsMic.uid], "new C setter is issued immediately instead of waiting for B")
    expect(monitor.preferredMicrophoneUID == airpodsMic.uid, "latest accepted MicLock selection becomes preferred immediately")
    expect(monitor.recentAudioEvents.isEmpty, "superseded B and pending C are not recorded as confirmed")
}

/// 旧 B setter 的延迟回声到达时，不推断 provenance，也不能结束最新 C transaction。
@MainActor
private func testLateSupersededTrustedCallbackDoesNotCancelLatest() async {
    test("late superseded trusted callback does not cancel latest")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    monitor.selectDevice(airpodsMic)

    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    expect(monitor.currentDevice?.uid == usbMic.uid, "late B callback may update current UI")
    expect(monitor.recentAudioEvents.isEmpty, "late B callback cannot confirm latest C")

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, airpodsMic.uid, airpodsMic.uid], "watchdog retries C, never the superseded B")

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(monitor.recentAudioEvents.count == 1, "only latest C confirmation produces an event")
    expect(monitor.recentAudioEvents.first?.toDeviceName == airpodsMic.name, "confirmed event belongs to latest C")
}

/// B → C → D 每次点击都立即发出 setter，但 active transaction 永远只代表最后的 D。
@MainActor
private func testRapidTrustedSelectionsTrackOnlyLatestTransaction() {
    test("rapid trusted selections track only latest transaction")

    let deskMic = makeDevice("DeskMic", name: "Desk Microphone", id: 4, transport: 0)
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic, deskMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    monitor.selectDevice(airpodsMic)
    monitor.selectDevice(deskMic)

    expect(provider.setCalls == [usbMic.uid, airpodsMic.uid, deskMic.uid], "each explicit MicLock click issues its setter immediately")
    expect(monitor.preferredMicrophoneUID == deskMic.uid, "only latest D remains the intended preferred target")

    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(monitor.recentAudioEvents.isEmpty, "superseded B/C callbacks cannot finish D transaction")

    provider.current = deskMic
    monitor.handleDefaultInputChanged()
    expect(monitor.recentAudioEvents.count == 1, "D confirmation records exactly one trusted event")
    expect(monitor.recentAudioEvents.first?.toDeviceName == deskMic.name, "event belongs to latest D")
}

/// Trusted 是短生命周期 UI command：首次未确认后仅在 500ms fast retry 一次，
/// 再过 500ms 仍未确认就结束，不进入 Protection 的 1/2/4/.../64s 永久重试。
@MainActor
private func testTrustedSelectionExpiresAfterSingleFastRetry() async {
    test("trusted selection expires after single fast retry")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    expect(provider.setCalls == [usbMic.uid], "initial trusted command writes once")

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "first watchdog performs the only fast retry")

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "final confirmation watchdog expires without another setter")
    expect(monitor.lastError == "Unable to confirm default input change", "expired trusted command reports bounded confirmation failure")

    await scheduler.advance(by: .seconds(120))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "expired trusted command never enters background 64s retry")
}

/// Auto + Protection ON 下，Trusted final watchdog 是 synthetic observation。
/// timeout 只能结束 Trusted command，不能把未变化的 current 反向学习成 external switch。
@MainActor
private func testTrustedTimeoutDoesNotCreateAutoExternalSwitchCandidate() async {
    test("trusted timeout does not create auto external switch candidate")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        protection: true,
        settle: 1.0,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await scheduler.advance(by: .seconds(1))

    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "trusted command performs only initial set plus one fast retry")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current remains BuiltIn when trusted command expires")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "trusted timeout preserves the user's latest preferred USB")
    expect(monitor.lastError == "Unable to confirm default input change", "trusted timeout reports confirmation failure")
    expect(
        !monitor.recentAudioEvents.contains(where: { $0.kind == .acceptedUserSwitch }),
        "synthetic trusted timeout does not fabricate an accepted external switch"
    )

    await scheduler.advance(by: .seconds(5))

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "no later candidate timer can learn unchanged BuiltIn as preferred")
    expect(
        !monitor.recentAudioEvents.contains(where: { $0.kind == .acceptedUserSwitch }),
        "no accepted external switch appears without a real callback"
    )
}

/// Trusted 已 timeout 后，HAL 仍可能稍晚完成之前 accepted 的 setter。
/// fresh current 一旦证明 current == preferred，就必须清掉已经被解决的 confirmation error。
@MainActor
private func testLateTrustedSuccessClearsConfirmationError() async {
    test("late trusted success clears confirmation error")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await scheduler.advance(by: .seconds(1))

    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "trusted command writes once and performs one fast retry")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current is still A when trusted confirmation expires")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "accepted trusted command keeps B as preferred after expiry")
    expect(monitor.lastError == "Unable to confirm default input change", "trusted expiry reports confirmation failure")

    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == usbMic.uid, "late HAL success updates current to B")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "late success leaves preferred at B")
    expect(monitor.lastError == nil, "fresh current matching preferred clears resolved trusted confirmation error")
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "late callback only clears transient error and does not issue another setter")
}

/// Trusted timeout 只屏蔽产生 timeout 的 synthetic watchdog；之后真正的 default-input
/// callback 仍然是新的外部事实，可以正常进入 Auto candidate 并在 settle 后被接受。
@MainActor
private func testRealExternalSwitchAfterTrustedTimeoutIsAccepted() async {
    test("real external switch after trusted timeout is accepted")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        protection: true,
        settle: 1.0,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await scheduler.advance(by: .seconds(1))

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "trusted timeout preserves USB as the user's latest preferred")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current remains BuiltIn after trusted timeout")

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    await scheduler.advance(by: .seconds(1))

    expect(monitor.currentDevice?.uid == airpodsMic.uid, "real external callback updates current to AirPods")
    expect(monitor.preferredMicrophoneUID == airpodsMic.uid, "Auto accepts the real external switch after settle")
    expect(
        monitor.recentAudioEvents.contains {
            $0.kind == .acceptedUserSwitch
                && $0.fromDeviceName == usbMic.name
                && $0.toDeviceName == airpodsMic.name
        },
        "accepted external event records USB to AirPods"
    )
}

/// Manual 不做 external-switch learning；Trusted timeout 后仍应继续 normal Manual policy，
/// 因而 current != preferred 时会启动 Protection Restore，而不是被 timeout 结果截断。
@MainActor
private func testTrustedTimeoutStillFallsThroughToManualProtection() async {
    test("trusted timeout still falls through to manual protection")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: true,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    await scheduler.advance(by: .seconds(1))

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "Trusted timeout keeps USB as preferred in Manual mode")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current remains BuiltIn when Trusted command expires")
    expect(
        provider.setCalls == [usbMic.uid, usbMic.uid, usbMic.uid],
        "Manual policy immediately starts a Protection Restore after Trusted expiry"
    )
}

/// current read failure 不能绕过 Trusted 的 bounded lifetime；否则 final watchdog 的早退
/// 会把一次 UI command 重新变成永久 pending。
@MainActor
private func testTrustedSelectionExpirySurvivesCurrentReadFailure() async {
    test("trusted selection expiry survives current read failure")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice,
        objectID: nil,
        status: -1
    )

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "first watchdog still performs the one fast retry when current read fails")

    await scheduler.advance(by: .milliseconds(500))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "final read failure expires trusted command without another setter")
    expect(monitor.lastError == "Unable to confirm default input change", "read failure cannot leave trusted command permanently pending")

    provider.currentInputDeviceError = nil
    await scheduler.advance(by: .seconds(2))
    expect(provider.setCalls == [usbMic.uid, usbMic.uid], "recovery after expiry does not resurrect trusted retry")
}

/// sourceUID == nil 且 current 仍为 nil 时，watchdog 也必须主动重试 setter；
/// 不能因为没有 source/current 可比较而永久 pending。
@MainActor
private func testNilSourcePendingSwitchWatchdogRetriesWithoutCurrent() async {
    test("nil-source pending switch watchdog retries without current")

    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic],
        current: nil,
        preferred: nil,
        mode: .manual
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)
    expect(provider.setCalls == [usbMic.uid], "nil-source transaction starts with one setter")

    try? await Task.sleep(for: .milliseconds(700))

    expect(provider.setCalls.count >= 2, "watchdog retries even while current remains nil")
}

/// 设备枚举失败与成功空列表必须区分。枚举失败时只刷新可独立读取的 current，
/// 不得把 [] 当成真实 topology、不得失败 pending transaction。
@MainActor
private func testEnumerationFailureDoesNotApplyEmptyTopology() {
    test("enumeration failure does not apply empty topology")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "restore is pending before enumeration failure")

    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == airpodsMic.uid, "current still refreshes when enumeration fails")
    expect(monitor.devices.map(\.uid).sorted() == [airpodsMic.uid, builtInMic.uid].sorted(), "last valid topology is preserved")
    expect(monitor.deviceEnumerationError != nil, "enumeration failure is surfaced separately")
    expect(monitor.lastError == nil, "invalid topology snapshot does not fail pending target")
    expect(provider.setCalls == [builtInMic.uid], "invalid snapshot does not run policy or repeat setter")

    provider.listInputDevicesError = nil
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.deviceEnumerationError == nil, "successful enumeration clears enumeration error")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "pending restore confirms after enumeration recovers")
    expect(notifier.presentCount == 1, "confirmation still notifies after enumeration recovers")
}

/// 单个 HAL object 的关键属性读取失败时，健康设备仍应出现在 UI snapshot；
/// 但 partial snapshot 不能应用 removal / target-offline / Auto learning 等不可逆策略事实。
@MainActor
private func testPartialTopologyUpdatesUIButFreezesPolicyFacts() {
    test("partial topology updates UI but freezes policy facts")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        scheduler: scheduler
    )

    // USB 对象的关键属性暂时不可读；其余健康对象仍能组成 partial snapshot。
    provider.devices = [builtInMic, airpodsMic]
    provider.incompleteDeviceIDs = [usbMic.deviceID]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(
        monitor.devices.map(\.uid).sorted() == [airpodsMic.uid, builtInMic.uid].sorted(),
        "partial snapshot still updates healthy devices for UI"
    )
    expect(monitor.currentDevice?.uid == airpodsMic.uid, "current UI still reflects independently readable state")
    expect(monitor.deviceEnumerationError != nil, "partial topology is surfaced for diagnostics")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "Auto does not learn from a partial topology")
    expect(provider.setCalls.isEmpty, "partial topology does not treat omitted USB as a removal event")

    // 同一可见列表随后成为完整 snapshot：现在 USB removal 才是可信事实，
    // Auto 开启 protection window 并恢复原 preferred。
    provider.incompleteDeviceIDs = []
    monitor.handleDeviceListChanged()

    expect(monitor.deviceEnumerationError == nil, "complete snapshot clears partial-topology diagnostics")
    expect(provider.setCalls == [builtInMic.uid], "only a complete snapshot may apply removal and trigger protection")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred remains protected after complete recovery")
}

/// PendingSwitch 已真实到达 target 时，current 本身就是充分成功证据；
/// 即使同一轮 topology 枚举失败，也必须完成 transaction。
@MainActor
private func testPendingSwitchConfirmsWhenEnumerationFailsButCurrentReachedTarget() {
    test("pending switch confirms when enumeration fails but current reached target")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "restore starts pending")

    provider.current = builtInMic
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "current target is reflected immediately")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.manualLock), "target confirmation does not depend on topology enumeration")
    expect(notifier.presentCount == 1, "confirmed restore still notifies")
}

/// Manual 是严格锁定：topology 枚举瞬时失败时，仍可依赖上一份有效设备表恢复 preferred。
@MainActor
private func testManualRestoresWhenEnumerationFails() {
    test("manual restores when enumeration fails")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "Manual restore still runs with last valid topology")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "immediate provider confirmation restores current")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred remains locked")
}

/// setter accepted 但 current 长时间停在 source 时，watchdog 必须重新 setter；
/// pending 可以持续存在，但必须主动 retry，而不是“永久 pending 且永远不做事”。
@MainActor
private func testPendingSwitchWatchdogRetriesStuckSource() async {
    test("pending switch watchdog retries stuck source")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "initial restore requested")

    await scheduler.advance(by: .milliseconds(500))

    expect(provider.setCalls.count >= 2, "watchdog retries while current remains source")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "watchdog never learns source as preferred")
}

/// Auto protection-window hijack 的 setter 如果一直 accepted、但 current 永远停在 source，
/// 完整 watchdog 退避周期结束后也必须保持保护事务，不能落入新的 external candidate
/// 并把 source（抢麦设备）反向学习成 preferred。
@MainActor
private func testPendingSwitchWatchdogDoesNotLearnSourceAfterRetryThreshold() async {
    test("pending switch watchdog does not learn source after retry threshold")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 1.0,
        scheduler: scheduler
    )

    provider.applySetImmediately = false

    // AirPods 接入并抢占 default input：真实 topology delta 先开启 Auto protection window，
    // 随后 corrective restore 被 HAL 接受，但真实 current 始终不切回 BuiltIn。
    // USB 预先在线，仅用于后面验证“第三个 current”会 supersede 旧事务。
    provider.devices = [builtInMic, usbMic, airpodsMic]
    provider.current = airpodsMic
    monitor.handleDeviceListChanged()

    expect(provider.setCalls == [builtInMic.uid], "initial hijack restore requested")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred remains BuiltIn while restore is pending")

    // 0.5s + 1s + 2s + 4s = 7.5s 到达旧实现的 retry exhaustion；
    // 再越过 1s stable candidate 窗口，旧实现会在约 8.5s 把 AirPods 学成 preferred。
    await scheduler.advance(by: .seconds(9.5))

    expect(provider.setCalls.count == 5, "one watchdog chain completes four fast retries, then backs off to 8s")
    expect(monitor.currentDevice?.uid == airpodsMic.uid, "provider still reports the hijacking source")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "retry threshold never reclassifies source as preferred")
    expect(
        !monitor.recentAudioEvents.contains(where: { $0.kind == .acceptedUserSwitch }),
        "no accepted user switch is recorded for the stuck source"
    )
    expect(
        monitor.lastError == "Unable to confirm default input change; protection is retrying",
        "UI reports active retrying protection after the fast retry threshold is reached"
    )
    expect(monitor.protectionRetryState == .awaitingConfirmation, "settings exposes long confirmation retry state")
    expect(notifier.presentCount == 0, "unconfirmed restore never sends a notification")

    // 第三个、已在线的 current 是明确 supersede 事实：旧事务应结束，retrying 错误也应清理。
    provider.current = usbMic
    monitor.handleDefaultInputChanged()
    expect(monitor.lastError == nil, "superseding current clears stale retrying status")
    expect(monitor.protectionRetryState == nil, "superseding current clears settings retry state")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "supersede does not immediately rewrite preferred")
}

/// Auto hijack 的初始 protection window 已结束后，后续 protection retry 只有在
/// fresh current 确认恢复成功时才重新开启 protection window；若随后立即被 source 抢回，
/// 仍要再次 restore，不能进入 external candidate，更不能把 source 学成 preferred。
/// 第一次确认同时启动 notification cooldown，紧接着的恢复不得重复通知。
@MainActor
private func testProtectionRetryConfirmationReopensProtectionWindow() async {
    test("protection retry confirmation reopens protection window")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 1.0,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    monitor.handleDeviceListChanged()

    expect(provider.setCalls == [builtInMic.uid], "initial topology hijack starts one restore")
    expect(notifier.presentCount == 0, "pending restore has not notified")

    // 让最初 protection window 到期，并让前两个 watchdog retry 仍保持未确认。
    await scheduler.advance(by: .seconds(1.5))
    expect(provider.setCalls.count == 3, "watchdog has retried at 0.5s and 1.5s")

    // 下一档 2s retry 同步生效并被 fresh read 确认；只有 confirmation 才重新开启 protection window。
    provider.applySetImmediately = true
    await scheduler.advance(by: .seconds(2))

    expect(monitor.currentDevice?.uid == builtInMic.uid, "later accepted retry reaches preferred")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.automaticHijack), "retry confirmation keeps original restore semantics")
    expect(notifier.presentCount == 1, "retry confirmation submits one notification and starts cooldown")

    // 立刻再次被 AirPods 抢回。因为 confirmation 已重新开启 protection window，这次必须再次 restore；
    // 第二次确认仍在 notification cooldown 内，不得重复发送。
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.count == 5, "immediate re-hijack is restored instead of becoming a stable candidate")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "second hijack is corrected immediately")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred remains BuiltIn across re-hijack")
    expect(
        !monitor.recentAudioEvents.contains(where: { $0.kind == .acceptedUserSwitch }),
        "no accepted external switch is created after confirmation reopened protection"
    )
    expect(notifier.presentCount == 1, "notification cooldown suppresses the immediate duplicate restore")
}

/// 更早一次已经 accepted 的 protection setter 可能在旧 protection window 结束后才真正到达 target，
/// 即使最近一次 watchdog retry 被拒绝，fresh current confirmation 仍必须重新开启 protection window。
/// 否则紧接着的再次抢麦会进入 external candidate，并可能反向学习 source。
@MainActor
private func testDelayedProtectionConfirmationReopensProtectionWindow() async {
    test("delayed protection confirmation reopens protection window")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 1.0,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    monitor.handleDeviceListChanged()

    expect(provider.setCalls == [builtInMic.uid], "initial hijack restore is accepted but remains pending")

    // 最近一次 watchdog retry 被拒绝，因此它不会重新开启 protection window。
    provider.forceSetFailure = true
    await scheduler.advance(by: .milliseconds(700))
    expect(provider.setCalls.count == 2, "first watchdog retry is rejected")
    expect(monitor.protectionRetryState == .setterRejected, "rejected retry is visible while transaction remains pending")

    // 越过初始 1s protection window，但保持在下一档 1s watchdog（约 t=1.5s）之前。
    await scheduler.advance(by: .milliseconds(500))

    // 模拟最初 accepted 的 CoreAudio 请求现在才真正生效。
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "late HAL propagation confirms the original protection restore")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.automaticHijack), "late confirmation keeps protection restore semantics")
    expect(notifier.presentCount == 1, "late confirmation sends one notification")

    // confirmation 自身应已重新开启 protection window；立即再次抢麦必须继续保护，而不是 external candidate。
    provider.forceSetFailure = false
    provider.applySetImmediately = true
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.count == 3, "immediate re-hijack after late confirmation is restored")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "re-hijack is corrected to BuiltIn")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "late confirmation path never learns AirPods as preferred")
    expect(
        !monitor.recentAudioEvents.contains(where: { $0.kind == .acceptedUserSwitch }),
        "late confirmation path never creates a stable external-switch acceptance"
    )
    expect(notifier.presentCount == 1, "notification cooldown suppresses the immediate re-hijack notification")
}

/// Trusted User Selection 只做一次 fast retry，并且永远不暴露 Protection retry 状态。
@MainActor
private func testTrustedSelectionRetryNeverExposesProtectionState() async {
    test("trusted selection retry never exposes protection state")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        protection: false,
        scheduler: scheduler
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "trusted selection commits preferred after accepted setter")
    expect(monitor.protectionRetryState == nil, "trusted selection never starts protection retry UI")

    await scheduler.advance(by: .seconds(2))

    expect(provider.setCalls.count == 2, "trusted selection performs only one bounded fast retry")
    expect(monitor.protectionRetryState == nil, "expired trusted selection still has no protection state")
    expect(
        monitor.lastError == "Unable to confirm default input change",
        "bounded trusted selection reports confirmation failure without retry wording"
    )
    expect(monitor.lastError?.contains("protection") == false, "trusted selection wording never claims protection is retrying")
}

/// 旧 200ms candidate 无法覆盖更慢的 HAL 属性分阶段变化。
/// candidate 现在复用 settleSeconds，因此 350ms 后 topology removal 仍可取消学习。
@MainActor
private func testPreferredRemovalBeyondLegacyCandidateDelay() async {
    test("preferred removal beyond legacy candidate delay")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: usbMic.uid,
        mode: .auto,
        settle: 1.0
    )

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    try? await Task.sleep(for: .milliseconds(350))
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "legacy 200ms boundary no longer commits fallback")

    provider.devices = [builtInMic]
    monitor.handleDeviceListChanged()
    await waitPastStableExternalSwitchClassification()

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "later topology removal preserves offline preferred")
}

/// current 不存在于成功枚举的 devices 时，联合采样自相矛盾。
/// UI 可以显示真实 current，但 Auto 不能学习它，也不能应用假的 removal。
@MainActor
private func testCurrentMissingFromTopologyIsInconclusive() async {
    test("current missing from topology is inconclusive")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 1.0
    )

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == airpodsMic.uid, "UI follows current even when topology is inconsistent")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "inconsistent sample cannot learn preferred")
    expect(monitor.devices.map(\.uid) == [builtInMic.uid], "last valid topology remains unchanged")

    try? await Task.sleep(for: .milliseconds(350))
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "recovery retry cannot commit missing current UID")

    provider.devices = [builtInMic, airpodsMic]
    monitor.handleDeviceListChanged()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "topology catch-up enters protection instead of accepting AirPods")
}

/// stable candidate 的确认若恰好遇到设备枚举失败，不应永久悬挂。
/// 后续有效 wake-up 应能重新安排确认并最终学习 preferred。
@MainActor
private func testCandidateRecoversAfterEnumerationFailure() async {
    test("candidate recovers after enumeration failure")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)
    await waitPastStableExternalSwitchClassification()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "invalid confirmation snapshot does not learn candidate")
    expect(monitor.deviceEnumerationError != nil, "enumeration failure is visible after candidate confirmation attempt")

    provider.listInputDevicesError = nil
    monitor.handleDefaultInputChanged()
    await waitPastStableExternalSwitchClassification()

    expect(monitor.deviceEnumerationError == nil, "valid wake-up clears enumeration error")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "same candidate can be confirmed after enumeration recovers")
    expect(monitor.recentAudioEvents.first?.kind == .acceptedUserSwitch, "recovered candidate records accepted switch")
}

/// 新事务必须原子取代旧事务：Auto 恢复未确认时切到 Manual，
/// 新的 startup 对齐确认后不能发送旧 automaticHijack 通知或记录旧事件。
@MainActor
private func testPendingRestoreIsAtomicallySupersededByModeChange() {
    test("pending restore is atomically superseded by mode change")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )
    provider.applySetImmediately = false

    // 打开 Auto protection window，再模拟系统抢到 AirPods，产生未确认的 automaticHijack restore。
    provider.devices = [builtInMic, airpodsMic, usbMic]
    monitor.handleDeviceListChanged()
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "auto restore is pending")
    expect(notifier.presentCount == 0, "pending auto restore has not notified")
    expect(monitor.recentAudioEvents.isEmpty, "pending auto restore has not recorded event")

    // 切到 Manual 会 evaluateStartupPolicy，启动一笔新的 startup 对齐事务并 supersede 旧事务。
    monitor.protectionMode = .manual
    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "manual mode starts a replacement startup transaction")

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(notifier.presentCount == 0, "startup confirmation does not leak old auto notification")
    expect(monitor.recentAudioEvents.count == 1, "only replacement transaction is recorded")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.startup), "confirmed event belongs to replacement startup transaction")
}

/// 异步切换期间的中间 callback 不应重复 setter。
@MainActor
private func testIntermediateCallbackWhileExpectedDoesNotRestoreAgain() {
    test("intermediate callback while expected does not repeat setter")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    provider.applySetImmediately = false
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "first restore requested")

    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "no duplicate restore while pending")
    expect(notifier.presentCount == 0, "still no premature notification")

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "final confirmation remains idempotent")
    expect(notifier.presentCount == 1, "one notification after confirmation")
}

// MARK: - Auto Mode (§58-§59)

/// A1：设备列表新增 AirPods 后默认输入被抢 → 立即恢复，preferred 不变，通知一条。
@MainActor
private func testA1_NewDeviceHijack() {
    test("A1 new device hijack")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // AirPods 接入：设备列表事件。
    provider.devices = [builtInMic, airpodsMic]
    monitor.handleDeviceListChanged()

    // macOS 把默认输入切到 AirPods。
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "immediate restore (no delay)")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred stays BuiltIn")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current restored")
    expect(notifier.presentCount == 1, "exactly one notification")
}

/// A1 反序回归：DefaultInput callback 先于 Devices callback 时，
/// 第一次 wake-up 会重新读取当时可观察到的 devices/current，并在 topology 已同步时识别新增设备抢麦。
@MainActor
private func testA1_DefaultCallbackBeforeDeviceAddedCallback() {
    test("A1 default callback before device-added callback")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // CoreAudio 真实状态已经同时变化，但 listener 投递顺序是 Default → Devices。
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "default-first callback still restores hijack immediately")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "default-first callback does not learn AirPods")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "current restored after default-first callback")
    expect(notifier.presentCount == 1, "default-first hijack notifies once")

    // 随后的 Devices callback 只会看到 no delta，不得改变结论或重复 setter。
    monitor.handleDeviceListChanged()
    expect(provider.setCalls == [builtInMic.uid], "later devices callback is idempotent")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred remains BuiltIn")
}

/// preferred 拔出反序回归：DefaultInput callback 先到时必须先刷新 topology，
/// 识别 preferred 已离线并保留原 UID，不能把系统 fallback 学成新的 preferred。
@MainActor
private func testPreferredRemoval_DefaultCallbackBeforeDeviceListCallback() {
    test("preferred removal default callback before device-list callback")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: usbMic.uid,
        mode: .auto
    )

    provider.devices = [builtInMic]
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "offline preferred is not restored to an unavailable device")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "default-first removal preserves offline preferred UID")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "system fallback remains current while preferred is offline")

    monitor.handleDeviceListChanged()
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "later devices callback does not overwrite offline preferred")
}

/// 分阶段属性变化回归：DefaultInput 已 fallback，但 Devices 尚未移除 preferred。
/// Auto stable 只能先形成候选，不能立刻学习 fallback；随后 topology delta 会取消候选。
@MainActor
private func testPreferredRemoval_DefaultPropertyChangesBeforeDevicesProperty() async {
    test("preferred removal default property changes before devices property")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: usbMic.uid,
        mode: .auto
    )

    // Phase 1：default 已 fallback，但设备枚举仍暂时报告 USB 在线。
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "UI follows real fallback current immediately")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "fallback is only a candidate before topology settles")
    expect(monitor.recentAudioEvents.isEmpty, "candidate is not recorded as accepted yet")

    // Phase 2：HAL 稍后才把 USB 从 devices 中移除。
    provider.devices = [builtInMic]
    monitor.handleDeviceListChanged()

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "topology removal preserves offline preferred")

    // 即使旧 candidate timer 随后醒来，也不能再学习 BuiltIn。
    await waitPastStableExternalSwitchClassification()
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "cancelled candidate cannot commit after topology delta")
    expect(monitor.recentAudioEvents.isEmpty, "cancelled fallback candidate leaves no accepted event")
}

/// A2：设备稳定后的外部切换 → 短暂候选确认后接受并保存为新的 preferred，不恢复。
@MainActor
private func testA2_SettledUserSwitch() async {
    test("A2 settled user switch")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 无拓扑事件发生 → stable，但先只形成短暂候选。
    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "no restore for stable external switch candidate")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "candidate does not learn preferred immediately")
    expect(monitor.currentDevice?.uid == usbMic.uid, "UI current updates immediately while preferred learning waits")

    await waitPastStableExternalSwitchClassification()

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred learned after candidate confirmation")
    expect(notifier.presentCount == 0, "no notification on accept")
    expect(monitor.recentAudioEvents.first?.kind == .acceptedUserSwitch, "recent event explains accepted switch")
    expect(monitor.recentAudioEvents.first?.fromDeviceName == builtInMic.name, "accepted switch event starts from old preferred")
}

/// A2 回归：no-delta devices wake-up 也只能维持同一 candidate，不能改变 Recent Event 来源。
@MainActor
private func testA2_RecentEventUsesOldPreferredAfterNoDeltaDeviceCallback() async {
    test("A2 recent event uses old preferred after no-delta devices callback")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 外部切到 USB 后，CoreAudio 先送一个 devices callback；设备集合没有变化，
    // 只应创建/维持同一个候选，不能立刻提交 preferred。
    provider.current = usbMic
    monitor.handleDeviceListChanged()
    monitor.handleDefaultInputChanged()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "no-delta wake-ups keep candidate pending")

    await waitPastStableExternalSwitchClassification()

    let event = monitor.recentAudioEvents.first
    expect(event?.kind == .acceptedUserSwitch, "accepted switch event is recorded")
    expect(event?.fromDeviceName == builtInMic.name, "event source remains old preferred")
    expect(event?.toDeviceName == usbMic.name, "event target is new current device")
}

/// A3：protection window 内的外部切换 → 按启发式恢复（预期行为，非 bug）。
@MainActor
private func testA3_ManualSwitchInsideProtectionWindow() {
    test("A3 switch inside protection window")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 制造拓扑变化开启 protection window。
    provider.devices = [builtInMic, usbMic, airpodsMic]
    monitor.handleDeviceListChanged()

    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "restore preferred inside window")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred not learned")
}

/// A4：新设备接入但没抢麦，稳定后用户再选它 → 接受（关键回归）。
@MainActor
private func testA4_NewDeviceSettlesThenAccepted() async {
    test("A4 new device settles then accepted")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // USB 接入但未抢默认输入。
    provider.devices = [builtInMic, usbMic]
    monitor.handleDeviceListChanged()

    // 等待 protection window 到期并回到 stable。
    await waitPastSettleWindow()

    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "stable external switch does not restore")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred learning waits for candidate confirmation")

    await waitPastStableExternalSwitchClassification()

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred learned after candidate confirmation")
}

// MARK: - Burst Robustness (§60)

/// CoreAudio burst：交错重复的列表/默认输入事件，最终收敛，
/// setter 无循环，短时间重复恢复由 Auto notification cooldown 去重。
@MainActor
private func testBurst() {
    test("burst robustness")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // DEVICE_LIST_CHANGED（AirPods 加入）
    provider.devices = [builtInMic, airpodsMic]
    monitor.handleDeviceListChanged()

    // DEFAULT_INPUT → AirPods（第一次抢麦）
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid], "first restore")

    // 系统再次抢麦（仍在 notification cooldown 内）
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "second restore")

    // 重复的同值默认输入事件（幂等）
    monitor.handleDefaultInputChanged()
    monitor.handleDefaultInputChanged()

    // 重复的同集合列表事件（无 delta，不重置窗口）
    monitor.handleDeviceListChanged()

    // 恢复后的 self-induced 确认
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.count == 2, "no extra setter from burst/idempotent events")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "final current = preferred")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "preferred stable")
    expect(notifier.presentCount == 1, "notification cooldown suppresses immediate duplicate restore")
}

/// pending restore 确认前关闭通知，不应启动 Auto notification cooldown。
@MainActor
private func testNotificationCooldownStartsOnlyWhenActuallySubmitted() {
    test("notification cooldown starts only when actually submitted")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 30.0
    )
    provider.applySetImmediately = false

    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid], "first hijack starts pending restore")
    expect(notifier.presentCount == 0, "pending restore has not notified")

    monitor.notificationsEnabled = false
    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(notifier.presentCount == 0, "confirmation while notifications are off sends nothing")

    monitor.notificationsEnabled = true
    provider.applySetImmediately = true
    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "second hijack is restored after notifications are re-enabled")
    expect(notifier.presentCount == 1, "disabled confirmation did not start cooldown, so the next restore may notify")
}

/// 运行中修改 settleSeconds 会重算尚未过期的 protection window，
/// Auto notification cooldown 也按最新 settleSeconds 判断；旧 1s 边界不能提前放行。
@MainActor
private func testSettleConfigurationChangeExtendsProtectionAndNotificationCooldown() async {
    test("settle configuration change extends protection and notification cooldown")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        settle: 1.0
    )

    provider.devices = [builtInMic, airpodsMic]
    monitor.handleDeviceListChanged()

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()
    expect(notifier.presentCount == 1, "first hijack notifies once")

    // 将仍活跃的 protection window 与后续 notification cooldown 从 1s 扩展到 30s；等待超过旧 1s。
    monitor.settleSeconds = 30.0
    await waitPastSettleWindow()

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "second hijack is still restored inside extended protection window")
    expect(notifier.presentCount == 1, "updated notification cooldown suppresses the second notification")
}

// MARK: - Reconnect (§61)

/// preferred 断开 → 保留 UID；重新出现 → 自动恢复。
@MainActor
private func testPreferredReconnect() {
    test("preferred reconnect")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: usbMic,
        preferred: usbMic.uid,
        mode: .auto
    )

    // USB 拔掉：设备列表移除，系统 fallback 到 BuiltIn。
    provider.devices = [builtInMic]
    provider.current = builtInMic
    monitor.handleDeviceListChanged()
    monitor.handleDefaultInputChanged()

    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred UID preserved while offline")
    expect(provider.setCalls.isEmpty, "no fallback to other device")

    // USB 重新接入：同 UID 复现。
    provider.devices = [builtInMic, usbMic]
    monitor.handleDeviceListChanged()

    expect(provider.setCalls == [usbMic.uid], "auto restore on reconnect (same UID)")
    expect(monitor.currentDevice?.uid == usbMic.uid, "current = USB after reconnect")
    expect(notifier.presentCount == 1, "reconnect notification")
}

/// preferred 重连时，系统若已自动恢复 preferred，不应重复 setter。
@MainActor
private func testPreferredReconnectAlreadyCurrentDoesNotSetAgain() {
    test("preferred reconnect already current does not set again")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic],
        current: builtInMic,
        preferred: usbMic.uid,
        mode: .auto
    )

    provider.devices = [builtInMic, usbMic]
    provider.current = usbMic
    monitor.handleDeviceListChanged()

    expect(
        monitor.currentDevice?.uid == usbMic.uid,
        "device list callback refreshes current before reconnect policy"
    )
    expect(provider.setCalls.isEmpty, "no redundant setter when preferred is already current")
}

// MARK: - Trusted selection inside protection window (§62)

@MainActor
private func testUserSelectionInsideProtectionWindow() {
    test("user selection inside protection window")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 开启 protection window。
    provider.devices = [builtInMic, usbMic, airpodsMic]
    monitor.handleDeviceListChanged()

    // 用户直接通过 MicLock 菜单选择 USB：Trusted User Action。
    monitor.selectDevice(usbMic)

    expect(provider.setCalls == [usbMic.uid], "trusted selection applies immediately")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred = USB immediately")

    // 后续 self-induced 回调不得把 preferred restore 回旧设备。
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [usbMic.uid], "no restore back to old preferred")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred stays USB")
}

// MARK: - Protection Off (§64)

@MainActor
private func testProtectionOff() {
    test("protection off")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto,
        protection: false
    )

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "no restore when protection off")
    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "no learning when protection off")
    expect(notifier.presentCount == 0, "no notification when protection off")
}

// MARK: - Startup (§48)

@MainActor
private func testStartupEnforce() {
    test("startup enforce")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: airpodsMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    monitor.evaluateStartupPolicy()

    expect(provider.setCalls == [builtInMic.uid], "startup restores preferred")
    expect(notifier.presentCount == 0, "startup restore does not notify")
}

/// init 时设备枚举成功，但默认输入读取瞬时失败：不能把失败解释成“没有默认输入”。
/// start() 进入启动策略后应主动重采样；不依赖任何外部 callback 也要最终恢复 persisted preferred。
@MainActor
private func testStartupCurrentReadFailureRecoversWithoutExternalCallback() async {
    test("startup current read failure recovers without external callback")

    let scheduler = ManualAudioMonitorScheduler()
    let suite = "MicLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(builtInMic.uid, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set(true, forKey: Preferences.protectionEnabledKey)
    defaults.set(ProtectionMode.auto.rawValue, forKey: Preferences.protectionModeKey)
    defaults.set(true, forKey: Preferences.notificationsEnabledKey)
    defaults.set(1.0, forKey: Preferences.settleSecondsKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice,
        objectID: nil,
        status: -1
    )

    let notifier = RecordingNotifier()
    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: notifier,
        scheduler: scheduler
    )

    expect(monitor.currentDevice == nil, "failed initial current read does not invent a real no-default state")
    expect(monitor.deviceEnumerationError != nil, "current read failure is surfaced")

    // 模拟 start()：listeners 已就绪后启动 recovery；期间没有任何 CoreAudio callback。
    monitor.evaluateStartupPolicy()
    provider.currentInputDeviceError = nil
    await scheduler.advance(by: .milliseconds(250))

    expect(provider.setCalls == [builtInMic.uid], "startup recovery restores preferred after current read recovers")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "startup recovery confirms the restored current")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.startup), "startup semantics are preserved")
    expect(notifier.presentCount == 0, "startup recovery stays silent")
}

/// 运行中 current property read 失败时，最后一次可信 current 必须保留；
/// recovery 成功后再根据新事实执行策略。
@MainActor
private func testRuntimeCurrentReadFailurePreservesLastTrustedCurrent() async {
    test("runtime current read failure preserves last trusted current")

    let scheduler = ManualAudioMonitorScheduler()
    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, airpodsMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual,
        scheduler: scheduler
    )

    provider.current = airpodsMic
    provider.currentInputDeviceError = AudioDeviceProviderError.coreAudio(
        operation: .queryDefaultInputDevice,
        objectID: nil,
        status: -1
    )
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "failed read preserves the last trusted current")
    expect(provider.setCalls.isEmpty, "policy does not act on an unreadable current sample")

    provider.currentInputDeviceError = nil
    await scheduler.advance(by: .milliseconds(250))

    expect(provider.setCalls == [builtInMic.uid], "recovery observes AirPods and restores BuiltIn")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "recovery converges back to the preferred current")
}

/// init 时 topology 枚举瞬时失败，且之后没有任何外部 CoreAudio callback：
/// 启动阶段必须主动恢复枚举，并把第一份可信快照作为 startup baseline，
/// 最终使用 .startup 语义恢复 preferred，且不发送通知。
@MainActor
private func testStartupEnumerationFailureRecoversWithoutExternalCallback() async {
    test("startup enumeration failure recovers without external callback")

    let scheduler = ManualAudioMonitorScheduler()

    let suite = "MicLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(builtInMic.uid, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set(true, forKey: Preferences.protectionEnabledKey)
    defaults.set(ProtectionMode.auto.rawValue, forKey: Preferences.protectionModeKey)
    defaults.set(true, forKey: Preferences.notificationsEnabledKey)
    defaults.set(1.0, forKey: Preferences.settleSecondsKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)

    let notifier = RecordingNotifier()
    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: notifier,
        scheduler: scheduler
    )

    expect(monitor.devices.isEmpty, "failed init enumeration does not invent an empty trusted topology")
    expect(monitor.currentDevice?.uid == airpodsMic.uid, "current can still be read during init enumeration failure")
    expect(monitor.deviceEnumerationError != nil, "init enumeration failure is visible")

    // 模拟 start() 已安装 listeners 后进入 evaluateStartupPolicy；不制造任何外部 callback。
    provider.listInputDevicesError = nil
    monitor.evaluateStartupPolicy()

    await scheduler.advance(by: .milliseconds(250))

    expect(monitor.deviceEnumerationError == nil, "startup recovery clears the enumeration error")
    expect(
        monitor.devices.map(\.uid).sorted() == [airpodsMic.uid, builtInMic.uid].sorted(),
        "startup recovery installs the first trusted topology as a baseline"
    )
    expect(provider.setCalls == [builtInMic.uid], "startup recovery restores persisted preferred without an external callback")
    expect(monitor.currentDevice?.uid == builtInMic.uid, "startup recovery confirms BuiltIn as current")
    expect(monitor.recentAudioEvents.first?.kind == .restored(.startup), "recovered alignment keeps startup event semantics")
    expect(notifier.presentCount == 0, "startup recovery does not send a restore notification")
}

/// Fresh install 不能在 init 枚举失败时用不完整的 current fallback 初始化 preferred。
/// 第一份可信 startup baseline 到达后应按既定默认规则优先选择 BuiltIn。
@MainActor
private func testFreshInstallEnumerationFailurePrefersBuiltInOverCurrent() async {
    test("fresh install enumeration failure prefers built-in over current")

    let scheduler = ManualAudioMonitorScheduler()

    let suite = "MicLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(false, forKey: Preferences.protectionEnabledKey)
    defaults.set(ProtectionMode.auto.rawValue, forKey: Preferences.protectionModeKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic, airpodsMic]
    provider.current = airpodsMic
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)

    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: RecordingNotifier(),
        scheduler: scheduler
    )

    expect(monitor.preferredMicrophoneUID == nil, "untrusted init snapshot does not persist AirPods as first-run preferred")

    provider.listInputDevicesError = nil
    monitor.evaluateStartupPolicy()
    await scheduler.advance(by: .milliseconds(250))

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "trusted recovery baseline initializes BuiltIn preferred")
    expect(defaults.string(forKey: Preferences.preferredMicrophoneUIDKey) == builtInMic.uid, "recovered first-run preferred is persisted")
}

/// Fresh install 初始枚举失败且 current 也不可读时，同样必须在可信 recovery baseline
/// 到达后完成 BuiltIn 默认初始化，不能让 preferred 永久保持 nil。
@MainActor
private func testFreshInstallEnumerationFailureWithNilCurrentPrefersBuiltIn() async {
    test("fresh install enumeration failure with nil current prefers built-in")

    let scheduler = ManualAudioMonitorScheduler()

    let suite = "MicLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(false, forKey: Preferences.protectionEnabledKey)
    defaults.set(ProtectionMode.auto.rawValue, forKey: Preferences.protectionModeKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic, airpodsMic]
    provider.current = nil
    provider.listInputDevicesError = AudioDeviceProviderError.coreAudio(operation: .enumerateDeviceListData, objectID: nil, status: -1)

    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: RecordingNotifier(),
        scheduler: scheduler
    )

    expect(monitor.preferredMicrophoneUID == nil, "failed init with nil current leaves preferred undecided")

    provider.listInputDevicesError = nil
    provider.current = airpodsMic
    monitor.evaluateStartupPolicy()
    await scheduler.advance(by: .milliseconds(250))

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "trusted recovery baseline initializes BuiltIn even after nil init current")
}

// MARK: - Idempotency (§55)

@MainActor
private func testIdempotentCallbacks() {
    test("idempotent callbacks")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .manual
    )

    // DEFAULT_INPUT 未实际变化的重复回调。
    monitor.handleDefaultInputChanged()
    monitor.handleDefaultInputChanged()
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "no repeated setter for unchanged default")
}

// MARK: - First run

@MainActor
private func testFirstRunDefaultSelection() {
    test("first run default selection")

    let (monitor, _, _) = makeMonitor(
        devices: [airpodsMic, builtInMic],
        current: airpodsMic,
        preferred: nil
    )

    expect(monitor.preferredMicrophoneUID == nil, "pre-listener snapshot does not initialize preferred")
    monitor.evaluateStartupPolicy()

    expect(monitor.preferredMicrophoneUID == builtInMic.uid, "first run prefers built-in mic")
}

// MARK: - Preferences (§39-§40)

/// 设备名持久化：上次会话记录的名字，重启后离线 preferred 仍显示可读名。
@MainActor
private func testDeviceNamePersistence() {
    test("device name persistence")

    let suite = "MicLockTests.prefs.names.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    // 上一次会话记录过 USB 的名字，本次启动 USB 不在线。
    defaults.set(["USB": "USB Microphone"], forKey: Preferences.deviceNamesKey)
    defaults.set(usbMic.uid, forKey: Preferences.preferredMicrophoneUIDKey)
    defaults.set(true, forKey: Preferences.protectionEnabledKey)
    defaults.set(ProtectionMode.auto.rawValue, forKey: Preferences.protectionModeKey)

    let provider = FakeAudioDeviceProvider()
    provider.devices = [builtInMic]
    provider.current = builtInMic

    let monitor = AudioMonitor(
        provider: provider,
        preferences: Preferences(defaults: defaults),
        notifier: RecordingNotifier()
    )

    expect(monitor.offlinePreferredName == "USB Microphone", "offline preferred shows persisted name")

    // USB 重新在线，但这一轮 HAL Name property 瞬时失败：UI 可以使用 fallback，
    // 但 fallback 不能覆盖上一轮已经持久化的真实设备名称。
    let unresolvedUSB = AudioInputDevice(
        uid: usbMic.uid,
        deviceID: usbMic.deviceID,
        name: "Unknown (\(usbMic.deviceID))",
        transportType: usbMic.transportType,
        nameIsResolved: false
    )
    provider.devices = [builtInMic, unresolvedUSB]
    monitor.handleDeviceListChanged()

    expect(
        monitor.devices.first(where: { $0.uid == usbMic.uid })?.name == unresolvedUSB.name,
        "UI may display the unresolved fallback name"
    )
    var stored = defaults.dictionary(forKey: Preferences.deviceNamesKey)?["USB"] as? String
    expect(stored == "USB Microphone", "unresolved fallback does not overwrite persisted name")

    // 再次离线时仍应显示上一次真正解析到的名字，而不是 Unknown fallback。
    provider.current = builtInMic
    provider.devices = [builtInMic]
    monitor.handleDeviceListChanged()
    expect(monitor.offlinePreferredName == "USB Microphone", "offline name survives transient name-read failure")

    // Name property 恢复后，新的真实名称仍然可以正常刷新缓存。
    let renamedUSB = AudioInputDevice(
        uid: usbMic.uid,
        deviceID: usbMic.deviceID,
        name: "RØDE NT-USB",
        transportType: usbMic.transportType
    )
    provider.devices = [builtInMic, renamedUSB]
    monitor.handleDeviceListChanged()

    stored = defaults.dictionary(forKey: Preferences.deviceNamesKey)?["USB"] as? String
    expect(stored == "RØDE NT-USB", "resolved HAL name still refreshes persisted name")
}

/// 全新安装 → auto。
@MainActor
private func testPreferencesFreshInstall() {
    test("preferences fresh install")

    let suite = "MicLockTests.prefs.fresh.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let prefs = Preferences(defaults: defaults)

    expect(prefs.protectionMode == .auto, "fresh install defaults to auto")
    expect(prefs.protectionEnabled == false, "fresh install protection off")
    expect(prefs.settleSeconds == 2.0, "fresh install settle = 2.0s")
    expect(prefs.notificationsEnabled == true, "fresh install notifications on")
}

/// settleSeconds 钳制在 1...30。
@MainActor
private func testPreferencesSettleClamp() {
    test("preferences settle clamp")

    let suite = "MicLockTests.prefs.clamp.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let prefs = Preferences(defaults: defaults)

    prefs.settleSeconds = 0.2
    expect(prefs.settleSeconds == 1.0, "below range clamps to 1.0")

    prefs.settleSeconds = 100
    expect(prefs.settleSeconds == 30.0, "above range clamps to 30.0")
}


@MainActor
private func testRecentEventsKeepLatestTen() async {
    test("recent events keep latest ten")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    for index in 0..<12 {
        provider.current = index.isMultiple(of: 2) ? usbMic : builtInMic
        monitor.handleDefaultInputChanged()
        await waitPastStableExternalSwitchClassification()
    }

    expect(monitor.recentAudioEvents.count == 10, "recent event history is capped at ten")
    expect(monitor.recentAudioEvents.first?.toDeviceName == builtInMic.name, "newest event is first")
}
