# MTM-1 命令层（从 SDK Java 层提取）

来源：`com.microtechmd.library` 的 `PresenterDelivery` / `PresenterMonitor` / `PresenterSystem`，以及 `aaps/pumps/equil/EquilPump`、`EquilPumpController` 的调用点。

## 1. 总线角色

| 角色 | 值 | 出处 |
|---|---|---|
| 手机端源地址 | **9** | `getRemoteParameter` 里 `sourceAddress = 9` |
| 泵地址 | **0** | `EntityDevice.setAddress(0)` → `Presenter.setAddress(0)` |
| system 模块端口 | 0 | `PresenterSystem` 构造 `EntityMessage` 用 sourcePort=0 / targetPort=0 |
| delivery 模块端口 | 4 | `PresenterDelivery.getRemoteParameter` 用 4 / 4 |
| monitor 模块端口 | 5 | `PresenterMonitor.queryHistory` / `setDateTime` 用 5 / 5 |

operation 枚举：`EVENT 0, SET 1, GET 2, WRITE 3, READ 4, NOTIFY 5, ACK 6`。

## 2. delivery 的 parameter 码

| 动作 | parameter | operation | 数据区 |
|---|---|---|---|
| 运行模式 | 0 | GET 2 / SET 1 | `uint8` 0=停止 1=运行 2=暂停 |
| 基础率 | 2 | GET 2 / SET 1 | 48 × `uint16`（小端） |
| 大剂量 | 3 | GET 2 / SET 1 | 2 × (`int32` amount + `int32` interval) |
| 临时基础率 | 4 | GET 2 / SET 1 | `int32` amount + `int32` interval |
| 设置（状态） | 5 | GET 2 / SET 1 | 20 字节，见下 |
| 退针 | 6 | SET 1 | — |
| 排气 | 7 | SET 1 | — |

## 3. 实体编码（已核对）

### 基础率（parameter 2）

- 48 段 × 30 分钟 = 24 小时，`toByteArray` 逐段写 `writeShortEndian`。
- 单位：`amount × 0.001` U/h（`EquilPump` 里 `getAmount(i) * 0.001`，常量 `0x3f50624dd2f1a9fc`）。
- `setBasalProfile(int[48])` 传入后按最小 50（=0.05 U/h）做零段合并，所以泵侧分辨率是 0.05 U/h。

### 临时基础率（parameter 4）

- `ProfileTemporary`：`PROFILE_COUNT=1`、`PROFILE_LENGTH=8`、`PROFILE_RATIO=1000`。
- 字段：`temp_amount0`(int) + `temp_interval0`(int)，`writeIntEndian` 小端。
- 百分比模式：`PERCENT_TAG = 0x80000000`，amount 置 bit31。
- AAPS 层调用：`setTemporaryProfile((int)(rate*1000), durationMin, isPercent)`。

### 设置/状态（parameter 5）

`Setting.toByteArray` 顺序：

| 偏移 | 类型 | 字段 |
|---|---|---|
| 0 | int32 | status_expiration_time |
| 4 | int32 | status_auto_off_time |
| 8 | uint16 | status_reservoir_low_limit |
| 10 | uint16 | status_quick_bolus_step |
| 12 | uint16 | status_occlusion_limit |
| 14 | uint16 | status_unit_amount |
| 16 | uint16 | status_basal_rate_limit |
| 18 | uint16 | status_bolus_amount_limit |

`getSetting(index)` 的下标表：

| index | 字段 |
|---|---|
| 1 | expirationTime |
| 2 | autoOffTime |
| 3 | reservoirLowLimit |
| 4 | quickBolusStep |
| 5 | occlusionLimit |
| 6 | unitAmount |
| 7 | basalRateLimit |
| 8 | bolusAmountLimit |
| 9 | bolusStep（本地保存） |
| 10 | bolusRatio（本地保存） |
| 11 | acknowledgement（本地保存） |

## 4. monitor 的 parameter 码

| 动作 | parameter | operation | 数据区 |
|---|---|---|---|
| 对时 | 0 | SET 1 | 时间结构 |
| 读历史 | 1 | GET 2 | 序号/时间戳 |

## 5. 尚未完成（不写代码，避免剂量错误）

- **大剂量编码**：`setBolusProfile` 里有 0.025U 量化 + `mSettingBolusRatio` 的区间重排算法，还没逐行核对完，暂不提供写入。
- **排气/退针**：`setPriming(int)` 的单位未知。
- **历史记录**：`EntityHistory` 的字段布局未解析。
- **握手/ACK**：连接后首帧与 ACK 规则仍待抓包确认。

## 6. 历史记录（18 字节）

`EntityHistory.fromByteArray` 逐字节读取，布局：

| 偏移 | 含义 |
|---|---|
| 0..5 | 年、月、日、时、分、秒（十进制数值，非 BCD） |
| 6,7 | parameterByte0 / parameterByte1 |
| 8..9 | parameterShort0（小端 uint16） |
| 10..11 | parameterShort1（小端 uint16） |
| 12..13 | eventIndex（小端 uint16） |
| 14 | eventPort |
| 15 | eventType |
| 16 | eventLevel（0 通知 / 1 提醒 / 2 报警，`COUNT_URGENCY = 3`） |
| 17 | eventData |

读取请求：`EntityMessage(source=9, target=0, 5, 5, GET, 1, data=EntityNumber(1, index))`。
`deviceTime` 打包规则：`秒 + 分×100 + 时×10000 + 日×1e6 + 月×1e8 + 年×1e10`。

## 7. 大剂量算法（已逐行跟踪，单位未验证 → 暂不启用）

`PresenterDelivery.setBolusProfile(amountTotal, amountExtended, intervalExtended)`：

```
total     = round25(total)                    // round25(x) = ((x + 24) / 25) * 25
immediate = total > extended ? total - extended : 0
immediate = round25(immediate)
extended' = total - immediate
pulse     = (immediate + 49) / 50             // 以 0.05U 为一档
if pulse > 1:
    pulse = pulse * mSettingBolusRatio        // 设置项 index 10
    interval0 = (immediate * 360000) / (pulse * 25)
    if interval0 <= 11200: pulse -= 1
setInterval(0, pulse); setAmount(0, immediate)
setInterval(1, intervalExtended); setAmount(1, extended')
```

`interval0` 的量纲（毫秒/100ms 刻度）和 `mSettingBolusRatio` 的取值域还没确认真机行为，所以 iOS 端仍不开放写入。
