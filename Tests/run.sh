#!/bin/zsh

# 构建并运行 MicLock 单元测试。
#
# 与 App 相同的 Core/Services 源一起编译（不含 MicLockApp 的 @main 入口），
# 注入 FakeAudioDeviceProvider / RecordingNotifier 模拟 CoreAudio 与通知，
# 直接调用 handleDefaultInputChanged() / handleDeviceListChanged() 模拟事件。
# 测试失败时以非零退出码结束。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BUILD_DIR="${ROOT}/build"

TEST_BIN="${BUILD_DIR}/MicLockTests"

ARCH="$(uname -m)"

echo "[*] Selecting Swift toolchain..."

TOOLCHAIN="$("${ROOT}/Scripts/select-toolchain.sh")"

echo "    ${TOOLCHAIN}"

SWIFT="${TOOLCHAIN}/usr/bin/swiftc"

echo "[*] Selecting a usable macOS SDK..."

SDK="$("${ROOT}/Scripts/select-sdk.sh")"

echo "    ${SDK}"

echo "[*] Building unit tests..."

mkdir -p "${BUILD_DIR}"

rm -f "${TEST_BIN}"

"${SWIFT}" \
    -O \
    -swift-version 6 \
    -sdk "${SDK}" \
    -target "${ARCH}-apple-macos14.0" \
    -framework CoreAudio \
    -framework UserNotifications \
    -framework ServiceManagement \
    "${ROOT}"/Sources/Core/*.swift \
    "${ROOT}"/Sources/Services/*.swift \
    "${ROOT}"/Tests/*.swift \
    -o "${TEST_BIN}"

echo "[*] Running unit tests..."
echo

"${TEST_BIN}"

echo
echo "[+] All tests passed."
