# Auto 模式原理

MicLock 管理的是系统默认输入设备，不是录音权限，也不能控制 App 内部单独选择的麦克风。`preferred` 是持久化的目标，`current` 是最近一次成功读取的系统实际值；两者不相等不等于刚刚发生了一次外部切换。

## 固定的产品规则

| 场景 | Auto | Manual |
|---|---|---|
| 首选在线，启动、重新开启保护时当前设备不一致 | 立即请求恢复，启动对齐不通知 | 相同 |
| 可信 topology 发生设备增减 | 进入保护窗口 | 始终严格保护 |
| 保护窗口内当前偏离首选 | 立即请求恢复 | 立即请求恢复 |
| 窗口外观察到真正的新外部默认设备变化 | 连续有效确认 `settleSeconds` 后学习 | 恢复首选 |
| MicLock 内明确选择 | 不受保护窗口限制 | 相同 |
| 首选离线 | 保留首选，等待重连 | 相同 |
| 关闭保护 | 只刷新，不恢复，不自动学习 | 相同 |

“立即恢复”指立即发起 setter，不代表 HAL 保证同步完成。setter 返回成功后，仍然只能用新的、成功的 current read 确认。MicLock 内的选择沿用原有失败语义：setter 直接拒绝时不覆盖旧首选；请求被接受后保存新首选，确认超时也不把首选回滚到旧 current。当前设备已经等于目标时，不需要重复 setter。

## 两个概念，不是多套互相取消的状态机

### AutoPolicy：三个互斥阶段

```swift
stable
protecting(since: ContinuousClock.Instant)
considering(Candidate)
```

`protecting` 表示最近一次可信拓扑变化或已经确认的恢复之后的保护窗口。截止时间由 `since + settleSeconds` 推导；不再存两份时间，也不需要专门的 settle timer、episode ID 或 revision。下一次实际决策按单调时钟判断是否到期。修改配置前先按旧时长结算，避免延长配置把已经结束的窗口重新激活。

Auto 在保护关闭时仍记录可信 topology 变化建立的窗口，但不执行恢复或学习；重新开启保护不会清掉尚未过期的窗口，因此设备接入后的延迟系统切换仍会受到保护。

`considering` 表示已有一次合格的新变化，正在确认能否学习。Candidate 只保存 current 的 `revision`、旧首选 UID/名称、新设备以及 `validSince`。保护窗口与候选不能同时存在。

### DefaultInputWriter：一笔逻辑写入

`pending == nil` 表示没有待确认的请求；否则保留目标、来源、最初的 current UID、展示信息、通知资格和重试阶段。Writer 不管理 Auto 的截止时间，不携带通知 episode，不读取 UI 缓存来判成功。

Writer 是 AudioMonitor 内的可观测值类型，`lastError` 与 `protectionRetryState` 由结构化状态推导。不能为了减少观测把整个 writer 标为 `@ObservationIgnored`，否则错误提示可能不刷新。

## 变化证据从哪里来

所有成功的 current read 经过 `readCurrent()`，包括 callback、watchdog、recovery、用户选择前后的读取。

首次成功读取只建立基线。之后只有 UID 真正改变才推进 `currentRevision`；重复回调、相同值、错误读取都不凭空产生一次变化。成功读到 nil 与读取失败分开处理；前者是一次明确的“没有默认输入”，后者保留 UI 缓存。

候选只能由合格的 `observation.changed` 开始。回调类型不是用户意图证明：timer 确实读到 A→B 时可以发现新变化，但 timer 读到 A→A 不能仅因为 `A != preferred` 而启动学习。MicLock 正在处理的写入观察优先由 Writer 消费，不能同时作为外部切换证据。

因此 Trusted 超时后，即使收到无变化的 Devices/DefaultInput callback，或者 recovery timer 再次读到旧 A，也不会覆盖用户选择的 B。不需要专门的 `trustedSelectionExpired` 策略返回值或 timeout 后的屏蔽 flag。

注意：revision 只能证明“观察值改变”，不能证明“由哪个进程改变”。它不是 HAL 写入来源识别机制。

## 候选连续性与不完整采样

联合采样仍不是原子快照。只有 current read 成功、枚举完整、current 属于该设备集合（或明确为 nil）时，才更新可信 topology、判断离线或提交 Auto 学习。

采样失败、partial topology、跨属性不一致都会将候选的 `validSince` 置为 nil，并取消其确认 timer。后续采样恢复有效时，从恢复时刻重新计满整个窗口；不能把不可观察的时段算作持续稳定。

当前 UID 在异常期间出现 B→C→B 时，每次成功读取都推进 revision，旧 B 候选不会复活。保留的是最近一次真实变化的证据，不是旧截止时间。没有新变化、也没有既存合格候选时，恢复采样不会凭空开始学习。

设备健康展示与可信策略快照分开：`devices` 可以展示 partial 中的健康设备；`trustedDevices` 保留最后完整快照。`nil` 表示尚无基线，空数组表示已成功采到空列表。构造阶段的初始 UI 快照即使可信，也不会初始化首选；从 listener 安装后的 startup fresh sample 开始，后续可信采样在首选仍未初始化时，都可以按“内置优先、否则当前”的规则补全，因此初次空列表不再结束初始化机会。

