#!/usr/bin/env bash

# 选择用于编译的 Swift 6+ 工具链根目录，把路径输出到 stdout。
# 供 build.sh 与 Tests/run.sh 共用。
#
# 优先级：
# 1. MICLOCK_TOOLCHAIN 显式覆盖
# 2. xcrun 当前选中的 swiftc
# 3. /Library 与 ~/Library 下可用的独立 .xctoolchain，按真实 swiftc 版本选择
#
# 不再按目录名排序：目录名不保证等于编译器版本，也避免依赖 macOS sort 是否支持 -V。

set -euo pipefail

version_major=0
version_minor=0
version_patch=0

usable() {
    local root="$1"
    local text

    [[ -n "$root" && -x "$root/usr/bin/swiftc" ]] || return 1
    text="$("$root/usr/bin/swiftc" --version 2>/dev/null)" || return 1

    if [[ "$text" =~ [Vv]ersion[[:space:]]+([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
        version_major="${BASH_REMATCH[1]}"
        version_minor="${BASH_REMATCH[2]}"
        version_patch="${BASH_REMATCH[4]:-0}"
        (( version_major >= 6 ))
    else
        return 1
    fi
}

if [[ -n "${MICLOCK_TOOLCHAIN:-}" ]]; then
    usable "$MICLOCK_TOOLCHAIN" || {
        echo "error: MICLOCK_TOOLCHAIN 必须包含可用的 Swift 6+ usr/bin/swiftc: $MICLOCK_TOOLCHAIN" >&2
        exit 1
    }
    printf '%s\n' "$MICLOCK_TOOLCHAIN"
    exit 0
fi

compiler="$(xcrun --find swiftc 2>/dev/null || true)"
if [[ "$compiler" == */usr/bin/swiftc ]]; then
    selected="${compiler%/usr/bin/swiftc}"
    if usable "$selected"; then
        printf '%s\n' "$selected"
        exit 0
    fi
fi

shopt -s nullglob
best=""
best_major=0
best_minor=0
best_patch=0

for candidate in \
    /Library/Developer/Toolchains/*.xctoolchain \
    "$HOME"/Library/Developer/Toolchains/*.xctoolchain; do
    [[ "$candidate" != */swift-latest.xctoolchain ]] || continue
    usable "$candidate" || continue

    if (( version_major > best_major ||
          (version_major == best_major && version_minor > best_minor) ||
          (version_major == best_major && version_minor == best_minor && version_patch > best_patch) )); then
        best="$candidate"
        best_major="$version_major"
        best_minor="$version_minor"
        best_patch="$version_patch"
    fi
done

[[ -n "$best" ]] || {
    echo "error: 未找到可用的 Swift 6+ 编译器。请选择合适的 Xcode，或设置 MICLOCK_TOOLCHAIN；详见 docs/build.md。" >&2
    exit 1
}

printf '%s\n' "$best"
