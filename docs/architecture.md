# MicLock 架构与实现

MicLock 只做一件事：守住系统默认输入设备（CoreAudio 的 `kAudioHardwarePropertyDefaultInputDevice`），不让新接入的设备悄悄抢占。本文介绍模块结构、事件流、恢复路径、通知、登录项、配置、调试与测试；Auto 模式的判定细节见 [auto-mode.md](auto-mode.md)。

## 设计原则

- **事件驱动为主**：正常 CoreAudio 决策由 Devices / DefaultInput 回调唤醒，不做常驻周期性 enforce；仅在采样失败或程序化切换尚未确认时使用有界退避的主动 re-read / retry，另外用 Task 承载 settle 窗口、Settings 诊断、通知授权延迟和系统服务状态收敛复核（见 [auto-mode.md](auto-mode.md)）
- **分层可测**：CoreAudio 访问封装在 `AudioDeviceProviding` 协议后面，策略层（AudioMonitor）只依赖协议；单元测试注入内存 Fake
- **单写入口**：所有恢复统一走 `restorePreferred(from:to:reason:)`，唯一的写入目标始终是 `DefaultInputDevice`，绝不触碰任何输出设备
- **零依赖**：仅使用系统框架（SwiftUI / AppKit / CoreAudio / UserNotifications / ServiceManagement / OSLog / Observation）

## 模块结构

```mermaid
flowchart TD
    subgraph UI["菜单栏与设置（SwiftUI Scene 层）"]
        APP["MenuBarExtra(.window) / MenuBarView（高频操作）"]
        SET["Settings Scene / SettingsView（低频配置 + 关于）"]
    end
    subgraph CORE["Sources/Core — 策略层"]
        AM["AudioMonitor（@MainActor 状态机）"]
        LB["ListenerBox（CoreAudio 属性监听）"]
        PR["Preferences（UserDefaults）"]
        PROV["AudioDeviceProviding 协议"]
        LIVE["LiveAudioDeviceProvider"]
    end
    subgraph SERVICES["Sources/Services"]
        NM["NotificationManager（NotificationPresenting 实现）"]
        LM["LaunchAtLoginManager（SMAppService）"]
    end
    subgraph TESTS["Tests/ — 仅测试时编译"]
        FAKE["FakeAudioDeviceProvider / RecordingNotifier"]
    end

    APP -->|"@Bindable 观测"| AM
    SET -->|"@Bindable 观测"| AM
    SET -->|"登录项开关"| LM
    AM -->|"读写配置"| PR
    AM -->|"枚举 / 读写默认输入"| PROV
    AM -->|"恢复通知"| NM
    AM -->|"安装 / 卸载监听"| LB
    LB -->|"事件回调（主队列）"| AM
    PROV -.->|"真实实现"| LIVE
    PROV -.->|"测试注入"| FAKE
    LIVE -->|"AudioObject C API"| HAL["CoreAudio HAL"]
```