不完整采样不能建立新的拓扑事实或学习首选。但已经由可信拓扑建立的保护窗口仍然有效：只要 fresh current 明确偏离首选，就和 Manual 一样尝试恢复最后可信的目标，实际是否可写由 Provider 重新解析 UID 决定；失败进入已有退避，只有完整快照才能判定目标离线并取消。没有成功 current read 时，绝不使用缓存冒充新的恢复或确认依据。

仍保留保守的全局可信边界，不增加逐设备置信度、隔离表等状态机。长期异常设备仍可能暂停新的拓扑分类及 Auto 学习；这不等于撤销已建立的保护。`trustedDevices` 同时支撑首选在线/离线 UI，必须参与 Observation；离线错误绑定具体失败的目标 UID，后续 fresh current 到达该目标，或完整可信 topology 再次证明该 UID 已在线时，都会清除这条已经过期的 target-offline 错误。

## 写入确认与重试

Trusted 选择保留原有 latest-wins：新点击立即取代旧逻辑请求，并发出新 setter。500ms 后对最新目标重试一次，再给 500ms 确认窗口；仍未确认则结束，保存新首选并显示确认失败。之后真实 current 到达该首选时清除超时错误。Manual 会在 Trusted 结束后恢复其严格保护策略。

Protection 继续按 0.5、1、2、4、8、16、32、64 秒退避，之后保持最长 64 秒。setter 拒绝与“接受但尚未确认”分别显示。重试请求无论被接受或拒绝，都不延长 Auto 保护窗口；只有真实确认恢复成功时，才从确认时刻重新开启一次窗口，以保护紧接着的再次抢麦。

保留既有的 Protection 第三状态规则：当前还是起始 source 时，等待/重试；真实 current 到达另一个非 target 设备时，可以结束旧 restore 并重新运行策略。只有本轮确实观察到新的 UID 变化，才有资格成为 Auto 候选。`sourceUID` 因这一兼容规则保留，不伪装成可靠的外部写入来源证明。拓扑不可信时也不能提交学习。

关闭保护、切换模式、MicLock 的更新选择会取消逻辑请求、尚未完成的显式对齐及其 watchdog。目标离线只有在完整可信快照中才能确认。成功的 fresh current 等于目标可以独立确认写入，即使同次枚举失败；缓存碰巧等于目标不能确认。

## 通知：独立冷却，不再绑定 episode

仅在恢复已经确认、请求创建时允许通知、确认时通知开关仍开启且不是启动对齐时，提交恢复通知。

Auto 只记录 `lastAutoNotificationAt`，两次提交通知至少间隔当前 `settleSeconds`；未提交的恢复不消耗冷却。Manual 保持每次确认恢复可通知。配置变化影响后续冷却判断。

这是有意的行为变化：持续时间很长的反复抢麦可能在一个连续保护过程中收到多条间隔通知；很接近的独立插拔也可能共用冷却。以前承诺的“一个 episode 恰好最多一条”不再适用。换取的是删除 `PendingNotification`、`notificationSent`、`episodeID` 和 rebind 全部跨状态耦合。冷却限制的是提交，不保证系统实际展示横幅。

## 计时器与恢复

音频核心仅有三类任务：候选确认、写入 watchdog、异常采样恢复。保护窗口自己不需要 timer。采样恢复从 250ms、500ms、1s、2s 逐级退避到最长 64s，成功后清零；比旧实现长期每 2 秒重新采样更克制，但异常刚恢复且没有 callback 时可能更晚发现。

候选 timer 校验 revision 和截止时间，Writer timer 校验请求 ID。任务只负责唤醒；提交候选前仍检查当前证据、可信 topology 和单调时间。通知授权等非音频任务独立存在，不能把“三类”误写成整个 App 只有三类异步任务。

## 尚存边界

Auto 仍是启发式：窗口内真正的用户外部切换可能被恢复，窗口外迟到的系统变化可能被接受；窗口内明确选择请使用 MicLock 菜单。可信联合采样也不提供 HAL 原子性保证。

取消 pending 不会撤销 HAL 已接受的写入。最新目标确认以后，旧 setter 极晚生效，仍可能被当作新外部变化；这次瘦身没有声称解决 HAL 完成乱序。无 callback、无待处理任务的静默变化也不能立即感知。

测试覆盖原有 `AudioMonitorTests.swift`、危险时序回归 `StateMachineRegressionTests.swift`、重构验收 `StateMachineAcceptanceTests.swift`、`PostRefactorRegressionTests.swift`、`LiveAudioDeviceProviderTests.swift` 和 `SettingsBoundaryTests.swift`。时间敏感的 AudioMonitor/状态机测试使用 Manual Scheduler；Provider 与设置/通知边界测试使用各自的可控 fixture / continuation，不把新的 wall-clock sleep 引入这些回归。原有睡眠用例保留，另行迁移，避免把性能优化混进这次行为重构。
