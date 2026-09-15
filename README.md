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
  - **自动**：保护窗口内阻止系统抢麦；窗口外观察到新的默认输入变化时，持续稳定一段时间后接受为新的首选；默认输入持续为空且首选仍在线时恢复首选
  - **手动**：严格锁定首选麦克风，任何来源的外部切换都会被立即恢复
- CoreAudio 正常路径由事件驱动；仅在监听安装失败、采样失败或程序化切换未确认时使用有限/退避恢复，不进行常驻轮询
- 设备 Device UID 持久化，跨插拔稳定；首选设备离线时保留等待重连
- 最近事件：展示已经确认生效的用户选择、Auto 接受与恢复动作，并说明每次自动决策的原因
- 恢复通知开启时，已经确认的麦克风恢复动作可发送本地通知；Manual 模式恢复通知最多 10 秒一条（恢复动作本身不降频）。CoreAudio 监听连续安装失败进入终态时，会独立进行系统通知授权检查，并在系统允许时最多提交一条故障通知；该可靠性告警不受「显示通知」开关控制。系统授权被拒时在设置中引导开启
- 登录时启动（SMAppService，设置 → 通用）
- 无第三方依赖、无网络、不录音、无 root

详细文档见 [docs/](docs/)：

- [build.md](docs/build.md) —— 构建系统：工具链/SDK 探测、Swift 6 要求、图标生成、Makefile、安装路径
- [architecture.md](docs/architecture.md) —— 模块结构、事件流、恢复路径、通知、登录项、配置、调试、测试
- [auto-mode.md](docs/auto-mode.md) —— Auto 模式判定原理、保护/候选窗口、写入确认、重试与已知限制
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
| `make install` | 构建 → 覆盖安装到 `/Applications` → 启动（不要使用 sudo） |
| `make clean` | 清理构建产物 |

若 `/Applications` 不可写，可使用 `make install INSTALL_DIR="$HOME/Applications"` 安装到用户应用目录。`make install` 会先把新 `.app` 完整复制到安装目录内的临时位置，再替换旧 bundle；不要使用 `sudo make install`。

通知开关开启时，正常启动并成功建立 CoreAudio 监听后约 0.5 秒请求通知权限；若监听连续安装失败进入终态，则会为故障通知立即做一次 fresh authorization check。被拒绝时设置窗口（通用 → 通知）会显示提示行并可一键跳转系统设置。

更多调试手段（`MICLOCK_TRACE_PATH` 决策流文件、OSLog）见 [docs/architecture.md](docs/architecture.md)。

## 数据存储

Bundle Identifier：`lee.miclock.app`

UserDefaults（`lee.miclock.app` 域）：

| 键 | 含义 |
|---|---|
| `preferredMicrophoneUID` | 首选麦克风 Device UID |
| `protectionEnabled` | 是否启用保护 |
| `protectionMode` | `auto` / `manual` |
| `notificationsEnabled` | 是否显示普通麦克风恢复通知；不影响 CoreAudio 监听终态故障可靠性告警 |
| `settleSeconds` | 设备稳定窗口（1–30s，默认 2） |
| `lastKnownDeviceNames` | 设备 UID → 最近已知名称（离线设备仍显示可读名） |

登录项状态由 `SMAppService` 管理，不做本地持久化。

## 隐私与安全

无网络访问、无 telemetry、无自动更新、无第三方依赖、无 shell 执行、无 root/sudo、无辅助功能权限、无录音。仅操作 CoreAudio 的 `DefaultInputDevice` 属性，绝不触碰任何输出设备。

## 参考

[MicGuard](https://github.com/pszypowicz/MicGuard)
