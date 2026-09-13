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
    testIntermediateCallbackWhileExpectedDoesNotRestoreAgain()
    testA1_NewDeviceHijack()
    testA2_SettledUserSwitch()
    testA3_ManualSwitchInsideSettleWindow()
    await testA4_NewDeviceSettlesThenAccepted()
    testBurst()
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
    expect(
        monitor.recentAudioAction?.kind == .restored(.manualLock),
        "recent action records manual restore reason"
    )
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
    expect(
        monitor.recentAudioAction?.kind == .selectedInMicLock,
        "recent action records trusted MicLock selection"
    )

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
    expect(monitor.recentAudioAction == nil, "failed selection is not recorded as completed")
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

    provider.current = builtInMic
    monitor.handleDefaultInputChanged()

    expect(monitor.currentDevice?.uid == builtInMic.uid, "confirmed current is preferred")
    expect(notifier.presentCount == 1, "notification sent after real confirmation")
    expect(provider.setCalls == [builtInMic.uid], "confirmation does not trigger another setter")
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

/// A2：设备稳定后的外部切换 → 接受并保存为新的 preferred，不恢复。
@MainActor
private func testA2_SettledUserSwitch() {
    test("A2 settled user switch")

    let (monitor, provider, notifier) = makeMonitor(
        devices: [builtInMic, usbMic],
        current: builtInMic,
        preferred: builtInMic.uid,
        mode: .auto
    )

    // 无拓扑事件发生 → settled。
    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "no restore for user-initiated switch")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred learned = USB")
    expect(notifier.presentCount == 0, "no notification on accept")
    expect(
        monitor.recentAudioAction?.kind == .acceptedUserSwitch,
        "recent action explains accepted Auto Mode user switch"
    )
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

    // 等待 settle window 过期：USB 从 unsettledNewUIDs 移除。
    await waitPastSettleWindow()

    provider.current = usbMic
    monitor.handleDefaultInputChanged()

    expect(provider.setCalls.isEmpty, "accept user switch to settled new device")
    expect(monitor.preferredMicrophoneUID == usbMic.uid, "preferred learned = USB")
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
