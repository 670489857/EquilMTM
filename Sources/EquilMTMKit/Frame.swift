import Foundation

/// 12 字节头 + 数据。字段含义见 Docs/PROTOCOL_NOTES.md
public struct Frame: Equatable {
    public static let headerLength = 12
    public static let maxFrameLength = 0xFA          // 250
    public static let maxPayload = maxFrameLength - headerLength // 238

    public var address: UInt8
    public var port: UInt8
    public var length: UInt8          // = 12 + data.count
    public var fragmentOffset: UInt8
    public var sequence: UInt8        // 0..63
    public var isLast: Bool
    public var sourcePort: UInt8
    public var targetPort: UInt8
    public var mode: PumpMode
    public var operation: PumpOperation
    public var data: Data

    public var isCRCOK: Bool {
        let head5 = Data([address, port, length, fragmentOffset,
                          (sequence & 0x3F) | (isLast ? 0x80 : 0)])
        guard CRC.crc8(head5) == crc8 else { return false }

        var crc = CRC.crc16(Data([sourcePort, targetPort]))
        crc = CRC.crc16(Data([mode.rawValue, operation.rawValue]), init: crc)
        crc = CRC.crc16(data, init: crc)
        return crc == crc16
    }

    // 解析时保留原始校验值
    var crc8: UInt8 = 0
    var crc16: UInt16 = 0

    public init(address: UInt8, port: UInt8 = 0, sourcePort: UInt8, targetPort: UInt8,
                mode: PumpMode, operation: PumpOperation, data: Data,
                fragmentOffset: UInt8 = 0, sequence: UInt8 = 0, isLast: Bool = true) {
        self.address = address
        self.port = port
        self.sourcePort = sourcePort
        self.targetPort = targetPort
        self.mode = mode
        self.operation = operation
        self.data = data
        self.fragmentOffset = fragmentOffset
        self.sequence = sequence
        self.isLast = isLast
        self.length = UInt8(Frame.headerLength + data.count)
        let body = Data([sourcePort, targetPort])
        var crc = CRC.crc16(body)
        crc = CRC.crc16(Data([mode.rawValue, operation.rawValue]), init: crc)
        crc = CRC.crc16(data, init: crc)
        self.crc16 = crc
        let head5 = Data([address, port, self.length, fragmentOffset,
                          (sequence & 0x3F) | (isLast ? 0x80 : 0)])
        self.crc8 = CRC.crc8(head5)
    }

    public func encoded() -> Data {
        var out = Data([address, port, length, fragmentOffset,
                        (sequence & 0x3F) | (isLast ? 0x80 : 0), crc8,
                        sourcePort, targetPort,
                        UInt8(crc16 & 0xFF), UInt8(crc16 >> 8),
                        mode.rawValue, operation.rawValue])
        out.append(data)
        return out
    }
}

/// 把一条消息切成若干帧：载荷 = [operation][parameter][data...]
public enum FrameEncoder {
    public static func frames(for message: PumpMessage,
                              chunkSize: Int = Frame.maxPayload) -> [Frame] {
        precondition(chunkSize > 0 && chunkSize <= Frame.maxPayload)
        var payload = Data([message.operation.rawValue, message.parameter])
        payload.append(message.data)

        var frames: [Frame] = []
        var offset = 0
        var seq: UInt8 = 0
        repeat {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload[offset..<end]
            let last = end == payload.count
            frames.append(Frame(address: message.address, sourcePort: message.sourcePort,
                                targetPort: message.targetPort, mode: message.mode,
                                operation: message.operation, data: Data(chunk),
                                fragmentOffset: UInt8(offset), sequence: seq & 0x3F,
                                isLast: last))
            offset = end
            seq += 1
        } while offset < payload.count
        return frames
    }
}

/// 增量解析：喂字节，出完整帧
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        while buffer.count >= Frame.headerLength {
            let length = Int(buffer[buffer.startIndex + 2])
            guard length >= Frame.headerLength, length <= Frame.maxFrameLength else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            let raw = buffer.prefix(length)
            buffer.removeFirst(length)
            if let frame = FrameDecoder.parse(Data(raw)) { frames.append(frame) }
        }
        return frames
    }

    static func parse(_ raw: Data) -> Frame? {
        guard raw.count >= Frame.headerLength else { return nil }
        let b = [UInt8](raw)
        var frame = Frame(address: b[0], port: b[1], sourcePort: b[6], targetPort: b[7],
                          mode: PumpMode(rawValue: b[10]) ?? .ack,
                          operation: PumpOperation(rawValue: b[11]) ?? .event,
                          data: raw.suffix(from: Frame.headerLength),
                          fragmentOffset: b[3], sequence: b[4] & 0x3F,
                          isLast: (b[4] & 0x80) != 0)
        frame.crc8 = b[5]
        frame.crc16 = UInt16(b[8]) | (UInt16(b[9]) << 8)
        frame.length = b[2]
        return frame
    }
}

/// 多帧重组
public struct MessageAssembler {
    private var buffer: Data = Data()
    private var lastOffset = 0

    public init() {}

    public mutating func accept(_ frame: Frame) -> PumpMessage? {
        if frame.fragmentOffset == 0 { buffer = Data(); lastOffset = 0 }
        guard Int(frame.fragmentOffset) == lastOffset else { return nil }
        buffer.append(frame.data)
        lastOffset += frame.data.count
        guard frame.isLast else { return nil }

        guard buffer.count >= 2 else { return nil }
        let op = PumpOperation(rawValue: buffer[buffer.startIndex]) ?? frame.operation
        let param = buffer[buffer.startIndex + 1]
        let payload = buffer.dropFirst(2)
        return PumpMessage(address: frame.address, sourcePort: frame.sourcePort,
                           targetPort: frame.targetPort, mode: frame.mode,
                           operation: op, parameter: param, data: Data(payload))
    }
}
