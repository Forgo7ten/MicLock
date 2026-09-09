#!/bin/zsh

# 构建 MicLock.app（只构建，不运行测试；单元测试见 Tests/run.sh）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

BUILD_DIR="${ROOT}/build"

APP="${BUILD_DIR}/MicLock.app"

CONTENTS="${APP}/Contents"

MACOS="${CONTENTS}/MacOS"

RESOURCES="${CONTENTS}/Resources"

HOST_ARCH="$(uname -m)"
TARGET_ARCH="${MICLOCK_ARCH:-${HOST_ARCH}}"

case "${TARGET_ARCH}" in
    arm64|x86_64) ;;
    *)
        echo "error: 不支持的目标架构: ${TARGET_ARCH}（仅支持 arm64 / x86_64）" >&2
        exit 1
        ;;
esac

echo "[*] Cleaning..."

rm -rf "${APP}"

mkdir -p "${MACOS}" "${RESOURCES}"

echo "[*] Checking Info.plist..."

plutil -lint "${ROOT}/Info.plist"

cp "${ROOT}/Info.plist" \
    "${CONTENTS}/Info.plist"

echo "[*] Selecting Swift toolchain..."

TOOLCHAIN="$("${ROOT}/Scripts/select-toolchain.sh")"

echo "    ${TOOLCHAIN}"

SWIFT="${TOOLCHAIN}/usr/bin/swiftc"

echo "[*] Selecting a usable macOS SDK..."

SDK="$("${ROOT}/Scripts/select-sdk.sh")"

echo "    ${SDK}"

# App 图标（icns 不入库，缺失时从 SVG 现生成，见 Scripts/genicon.swift）
if [[ ! -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    echo "[*] Generating AppIcon.icns from SVG..."

    "${SWIFT}" \
        -O \
        -swift-version 6 \
        -sdk "${SDK}" \
        -target "${HOST_ARCH}-apple-macos14.0" \
        "${ROOT}/Scripts/genicon.swift" \
        -o "${BUILD_DIR}/genicon"

    "${BUILD_DIR}/genicon" "${BUILD_DIR}/AppIcon.iconset" "${ROOT}/Resources/AppIcon.svg"

    iconutil -c icns "${BUILD_DIR}/AppIcon.iconset" \
        -o "${ROOT}/Resources/AppIcon.icns"

    rm -f "${BUILD_DIR}/genicon"
    rm -rf "${BUILD_DIR}/AppIcon.iconset"
fi

cp "${ROOT}/Resources/AppIcon.icns" \
    "${RESOURCES}/AppIcon.icns"

cp "${ROOT}/Resources/MenuBarIconTemplate.svg" \
    "${RESOURCES}/MenuBarIconTemplate.svg"

echo "[*] Building MicLock..."

# 与 Info.plist 的 LSMinimumSystemVersion 保持一致：最低 macOS 14.0
# （Observation 框架的 @Observable 需要 14.0）。
"${SWIFT}" \
    -O \
    -swift-version 6 \
    -sdk "${SDK}" \
    -target "${TARGET_ARCH}-apple-macos14.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreAudio \
    -framework UserNotifications \
    -framework ServiceManagement \
    "${ROOT}"/Sources/*.swift \
    "${ROOT}"/Sources/Core/*.swift \
    "${ROOT}"/Sources/Services/*.swift \
    -o "${MACOS}/MicLock"

echo "[*] Ad-hoc signing (Hardened Runtime)..."

codesign \
    --force \
    --sign - \
    --options runtime \
    "${APP}"

echo
echo "[+] Build complete:"
echo
echo "    ${APP}"
echo
echo "[+] Run:"
echo
echo "    open \"${APP}\""
