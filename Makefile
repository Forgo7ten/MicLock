# MicLock 构建快捷命令（详解见 docs/build.md）

ROOT := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

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
	@echo "  make install  停止旧实例 → 安装到 /Applications → 启动"
	@echo "  make clean    清理构建产物"
	@echo
	@echo "详见 docs/build.md"

build:
	./build.sh

test:
	./Tests/run.sh

# 从 Resources/AppIcon.svg 重新生成 Resources/AppIcon.icns
icon:
	@TOOLCHAIN="$$( $(ROOT)Scripts/select-toolchain.sh )"; \
	SDK="$$( $(ROOT)Scripts/select-sdk.sh )"; \
	"$$TOOLCHAIN/usr/bin/swiftc" -O -swift-version 6 \
		-sdk "$$SDK" -target "$$(uname -m)-apple-macos14.0" \
		$(ROOT)Scripts/genicon.swift -o build/genicon && \
	./build/genicon /tmp/AppIcon.iconset Resources/AppIcon.svg && \
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns && \
	rm -f build/genicon && \
	echo "[+] Resources/AppIcon.icns 已更新（重新 build 生效）"

run: build
	open "$(APP)"

debug: build
	MICLOCK_DEBUG=1 ./$(APP)/Contents/MacOS/MicLock

# 停止旧实例 → 注销 build/ 残留注册 → 覆盖安装到 /Applications → 启动
# build/ 注册项残留会让通知系统解析到无图标的旧 bundle（同 bundle ID），故每次注销。
# /Applications 通常 admin 组可直接写入；仅当旧 .app 属主为 root（如 pkg 安装）时需 sudo make install。
install:
	@pgrep -x MicLock >/dev/null && { pkill -x MicLock; sleep 2; } || true
	@LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; \
	if [ -d "$(APP)" ]; then "$$LSREG" -u "$(APP)" 2>/dev/null || true; fi
	rm -rf "$(INSTALL_DIR)/MicLock.app"
	ditto "$(APP)" "$(INSTALL_DIR)/MicLock.app"
	open "$(INSTALL_DIR)/MicLock.app"
	@sleep 3; pgrep -x MicLock >/dev/null && echo "[+] 已安装并运行: $(INSTALL_DIR)/MicLock.app" \
		|| { echo "[!] 启动失败，检查 Console"; exit 1; }

clean:
	rm -rf build