| 文件 | 职责 |
|---|---|
| `Sources/MicLockApp.swift` | SwiftUI App 入口：`MenuBarExtra(.window)`（高频操作，左/右键共用）与 `Settings` Scene 两个 Scene；`MicLockAppDelegate` 负责启动时序、label 状态镜像与右键事件桥接 |
| `Sources/ActivationPolicyManager.swift` | 动态 Activation Policy：平时 `.accessory` 常驻菜单栏，打开普通窗口（Settings）时临时 `.regular`（有 Dock / 顶部 App Menu），demand 全部结束后切回。窗口 identity 与 regular demand 两个正交状态：identity（weak，close 后保留）识别复用的 NSWindow；demand 由用户意图与 `willCloseNotification` 驱动 policy。无基于超时的降级——`openSettings()` 没有 success/failure 回调，窗口物化耗时（实测 ~2–3s）不能推断 Scene 生命周期 |
| `Sources/SettingsView.swift` | 设置窗口：通用（登录项 / 通知）/ 高级（设备稳定窗口）/ 关于（`AboutView`）三个 Tab；`WindowAccessor` bridge 把底层 NSWindow 注册给 ActivationPolicyManager |
| `Sources/AboutView.swift` | 设置窗口「关于」Tab 内容：图标、动态版本/构建号、说明与 GitHub / License 链接 |
| `Sources/Core/AudioMonitor.swift` | 核心策略协调器：事件处理、Auto 稳定性状态机、程序化切换事务、恢复、Recent Events、通知编排与调试 trace；UI 可见状态以 `@Observable` 暴露，内部状态 `@ObservationIgnored` |
| `Sources/Core/LiveAudioDeviceProvider.swift` | CoreAudio HAL 封装：设备枚举、UID/名称/传输类型查询、默认输入读写 |
| `Sources/Core/AudioDeviceProviding.swift` | CoreAudio 访问抽象协议（测试注入点） |
| `Sources/Core/AudioInputDevice.swift` | 设备模型 |
| `Sources/Core/Preferences.swift` | UserDefaults 封装 |
| `Sources/Core/ProtectionMode.swift` | `auto` / `manual`、`RestoreReason` 与 `RecentAudioEvent` 模型及展示文案 |
| `Sources/Core/NotificationPresenting.swift` | 通知抽象协议（测试注入点） |
| `Sources/Services/NotificationManager.swift` | UserNotifications 授权管理与横幅投递 |
| `Sources/Services/LaunchAtLoginManager.swift` | SMAppService 登录项 |
| `Scripts/select-toolchain.sh` | Swift 工具链发现（系统/用户目录中最新，可用 `MICLOCK_TOOLCHAIN` 覆盖） |
| `Scripts/select-sdk.sh` | 用所选工具链探测可用 macOS SDK（构建与测试共用） |
| `Scripts/genicon.swift` | App 图标生成器（绘制 `Resources/AppIcon.svg` 的同源几何，产出 iconset 后经 `iconutil -c icns` 打包） |
| `Resources/AppIcon.svg` | App 图标设计源（卡通麦克风）；`Resources/AppIcon.icns` 为构建产物 |
| `Resources/MenuBarIconTemplate.svg` | 菜单栏单色 template image，运行时由 macOS 着色 |
| `Tests/` | 单元测试源码与 `run.sh` 测试脚本 |

## 设备标识：UID 而不是 AudioDeviceID

CoreAudio 的 `AudioDeviceID` 是运行时数值，重启或重插后会变；`kAudioDevicePropertyDeviceUID`（如 `BuiltInMicrophoneDevice`）在系统中长期稳定。因此：

- 持久化与协议边界上一律使用 **UID**（`preferredMicrophoneUID`）
- `deviceID` 仅在单次运行的 CoreAudio 操作中解析使用，绝不落盘
- 「内置麦克风」只按 `TransportType == kAudioDeviceTransportTypeBuiltIn` 判断，不按名字猜测

首选设备离线时：保留 UID 等待重连，不学习系统临时 fallback 的设备，菜单显示「⚠ 未连接」。

## 事件流

两个监听都注册在 CoreAudio 系统对象（`kAudioObjectSystemObject`）上，回调投递到主队列，再经 `Task { @MainActor … }` 进入状态机——决策全程在主 actor 串行执行，无需加锁：

| 属性 | 处理 |
|---|---|
| `kAudioHardwarePropertyDevices`（设备拓扑） | `handleDeviceListChanged()`：只作为 wake-up，进入统一 `reconcileCoreAudioState()` |
| `kAudioHardwarePropertyDefaultInputDevice`（默认输入） | `handleDefaultInputChanged()`：只作为 wake-up，进入统一 `reconcileCoreAudioState()` |

每次 reconcile 都重新读取默认输入并尝试枚举设备列表，但这不是 HAL 提供的原子 snapshot：DefaultInput 与 Devices 两个属性本身仍可能分阶段收敛。全局枚举失败、默认输入读取失败、单设备 input-stream/UID 关键查询失败，或 `current.uid` 不存在于本轮完整 devices 中时，都把这轮 topology sample 视为 inconclusive。单设备失败会返回 partial snapshot：`devices` 仍更新为本轮可读取的健康设备供 UI/诊断使用，但策略层保留上一份完整可信的 `trustedDevices / connectedUIDs`；读取 current 失败则保留最后一次可信 `currentDevice`。只有完整且与 current 一致的 sample 才能应用 topology delta、target-offline 和 Auto classification；失败路径通过独立 recovery retry 重新采样。

**stable external switch candidate**：Auto + stable 下的外部 default 变化不会立刻覆盖 preferred，而是建立 candidate。UI 的 `currentDevice` 立即更新；candidate 分类窗口复用 `settleSeconds`，若期间出现 topology delta 就取消；窗口结束时只有 target 仍存在于可信 `connectedUIDs` 且 current 未变化才学习新的 preferred。它只延迟 preferred 学习，不延迟 corrective restore；本质仍是时间启发式而非 HAL 原子性保证。

