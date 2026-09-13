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
        P2 -->|target 离线 / 明确用户取消 / 外部状态 supersede| P1
    end
```

## CoreAudio 统一收敛流程

`kAudioHardwarePropertyDevices` 与 `kAudioHardwarePropertyDefaultInputDevice` 是两个独立属性，MicLock **不依赖两个 listener 的跨属性投递顺序**。两个 listener 都只作为 wake-up 信号，统一进入 `reconcileCoreAudioState()`；每次都会重新读取 devices 与 current，但这只是一次一致化采样，**不是 CoreAudio 提供的原子 snapshot 保证**。HAL 仍可能先改变 DefaultInput、稍后才更新 Devices。

```swift
newCurrent = provider.currentInputDevice()
newDevices = try provider.listInputDevices()
```

只有 topology 采样有效且与 `current` 不矛盾时，本轮结果才可用于 topology/Auto policy：全局枚举失败、关键单设备 identity 查询失败，或 `current.uid` 根本不在本轮 `devices` 中，都会把这轮采样视为 inconclusive。此时保留上一份有效 `devices / connectedUIDs`，仍更新可独立读取的 `currentDevice`，并安排短暂 recovery retry。`current == pending.target` 这种不依赖 topology 的确定事实仍可立即确认；Manual 也可使用上一份有效 topology 继续严格恢复。有效采样后固定按以下顺序处理：

1. 用 `newDevices` 与 `connectedUIDs` 求 topology delta；有真实 delta 时先进入/延长 `settling`
2. 更新 `devices / connectedUIDs / currentDevice`
3. 处理 `PendingSwitch` 的确认、取消或 supersede
4. 最后运行 Auto / Manual policy

对于 **Auto + stable + 外部 default 变化**，即使本轮 `devices` 暂时仍显示旧 preferred 在线，也不会立刻学习新的 preferred，而是建立 `StableExternalSwitchCandidate`。`currentDevice` 会立即更新供 UI 展示；candidate 的分类窗口复用用户配置的 `settleSeconds`，不再使用额外的隐藏 200ms 常量。若窗口内出现 topology delta，candidate 立即取消并按 topology 事实处理；窗口结束时只有 topology sample 仍有效、`current` 未变化且 candidate target 仍存在于 `connectedUIDs`，才确认这是 stable external switch 并学习新的 preferred。若确认采样无效，则保留 candidate，等待 recovery / 后续 wake-up。这个 candidate 只延迟“学习 preferred”，不会延迟 corrective restore。

```mermaid
flowchart TD
    A["Devices 或 DefaultInput callback"] --> B["先读取真实 current，再尝试枚举 devices"]
    B --> C{"current == pending target？"}
    C -->|是| E1["确认事务：提交 Recent Event / 通知"]
    C -->|否| D{"topology sample 有效且与 current 一致？"}
    D -->|否| D1["保留上次有效 topology；Manual 可继续恢复；Auto 冻结分类；安排 recovery"]
    D -->|是| E["应用 topology delta，再处理 PendingSwitch / policy"]
    E -->|target 已离线| E2["失败旧事务，继续 policy"]
    E -->|仍是明确 source| E4["watchdog recheck / retry"]
    E -->|其他非 target current| E3["外部事实 supersede 旧事务，继续 policy"]
    E -->|否| F{"保护开启？"}
    E2 --> F
    E3 --> F
    E1 --> Z[结束]
    E4 --> Z
    F -->|否| Z
    F -->|是| G{"preferred 已设置且在线？"}
    G -->|离线| G1[保留 preferred UID]
    G -->|在线且 current != preferred| H{"模式"}
    H -->|manual| R[立即发起 restore transaction]
    H -->|auto + settling| R
    H -->|auto + stable| U[建立 / 确认 StableExternalSwitchCandidate]
