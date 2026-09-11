<div align="center">
  <img src="Resources/AppIcon.svg" alt="MicLock 图标" width="160">
  <h1>MicLock</h1>
  <p>轻量的 macOS 菜单栏音频输入设备保护工具</p>
  <p>防止 AirPods、USB 声卡和会议软件的虚拟设备悄悄抢占系统默认麦克风。</p>
</div>

MicLock 监听 macOS 的 CoreAudio 设备变化，在不录音、不联网的前提下，帮助你稳定控制系统默认输入设备。它适合经常切换耳机、麦克风、声卡或会议软件虚拟音频设备的场景。

## 功能

- 自定义模板图标常驻菜单栏，左键或右键均可打开面板；平时无 Dock 图标，打开设置窗口时临时显示 Dock 图标，关闭后恢复，防双开
- 菜单栏面板只保留高频操作（保护开关、模式、首选麦克风）；「设置…」打开独立设置窗口（通用 / 高级 / 关于）
- 两种保护模式：
  - **自动**：设备接入的不稳定窗口内阻止系统抢麦；设备稳定后，你主动切换的麦克风会自动成为新的首选
  - **手动**：严格锁定首选麦克风，任何来源的外部切换都会被立即恢复
- CoreAudio 事件驱动，无轮询
- 设备 Device UID 持久化，跨插拔稳定；首选设备离线时保留等待重连
- 恢复时发送本地通知（首次启动自动请求授权，被拒时在设置中引导开启）
- 登录时启动（SMAppService，设置 → 通用）
- 无第三方依赖、无网络、不录音、无 root

详细文档见 [docs/](docs/)：

- [build.md](docs/build.md) —— 构建系统：工具链/SDK 探测、Swift 6 要求、图标生成、Makefile、安装路径
- [architecture.md](docs/architecture.md) —— 模块结构、事件流、恢复路径、通知、登录项、配置、调试、测试
- [auto-mode.md](docs/auto-mode.md) —— Auto 模式判定原理、settle 窗口、时序示例、已知限制
- [releasing.md](docs/releasing.md) —— GitHub 网页发版、tag/版本规则与 Release 产物

## 系统要求

- **macOS 14.0 及以上**（运行）
- 构建机：Swift 6 工具链 + Command Line Tools。工具链安装与原理见 [docs/build.md](docs/build.md#为什么需要-swift-6-工具链)

## 安装

### Homebrew（推荐）

```zsh
brew install --cask Forgo7ten/tap/miclock
```

安装完成后可直接从“应用程序”或 Spotlight 启动 MicLock。

### GitHub Releases

也可以从 [GitHub Releases](https://github.com/Forgo7ten/MicLock/releases)
直接下载对应架构的 ZIP：

- Apple Silicon：`MicLock-vX.Y.Z-arm64.zip`
- Intel：`MicLock-vX.Y.Z-x86_64.zip`

解压后将 `MicLock.app` 移动到 `/Applications` 或 `~/Applications`，
然后启动应用。

## 从源码构建

如果需要参与开发或自行构建：

```zsh
git clone https://github.com/Forgo7ten/MicLock.git
cd MicLock

make            # 测试 + 构建
make install    # 安装到 /Applications 并启动
```

常用命令：

| 命令 | 作用 |
|---|---|
| `make build` | 构建 `build/MicLock.app` |
| `make test` | 编译并运行单元测试 |
| `make icon` | 从 `Resources/AppIcon.svg` 重新生成 icns |
| `make run` | 构建并启动 |
| `make debug` | `MICLOCK_DEBUG=1` 前台运行，决策日志到终端 |
| `make install` | 停止旧实例 → 安装到 /Applications → 启动 |
| `make clean` | 清理构建产物 |

首次启动约 0.5 秒后请求通知权限，允许即可；被拒绝时设置窗口（通用 → 通知）会显示提示行并可一键跳转系统设置。

更多调试手段（`MICLOCK_TRACE_PATH` 决策流文件、OSLog）见 [docs/architecture.md](docs/architecture.md#调试)。

## 数据存储

Bundle Identifier：`lee.miclock.app`

UserDefaults（`lee.miclock.app` 域）：

| 键 | 含义 |
|---|---|
| `preferredMicrophoneUID` | 首选麦克风 Device UID |
| `protectionEnabled` | 是否启用保护 |
| `protectionMode` | `auto` / `manual` |
| `notificationsEnabled` | 恢复时是否显示通知 |
| `settleSeconds` | 设备稳定窗口（1–30s，默认 2） |
| `lastKnownDeviceNames` | 设备 UID → 最近已知名称（离线设备仍显示可读名） |

登录项状态由 `SMAppService` 管理，不做本地持久化。

## 隐私与安全

无网络访问、无 telemetry、无自动更新、无第三方依赖、无 shell 执行、无 root/sudo、无辅助功能权限、无录音。仅操作 CoreAudio 的 `DefaultInputDevice` 属性，绝不触碰任何输出设备。

## 参考

[MicGuard](https://github.com/pszypowicz/MicGuard)