**self-induced 回声**：MicLock 自己 set `DefaultInputDevice` 同样会触发监听。现在用 `ProgrammaticSwitchState.awaitingConfirmation(PendingSwitch)` 原子保存 transaction ID、目标 UID、origin、待提交 Recent Event 与通知。程序化切换成功确认只消费**本次 fresh current observation**，绝不读取共享 `currentDevice` cache；因此 current read 失败时，即使缓存值恰好等于 target，也不能误确认。Protection Restore 是持续 invariant：若 current 仍是明确 source，watchdog 会按 500ms → 1s → 2s → 4s → 8s → 16s → 32s → 64s 重读并重试 setter，之后保持 64s capped interval 持续主动 retry。Trusted User Selection 则采用 **latest-wins + bounded lifetime**：新的 MicLock 点击立即 supersede 旧 Trusted transaction 并马上 `set(newTarget)`；active transaction 永远只代表最后一次明确选择。Trusted 不根据 source、第三状态或 callback 类型推断 writer provenance；首次未确认时 500ms 后只快速 retry 一次，再给 500ms 最终确认窗口，仍未确认就结束并交还正常 policy。

**Auto 稳定性**：`StabilityState` 与程序化切换事务正交存在，仅有 `stable` / `settling(SettleEpisode)` 两态。每个 episode 保存唯一 ID、revision、`lastActivity`、deadline 与通知去重状态；timer 醒来必须同时匹配 episode ID + revision + deadline 才能把状态变成 stable。详见 [auto-mode.md](auto-mode.md)。

```mermaid
sequenceDiagram
    participant HAL as CoreAudio HAL
    participant AM as AudioMonitor
    participant P as LiveAudioDeviceProvider
    participant N as NotificationManager

    HAL--)AM: Devices 或 DefaultInput 变化（主队列回调）
    AM->>P: currentInputDevice() + listInputDevices()
    AM->>AM: current 先推进确定事实；仅可信 topology 才应用 delta
    alt 存在 PendingSwitch
        AM->>AM: current==target 立即 confirm；可信 topology 才判 target offline；Protection 可长期 retry，Trusted 只短时 retry
    else 需要恢复（manual，或 auto=settling）
        AM->>AM: 建立 PendingSwitch transaction（source + target）
        AM->>P: setInputDevice(preferred UID)
        AM->>AM: 延长当前 settle episode / revision
        AM->>P: currentInputDevice()（确认真实结果）
        alt current == transaction.targetUID
            AM->>AM: 原子提交 Recent Event / notification
            AM->>N: presentRestored（episode ID 去重）
        else 状态仍未传播
            HAL--)AM: 等待后续 CoreAudio wake-up，不按固定时间宣告失败
        end
    else auto=stable
        AM->>AM: 建立 StableExternalSwitchCandidate
        alt 随后出现 topology delta
            AM->>AM: 取消 candidate，按 topology 事实处理
        else 分类窗口内 topology 不变且 current 未变
            AM->>AM: 确认 candidate，学习 preferred = current
        end
    end
```

## 启动顺序

1. 读取偏好 → 枚举设备 → 读取当前默认输入（`AudioMonitor.init`）
2. 首次运行且无 preferred：只使用可信 startup baseline 初始化，优先内置麦克风；没有内置设备时，仅当 current 也存在于该 topology 中才 fallback 到 current。若初始枚举/默认输入读取失败、返回 partial snapshot，或 `current ∉ devices`，暂不决定 preferred
3. App 完成启动后安装监听并执行启动对齐（`start()` → `evaluateStartupPolicy()`）：保护开启且 preferred 在线且 current ≠ preferred → 恢复（不通知）。若 init 阶段 topology/current 读取失败、快照不完整或联合快照不一致，则此时启动独立 startup recovery；第一份完整可信快照作为启动基线写入，并在运行 policy 前补全 fresh-install preferred，不把“空缓存 → 全量设备”误判为 topology added，再继续以 `.startup` 语义完成对齐
4. 通知已开启时，启动约 0.5 秒后检查（必要时请求）通知授权

授权请求必须放在 App 完成启动之后——App 构造阶段调用 `requestAuthorization` 会被系统静默忽略，弹窗根本不出现。

## 恢复路径（唯一入口）

