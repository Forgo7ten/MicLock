# MicLock 构建快捷命令（详解见 docs/build.md）

# GNU make 的 firstword 会把带空格的 Makefile 路径拆开；这里明确要求从仓库根目录
# 调用，或使用 make -C /path/to/MicLock，因此 CURDIR 可以安全保留路径中的空格。
ROOT := $(CURDIR)/

APP := $(ROOT)build/MicLock.app
INSTALL_DIR := /Applications

.PHONY: all help build test icon run debug install clean

# 默认：测试 + 构建
all: test build

help:
	@echo "MicLock 构建命令："
	@echo
	@echo "  make          测试 + 构建（等价 make all）"
	@echo "  make build    构建 build/MicLock.app"
	@echo "  make test     编译并运行单元测试"
	@echo "  make icon     从 Resources/AppIcon.svg 重新生成 icns"
	@echo "  make run      构建并启动"
	@echo "  make debug    MICLOCK_DEBUG=1 前台运行，决策日志到终端"
	@echo "  make install  构建 → 覆盖安装到 /Applications → 启动（不要 sudo）"
	@echo "  make clean    清理构建产物"
	@echo
	@echo "详见 docs/build.md"

build:
	./build.sh

test:
	./Tests/run.sh

# 从 Resources/AppIcon.svg 重新生成 Resources/AppIcon.icns。
# 使用 build/ 下独立临时目录，避免多个 checkout 共享 /tmp/AppIcon.iconset。
icon:
	mkdir -p "$(ROOT)build"
	@set -eu; \
	TOOLCHAIN="$$( "$(ROOT)Scripts/select-toolchain.sh" )"; \
	SDK="$$( "$(ROOT)Scripts/select-sdk.sh" )"; \
	TEMP="$$(mktemp -d "$(ROOT)build/icon.XXXXXX")"; \
	trap 'rm -rf "$$TEMP"' EXIT; \
	"$$TOOLCHAIN/usr/bin/swiftc" -O -swift-version 6 \
		-sdk "$$SDK" -target "$$(uname -m)-apple-macos14.0" \
		"$(ROOT)Scripts/genicon.swift" -o "$$TEMP/genicon"; \
	"$$TEMP/genicon" "$$TEMP/AppIcon.iconset" "$(ROOT)Resources/AppIcon.svg"; \
	iconutil -c icns "$$TEMP/AppIcon.iconset" -o "$(ROOT)Resources/AppIcon.icns"; \
	echo "[+] Resources/AppIcon.icns 已更新（重新 build 生效）"

run: build
	open "$(APP)"

debug: build
	MICLOCK_DEBUG=1 "$(APP)/Contents/MacOS/MicLock"

# make install 只负责把已经成功构建的 .app 覆盖到稳定安装路径。
# 先完整复制到 INSTALL_DIR 内的临时目录，复制成功后再替换旧 bundle，避免 copy
# 失败时先删掉当前可用版本。GUI 进程只操作当前用户，禁止 sudo/root 执行。
install:
	@if [ "$$(id -u)" = 0 ]; then \
		echo "error: 不要使用 sudo make install；权限不足时使用 INSTALL_DIR=\"$$HOME/Applications\"" >&2; \
		exit 1; \
	fi
	@$(MAKE) build
	@set -eu; \
	USER_ID="$$(id -u)"; \
	DST="$(INSTALL_DIR)/MicLock.app"; \
	mkdir -p "$(INSTALL_DIR)"; \
	STAGE="$$(mktemp -d "$(INSTALL_DIR)/.MicLock-install.XXXXXX")"; \
	trap 'rm -rf "$$STAGE"' EXIT; \
	ditto "$(APP)" "$$STAGE/MicLock.app"; \
	if pgrep -u "$$USER_ID" -x MicLock >/dev/null; then \
		pkill -u "$$USER_ID" -x MicLock; \
		sleep 1; \
		if pgrep -u "$$USER_ID" -x MicLock >/dev/null; then \
			echo "error: MicLock 仍在运行，未覆盖已安装的应用" >&2; \
			exit 1; \
		fi; \
	fi; \
	LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; \
	if [ -x "$$LSREG" ]; then "$$LSREG" -u "$(APP)" 2>/dev/null || true; fi; \
	rm -rf "$$DST"; \
	mv "$$STAGE/MicLock.app" "$$DST"; \
	open "$$DST"; \
	echo "[+] 已安装并请求启动: $$DST"

clean:
	rm -rf build
