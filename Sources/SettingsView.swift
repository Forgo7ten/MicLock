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
    private var launchAtLoginError: String?

    @State
    private var loginItemSyncTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)

                Text("登录 macOS 后自动启动 MicLock，并保持静默运行在菜单栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            launchAtLoginError = nil
        }
        .onDisappear {
            loginItemSyncTask?.cancel()
        }
    }

    // MARK: - Pieces

    /// 显式区分“用户修改 Toggle”和“程序同步状态”：
    /// onAppear / 延迟复核直接写 launchAtLoginOn，不会再次调用 SMAppService。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginOn },
            set: { enabled in
                handleLaunchAtLogin(enabled)
            }
        )
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
    // 用户操作经显式 Binding 触发一次服务写入；onAppear 和延迟复核
    // 只同步本地状态，不产生 register/unregister 副作用。

    private func handleLaunchAtLogin(_ enabled: Bool) {
        loginItemSyncTask?.cancel()

        let previous = launchAtLoginOn
        launchAtLoginOn = enabled
        launchAtLoginError = nil

        do {
            try LaunchAtLoginManager.setEnabled(enabled)
        } catch {
            // 服务写入失败：只回滚本地 UI，不触发反向 unregister/register。
            launchAtLoginOn = previous
            launchAtLoginError = "设置登录启动失败：\(error.localizedDescription)。请确认 MicLock 已安装在 /Applications 或 ~/Applications。"
            return
        }

        // 乐观 UI 已由 Toggle 更新，最多复核 ~3 秒收敛到真实状态。
        loginItemSyncTask = Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(0.75))
                guard !Task.isCancelled else { return }

                let status = LaunchAtLoginManager.status

                if enabled {
                    // 待批准仍属于“已经请求开启”，保持勾选等待用户批准。
                    if status == .enabled || status == .pendingApproval {
                        return
                    }
                } else if status == .off {
                    return
                }
            }

            // 3 秒后仍未收敛：以系统真实状态为准。
            let actualEnabled = LaunchAtLoginManager.isEnabled
            launchAtLoginOn = actualEnabled

            if actualEnabled != enabled {
                launchAtLoginError = enabled
                    ? "登录启动未能在系统中生效，请稍后重试。"
                    : "关闭登录启动未能在系统中生效，请稍后重试。"
            }
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