Manual 抢麦恢复、Auto 抢麦恢复、重连恢复、启动对齐全部走 `restorePreferred(from:to:reason:)`：

1. 创建一笔 `PendingSwitch`，原子保存 transaction ID、source UID、目标 UID、`ProgrammaticSwitchOrigin`（`protectionRestore(reason)` / `trustedUserSelection`）、展示 metadata 与本次通知 draft；Recent Event kind 在确认时只从 origin 推导，避免双写语义失配
2. `provider.setInputDevice(preferred.uid)`——恢复路径统一只写 `DefaultInputDevice`；provider 以 `throws` 保留设备 lookup、CoreAudio 操作阶段与 `OSStatus`，上层日志不再把所有失败压成一个 Bool。用户在 MicLock 中主动选择设备时由 `selectDevice(_:)` 发起同类程序化事务
3. 用户在 MicLock 中主动选择设备前会 fresh-read current：若系统已经真实使用 target，则无需 setter，直接完成 Trusted User Action；若 target 同时已经是 preferred，则纯 no-op，不制造同设备 Recent Event。fresh read 失败时不能使用缓存 current 冒充成功事实，仍走正常 setter 路径
4. 用户选择所需 setter 立即失败时，该次 Trusted User Action 失败，不覆盖 preferred；Protection restore 的 setter 若抛错，则保留 transaction、显示 `Unable to set default input device; protection will keep retrying`，由 watchdog 继续退避重试，同时日志保留具体 provider error
5. Protection restore 的 setter 被接受：延长当前 settle episode，重新读取真实 `currentDevice`；Trusted User Selection 不制造 protection settle episode。若已经达到 target 则立即确认，否则保持 pending
6. Protection Restore 的 PendingSwitch watchdog 按 500ms → 1s → 2s → 4s → 8s → 16s → 32s → 64s 重读 current 并在需要时重试 setter；accepted retry 同样重新开启/延长 settle，并把“已经存在”的 Auto pending notification 重新绑定到当前 episode；不会凭空补造原本为 nil 的通知。完成前四档快速重试后显示 `protection is retrying`。Trusted User Selection 不共享这条永久生命周期：只在 500ms 做一次 fast retry，再等待 500ms fresh confirmation，约 1 秒仍未确认即结束，且从不修改 `ProtectionRetryState`
7. `current == target` 只有来自本轮成功 fresh read 时才可独立于 topology 确认；共享 `currentDevice` cache 绝不能作为 confirmation evidence。Auto 下 Protection restore 的真实 target confirmation 本身也会重新开启/延长 settle，并在提交前把既有 notification rebind 到当前 episode。target offline 只有完整可信 topology 才可判定。Trusted User Selection 使用 latest-wins：新的 MicLock 点击立即 supersede 旧 Trusted transaction 并发出新 setter；旧 setter 的延迟回声、未知第三状态或真实 callback 都不参与 provenance 推断，也不能取消最新 target。短确认窗口耗尽后旧 Trusted transaction 结束，本轮 current 立即重新进入正常 policy
8. 确认时从 origin 推导并提交 Recent Event；Auto notification 按当前绑定的 episode ID 做去重。无论 episode 是由 accepted retry 还是延迟 confirmation 重新锚定，notification 都会先 rebind，因此该 episode 的 `notificationSent` 能正确消费，紧接着再次抢麦也不会重复通知

Protection Restore **不使用固定 confirmation timeout**；经过多少秒本身不是其失败证据，watchdog 只负责 recheck / retry。Trusted User Selection 明确例外：它是有界 UI command，约 1 秒短确认窗口耗尽后结束，避免几分钟后仍后台 `set()` 旧用户选择。`settleTask` 仍只负责 Auto 稳定窗口；业务事实分别保存在 `StabilityState` 与 `ProgrammaticSwitchState` 中。运行中修改 `settleSeconds` 会同时重排当前 settle episode 与 stable external switch candidate 的 deadline。

`RestoreReason`：`manualLock`（Manual 恢复）/ `automaticHijack`（Auto 判定抢麦）/ `preferredReconnected`（重连恢复）/ `startup`（启动对齐，不发通知）。

## 通知

**授权**：`NotificationManager.ensureAuthorization()` 先读 `UNUserNotificationCenter.notificationSettings()`；`notDetermined` 才调 `requestAuthorization`（此时请求才会真正弹窗）；被拒时设置窗口（通用 → 通知）显示提示行并可一键跳转系统设置。请求时机：通知已开启时启动后 0.5s，或用户重新打开「显示通知」开关时。

