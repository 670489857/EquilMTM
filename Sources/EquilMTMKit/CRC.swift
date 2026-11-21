import Foundation

/// CRC-8/MAXIM：poly 0x8C（反射），init 0 — 帧头 byte0..4
/// CRC-16/MODBUS：poly 0xA001，init 0xFFFF — 帧头 byte6..7 + byte10..11 + 数据
public enum CRC {
    private static let table8: [UInt8] = (0..<256).map { i -> UInt8 in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        return c
    }

    private static let table16: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }

    public static func crc8(_ bytes: some Sequence<UInt8>, init value: UInt8 = 0) -> UInt8 {
        var c = value
        for b in bytes { c = table8[Int(c ^ b)] }
        return c
    }

    public static func crc16(_ bytes: some Sequence<UInt8>, init value: UInt16 = 0xFFFF) -> UInt16 {
        var c = value
        for b in bytes { c = table16[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }
}
