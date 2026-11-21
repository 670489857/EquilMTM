import SwiftUI
import EquilMTMKit

@main
struct EquilMTMDemoApp: App {
    var body: some Scene {
        WindowGroup { PumpView() }
    }
}

final class PumpViewModel: ObservableObject {
    @Published var stateText = "未连接"
    @Published var modeText = "未知"
    @Published var basalRates: [Double] = Array(repeating: 0, count: 48)
    @Published var tempText = "无"
    @Published var settings: [SettingIndex: Int] = [:]
    @Published var records: [HistoryRecord] = []
    @Published var log: [String] = []

    private let session = PumpSession()

    init() {
        session.onState = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .idle: self?.stateText = "未连接"
                case .scanning: self?.stateText = "扫描中…"
                case .connecting: self?.stateText = "连接中…"
                case .ready: self?.stateText = "已连接"
                case .failed(let error): self?.stateText = "失败：\(error)"
                }
            }
        }
        session.onMessage = { [weak self] message in
            DispatchQueue.main.async { self?.handle(message) }
        }
        session.onFrame = { [weak self] frame in
            guard !frame.isCRCOK else { return }
            DispatchQueue.main.async { self?.append("校验失败帧：\(frame.encoded().count)B") }
        }
    }

    func connect() { session.connect() }
    func disconnect() { session.disconnect() }

    func readAll() {
        for command in [PumpCommands.readMode(), PumpCommands.readBasalProfile(),
                        PumpCommands.readTemporaryProfile(), PumpCommands.readSetting()] {
            session.send(command)
        }
        append("读取状态")
    }

    func setBasal(_ rates: [Double]) {
        session.send(PumpCommands.setBasalProfile(rates))
        append("写入基础率")
    }

    func setTemp(rate: Double, minutes: Int) {
        session.send(PumpCommands.setTemporaryBasal(rate: rate, minutes: minutes))
        append(String(format: "临时基础率 %.2f U/h × %d 分钟", rate, minutes))
    }

    func readHistory() {
        var message = PumpCommands.readHistory()
        message.data = HistoryQuery.payload(index: Int32(records.count))
        session.send(message)
        append("读历史 index=\(records.count)")
    }

    func setRun(_ mode: PumpRunMode) {
        session.send(PumpCommands.setRunMode(mode))
        append("模式 → \(mode)")
    }

    private func handle(_ message: PumpMessage) {
        append("收到 op=\(message.operation) param=\(message.parameter) \(message.data.count)B")
        switch (message.operation, message.parameter) {
        case (PumpOperation.get, DeliveryParameter.basalProfile.rawValue):
            parseBasal(message.data)
        case (PumpOperation.get, DeliveryParameter.setting.rawValue):
            if let parsed = EntityCodec.parseSetting(message.data) { settings = parsed }
        case (PumpOperation.get, DeliveryParameter.mode.rawValue):
            modeText = "\(message.data.first ?? 0)"
        case (PumpOperation.get, DeliveryParameter.temporaryProfile.rawValue):
            parseTemp(message.data)
        case (_, MonitorParameter.history.rawValue):
            if let record = HistoryRecord.parse(message.data) {
                records.insert(record, at: 0)
            }
        default:
            break
        }
    }

    private func parseBasal(_ data: Data) {
        guard data.count >= 96 else { return }
        let b = [UInt8](data)
        basalRates = (0..<48).map { i in
            Double(Int(b[i * 2]) | Int(b[i * 2 + 1]) << 8) / 1000
        }
    }

    private func parseTemp(_ data: Data) {
        guard data.count >= 8 else { return }
        let b = [UInt8](data)
        let amount = Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8
            | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        let minutes = Int32(bitPattern: UInt32(b[4]) | UInt32(b[5]) << 8
            | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        if amount < 0 {
            tempText = "百分比 \(UInt32(bitPattern: amount) & 0x7FFF_FFFF)% × \(minutes) 分钟"
        } else {
            tempText = String(format: "%.3f U/h × %d 分钟", Double(amount) / 1000, minutes)
        }
    }

    private func append(_ line: String) {
        log.insert("\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))  \(line)", at: 0)
        if log.count > 40 { log.removeLast() }
    }
}

struct PumpView: View {
    @StateObject private var vm = PumpViewModel()
    @State private var tempRate: Double = 1.0
    @State private var tempMinutes: Double = 30

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    HStack { Text("状态"); Spacer(); Text(vm.stateText).foregroundStyle(.secondary) }
                    HStack {
                        Button("连接") { vm.connect() }
                        Spacer()
                        Button("断开") { vm.disconnect() }
                        Spacer()
                        Button("读状态") { vm.readAll() }
                    }
                }

                Section("运行") {
                    HStack { Text("模式"); Spacer(); Text(vm.modeText).foregroundStyle(.secondary) }
                    HStack {
                        Button("运行") { vm.setRun(.run) }
                        Spacer()
                        Button("暂停") { vm.setRun(.suspend) }
                        Spacer()
                        Button("停止") { vm.setRun(.stop) }
                    }
                    .buttonStyle(.borderless)
                }

                Section("临时基础率") {
                    HStack { Text("速率"); Spacer(); Text(String(format: "%.2f U/h", tempRate)) }
                    Slider(value: $tempRate, in: 0...10, step: 0.05)
                    HStack { Text("时长"); Spacer(); Text("\(Int(tempMinutes)) 分钟") }
                    Slider(value: $tempMinutes, in: 0...240, step: 30)
                    Button("下发") { vm.setTemp(rate: tempRate, minutes: Int(tempMinutes)) }
                    Text(vm.tempText).foregroundStyle(.secondary)
                }

                Section("基础率（48 段 / 30 分钟）") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                        ForEach(0..<48, id: \.self) { i in
                            Text(String(format: "%.2f", vm.basalRates[i]))
                                .font(.footnote.monospacedDigit())
                        }
                    }
                }

                Section("历史记录（\(vm.records.count)）") {
                    Button("读一条历史") { vm.readHistory() }
                    ForEach(vm.records.indices, id: \.self) { i in
                        let r = vm.records[i]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                                        r.year, r.month, r.day, r.hour, r.minute, r.second))
                                .font(.footnote.monospacedDigit())
                            Text("type=\(r.eventType) level=\(r.eventLevel) data=\(r.eventData) "
                                 + "p=\(r.parameterShorts.map(String.init).joined(separator: ","))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("日志") {
                    ForEach(vm.log, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("微泰 MTM-1")
        }
    }
}
