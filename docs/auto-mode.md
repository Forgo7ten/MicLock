# Auto 模式原理

一句话：**恢复永远是立即的；settle 窗口只用来给变化定性**——判断默认输入变化更像「设备拓扑变化引起的系统抢麦」还是「设备已经稳定后的外部切换」。MicLock 不通过延迟恢复来观察结果，因此不会故意让错误麦克风保持数秒。

## Auto 与 Manual 的差异

| 场景 | Auto | Manual |
|---|---|---|
| 设备接入/断开的稳定窗口内的外部切换 | 立即恢复 | 立即恢复 |
| 稳定窗口外的外部切换（系统设置、其他 App、CLI） | 接受，并学习为新的 preferred | 立即恢复 |
| MicLock 菜单中主动选择 | 立即接受 | 立即接受 |
| 通知频率 | 一个 settle episode 最多一条 | 每次确认恢复后通知 |
| preferred 何时变化 | 稳定后的外部切换 / MicLock 菜单选择 | 仅 MicLock 菜单选择 |

## 为什么是两个正交状态机

Auto Mode 同时存在两类彼此独立的状态：

1. **稳定性状态 `StabilityState`**：系统当前是稳定 (`stable`) 还是处于设备变化 episode (`settling`)。
2. **程序化切换状态 `ProgrammaticSwitchState`**：MicLock 是否正在等待自己发起的一次 `DefaultInputDevice` 写入被 CoreAudio 真实确认。

二者可以同时成立。例如 AirPods 接入时，MicLock 可以一边处于 `settling`，一边等待「恢复到内置麦克风」这笔程序化切换确认。因此不能把它们压成一个扁平的 `stable / settling / enforcing` 枚举，否则会出现组合状态爆炸。

```mermaid
flowchart LR
    subgraph Stability["稳定性状态"]
        S1[stable]
        S2["settling(SettleEpisode)"]
        S1 -->|真实设备拓扑 delta| S2
        S2 -->|再次拓扑活动 / corrective restore| S2
        S2 -->|当前 revision 的 deadline 到期| S1
    end

    subgraph Switch["程序化切换事务"]
        P1[idle]
        P2["awaitingConfirmation(PendingSwitch)"]
        P1 -->|MicLock setInputDevice| P2
        P2 -->|真实 current == target| P1
        P2 -->|timeout / cancel / supersede| P1
    end
```

## DefaultInputDevice 判定流程

每次 `handleDefaultInputChanged()` 都先重新读取 CoreAudio 的真实默认输入，然后按以下顺序处理：

```mermaid
flowchart TD
    A["DefaultInputDevice callback"] --> B["重读真实 current"]
    B --> C{"存在 PendingSwitch？"}
    C -->|是| D{"current == transaction.targetUID？"}
    D -->|是| D1["确认事务：提交 Recent Event / 通知，回到 idle"]
    D -->|否| D2["吸收中间 callback，继续等待；不重复 setter"]
    C -->|否| E{"保护开启？"}
    E -->|否| Z[结束：只观察，不学习]
    E -->|是| F{"preferred 已设置？"}
    F -->|否| L[学习 current 为 preferred]
    F -->|是| G{"current == preferred？"}
    G -->|是| Z
    G -->|否| H{"preferred 在线？"}
    H -->|否| Z2[保留 preferred UID，等待重连]
    H -->|是| I{"模式"}
    I -->|manual| R[立即发起 restore transaction]
    I -->|auto| J{"StabilityState"}
    J -->|settling| R
    J -->|stable| U[接受外部切换并学习 preferred]
```

这里有三个关键约束：

- **真实状态优先**：callback 只表示属性发生过变化，策略始终重新读取 CoreAudio 当前值。
- **程序化事务优先**：MicLock 自己的写入回声必须在 Auto/Manual 判定之前吸收，否则会形成 setter 循环。
- **保护关闭不学习**：关闭保护期间的临时系统选择不会悄悄覆盖 preferred。

## StabilityState 与 SettleEpisode

稳定性只有两个状态：

```swift
stable
settling(SettleEpisode)
```

`SettleEpisode` 保存：

- `id`：episode 唯一 ID；同一次接入/反抢收敛过程始终保持同一个 ID
- `revision`：每次延长 deadline 都递增，用来淘汰已经过期的 timer
- `lastActivity`：最近一次真实拓扑活动或 corrective restore 的单调时钟时间
- `deadline`：本 revision 的稳定截止时间
- `notificationSent`：该 episode 是否已经投递过恢复通知

### 进入与延长 episode

设备列表出现真实 delta 时进入 `settling`。如果已经在 `settling`，不会创建新 episode，只更新 `lastActivity / deadline` 并增加 `revision`。

恢复 preferred 成功发起后也会延长同一个 episode，因为 macOS / 蓝牙协议栈可能在被恢复后立即再次抢麦。这样同一次接入造成的多次反抢仍属于同一个 protection episode。

### timer 只是执行机制

`settleTask` 不是业务事实来源。每个 task 都携带创建时的 `episode.id + revision`，醒来时只有同时满足以下条件才允许把状态改成 `stable`：

- 当前仍是同一个 episode ID
- revision 仍匹配
- 当前单调时间已经达到该 revision 的 deadline

因此被取消但晚到的旧 task、旧 revision 或前一个 episode 的 task 都无法结束新的 settle window。

### 运行中修改 settleSeconds

修改 `settleSeconds` 对当前 episode **立即生效**。MicLock 以当前 episode 的 `lastActivity` 为基点重新计算 deadline，并增加 revision：

