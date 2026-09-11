#!/bin/zsh

# 选择“所选 Swift 工具链能解析”的 macOS SDK，把路径输出到 stdout。
# 供 build.sh 与 Tests/run.sh 共用。
#
# 背景：Swift 5.8 编译器读取新版 SDK（15/26+）里使用 Swift 6 语法
# （typed throws 等）的 swiftinterface 会直接崩溃（signal 11）；
# 旧版编译器同时代（macOS 13.x）的 SDK 又没有 Observation 模块。
# 安装 Swift 6+ 工具链后（见 select-toolchain.sh）即可使用新版 SDK。
# 判定方式：用覆盖真实依赖的最小文件做 -typecheck 探针
# （含 @Observable 宏展开、didSet、MenuBarExtra/Settings Scene、AppKit 激活策略、
# ServiceManagement 登录项、CoreAudio 监听块、通知中心与 OSLog 结构化日志插值）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ARCH="$(uname -m)"

TOOLCHAIN="$("${ROOT}/Scripts/select-toolchain.sh")"

SWIFT="${TOOLCHAIN}/usr/bin/swiftc"

PROBE_DIR="$(mktemp -d)"

trap 'rm -rf "${PROBE_DIR}"' EXIT

cat > "${PROBE_DIR}/probe.swift" <<'PROBE'
import SwiftUI
import AppKit
import CoreAudio
import UserNotifications
import ServiceManagement
import Observation
import OSLog

@Observable
@MainActor
final class ProbeModel {
    private static let logger = Logger(
        subsystem: "local.miclock.probe",
        category: "SDK"
    )

    @ObservationIgnored private var task: Task<Void, Never>?

    var value: Int {
        didSet {
            if value < 0 { value = 0 }
        }
    }

    init() {
        value = 0
    }

    func probeStructuredLogging() {
        Self.logger.debug(
            "OSLog probe value=\(self.value, privacy: .public)"
        )
    }

    func probeFrameworkAPIs() {
        _ = NSApp.setActivationPolicy(.accessory)
        _ = SMAppService.mainApp.status
        _ = UNUserNotificationCenter.current()
    }
}

struct ProbeView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings") {
            openSettings()
        }
    }
}

struct ProbeApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        MenuBarExtra("Probe", systemImage: "mic") {
            ProbeView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ProbeView()
                .environment(model)
        }
    }
}

var probeListener: AudioObjectPropertyListenerBlock?
PROBE

PROBE_LOG="${PROBE_DIR}/probe.log"
: > "${PROBE_LOG}"

for CANDIDATE in \
    "$(xcrun --show-sdk-path --sdk macosx)" \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
    [[ -d "${CANDIDATE}" ]] || continue

    CANDIDATE_LOG="${PROBE_DIR}/candidate.log"

    if "${SWIFT}" -typecheck \
        -swift-version 6 \
        -sdk "${CANDIDATE}" \
        -target "${ARCH}-apple-macos14.0" \
        "${PROBE_DIR}/probe.swift" >"${CANDIDATE_LOG}" 2>&1; then
        echo "${CANDIDATE}"
        exit 0
    fi

    {
        echo "=== SDK probe failed: ${CANDIDATE} ==="
        cat "${CANDIDATE_LOG}"
        echo
    } >> "${PROBE_LOG}"
done

echo "error: 所选 Swift 工具链无法解析任何已安装的 macOS SDK" >&2

if [[ -s "${PROBE_LOG}" ]]; then
    echo "Swift probe diagnostics:" >&2
    cat "${PROBE_LOG}" >&2
else
    echo "error: 未找到可测试的 macOS SDK 候选路径" >&2
fi

exit 1
