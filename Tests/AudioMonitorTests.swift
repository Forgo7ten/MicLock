import Foundation

// 每个测试函数对应设计文档的一个场景。
// 通过直接调用 monitor.handleDefaultInputChanged() /
// monitor.handleDeviceListChanged() 模拟 CoreAudio 回调。

@MainActor
func runAllTests() async {
    testM1_ManualRestore()
    testM2_PreferredOffline()
    testM3_TrustedUserSelection()
    testUserSelectionFailureDoesNotPersistPreferred()
    testRestoreImmediateConfirmation()
    testRestoreWaitsForRealConfirmation()
    await testDelayedConfirmationBeyondLegacyTimeoutSucceeds()
    testPendingSwitchFailsWhenTargetDisappears()
    testPendingSwitchFailsWhenTargetDisappearsAndCurrentIsNil()
    testNilSourcePendingSwitchIsSupersededByNonTargetCurrent()
    testEnumerationFailureDoesNotApplyEmptyTopology()
    await testCandidateRecoversAfterEnumerationFailure()
    testPendingRestoreIsAtomicallySupersededByModeChange()
    testIntermediateCallbackWhileExpectedDoesNotRestoreAgain()
    testA1_NewDeviceHijack()
    testA1_DefaultCallbackBeforeDeviceAddedCallback()
    testPreferredRemoval_DefaultCallbackBeforeDeviceListCallback()
    await testPreferredRemoval_DefaultPropertyChangesBeforeDevicesProperty()
    await testA2_SettledUserSwitch()
    await testA2_RecentEventUsesOldPreferredAfterNoDeltaDeviceCallback()
    testA3_ManualSwitchInsideSettleWindow()
    await testA4_NewDeviceSettlesThenAccepted()
    testBurst()
    testNotificationDedupeOnlyConsumedWhenActuallySent()
    await testSettleConfigurationChangeKeepsEpisodeNotificationDeduped()
    testPreferredReconnect()
    testPreferredReconnectAlreadyCurrentDoesNotSetAgain()
    testUserSelectionInsideSettleWindow()
    testProtectionOff()
    testStartupEnforce()
    testIdempotentCallbacks()
    testFirstRunDefaultSelection()
    testDeviceNamePersistence()
    testPreferencesFreshInstall()
    testPreferencesSettleClamp()
    await testRecentEventsKeepLatestTen()
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

/// sourceUID == nil 时，只要出现非 target 的真实 current，就说明旧事务已被新的外部事实取代。
/// 不能因为没有 source 可比较而永久挡住后续 policy。
@MainActor
private func testNilSourcePendingSwitchIsSupersededByNonTargetCurrent() {
    test("nil-source pending switch is superseded by non-target current")

    let (monitor, provider, _) = makeMonitor(
        devices: [usbMic, airpodsMic],
        current: nil,
        preferred: nil,
        mode: .manual
    )

    provider.applySetImmediately = false
    monitor.selectDevice(usbMic)

    expect(provider.setCalls == [usbMic.uid], "trusted selection starts pending switch from nil source")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "trusted selection persists target preferred")

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(
        provider.setCalls == [usbMic.uid, usbMic.uid],
        "non-target current supersedes nil-source transaction and manual policy continues"
    )
    expect(
        monitor.currentDevice?.uid == airpodsMic.uid,
        "monitor keeps the real non-target current while replacement restore waits"
    )
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

    provider.listInputDevicesError = AudioDeviceProviderError.inputDeviceEnumerationFailed
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

    provider.listInputDevicesError = AudioDeviceProviderError.inputDeviceEnumerationFailed
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

    // 打开 Auto settle window，再模拟系统抢到 AirPods，产生未确认的 automaticHijack restore。
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

/// A3：settle window 内的外部切换 → 按启发式恢复（预期行为，非 bug）。
@MainActor
private func testA3_ManualSwitchInsideSettleWindow() {
    test("A3 switch inside settle window")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 制造拓扑变化开启 settle window。
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

    // 等待 settle episode 到期并回到 stable。
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
/// setter 无循环，Auto 通知一 episode 一条。
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

    // 系统再次抢麦（同一 episode）
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
    expect(notifier.presentCount == 1, "one notification per protection episode")
}

/// pending restore 确认前关闭通知，不应消耗当前 episode 的去重额度。
@MainActor
private func testNotificationDedupeOnlyConsumedWhenActuallySent() {
    test("notification dedupe only consumed when actually sent")

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

    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "second hijack is restored in same episode")
    expect(notifier.presentCount == 1, "second hijack can still consume the unused notification slot")
}

/// 运行中的 settleSeconds 修改必须立即重排当前 episode 的 deadline；
/// 旧 timer 到点后不能提前结束 episode、重置通知去重状态。
@MainActor
private func testSettleConfigurationChangeKeepsEpisodeNotificationDeduped() async {
    test("settle configuration change keeps episode notification deduped")

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

    // 把当前 episode 从 1s 延长到 30s；等待超过旧 1s deadline。
    monitor.settleSeconds = 30.0
    await waitPastSettleWindow()

    provider.current = airpodsMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls == [builtInMic.uid, builtInMic.uid], "second hijack is still restored inside extended episode")
    expect(notifier.presentCount == 1, "old timer cannot reset notification dedupe")
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

// MARK: - Trusted selection inside settle window (§62)

@MainActor
private func testUserSelectionInsideSettleWindow() {
    test("user selection inside settle window")

    let (monitor, provider, _) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 开启 settle window。
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

    // USB 重新在线：名字刷新并写回 defaults。
    provider.devices = [builtInMic, usbMic]
    monitor.handleDeviceListChanged()

    let stored = defaults.dictionary(forKey: Preferences.deviceNamesKey)?["USB"] as? String
    expect(stored == "USB Microphone", "name persisted to defaults")
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
