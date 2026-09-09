#!/bin/zsh

# 选择用于编译的 Swift 工具链，把 .xctoolchain 目录输出到 stdout。
# 供 build.sh 与 Tests/run.sh 共用。
#
# 背景：本机 Command Line Tools 的 swiftc 是 5.8.1，无法解析新版 SDK
# （15/26+）里使用 Swift 6 语法的 swiftinterface，也缺少 @Observable 宏。
# 从 swift.org 安装的 Swift 6 工具链位于 /Library/Developer/Toolchains/
# （安装命令见 README），CLT 保持原样不动——脚本显式调用工具链内的 swiftc，
# 不改变系统默认编译器。
#
# 优先级：MICLOCK_TOOLCHAIN 环境变量 > 系统目录与用户目录中版本号最新的工具链。

set -euo pipefail

if [[ -n "${MICLOCK_TOOLCHAIN:-}" ]]; then
    [[ -d "${MICLOCK_TOOLCHAIN}" ]] || {
        echo "error: MICLOCK_TOOLCHAIN 不存在: ${MICLOCK_TOOLCHAIN}" >&2
        exit 1
    }
    echo "${MICLOCK_TOOLCHAIN}"
    exit 0
fi

CANDIDATES=()

for DIR in \
    /Library/Developer/Toolchains \
    "${HOME}/Library/Developer/Toolchains"; do
    [[ -d "${DIR}" ]] || continue
    for TOOLCHAIN in "${DIR}"/*.xctoolchain; do
        [[ -d "${TOOLCHAIN}" ]] && CANDIDATES+=("${TOOLCHAIN}")
    done
done

# swift-latest 是 swift.org 安装器创建的符号链接，版本号排序会把它排到
# 任意真实版本前面/后面造成误选，剔除后只比真实版本号。
CANDIDATES=("${(@)CANDIDATES:#*swift-latest.xctoolchain}")

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "error: 未找到 Swift 6+ 工具链。安装方法见 README（系统要求一节）。" >&2
    exit 1
fi

echo "${CANDIDATES[@]}" | tr ' ' '\n' | sort -rV | head -1
