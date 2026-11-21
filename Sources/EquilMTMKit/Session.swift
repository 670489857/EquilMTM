import Foundation

/// 会话层：BLE → 帧解析 → 消息重组；发送时切成帧逐包写出
public final class PumpSession {
    public var address: UInt8 = PumpBus.pumpAddress   // 泵地址 = 0（EntityDevice.setAddress(0)）
    public var localPort: UInt8 = 0x00        // SDK 里 address 帧的 port 字段

    public var onMessage: ((PumpMessage) -> Void)?
    public var onFrame: ((Frame) -> Void)?
    public var onState: ((PumpBLE.State) -> Void)?

    public let ble = PumpBLE()
    private var decoder = FrameDecoder()
    private var assembler = MessageAssembler()
    private var sendQueue: [Frame] = []
    private var sending = false
    private var lastFrameSentAt = Date.distantPast
    /// 帧间隔：BLE 20ms 连接间隔下，逐帧发送至少留 15–30ms，避免泵端丢包
    public var interFrameDelay: TimeInterval = 0.02

    public init() {
        ble.onReceive = { [weak self] data in self?.receive(data) }
        ble.onStateChange = { [weak self] state in self?.onState?(state) }
    }

    public func connect() { ble.startScan() }
    public func disconnect() { ble.disconnect() }

    public func send(_ message: PumpMessage, chunkSize: Int = 20) {
        let frames = FrameEncoder.frames(for: message, chunkSize: chunkSize)
        sendQueue.append(contentsOf: frames)
        pumpQueue()
    }

    private func pumpQueue() {
        guard !sending, !sendQueue.isEmpty else { return }
        let now = Date()
        let wait = interFrameDelay - now.timeIntervalSince(lastFrameSentAt)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pumpQueue() }
            return
        }
        sending = true
        let frame = sendQueue.removeFirst()
        lastFrameSentAt = Date()
        ble.write(frame.encoded())
        DispatchQueue.main.asyncAfter(deadline: .now() + interFrameDelay) { [weak self] in
            self?.sending = false
            self?.pumpQueue()
        }
    }

    private func receive(_ data: Data) {
        for frame in decoder.feed(data) {
            onFrame?(frame)
            if let message = assembler.accept(frame) { onMessage?(message) }
        }
    }
}
