import Foundation

/// SDK 里的 operation 枚举（EntityMessage 6 号字段）
public enum PumpOperation: UInt8 {
    case event = 0
    case set = 1
    case get = 2
    case write = 3
    case read = 4
    case notify = 5
    case acknowledge = 6
}

/// 应答模式（EntityMessage 5 号字段）
public enum PumpMode: UInt8 {
    case ack = 0
    case noAck = 1
}

/// 一条设备总线消息（对应 SDK 的 EntityMessage）
public struct PumpMessage {
    public var address: UInt8
    public var sourcePort: UInt8
    public var targetPort: UInt8
    public var mode: PumpMode
    public var operation: PumpOperation
    public var parameter: UInt8
    public var data: Data

    public init(address: UInt8, sourcePort: UInt8, targetPort: UInt8,
                mode: PumpMode = .ack, operation: PumpOperation,
                parameter: UInt8, data: Data = Data()) {
        self.address = address
        self.sourcePort = sourcePort
        self.targetPort = targetPort
        self.mode = mode
        self.operation = operation
        self.parameter = parameter
        self.data = data
    }
}
