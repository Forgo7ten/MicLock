import SwiftUI
import AppKit

@MainActor
struct MicLockSettingsView: View {

    @Bindable
    var monitor: AudioMonitor

    let activationPolicyManager: ActivationPolicyManager

    var body: some View {
        TabView {
            GeneralSettingsView(monitor: monitor)
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            AdvancedSettingsView(monitor: monitor)
                .tabItem {
                    Label("高级", systemImage: "slider.horizontal.3")
                }

            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 360)
        .background {
            // 把 Settings 底层 NSWindow 识别并登记给 ActivationPolicyManager；
            // close 后 identity 保留，重开复用同一窗口时无需重新注册。
            WindowAccessor { window in
                activationPolicyManager.registerSettingsWindow(window)
            }
        }
    }
}

/// SwiftUI Settings Scene 不暴露 NSWindow，经此 AppKit bridge 识别。
/// 用 viewDidMoveToWindow 而非 makeNSView/updateNSView 猜 attachment
/// 时机：SwiftUI 复用同一窗口时不会重跑 accessor，但 identity 在
/// ActivationPolicyManager 中保留，无需重新识别；SwiftUI 销毁旧窗口
/// 换新窗口时，viewDidMoveToWindow 以新 identity 回调。
@MainActor
private final class WindowProbeView: NSView {

    var onWindow: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        onWindow?(window)
    }
}

private struct WindowAccessor: NSViewRepresentable {

    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindow = onWindow
    }
}

@MainActor
private struct GeneralSettingsView: View {

    @Bindable
    var monitor: AudioMonitor

    @State
    private var launchAtLoginOn = false

    @State
    private var loginItemSyncTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { enabled in
                        handleLaunchAtLogin(enabled)
                    }

                Text("登录 macOS 后自动启动 MicLock，并保持静默运行在菜单栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                Toggle("显示通知", isOn: $monitor.notificationsEnabled)

                if monitor.notificationDenied {
                    notificationDeniedRow
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            launchAtLoginOn = LaunchAtLoginManager.isEnabled
        }
        .onDisappear {
            loginItemSyncTask?.cancel()
        }
    }

    // MARK: - Pieces

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

@MainActor
private struct AdvancedSettingsView: View {

    @Bindable
    var monitor: AudioMonitor

    var body: some View {
        Form {
            Section("设备切换") {
                HStack {
                    Text("设备稳定窗口")
                    Slider(value: $monitor.settleSeconds, in: Preferences.settleRange, step: 0.5)
                    Text("\(monitor.settleSeconds, specifier: "%.1f") 秒")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }

                Text("设备接入或移除后，MicLock 会等待该时间窗口稳定，再判断是否接受或恢复默认麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
