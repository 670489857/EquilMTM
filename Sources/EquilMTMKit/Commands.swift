import Foundation

/// 设备总线上的角色与端口（从 SDK 的 EntityMessage 构造调用点提取）
public enum PumpBus {
    /// 手机端（AAPS 里 `sourceAddress = 9`）
    public static let hostAddress: UInt8 = 9
    /// 泵地址：`EntityDevice.setAddress(0)`
    public static let pumpAddress: UInt8 = 0

    public static let systemPort: UInt8 = 0
    public static let deliveryPort: UInt8 = 4
    public static let monitorPort: UInt8 = 5
}

/// PresenterDelivery 的 parameter 码（`getRemoteParameter` / `setRemoteParameter` 的第 1 个参数）
public enum DeliveryParameter: UInt8 {
    case mode = 0
    case basalProfile = 2
    case bolusProfile = 3
    case temporaryProfile = 4
    case setting = 5
    case rewinding = 6
    case priming = 7
}

/// PresenterMonitor 的 parameter 码
public enum MonitorParameter: UInt8 {
    case dateTime = 0
    case history = 1
}

/// 状态字段下标：`PresenterDelivery.getSetting(index)`
public enum SettingIndex: Int, CaseIterable {
    case expirationTime = 1
    case autoOffTime = 2
    case reservoirLowLimit = 3
    case quickBolusStep = 4
    case occlusionLimit = 5
    case unitAmount = 6
    case basalRateLimit = 7
    case bolusAmountLimit = 8
    case bolusStep = 9
    case bolusRatio = 10
    case acknowledgement = 11
}

/// 泵运行模式
public enum PumpRunMode: Int {
    case stop = 0
    case run = 1
    case suspend = 2
}

// MARK: - 实体编码

public enum EntityCodec {
    /// 基础率：48 段、每段 30 分钟、单位 0.001 U/h，写成 48 个小端 uint16
    public static func basalProfile(_ rates: [Double]) -> Data {
        precondition(rates.count == 48)
        var data = Data(capacity: 96)
        for rate in rates {
            let value = UInt16(clamping: Int((rate * 1000).rounded()))
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    /// 临时基础率：amount(int32) + interval(int32，分钟)，小端；百分比模式给 amount 置 bit31
    public static func temporaryProfile(rate: Double, minutes: Int, percent: Bool = false) -> Data {
        // 绝对值按 0.001 U/h 缩放；百分比模式直接传百分数并置 bit31
        var amount = percent ? Int32(rate.rounded()) : Int32((rate * 1000).rounded())
        if percent { amount |= Int32(bitPattern: 0x8000_0000) }
        var data = Data(capacity: 8)
        data.append(contentsOf: withUnsafeBytes(of: amount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: Int32(minutes).littleEndian, Array.init))
        return data
    }

    /// 大剂量计划：完全复刻 `PresenterDelivery.setBolusProfile(III)` 的整数运算
    public struct BolusPlan: Equatable {
        public var totalMilliUnits: Int
        public var immediateMilliUnits: Int
        public var extendedMilliUnits: Int
        public var immediatePulses: Int
        public var intervalSeconds: Int

        public init(totalMilliUnits: Int, immediateMilliUnits: Int,
                    extendedMilliUnits: Int, immediatePulses: Int,
                    intervalSeconds: Int) {
            self.totalMilliUnits = totalMilliUnits
            self.immediateMilliUnits = immediateMilliUnits
            self.extendedMilliUnits = extendedMilliUnits
            self.immediatePulses = immediatePulses
            self.intervalSeconds = intervalSeconds
        }
    }

    /// AAPS 侧把胰岛素量换算成 0.001U 整数：`amount * 1000` 后 double-to-int
    public static func milliUnits(_ units: Double) -> Int { Int(units * 1000) }

    /// 复刻 vendor 算法：量按 0.025U 取整，`mSettingBolusRatio` 参与脉冲重排
    public static func bolusPlan(totalUnits: Double, extendedUnits: Double,
                                 intervalSeconds: Int, bolusRatio: Int) -> BolusPlan {
        var total = milliUnits(totalUnits)
        total = ((total + 24) / 25) * 25
        let extendedInput = milliUnits(extendedUnits)
        var immediate = total > extendedInput ? total - extendedInput : 0
        immediate = ((immediate + 24) / 25) * 25

        let amount0 = immediate * 25               // `mul-int v1, p2, 0x19`
        var pulses = (amount0 + 49) / 50           // `(v1 + 0x31) / 0x32`
        let amount1 = total - amount0
        let ratio = bolusRatio > 0 ? bolusRatio : 1
        if pulses > 1 {
            pulses *= ratio                        // `v2 = v2 * mSettingBolusRatio`
            let interval0 = (immediate * 360000) / (pulses * 25)
            if interval0 <= 11200 { pulses -= 1 }  // `0x2bc0 = 11200`
        }
        return BolusPlan(totalMilliUnits: total, immediateMilliUnits: immediate,
                         extendedMilliUnits: amount1, immediatePulses: pulses,
                         intervalSeconds: intervalSeconds)
    }

    /// 大剂量实体：两个 profile 各 amount(int32) + interval(int32)，共 16 字节
    public static func bolusProfile(_ plan: BolusPlan) -> Data {
        var data = Data(capacity: 16)
        for value in [plan.immediateMilliUnits * 25, plan.immediatePulses,
                      plan.extendedMilliUnits, plan.intervalSeconds] {
            data.append(contentsOf: withUnsafeBytes(of: Int32(value).littleEndian, Array.init))
        }
        return data
    }

    /// 排气：`setPriming` 里 `amount * 4 / 25`（整数截断），单 int32
    public static func priming(_ units: Double) -> Data {
        let value = (milliUnits(units) * 4) / 25
        return Data(withUnsafeBytes(of: Int32(value).littleEndian, Array.init))
    }

    /// EntityNumber 序列化为 4 字节小端 int（setMode 走的这条）
    public static func number(_ value: Int) -> Data {
        Data(withUnsafeBytes(of: Int32(value).littleEndian, Array.init))
    }

    /// 设置：expiration(int32) + autoOff(int32) + 6 个 uint16
    public static func setting(expirationTime: Int32, autoOffTime: Int32,
                               reservoirLow: UInt16, quickBolusStep: UInt16,
                               occlusionLimit: UInt16, unitAmount: UInt16,
                               basalRateLimit: UInt16, bolusAmountLimit: UInt16) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: expirationTime.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: autoOffTime.littleEndian, Array.init))
        for v in [reservoirLow, quickBolusStep, occlusionLimit,
                  unitAmount, basalRateLimit, bolusAmountLimit] {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return data
    }

