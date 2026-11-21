# 微泰贴泵（MTM-1）协议笔记 v2

> 数据源：`羽aps` / `3.4.2.6智慧度aaps` 的 `cn.tking.android.aaps.pumps.equil` + 厂商 SDK `com.microtechmd.library` + `libjni_interface.so`（arm64-v8a，带符号）。
> 本文结论全部来自反汇编 **+ unicorn 模拟执行验证**，不是猜测；未经真机验证的部分会明确标注。

---

## 1. 与 Equil 5.3（B 包）的区别

| | 微泰 MTM-1（本文） | Equil 5.3 / 5.3D |
|---|---|---|
| 驱动 | `cn.tking.android.aaps.pumps.equil`（羽aps） | `app.aaps.pump.equil` |
| 底层 | 厂商 SDK + `libjni_interface.so` | 纯 Kotlin 自研 |
| 加密 | **无**（明文 + 双 CRC） | AES-256-GCM |
| 传输 | BLE `0000F000` / `0000F001` | 同左 |
| 报文 | 12 字节头 + 分片载荷 | port+code+tag+iv+密文 |

两者的 UUID 相同但协议不兼容。

---

## 2. 调用链

```
EquilPumpBLE → PresenterDelivery / PresenterMonitor / PresenterSystem
            → ServiceRemote / TaskRemoteComm（端口=1，队列 + ACK + 重发）
            → PeripheralDevice → PeripheralBLE（GATT 写 F001 / 订阅通知）
            → JNIInterface.send(address, sourcePort, targetPort, mode, operation, parameter, data)
            → TaskComm_Send → 队列 → 写线程 → DevComm_Send → 组帧 → 写出
```

`JNIInterface.send` 的参数名在 smali 的 `MethodParameters` 里可直接读到：
`address, sourcePort, targetPort, mode, operation, parameter, data`。
`TaskRemoteComm.getPort()` 返回 `1`。

---

## 3. 帧格式（已确认）

每个 BLE 包是一帧，**12 字节头 + 数据**：

| 偏移 | 长度 | 字段 | 说明 |
|---|---|---|---|
| 0 | 1 | address | 目标设备地址（本机为泵地址，SDK 里由 `DevComm_Initialize` 的 config[0] 设定） |
| 1 | 1 | port | `TaskComm_Send` 传入，实测为 0 |
| 2 | 1 | length | **整帧长度 = 12 + 本帧数据长度**（不是数据长度本身） |
| 3 | 1 | offset | 本帧数据在整条消息中的偏移，逐帧累加 |
| 4 | 1 | seq | 序号 0..63；**最后一帧置 bit7（0x80）**；另有 bit6(0x40) 标志 |
| 5 | 1 | CRC8 | 对 byte0..byte4 的 CRC-8/MAXIM（poly 0x8C，init 0） |
| 6 | 1 | sourcePort | 源端口 |
| 7 | 1 | targetPort | 目标端口 |
| 8 | 2 | CRC16 | **小端**，对 `byte6..7 + byte10..11 + 数据区` 的 CRC-16/MODBUS（poly 0xA001，init 0xFFFF） |
| 10 | 1 | mode | 0=ACK，1=NO_ACK |
| 11 | 1 | operation | 0=EVENT 1=SET 2=GET 3=WRITE 4=READ 5=NOTIFY 6=ACK |
| 12 | n | data | 载荷，**前两字节 = operation、parameter，其后才是业务数据** |

校验顺序（`DevComm_Send` 实际执行）：

1. 先算 CRC16：`crc = CRC16(byte6..7, init=0xFFFF)` → `crc = CRC16(byte10..11, crc)` → `crc = CRC16(data, crc)`，结果写 byte8..9。
2. 再算 CRC8：`CRC8(byte0..4)` 写 byte5。
3. 数据拷到 byte12 起，长度字段 = 12 + 数据长度。

### 模拟验证记录

用 unicorn 直接执行 `DevComm_Send(addr=0, port=0, srcPort=0x11, dstPort=0x22, data=[AA BB CC DD], len=4, mode=0)`，实际在设备结构里生成：

```
01 00 06 00 00 1C | 11 22 | 42 69 | 00 33 | AA BB CC DD
^  ^  ^  ^  ^  ^     ^  ^    ^  ^    ^  ^
|  |  |  |  |  CRC8  |  |    CRC16  mode op
|  |  |  |  seq      源端口 目标端口
|  |  |  offset
|  |  length（该次因为分片长度参数异常而溢出成 0x06，正常应为 12+n）
|  port
address
```

校验：`CRC8(01 00 06 00 00)=0x1C` ✅；`CRC16(11 22 → 00 33 → AA BB CC DD)=0x6942` ✅（与帧内 `42 69` 一致）。

### 分片

- 单帧上限 `0xFA`（250 字节，含 12 字节头），即每片业务数据最多 238 字节。
- 超过则按 offset 连续切分，seq 递增，末帧 `seq|0x80`。
- 接收端按 `offset` 拼回整条消息，用 `length-12` 取数据长度。

### 尚未确认

1. `address` / `port` 的实际取值（需要真机抓一次连接首帧）。
2. 连接握手（`DevComm_Link` / `TaskComm_SetConfig` 的参数）与心跳 `DevComm_Tick` 周期。
3. ACK 行为：`mode=ACK` 时对端回什么、超时重发参数（在 `TaskRemoteComm` Java 层，后续补）。
4. 业务命令表：每个动作（基础率、大剂量、暂停、读历史）对应的 `sourcePort/targetPort/operation/parameter`，需从 `PresenterDelivery`/`PresenterMonitor` 的调用点逐个提取。

---

## 4. 下一步

1. 从 SDK 的 `Presenter*` 方法里提取「端口 + operation + parameter」命令表（纯静态，可继续做）。
2. 抓一次 BLE 抓包锁定 address/port 与握手帧（10 秒即可）。
3. 输出 Swift 实现（CoreBluetooth）并用工具回放校验帧。

---

## 6. 连接与链路（Java 层可读部分）

- `EntityDevice.setInterface(1)` → BLE（2 才是经典蓝牙）；`setBond(1)` 表示需要绑定。
- `PeripheralDevice.connect()` → `PeripheralBLE.connect(MAC)`；断开时调 `JNIInterface.switchLink(index, 0)` 再 `switchLink(index, 1)`。
- `TaskRemoteComm` 常量：`INTERVAL_CONNECTION_TIMEOUT = 0x2710`（10 秒）、`INTERVAL_LINK_CHECK = 0x64`（100 ms 链路轮询）。
- 消息在 Java 层先 `EntityMessage.toByteArray()` 入队，再由 native 写线程组帧，Java 只管「逻辑消息」。

### 仍需真机确认

1. 连接后是否要先发一条 system 模块（port 0）的 SET 消息做握手。
2. `mode=0`（ACK）与 `mode=1`（NO_ACK）分别对应哪些命令；泵的 ACK 是独立帧还是带 operation=6 的应答。
3. 超时重发次数（Java 层未见显式重试常量，可能由 `MessageList` 的定时器驱动）。
