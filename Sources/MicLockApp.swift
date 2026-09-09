import SwiftUI
import AppKit

@main
struct MicLockApp: App {

    @NSApplicationDelegateAdaptor(MicLockAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class MicLockAppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = AudioMonitor.live()
        // 启动顺序：load prefs → enumerate → read current（monitor.init）
        //           → install listeners → evaluate（start）。
        monitor.start()

        NotificationManager.shared.activate()
        menuBarController = MenuBarController(monitor: monitor)
    }
}

@MainActor
private final class MenuBarController: NSObject {

    private let monitor: AudioMonitor

    private let statusItem: NSStatusItem

    private let popover: NSPopover

    private let menuBarIcon: NSImage?

    private var aboutWindowController: AboutWindowController?

    init(monitor: AudioMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        menuBarIcon = Self.loadMenuBarIcon()

        super.init()

        configureStatusItem()
        configurePopover()
        updateStatusItem(protectionEnabled: monitor.protectionEnabled)
    }

    private static func loadMenuBarIcon() -> NSImage? {
        guard
            let url = Bundle.main.url(
                forResource: "MenuBarIconTemplate",
                withExtension: "svg"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        let secondaryClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(togglePopover(_:))
        )
        secondaryClick.buttonMask = 0x2
        button.addGestureRecognizer(secondaryClick)
    }

    private func configurePopover() {
        let rootView = MenuBarView(
            monitor: monitor,
            onProtectionStateChange: { [weak self] enabled in
                self?.updateStatusItem(protectionEnabled: enabled)
            },
            onShowAbout: { [weak self] in
                self?.showAbout()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.contentViewController = hostingController
    }

    private func showAbout() {
        // About 是独立窗口，先关闭 transient popover。
        popover.close()

        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }

        aboutWindowController?.showAbout()
    }

    private func updateStatusItem(protectionEnabled: Bool) {
        guard let button = statusItem.button else { return }

        button.image = menuBarIcon ?? NSImage(
            systemSymbolName: protectionEnabled ? "mic.fill" : "mic",
            accessibilityDescription: nil
        )
        button.alphaValue = protectionEnabled ? 1 : 0.45

        let accessibilityLabel = protectionEnabled
            ? "麦克风保护已开启"
            : "麦克风保护已关闭"
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.close()
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
            NSApp.activate()
        }
    }
}

@MainActor
struct MenuBarView: View {

    // @Bindable：@Observable 模型上产生 $monitor.xxx 绑定（macOS 14+）。
    @Bindable
    var monitor: AudioMonitor

    let onProtectionStateChange: @MainActor (Bool) -> Void

    let onShowAbout: @MainActor () -> Void

    @State
    private var launchAtLoginOn = false

    @State
    private var loginItemSyncTask: Task<Void, Never>?

    // 布局透明的 Group 拆分（旧 macOS 13 SDK 的 ViewBuilder.buildBlock
    // 子视图上限遗留的组织方式，新版 SDK 已无此限制，保留分组语义）。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Toggle("麦克风保护", isOn: $monitor.protectionEnabled)
                    .onChange(of: monitor.protectionEnabled) { enabled in
                        onProtectionStateChange(enabled)
                    }

                Picker("模式", selection: $monitor.protectionMode) {
                    Text("自动").tag(ProtectionMode.auto)
                    Text("手动").tag(ProtectionMode.manual)
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("首选麦克风")
                    .font(.headline)
            }

            Group {
                deviceList

                if let offline = monitor.offlinePreferredName {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(offline)（未连接）")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                Divider()

                HStack {
                    Text("当前麦克风")
                    Spacer()
                    Text(monitor.currentDeviceName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Toggle("显示通知", isOn: $monitor.notificationsEnabled)

                if monitor.notificationDenied {
                    notificationDeniedRow
                }

                Toggle("登录时启动", isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { enabled in
                        handleLaunchAtLogin(enabled)
                    }
                    .onAppear {
                        launchAtLoginOn = LaunchAtLoginManager.isEnabled
                    }
            }

            Group {
                DisclosureGroup("高级") {
                    HStack {
                        Text("设备稳定窗口")
                        Slider(value: $monitor.settleSeconds, in: Preferences.settleRange, step: 0.5)
                        Text("\(monitor.settleSeconds, specifier: "%.1f") 秒")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = monitor.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Divider()

                HStack {
                    Button("关于 MicLock") {
                        onShowAbout()
                    }

                    Spacer()

                    Button("退出") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Pieces

    /// 设备列表：多于 6 个时限高滚动，避免菜单窗口超出屏幕。
    @ViewBuilder
    private var deviceList: some View {
        if monitor.devices.isEmpty {
            Text("没有发现输入设备")
                .foregroundStyle(.secondary)
        } else if monitor.devices.count > 6 {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(monitor.devices) { device in
                        deviceRow(for: device)
                    }
                }
            }
            .frame(maxHeight: 320)
        } else {
            ForEach(monitor.devices) { device in
                deviceRow(for: device)
            }
        }
    }

    private var modeDescription: String {
        switch monitor.protectionMode {
        case .auto:
            return "阻止新接入的设备自动抢占麦克风。设备稳定后，主动切换的麦克风会自动成为新的首选设备。"
        case .manual:
            return "始终锁定到所选麦克风。任何来自系统或其他应用的输入切换都会被自动恢复。"
        }
    }

    private func deviceRow(for device: AudioInputDevice) -> some View {
        Button {
            monitor.selectDevice(device)
        } label: {
            HStack {
                Image(
                    systemName: monitor.preferredMicrophoneUID == device.uid
                        ? "checkmark.circle.fill"
                        : "circle"
                )

                VStack(alignment: .leading) {
                    Text(device.name)

                    if device.isBuiltIn {
                        Text("内置设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if monitor.currentDevice?.uid == device.uid {
                    Text("当前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notificationDeniedRow: some View {
        Button {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings"
            ) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack {
                Image(systemName: "bell.slash")
                    .foregroundStyle(.orange)
                Text("通知权限已被拒绝，点此前往系统设置开启")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Launch at Login
    //
    // SMAppService 的 status 在 register/unregister 成功后仍会滞后数秒
    // （BTM 数据库异步更新），不能把复选框直接绑定在 status 上——
    // 点击取消时 SwiftUI 立刻重读 status 拿到旧值，复选框会被弹回勾选。
    // 改为本地状态乐观驱动 + 延迟复核真实状态。

    private func handleLaunchAtLogin(_ enabled: Bool) {
        loginItemSyncTask?.cancel()

        guard LaunchAtLoginManager.setEnabled(enabled) else {
            // 注册/注销失败：回滚 UI 状态。
            launchAtLoginOn = !enabled
            monitor.reportError("设置登录启动失败（App 需安装在稳定位置，如 ~/Applications）")
            return
        }

        // 乐观 UI 已由 Toggle 更新，最多复核 ~3 秒收敛到真实状态。
        loginItemSyncTask = Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(0.75))
                guard !Task.isCancelled else { return }

                let status = LaunchAtLoginManager.status

                // 已注册待批准：系统已弹出设置面板引导，保持勾选。
                if status == .pendingApproval { return }

                if (status == .enabled) == enabled { return }
            }

            // 3 秒后仍未收敛：以真实状态为准。
            launchAtLoginOn = LaunchAtLoginManager.status == .enabled
        }
    }
}