**投递**：按 `RestoreReason` 生成标题，正文 `旧设备 → 新设备`，无声音；App 处于前台时仍显示横幅（`willPresent` 返回 `.banner`——菜单栏应用没有前台窗口概念，不设此项横幅会被吞掉）。

**去重**：Auto 模式下一次设备拓扑变化 = 一个 `SettleEpisode`。pending notification 会保存当前绑定的 episode ID；若 protection watchdog 的 accepted retry 在旧 episode 已结束后重新开启 episode，只会把既有 notification rebind 到新 episode，不会从 nil 补造通知。确认时只允许修改同 ID episode 的 `notificationSent`。只有通知开关仍开启、实际准备投递时才会把 `notificationSent` 置为 true；确认前关闭通知不会消耗该 episode 的去重额度。整个 episode 最多实际投递一条通知；Manual 模式没有 episode 限制；startup 对齐不通知。

## Recent Events

菜单栏最多展示最近 5 条，内存中最多保留最近 10 条。只有已经确认生效的关键动作才写入：MicLock 菜单选择、Auto 在 stable 状态接受的外部切换，以及各类已确认恢复。

程序化切换只保存 `ProgrammaticSwitchOrigin` 与 from/to metadata；确认 `current.uid == targetUID` 后才从 origin 推导 `RecentAudioEvent.Kind` 并构造事件，因此不存在 origin 与 event kind 双写不一致，且 `occurredAt` 表示确认时间。setter 立即失败、目标离线、被更新外部状态 supersede 或被新用户意图取代的动作都不会留下成功事件。Auto 接受外部切换时，事件来源使用旧 preferred，表达的是 policy 从旧 preferred 迁移到新 current 的事实。

## 登录时启动（SMAppService）

- 使用 `SMAppService.mainApp`（macOS 13+），不写 LaunchAgent plist、不改 `~/Library/LaunchAgents`；状态以系统为唯一事实来源，本地不持久化
- 要求 App 位于稳定路径（`~/Applications` 或 `/Applications`）——从临时构建目录 `open` 的 .app 注册会被系统拒绝
- 已知特性：`register()` / `unregister()` 成功返回后 `status` 仍会滞后数秒（底层 BTM 数据库异步落盘）。Toggle 通过显式 `Binding` 只在用户操作时调用服务写入；`onAppear` 与延迟复核只同步本地状态，不会再次触发 `register()` / `unregister()`。采用乐观更新 + 3 秒内轮询复核（每 0.75s 一次，共 4 次；`requiresApproval` 状态保持勾选并等用户在系统设置批准）；写入失败或状态未收敛时在“设置 → 通用 → 启动”就地显示错误

## 配置

UserDefaults（`lee.miclock.app` 域）：

| 键 | 含义 |
|---|---|
| `preferredMicrophoneUID` | 首选麦克风 Device UID |
| `protectionEnabled` | 是否启用保护 |
| `protectionMode` | `auto` / `manual`（未知值读作 manual） |
| `notificationsEnabled` | 恢复时是否显示通知（默认开） |
| `settleSeconds` | 设备稳定窗口，1–30s（默认 2） |

全新安装默认：Auto 模式、保护关闭、通知开、settle 2s——首次打开菜单由用户自行开启保护。

## 调试

- `MICLOCK_DEBUG=1`：关键决策流（事件、判定、恢复）镜像输出到 stderr，配合直接运行二进制使用
- `MICLOCK_TRACE_PATH=/path/to/log`：决策流追加写入文件。对 `open` 启动的 GUI 实例需经环境注入：

  ```zsh
  launchctl setenv MICLOCK_TRACE_PATH /tmp/miclock-trace.log
  open build/MicLock.app
  launchctl unsetenv MICLOCK_TRACE_PATH
  ```

- OSLog 统一日志（subsystem = `lee.miclock.app`，category 按模块）。注意部分环境下 `log show` 读不到统一日志，trace 文件是更可靠的决策记录

### OSLog 日志构造约束

`Logger` 的结构化日志参数是 `OSLogMessage`，不是普通 `String`。包含 `privacy` 标注的消息必须写成一个完整的插值字面量：

```swift
Self.logger.info(
    "RESTORE_CONFIRMED \(current.name, privacy: .public) → \(preferred.name, privacy: .public)"
)
```

