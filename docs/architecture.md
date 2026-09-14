# MicLock 架构与实现

MicLock 只管理系统默认输入设备（`kAudioHardwarePropertyDefaultInputDevice`）。不录音、不控制输出、不申请辅助功能权限。Auto 的产品规则、时间启发式和已知限制见 [auto-mode.md](auto-mode.md)；重构决策和迁移范围见 [state-machine-migration.md](state-machine-migration.md)。

## 模块与责任

| 模块 | 负责什么 | 不负责什么 |
|---|---|---|
| `AudioMonitor.swift` | 主 actor 上协调采样、策略、写入、持久化和 UI 投影 | 不直接访问 HAL C API；不把 callback 当成用户意图 |
| `AutoPolicy.swift` | 互斥的 stable / protecting / considering 阶段，候选连续性 | 不写设备，不管理通知或重试 |
| `DefaultInputWriter.swift` | 一笔待确认请求、来源、有限/持续重试阶段和结构化错误 | 不修改 Auto 的窗口，不假定 HAL 请求可取消 |
| `AudioMonitorScheduler.swift` | 统一单调时钟与可取消任务；支持确定性测试 | 不承载业务状态 |
| `CoreAudioListeners.swift` | 安装和移除默认输入、设备列表监听；失败时整体回滚 | 不做分类和恢复 |
| `AudioMonitorDiagnostics.swift` | OSLog 和可选 trace 输出 | 不影响状态决策 |
| `LiveAudioDeviceProvider.swift` / `AudioDeviceProviding.swift` | HAL 枚举、默认输入读写、partial snapshot 与底层错误 | 不学习 preferred |
| `Preferences.swift` | UserDefaults 读写 | 不保存运行期 AudioDeviceID |
| `ProtectionMode.swift` | 模式、恢复原因、近期事件和展示文案 | 不保存控制状态 |
| `NotificationPresenting.swift` / `NotificationManager.swift` | 通知授权和提交 | 不保证系统最终展示横幅 |

UI 仍是 `MicLockApp.swift` 中的菜单栏面板，以及 `SettingsView.swift` 中的通用/高级/关于设置。公开的 `AudioMonitor` 属性与选择入口保持兼容。`DefaultInputWriter` 作为可观测的值类型保存，使 `lastError` / `protectionRetryState` 的计算属性能驱动 UI；纯内部时序状态排除 Observation。

`ActivationPolicyManager.swift` 仍负责设置窗口打开时临时切到 `.regular`，关闭后回到 `.accessory`。窗口弱引用 identity 与 regular demand 的区别、右键 AppKit 桥接、登录项 UI 同步不在本次音频重构范围内。

## 数据的唯一事实来源

`preferredMicrophoneUID` 是持久化目标；`currentDevice` 是成功读取的实际当前设备，读取失败时只保留为 UI 缓存，不作成功确认。`currentRevision` 记录成功读取中实际发生的 UID 变化，不记录 callback 数量。

`devices` 服务 UI，允许来自 partial snapshot；`trustedDevices` 服务策略，只有完整且与 current 一致的快照才能替换。后者用 nil 区分“尚无基线”，用空数组表示“成功读到空列表”，不再同时维护一份长期 `connectedUIDs` 集合。差集仅在采样时临时计算。

内置设备由 `TransportType == kAudioDeviceTransportTypeBuiltIn` 判断，不猜设备名。首选离线时保留 UID，最近已知名称继续跨启动保存。只有尚未选过首选时才执行内置优先初始化；保护关闭也允许完成这个初始化，但不会因此切换设备。

## 一次统一收敛

```text
HAL callback / candidate timer / recovery timer / watchdog
  -> sample: fresh current + devices
  -> current revision、候选连续性、可信 topology
  -> fresh current 确认 Writer，或完整 topology 证明目标离线
  -> pending Writer 优先处理；必要时重试、结束或 supersede
  -> 启动/重连对齐、Manual enforce 或 Auto phase
  -> 只有合格的新变化才能建立外部候选
```

Devices 与 DefaultInput 是独立属性；连续读取不是原子事务。current 读取失败、枚举失败、partial、current 不属于设备表时，都不做不可逆 Auto 学习。Manual 可以使用最后一份完整 topology 继续请求恢复；已有写入只要被 fresh current 证明已到目标，就可以独立确认。

同一 `sample()` 被初始化、启动、callback 和 recovery 共用。原先独立的 startup refresh / runtime reconcile / startup recovery 初始化分支被合并。

## 启动与用户操作

初始化只读取配置和初始 UI 快照。AppDelegate 完成启动后调用 `start()`，先安装监听，再重新采样并请求启动对齐；不再用监听安装前的旧 current 直接判断。`alignmentRequested` 仅保存“一个尚未完成的显式对齐请求”，用于对齐时采样失败后的恢复，不是第二套 topology 可信状态。

