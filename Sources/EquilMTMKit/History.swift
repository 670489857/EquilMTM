import Foundation

/// 历史记录：18 字节，来自 `EntityHistory.fromByteArray`
///
/// | 偏移 | 含义 |
/// |---|---|
/// | 0..5 | 年 月 日 时 分 秒（十进制，非 BCD） |
/// | 6,7 | parameterByte0/1 |
/// | 8..9 | parameterShort0（小端） |
/// | 10..11 | parameterShort1（小端） |
/// | 12..13 | eventIndex（小端） |
/// | 14 | eventPort |
/// | 15 | eventType |
/// | 16 | eventLevel（0 通知 / 1 提醒 / 2 报警） |
/// | 17 | eventData |
public struct HistoryRecord: Equatable {
    public var year, month, day, hour, minute, second: Int
    public var parameterBytes: [Int]
    public var parameterShorts: [Int]
    public var eventIndex: Int
    public var eventPort: Int
    public var eventType: Int
    public var eventLevel: Int
    public var eventData: Int

    public static func parse(_ data: Data) -> HistoryRecord? {
        guard data.count >= 18 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        return HistoryRecord(
            year: Int(b[0]), month: Int(b[1]), day: Int(b[2]),
            hour: Int(b[3]), minute: Int(b[4]), second: Int(b[5]),
            parameterBytes: [Int(b[6]), Int(b[7])],
            parameterShorts: [u16(8), u16(10)],
            eventIndex: u16(12),
            eventPort: Int(b[14]), eventType: Int(b[15]),
            eventLevel: Int(b[16]), eventData: Int(b[17])
        )
    }

    /// 设备时钟打包成 64 位：秒 + 分×100 + 时×1e4 + 日×1e6 + 月×1e8 + 年×1e10
    public var deviceTime: UInt64 {
        UInt64(second) + UInt64(minute) * 100 + UInt64(hour) * 10_000
            + UInt64(day) * 1_000_000 + UInt64(month) * 100_000_000
            + UInt64(year) * 10_000_000_000
    }
}

/// 读历史请求的数据区：`EntityNumber(1, index)`
public enum HistoryQuery {
    public static func payload(index: Int32) -> Data {
        var data = Data([0x01])
        data.append(contentsOf: withUnsafeBytes(of: index.littleEndian, Array.init))
        return data
    }
}