- 新 deadline 仍在未来：取消旧 task，按新的剩余时间重新调度
- 新 deadline 已经过去：立即转为 `stable`

这样不会再出现「决策函数按新配置判断仍 unsettled，但旧 timer 按旧配置提前重置 episode / 通知去重」的分裂状态。

## ProgrammaticSwitchState 与 PendingSwitch

MicLock 自己发起的切换只存在两种状态：

```swift
idle
awaitingConfirmation(PendingSwitch)
```

一笔 `PendingSwitch` 原子保存：

- transaction `id`
- `targetUID`
- 待提交的 Recent Event draft
- 待提交的通知（如果本次动作应该通知）

旧实现中 `expectedDefaultUID`、pending Recent Event 和 pending notification 分开保存，存在两笔操作之间 metadata 串线的风险。现在新的程序化切换会整体 supersede 旧事务，target / event / notification 永远属于同一 transaction。

### 确认规则

`setInputDevice()` 返回成功只表示 CoreAudio 接受了写请求，不代表默认输入已经真实变化。因此：

1. 发起 `PendingSwitch`
2. 调用 setter
3. 重新读取真实 current
4. `current.uid == targetUID` 时才确认
5. 若未确认，等待后续 callback；1 秒确认 timeout 到达时最后再重读一次
6. 仍未命中则事务失败，不写成功 Recent Event、不发恢复通知

Recent Event 的 `occurredAt` 使用**确认时间**，而不是 setter 请求时间。

### 模式切换与保护关闭

模式切换代表新的用户意图，会取消旧模式下尚未确认的事务；切到 Manual 后再基于当前真实状态执行新的 startup 对齐。关闭保护同样会取消 pending transaction。

## 通知去重与 episode ID

Auto Mode 的 pending notification 会记录创建它时的 `episodeID`。确认时只有同 ID 的当前 episode 才能被标记为 `notificationSent = true`，因此旧事务晚到的 confirmation 不会污染一个更新的 episode。

同一 episode 第一次确认恢复后会把 `notificationSent` 置为 true；后续反抢仍立即恢复，但不会再次创建通知。Manual Mode 不使用 episode 去重。

## Trusted User Action

用户在 MicLock 菜单里选择设备属于明确的 Trusted User Action，不受 settle window 限制。选择动作同样走 `PendingSwitch`：setter 失败不覆盖 preferred；setter 被接受后 preferred 可以立即更新，但 Recent Event 仍等真实 current 达到目标后才提交。

设备刚接入的 settle window 内如果确实要更换首选麦克风，直接在 MicLock 菜单中选择即可。

## Recent Events 的解释语义

Recent Events 只记录已经确认成功的关键动作：

- MicLock 菜单中的用户选择
- Auto 在 `stable` 状态接受的外部切换
- Manual / Auto / preferred 重连 / startup 的恢复

Auto 接受外部切换时，事件的 `from` 使用**旧 preferred**，而不是缓存的 `previous currentDevice`。这是因为 CoreAudio 的 devices callback 可能先于 default-input callback 到达并提前刷新 current；旧 preferred 才是策略迁移前可靠的来源设备。

## 时序示例：AirPods 接入并反抢

```mermaid
sequenceDiagram
    participant SYS as macOS
    participant ML as MicLock
    Note over ML: preferred = MacBook Microphone; state = stable
    SYS->>ML: devices delta: AirPods added
    ML->>ML: create settle episode #7 rev1
    SYS->>ML: default input -> AirPods
    ML->>ML: state = settling => classify as hijack
    ML->>SYS: set preferred (transaction #20)
    ML->>ML: extend episode #7 to rev2
    SYS->>ML: default input -> MacBook Microphone
    ML->>ML: confirm transaction #20; record event; notification #7 = sent
    SYS->>ML: default input -> AirPods again
    ML->>SYS: restore again (same episode #7, no second notification)
    ML->>ML: current revision deadline reached -> stable
```

## 已知限制

- **settle window 内的真实用户外部切换仍可能被恢复**：CoreAudio 没有提供可靠的「是谁修改默认输入」来源。窗口内想明确更换首选，请使用 MicLock 菜单。
- **窗口结束后的系统延迟切换仍可能被接受**：稳定以后 MicLock 选择“允许用户意图”优先，无法证明一个外部变化一定来自人类操作。
- **个别虚拟驱动静默回弹**：若驱动接受 setter 后又静默回弹且完全不产生属性事件，事件驱动模型无法立即感知。
- **preferred 离线期间**：保留原 UID，不学习系统 fallback，等待同 UID 重连。

## 对应单元测试

`Tests/AudioMonitorTests.swift` 覆盖的关键行为包括：

| 测试 | 锁定的行为 |
|---|---|
| A1 new device hijack | settling 内抢麦 → 立即恢复、preferred 不变 |
| A2 settled user switch | stable 后外部切换 → 接受并学习 |
| A2 recent event uses old preferred | devices callback 先刷新 current 时解释历史仍正确 |
| A3 switch inside settle window | settle 内外部切换按启发式恢复 |
| A4 new device settles then accepted | 新设备稳定后允许用户切换到它 |
| pending restore superseded by mode change | 新事务原子取代旧事务，event / notification 不串线 |
| restore waits for real confirmation | 未真实确认前不伪造 current、不通知、不写 Recent Event |
| burst robustness | 反抢 / 重复 / 回声交错时 setter 不循环、episode 只通知一次 |
| settle configuration change | 修改 settleSeconds 后旧 timer 不得提前结束 episode 或重置去重 |
| user selection inside settle window | Trusted User Action 在 settle 内仍立即生效 |