不要用 `+` 拼接多个结构化日志片段：

```swift
Self.logger.info(
    "RESTORE_CONFIRMED \(current.name, privacy: .public) → " +
    "\(preferred.name, privacy: .public)"
)
```

保持单个插值字面量既能通过 Swift 6 编译，也能保留统一日志的格式和隐私元数据。此约束只适用于 `Logger` 的结构化消息；`trace(_:)` 接收普通 `String`，可以正常使用字符串运算。

## 单元测试

```zsh
./Tests/run.sh
```

与 App 相同的 Core/Services 源一起编译（不含 `@main` 入口），注入 `FakeAudioDeviceProvider`（内存设备表 + 可控 setter 失败/延迟/枚举失败状态 + 调用记录）与 `RecordingNotifier`（通知计数），直接调用 `handleDefaultInputChanged()` / `handleDeviceListChanged()` 模拟 CoreAudio wake-up，`UserDefaults` 用随机命名的独立 suite 隔离。时间敏感状态机统一依赖 `AudioMonitorScheduling`；`schedule(after:action:)` 在返回前完成 timer 登记，生产实现再用 `ContinuousClock + Task.sleep` 等待，测试则注入 `ManualAudioMonitorScheduler` 同步登记 action 并手动推进单调时间，因此多级 watchdog 不依赖 `Task.yield()` 调度时机，也不必真实等待 8/16/32/64 秒。当前 64 个用例 / 312 个断言：

| 场景 | 断言要点 |
|---|---|
| Manual scheduler | schedule 同步登记、单次 advance 可按 deadline 执行 action 内新建的下一档 timer、cancel 同步移除待执行 action |
| M1–M3（Manual） | 外部切换立即恢复、preferred 离线不动、MicLock 内选择立即生效且回调不误判 |
| Programmatic transaction | origin 是事务唯一语义来源；confirmation 只接受 fresh current observation，读取失败保留的 cache 不可确认；Trusted User Selection 使用 latest-wins，新点击立即 supersede 旧 transaction 并发出新 setter，旧 B/C 延迟回声不能完成或取消最新 D；Trusted 仅 500ms fast retry 一次并在第二个 500ms 窗口后结束，不进入永久 64s retry，也不暴露 Protection 状态；Protection restore 的 setter error 保留 transaction 并继续 persistent retry，accepted retry 与 Auto protection 的真实 target confirmation 都会重新锚定 settle；`current == target` 在枚举失败时仍可确认，Protection stuck source 会由 watchdog 主动持续重试且跨过退避阈值后也不会被 Auto 反向学习、超过旧 1s 阈值后的晚确认仍成功 |
| CoreAudio reconcile / A1–A4（Auto） | callback 正序/反序、属性分阶段变化与 `current ∉ devices` 矛盾采样都不会直接误学 preferred；current read 失败保留最后可信 current；单设备关键查询失败时 partial snapshot 更新健康 UI 设备但冻结可信 topology 策略事实；candidate 复用 settleSeconds 且 target 必须存在于可信 topology |
| Recent Events | accepted switch 来源取旧 preferred、失败动作不记录、历史最多十条且最新优先 |
| Stability / notification episode | burst 下 setter 不循环、watchdog accepted retry 与延迟 protection confirmation 都会重新开启 settle 并 rebind 既有 notification、episode 最多实际发送一条通知、关闭通知的 confirmation 不消耗额度、修改 settleSeconds 后旧 timer 不得提前结束 episode |
| 重连 | preferred 断开保留 UID、同 UID 复现自动恢复、系统已自动恢复时不重复 setter |
| 窗口内 Trusted 选择 | 立即生效且不被回声恢复 |
| 保护关闭 / 启动对齐 / 幂等 / 首次运行 / 钳制 | 各边界行为；init topology 枚举失败时无需外部 callback 也会主动恢复；fresh install 不使用不可信 current 初始化 preferred，第一份可信 baseline 按 BuiltIn 优先规则补全；persisted preferred 仍保持 `.startup` / 不通知语义 |

## 隐私与安全约束

无网络访问、无 telemetry、无自动更新、无第三方依赖、无 shell 执行、无 AppleScript、无 Accessibility、无 root/sudo、无录音（不申请麦克风权限）。唯一写入的 CoreAudio 属性是 `kAudioHardwarePropertyDefaultInputDevice`，绝不触碰输出设备。