```

这里有三个关键约束：

- **有效采样优先**：callback 只表示“值得重新检查”；devices/current 的联合读取不是原子事务，枚举失败或分阶段属性变化都不能被当成完整 topology 事实。
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

恢复 preferred 成功发起后也会延长同一个 episode，因为 macOS / 蓝牙协议栈可能在被恢复后立即再次抢麦。watchdog 后续某次 retry 如果终于被 CoreAudio 接受，同样会重新开启或延长 settle；即使旧 episode 已经结束，也会从该次 corrective restore 开始新的 protection episode。Auto 下 protection transaction 最终真实到达 target 时也会从 confirmation 时刻重新锚定 settle，因此“更早 accepted 的请求很晚才真正生效”不会在旧 episode 已结束后留下 stable 空窗。

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
- `sourceUID`：发起写入时观察到的 current
- `targetUID`
- `ProgrammaticSwitchOrigin`：`protectionRestore(reason)` 或 `trustedUserSelection`
- Recent Event 的 from/to 展示 metadata；kind 在确认时只从 origin 推导
- 待提交的通知（如果本次动作应该通知）

旧实现中 `expectedDefaultUID`、pending Recent Event 和 pending notification 分开保存，存在两笔操作之间 metadata 串线的风险。现在新的程序化切换会整体 supersede 旧事务，source / target / origin / metadata / notification 永远属于同一 transaction；origin 是程序化事务语义的唯一来源，不再额外保存一份可与 origin 冲突的 event kind。

### 确认规则：不使用固定时间宣告失败

`setInputDevice()` 返回成功只表示 CoreAudio 接受了写请求，不代表默认输入已经真实变化。HAL 也没有给出“必须在 1 秒或任何固定秒数内完成”的正确性保证，因此 PendingSwitch 不再设置 confirmation timeout。

后续用可靠的可观察事实推进事务：

1. `current.uid == targetUID`：这是独立于 topology 的充分成功证据；即使同一轮设备枚举失败，也立即确认。若 origin 是 Auto 下的 Protection restore，确认本身会先重新开启/延长 settle，并把既有 notification rebind 到当前 episode，再提交 Recent Event / 通知；Trusted User Selection 不制造 protection episode
2. 只有在 topology sample 有效且跨属性一致时，`targetUID` 不在线才可作为目标明确不可达的失败证据
3. `sourceUID != nil && current.uid == sourceUID`：说明写入尚未反映；watchdog 按 500ms → 1s → 2s → 4s → 8s → 16s → 32s → 64s 重新读取并重试 setter，之后固定 64s 一次。若该 transaction 的 origin 是 Protection restore，任何 accepted retry 都会重新开启/延长 settle；Trusted User Selection 则不会制造 protection episode
4. 完成前四档快速重试后，不把“时间经过”解释为 HAL failure，也不释放仍停留在 source 的 transaction。Protection restore 显示 `protection is retrying` 并更新 `ProtectionRetryState`；Trusted User Selection 只使用中性的 MicLock retry 文案，不暴露 Protection 状态
5. 其余非 target current：出现了更新的外部事实，旧事务被 supersede，随后重新运行 policy；特别地，`sourceUID == nil` 时任何实际出现的非 target current 都属于这种新事实
6. topology sample 无效：不能做 target-offline 判定；保留上一份有效 topology，并通过独立 recovery retry 重新采样
7. 模式切换、保护关闭或新的 Trusted User Action：属于明确的新用户意图，直接取消/取代旧事务；如果 UI 正显示 `protection is retrying`，同时清理这条只属于旧事务的瞬态状态

因此不会恢复旧的“固定 1 秒后宣告失败”语义：时间只触发重新检查/重试，不直接决定成功或失败。允许一笔 transaction 在 source 持续不变时长期 pending，但这种 pending 会按 capped interval 主动执行 setter；真正结束事务必须来自 target confirmed、target 确定离线、第三个 current 或新的用户意图，而不是单纯等待够久。

Protection restore 中还区分两类未完成状态：setter 返回 `true` 但 `current != target` 表示“请求已接受、等待确认”；watchdog 某次 setter 返回 `false` 则表示“请求本身被拒绝”。后者显示 `Unable to set default input device; protection will keep retrying`，前者在进入长期 retry 阶段后显示 `Unable to confirm default input change; protection is retrying`。任一后续成功确认都会由 `finishProgrammaticSwitchIfConfirmed()` 清空这些瞬态错误。设置窗口的「高级 → 设备切换」只显示 Protection restore 的结构化警告；Trusted User Selection 即使长期 pending 也不会修改 `ProtectionRetryState`，只使用中性的 MicLock retry 文案。MicLock UI 中用户主动选择设备若首个 setter 就失败，仍按该次 Trusted User Action 失败处理，不擅自改写 preferred。

Recent Event 的 `occurredAt` 使用**确认时间**，而不是 setter 请求时间。

### 模式切换与保护关闭

模式切换代表新的用户意图，会取消旧模式下尚未确认的事务；切到 Manual 后再基于当前真实状态执行新的 startup 对齐。关闭保护同样会取消 pending transaction。

## 通知去重与 episode ID

Auto Mode 的 pending notification 会记录当前绑定的 `episodeID`。如果旧 episode 已结束，而 Protection watchdog 的 accepted retry 或最终 target confirmation 新开了 episode，则**只对已经存在的 notification**重新绑定到新 episode；原本为 nil 的 notification 不会因为 retry / confirmation 而被凭空创建。确认时只有同 ID 的当前 episode 才能参与去重，因此 confirmation 消耗了新 episode 的通知额度后，紧接着的再次抢麦不会重复通知。

只有通知开关在确认时仍然开启、实际准备投递通知时，才把 `notificationSent` 置为 true。若事务确认前用户关闭通知，这次确认不会消耗 episode 的通知额度；之后在同一 episode 内重新开启通知，下一次恢复仍可以发送一次通知。Manual Mode 不使用 episode 去重。

## Trusted User Action

用户在 MicLock 菜单里选择设备属于明确的 Trusted User Action，不受 settle window 限制。选择动作同样走 `PendingSwitch`：setter 失败不覆盖 preferred；setter 被接受后 preferred 可以立即更新，但 Recent Event 仍等真实 current 达到目标后才提交。它可以复用同一 watchdog 重试机制，但不会重新开启 settle，也不会冒充 Protection retry。

设备刚接入的 settle window 内如果确实要更换首选麦克风，直接在 MicLock 菜单中选择即可。

## Recent Events 的解释语义

Recent Events 只记录已经确认成功的关键动作：

- MicLock 菜单中的用户选择
- Auto 在 `stable` 状态接受的外部切换
- Manual / Auto / preferred 重连 / startup 的恢复

Auto 接受外部切换时，事件的 `from` 使用**旧 preferred**。这表示一次明确的 policy 迁移：从旧 preferred 接受到新的 current；不会依赖 listener 到达顺序或某个 callback 前缓存的 current。

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
- **StableExternalSwitchCandidate 仍是时间启发式**：candidate 复用 `settleSeconds` 吸收常见的跨属性分阶段更新，并要求 target UID 存在于可信 topology；如果 CoreAudio 的 topology 更新延迟超过整个分类窗口，仍可能把系统 fallback 误判为稳定后的外部切换。这是 Auto 允许外部切换自动成为 preferred 所带来的产品 trade-off，而不是原子性保证。
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
