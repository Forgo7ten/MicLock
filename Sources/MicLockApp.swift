import SwiftUI
import AppKit
import Combine
import Observation

@main
struct MicLockApp: App {

    @NSApplicationDelegateAdaptor(MicLockAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarExtraContent(appDelegate: appDelegate)
        } label: {
            MenuBarExtraLabel(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsSceneContent(appDelegate: appDelegate)
        }
    }
}

@MainActor
private final class MicLockAppDelegate:
    NSObject,
    NSApplicationDelegate,
    ObservableObject
{

    @Published
    private(set) var monitor: AudioMonitor?

    // 部分 macOS 版本下，MenuBarExtra label 使用同一个 NSImage
    // 仅修改 opacity 时，状态栏图标可能无法可靠刷新。
    // 因此经此 @Published 镜像驱动 label 切换实际 Image 内容。
    @Published
    private(set) var protectionEnabled = true

    private var rightClickMonitor: Any?

    let activationPolicyManager = ActivationPolicyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = AudioMonitor.live()
        // 启动顺序：load prefs → enumerate → read current（monitor.init）
        //           → install listeners → evaluate（start）。
        monitor.start()

        NotificationManager.shared.activate()

        // App 完成启动后再交给 SwiftUI MenuBarExtra。
        self.monitor = monitor
        protectionEnabled = monitor.protectionEnabled
        trackProtectionState(of: monitor)

        // 右键菜单栏图标与左键同效（monitor 详见下方函数注释）。
        installMenuBarRightClickMonitor()

        activationPolicyManager.start()
    }

    /// MenuBarExtra 没有公开的 secondary-click 回调。
    /// 在本 App 的事件队列中捕获右键；若命中 MenuBarExtra 底层的
    /// NSStatusBarButton，则模拟 primary click，复用系统的窗口开关行为。
    ///
    /// 仅使用公开 AppKit API，但依赖 MenuBarExtra 当前由
    /// NSStatusBarButton 承载这一实现细节。
    private func installMenuBarRightClickMonitor() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard
                let window = event.window,
                let contentView = window.contentView
            else {
                return event
            }

            let point = contentView.convert(event.locationInWindow, from: nil)

            guard let hitView = contentView.hitTest(point) else {
                return event
            }

            guard let statusButton = sequence(first: hitView, next: { $0.superview })
                .compactMap({ $0 as? NSStatusBarButton })
                .first
            else {
                return event
            }

            // 复用 MenuBarExtra 原本的左键行为；吞掉原右键事件避免重复分发。
            statusButton.performClick(nil)
            return nil
        }
    }

    // 注：delegate 与 App 同生命周期，进程退出由系统清理 event monitor，
    // 因此不写 nonisolated deinit（Swift 6 下 deinit 不允许访问 MainActor 属性）。
    func applicationWillTerminate(_ notification: Notification) {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }

        activationPolicyManager.stop()
    }

    /// withObservationTracking 是一次性的，onChange 后必须重新挂载；
    /// 重挂前先读一次当前值，保证镜像收敛到最新状态。
    private func trackProtectionState(of monitor: AudioMonitor) {
        withObservationTracking {
            _ = monitor.protectionEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.protectionEnabled = monitor.protectionEnabled
                self.trackProtectionState(of: monitor)
            }
        }
    }

}

// Scene body 不随 delegate 的 @Published 变化重算；
// monitor nil→非 nil 的切换必须在 View 内通过 @ObservedObject 观察。

@MainActor
private struct MenuBarExtraContent: View {

    @ObservedObject
    var appDelegate: MicLockAppDelegate

    var body: some View {
        if let monitor = appDelegate.monitor {
            MenuBarView(
                monitor: monitor,
                beforeOpenSettings: {
                    appDelegate.activationPolicyManager.beginOpeningSettings()
                }
            )
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(14)
                .frame(width: 340)
        }
    }
}

@MainActor
private struct MenuBarExtraLabel: View {

    @ObservedObject
    var appDelegate: MicLockAppDelegate

    var body: some View {
        MenuBarLabel(protectionEnabled: appDelegate.protectionEnabled)
    }
}

// 与 MenuBarExtraContent 相同模式：Settings Scene body 也不随
// delegate 的 @Published 变化重算，monitor nil→非 nil 在 View 内观察。
@MainActor
private struct SettingsSceneContent: View {

    @ObservedObject
    var appDelegate: MicLockAppDelegate

    var body: some View {
        if let monitor = appDelegate.monitor {
            MicLockSettingsView(
                monitor: monitor,
                activationPolicyManager: appDelegate.activationPolicyManager
            )
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(30)
                .frame(width: 520, height: 360)
        }
    }
}

@MainActor
private struct MenuBarLabel: View {

    let protectionEnabled: Bool

    // 部分 macOS 版本下，MenuBarExtra label 使用同一个 NSImage
    // 仅修改 opacity 时，状态栏图标可能无法可靠刷新。
    // 因此预生成 enabled / disabled 两张图，状态变化时直接切换
    // label 的实际 Image 内容，避免使用定时刷新。
    private static let enabledIcon: NSImage? = {
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
    }()

    private static let disabledIcon: NSImage? = {
        guard let source = enabledIcon else { return nil }

        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 0.6
            )
            return true
        }

        image.isTemplate = true
        return image
    }()

    private var accessibilityLabel: String {
        protectionEnabled
            ? "麦克风保护已开启"
            : "麦克风保护已关闭"
    }

    var body: some View {
        Group {
            if protectionEnabled {
                if let image = Self.enabledIcon {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "mic.fill")
                }
            } else {
                if let image = Self.disabledIcon {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "mic")
                }
            }
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .help(accessibilityLabel)
    }
}

@MainActor
struct MenuBarView: View {

    // @Bindable：@Observable 模型上产生 $monitor.xxx 绑定（macOS 14+）。
    @Bindable
    var monitor: AudioMonitor

    /// openSettings 前先登记 regular demand 并激活 App
    /// （LSUIElement App 无 Dock 激活流程，详见 ActivationPolicyManager）。
    /// 返回 false 表示 .regular 切换失败，应放弃 openSettings()。
    let beforeOpenSettings: @MainActor () -> Bool

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Toggle("麦克风保护", isOn: $monitor.protectionEnabled)

                Picker("模式", selection: $monitor.protectionMode) {
                    Text("自动").tag(ProtectionMode.auto)
                    Text("手动").tag(ProtectionMode.manual)
                }
                .pickerStyle(.segmented)

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
            }

            Group {
                // 监听基础能力失败优先于一次性设备操作错误。
                if let error = monitor.listenerError ?? monitor.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Divider()

                HStack {
                    Button {
                        // 先切 .regular 再 openSettings，让 Settings 从一开始
                        // 就是普通 App 场景的一部分（有 Dock / 顶部 App Menu）。
                        guard beforeOpenSettings() else { return }
                        openSettings()
                    } label: {
                        Label("设置…", systemImage: "gearshape")
                    }

                    Spacer()

                    Button("退出 MicLock") {
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
}
