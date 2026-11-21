# EquilMTM — 微泰贴泵（MTM-1）iOS 移植

目标：把 `羽aps` 里的 `cn.tking.android.aaps.pumps.equil` + 厂商 SDK `com.microtechmd.library` 移植成独立 iOS App。
设备：微泰 Equil 贴敷泵 **MTM-1**（不是 Equil 5.3 / 5.3D）。

## 结论摘要

| 项 | 状态 |
|---|---|
| 传输 | BLE，Service `0000F000`，Char `0000F001` |
| 加密 | 无（明文 + 双 CRC） |
| 帧头 | 12 字节，已用 unicorn 模拟 `DevComm_Send` 验证 ✅ |
| 校验 | CRC-8/MAXIM（byte0..4）+ CRC-16/MODBUS（byte6..7 + byte10..11 + data）✅ |
| 分片 | 单帧 ≤250 字节（数据 ≤238），offset 累加、seq 0..63、末帧 0x80 |
| 业务命令表 | ✅ 端口/参数码/实体编码已提取（见 `Docs/COMMANDS.md`） |
| 历史记录 | ✅ 18 字节布局已解析（`History.swift`） |
| Demo App | ✅ SwiftUI（连接 / 状态 / 基础率 / 临时基础率 / 历史 / 日志） |
| 握手 / ACK | ⏳ 待抓包确认 |

## 目录

```
Docs/PROTOCOL_NOTES.md        协议详细说明（含模拟验证记录）
Docs/COMMANDS.md              命令层：端口/参数码/实体字节布局
Tools/mtm1_frames.py          帧解析/组帧工具（对照抓包用）
Sources/EquilMTMKit/
  CRC.swift                   双 CRC 查表实现
  Message.swift               PumpMessage / mode / operation 枚举
  Frame.swift                 12 字节头编解码、分片、重组、校验
  BLE.swift                   CoreBluetooth 通道（F000/F001）
  Commands.swift              命令构造：端口、parameter 码、实体编码
  History.swift               18 字节历史记录解析
  Session.swift               发送队列 + 接收管线
Tests/EquilMTMKitTests/       帧编码与 SDK 实测字节对齐的断言
Package.swift                 Swift Package（iOS 15+ / macOS 12+）
project.yml                   XcodeGen 工程描述（生成带 Demo 的 iOS App）
Demo/EquilMTMDemoApp.swift    SwiftUI 演示 App
```

## 用法

Xcode：`File → Open` 选本目录的 `Package.swift`，或新建 iOS App 工程后把 `EquilMTMKit` 作为本地 Package 依赖。

```swift
let session = PumpSession()
session.onMessage = { message in print(message.operation, message.parameter, message.data) }
session.connect()

// 发送：operation/parameter 由命令表决定（待补）
session.send(PumpMessage(address: 0x01, sourcePort: 0x00, targetPort: 0x01,
                         mode: .ack, operation: .get, parameter: 0x00))
```

## 已知风险

- `address`/`port` 的真实取值、连接握手帧、ACK 规则尚未用真机确认，当前的默认值（0x01 / 0x00）来自 SDK 结构推断。
- 未在真机上验证，不能用于实际给药控制；医疗设备控制代码上线前必须完成真机回放与失败保护。