    /// 解析状态包
    public static func parseSetting(_ data: Data) -> [SettingIndex: Int]? {
        guard data.count >= 20 else { return nil }
        let b = [UInt8](data)
        func i32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        return [
            .expirationTime: i32(0), .autoOffTime: i32(4),
            .reservoirLowLimit: u16(8), .quickBolusStep: u16(10),
            .occlusionLimit: u16(12), .unitAmount: u16(14),
            .basalRateLimit: u16(16), .bolusAmountLimit: u16(18)
        ]
    }
}

// MARK: - 命令构造

public enum PumpCommands {
    private static func message(_ module: UInt8, _ operation: PumpOperation,
                                _ parameter: UInt8, _ data: Data = Data(),
                                mode: PumpMode = .ack) -> PumpMessage {
        PumpMessage(address: PumpBus.pumpAddress, sourcePort: module,
                    targetPort: module, mode: mode, operation: operation,
                    parameter: parameter, data: data)
    }

    // 读
    public static func readBasalProfile() -> PumpMessage {
        message(PumpBus.deliveryPort, .get, DeliveryParameter.basalProfile.rawValue)
    }

    public static func readTemporaryProfile() -> PumpMessage {
        message(PumpBus.deliveryPort, .get, DeliveryParameter.temporaryProfile.rawValue)
    }

    public static func readBolusProfile() -> PumpMessage {
        message(PumpBus.deliveryPort, .get, DeliveryParameter.bolusProfile.rawValue)
    }

    public static func readSetting() -> PumpMessage {
        message(PumpBus.deliveryPort, .get, DeliveryParameter.setting.rawValue)
    }

    public static func readMode() -> PumpMessage {
        message(PumpBus.deliveryPort, .get, DeliveryParameter.mode.rawValue)
    }

    public static func readHistory() -> PumpMessage {
        message(PumpBus.monitorPort, .get, MonitorParameter.history.rawValue)
    }

    // 写
    public static func setBasalProfile(_ rates: [Double]) -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.basalProfile.rawValue,
                EntityCodec.basalProfile(rates))
    }

    public static func setTemporaryBasal(rate: Double, minutes: Int,
                                        percent: Bool = false) -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.temporaryProfile.rawValue,
                EntityCodec.temporaryProfile(rate: rate, minutes: minutes, percent: percent))
    }

    /// 大剂量：amountTotal / amountExtended 走 0.001U，intervalExtended 走秒
    public static func setBolus(plan: EntityCodec.BolusPlan) -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.bolusProfile.rawValue,
                EntityCodec.bolusProfile(plan))
    }

    public static func setBolus(totalUnits: Double, extendedUnits: Double,
                                intervalSeconds: Int, bolusRatio: Int) -> PumpMessage {
        let plan = EntityCodec.bolusPlan(totalUnits: totalUnits, extendedUnits: extendedUnits,
                                         intervalSeconds: intervalSeconds, bolusRatio: bolusRatio)
        return setBolus(plan: plan)
    }

    /// 停止大剂量 = setBolusProfile(0, 0, 0)
    public static func stopBolus() -> PumpMessage {
        setBolus(plan: EntityCodec.BolusPlan(totalMilliUnits: 0, immediateMilliUnits: 0,
                                             extendedMilliUnits: 0, immediatePulses: 0,
                                             intervalSeconds: 0))
    }

    public static func setRunMode(_ mode: PumpRunMode) -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.mode.rawValue,
                EntityCodec.number(mode.rawValue))
    }

    /// 排气：量走 0.001U，内部换算为 `amount * 4 / 25`
    public static func setPriming(units: Double) -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.priming.rawValue,
                EntityCodec.priming(units))
    }

    public static func rewind() -> PumpMessage {
        message(PumpBus.deliveryPort, .set, DeliveryParameter.rewinding.rawValue)
    }
}
