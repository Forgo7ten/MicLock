# 构建系统详解

MicLock 不用 Xcode 工程与 SPM，构建链由 shell 脚本 + Makefile 组成。本文解释每一步做什么、为什么这样做。

## 环境要求

- **运行目标**：macOS 14.0 及以上。Observation 框架的 `@Observable` 属性观测要求 macOS 14；编译目标（`-target …-apple-macos14.0`）与 Info.plist 的 `LSMinimumSystemVersion` 一致为 14.0
- **构建机**：需要 Swift 6 工具链 + 能通过 `Scripts/select-sdk.sh` typecheck 探针的 macOS 15.x / 26.x SDK + Command Line Tools（codesign / plutil / iconutil）。优先使用当前 Xcode 的默认 SDK，再尝试兼容的回退 SDK
- **Bundle Identifier**：固定为 `lee.miclock.app`

## 工具链与 SDK

两个探测脚本构成构建链的地基：

| 脚本 | 职责 | 覆盖方式 |
|---|---|---|
| `Scripts/select-toolchain.sh` | 从 `/Library/Developer/Toolchains/` 与 `~/Library/Developer/Toolchains/` 中选版本号最新的 `.xctoolchain`（剔除 `swift-latest` 符号链接防排序误选） | `MICLOCK_TOOLCHAIN=/path/to.xctoolchain` |
| `Scripts/select-sdk.sh` | 用所选工具链对候选 SDK 跑覆盖真实依赖面的 `-typecheck` 探针（`@Observable` 宏展开、`didSet`、`MenuBarExtra(.window)`、Settings Scene / `openSettings`、Activation Policy、CoreAudio 监听块、UserNotifications、ServiceManagement、OSLog 结构化日志插值），顺序：默认 SDK → 15.4 → 15 | 无（探测全自动） |

### 为什么需要 Swift 6 工具链

三个约束取交集：

1. `@Observable` 宏展开 → 编译器 ≥ 5.9
2. 本机没有 macOS 14 SDK，含 Observation 模块的最小可用 SDK 是 15.4 → 需要 ≥ 15.4 的 SDK
3. 15.4/26 SDK 的 `.swiftinterface` 使用 Swift 6 语法（typed throws 等）→ 编译器 ≥ 6.0

若 Command Line Tools 自带的 swiftc 较旧（如 5.8.1），从 swift.org 安装独立工具链（装到 `/Library/Developer/Toolchains/`，不动系统默认编译器，脚本会自动发现）：

```zsh
curl -L -o /tmp/swift-toolchain.pkg \
    "https://download.swift.org/swift-6.3.1-release/xcode/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE-osx.pkg"
sudo installer -pkg /tmp/swift-toolchain.pkg -target /
```

注意：本机构建固定使用 `-swift-version 6`（严格并发语言模式），但源码本身是 Swift 5 方言兼容写法——语言模式与编译器版本是两回事。

## 构建流程（build.sh）

```text
plutil -lint Info.plist            ← 校验 plist 语法
  → select-toolchain.sh            ← 选 Swift 6 工具链
  → select-sdk.sh                  ← 探测可用 SDK
  → swiftc -O -swift-version 6     ← 编译 Sources/（App + Core + Services）
     -target …-macos14.0           ← 与 LSMinimumSystemVersion 一致
     -framework SwiftUI/AppKit/CoreAudio/UserNotifications/ServiceManagement
  → cp Resources/AppIcon.icns      ← 图标进 bundle
  → cp Resources/MenuBarIconTemplate.svg ← 菜单栏 template image 进 bundle
  → codesign --sign - --options runtime   ← ad-hoc + Hardened Runtime
→ build/MicLock.app
```

注意：Observation 是 swift module 不是链接框架，`-framework Observation` 会导致 `ld: framework not found`——`import Observation` 即可，无需显式链接。

`build.sh` 默认构建当前 Mac 的架构；可用 `MICLOCK_ARCH=arm64` 或 `MICLOCK_ARCH=x86_64` 指定最终 App 的目标架构。构建期间需要立即运行的 `genicon` 始终按宿主架构编译，因此交叉编译不依赖宿主运行目标架构程序。Release workflow 会在对应架构的 GitHub macOS runner 上分别构建和打包两个 App。

## 单元测试（Tests/run.sh）

与 App 相同的 Core/Services 源 + Tests/ 一起编译（不含 App 的 `@main`），产出独立可执行文件直跑。Fake 注入模拟 CoreAudio 与通知，不依赖真实音频设备；断言失败以非零退出码结束。

`make test` 同时是 Core/Services 的 Swift 6 编译门禁：包括 OSLog 结构化消息构造在内的编译错误会在测试运行前直接失败。相关写法约束见[架构文档的 OSLog 日志构造约束](architecture.md#oslog-日志构造约束)。

## App 图标

设计源为 `Resources/AppIcon.svg`（入库）；`Resources/AppIcon.icns` 是**生成产物，不入库**（.gitignore 忽略）。`Scripts/genicon.swift` 用 NSImage 直载 SVG（AppKit 内建 CoreSVG 渲染，macOS 11+）输出标准 iconset 的全部 10 个尺寸，`iconutil -c icns` 打包。qlmanage 也能渲染 SVG 但四角无透明，不能替代。

**构建自举**：`build.sh` 检测到 icns 缺失时自动编译 genicon 并从 SVG 现生成——全新 clone 直接 `make build` 即可，无需手动步骤。改了 SVG 后想强制再生：`rm Resources/AppIcon.icns && make build`，或单独执行 `make icon` 后重新构建；`make icon` 会自行创建所需的 `build/` 目录，因此在 `make clean` 后也可直接运行。Finder 显示旧图标是 LaunchServices 缓存，`killall Finder` 或注销重登刷新。

`Resources/MenuBarIconTemplate.svg` 作为原始矢量资源直接复制到 App bundle。运行时以 `NSImage` 加载并设置 `isTemplate = true`，由 macOS 自动适配浅色、深色和选中状态；保护关闭时图标透明度降低。

## Makefile 快捷命令

| 命令 | 作用 |
|---|---|
| `make` | 测试 + 构建（等价于 `make all`） |
| `make build` | 构建 `build/MicLock.app` |
| `make test` | 编译并运行单元测试 |
| `make icon` | 从 SVG 重新生成 `Resources/AppIcon.icns`（可独立执行） |
| `make run` | 构建并启动（`open`） |
| `make debug` | `MICLOCK_DEBUG=1` 前台运行，决策日志到终端 |
| `make install` | 停止运行中的实例 → ditto 到 `/Applications` → 启动 |
| `make clean` | 删除 `build/` 产物 |
| `make all` | test + build（build 过程中会自动检查并生成缺失的 `AppIcon.icns`） |

## 安装路径与登录项

「登录时启动」（SMAppService）要求 App 位于稳定路径（`/Applications` 或 `~/Applications`）；从临时构建目录 `open` 的实例注册会被系统拒绝。`make install` 已处理停止旧实例、覆盖安装、重新启动。`/Applications` 通常 admin 组可直接写入；仅当旧 `.app` 属主为 root（如 pkg 安装）时需 `sudo make install`。