打开保护或切到 Manual 会执行同样的 fresh 对齐；切到 Auto 保留首选，等待后续事件。模式切换、关闭保护和新的明确选择会取消旧逻辑写入与候选。保护窗口在模式改变时重置，不能携带旧模式下的判定进度。

选择设备先 fresh-read current，已经使用该设备时直接更新首选、不重复 setter。否则进入统一 `submitWrite()`；首次 setter 拒绝时选择失败，接受后保存新首选，真实确认前不伪造 current 或成功事件。

## 计时、错误和通知

Auto 保护窗口保存一个起点，以单调时钟按需判断到期，没有独立 settle timer。Candidate 保存变化 revision 和有效计时起点；任意采样盲区中断计时，恢复后从头确认。writer watchdog 与候选 timer 分别核对请求 ID、revision/截止时间，过期任务不能提交新状态。

音频核心的延迟任务是：候选确认、写入 watchdog、异常采样恢复。Protection 使用最长 64 秒的持续退避；Trusted 仅一次 500ms 快速重试与随后 500ms 确认。采样恢复也退避到最长 64 秒，成功后重置。正常稳定状态没有周期性 enforce 或轮询。其他模块仍有通知授权、窗口诊断、登录项状态复核等异步任务。

Writer 错误用 `Failure` 枚举表达，UI 文案由枚举投影，业务不比较英文字符串。`deviceEnumerationError` 暂保留旧 API 名称以兼容 UI，但覆盖整个联合采样失败；名称扩展可留到 UI/诊断专项修改。

通知授权从 `start()` 后的短延迟任务或用户打开通知开关发起，`refreshNotificationAuthorization()` 在调用前和返回后检查开关。系统授权请求一旦已经提交，不声称可以撤销弹窗。关闭通知不提交恢复通知。

Auto 的通知去重独立于 AutoPolicy：`lastAutoNotificationAt` 与当前 `settleSeconds` 控制两次提交的最小间隔；Manual 保持每次确认可通知，startup 不通知。这改变了旧的 episode 精确去重契约，详见 [auto-mode.md](auto-mode.md)。通知 draft 被一个 `shouldNotify` 布尔值替代，没有 episodeID/rebind。

Recent Events 仍只记录已经确认的 MicLock 选择、Auto 接受和恢复。内存保留最近 10 条，菜单显示最近 5 条。恢复和选择的发生时间是确认时间，不是发出请求的时间；Auto 接受事件从旧首选指向新当前设备。

## 登录项与配置

登录项仍由 `SMAppService.mainApp` 管理，不保存第二份持久化登录项状态。通用设置通过显式 Binding 区分用户操作与 UI 回读，采用乐观显示和最多约 3 秒的短时复核；错误在设置页展示。音频重构没有修改这一模块。

UserDefaults 域仍是 `lee.miclock.app`：`preferredMicrophoneUID`、`protectionEnabled`、`protectionMode`、`notificationsEnabled`、`settleSeconds`、`lastKnownDeviceNames`。全新安装仍默认 Auto、保护关闭、通知开启、窗口 2 秒；不迁移或清除用户设置。窗口限定为 1–30 秒；运行时非有限值回落到 2 秒。

## 构建、测试和调试

构建脚本继续通配 `Sources/Core/*.swift`，测试脚本继续通配 `Tests/*.swift`，新增模块不需要修改工程文件。运行环境仍是 macOS 14+，原来的 Swift 6 构建要求不变。

```zsh
make test
make build
```

`Tests/main.swift` 依次调用原有测试、新增危险时序回归和重构验收。新测试全部注入 `ManualAudioMonitorScheduler`；原有真实等待用例仍保留。第一份补丁刻意只加入回归，在旧实现上失败；必须继续应用实现补丁后再验收最终结果。

需要检查默认回调与设备回调先后变化、重复回调、部分拓扑、当前读取失败、A→B→C 快速选择、旧确认迟到、首选离线/重连、通知开关、模式切换、配置变更与 startup fresh read。对第三方 HAL 的真实行为仍须用 macOS 设备验证，Fake Provider 不等于硬件驱动。

`MICLOCK_DEBUG=1` 将关键日志写 stderr；`MICLOCK_TRACE_PATH` 写 trace 文件。日志包括采样 revision、changed/valid、当前/首选/待确认目标、写入尝试和确认、事件与 provider 错误。trace 仅在主 actor 调用，因此删除旧的 NSLock；文件写入失败不会影响保护策略。

OSLog 的带 privacy 插值仍必须是一个完整的消息字面量，不能用字符串 `+` 拼接。统一日志的 subsystem 仍为 `lee.miclock.app`；不要把调试输出当成设备变化事实来源。
