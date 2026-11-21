import SwiftUI
import EquilMTMKit

@main
struct EquilMTMDemoApp: App {
    var body: some Scene {
        WindowGroup { PumpView() }
    }
}

/// 需要二次确认的给药动作
enum PumpAction: Identifiable {
    case bolus(total: Double, extended: Double, minutes: Int)
    case prime(units: Double)

    var id: String {
        switch self {
        case .bolus(let t, let e, let m): return "bolus-\(t)-\(e)-\(m)"
        case .prime(let u): return "prime-\(u)"
        }
    }

    var title: String {
        switch self {
        case .bolus: return "确认大剂量"
        case .prime: return "确认排气"
        }
    }

    var detail: String {
        switch self {
        case let .bolus(total, extended, minutes):
            if extended > 0 {
                return String(format: "总量 %.2f U，其中扩展 %.2f U / %d 分钟", total, extended, minutes)
            }
            return String(format: "立即推注 %.2f U", total)
        case let .prime(units):
            return String(format: "排气 %.2f U", units)
        }
    }
}

final class PumpViewModel: ObservableObject {
    @Published var stateText = "未连接"
    @Published var modeText = "未知"
    @Published var basalRates: [Double] = Array(repeating: 0, count: 48)
    @Published var tempText = "无"
    @Published var bolusText = "无"
    @Published var settings: [SettingIndex: Int] = [:]
    @Published var records: [HistoryRecord] = []
    @Published var log: [String] = []
    @Published var bolusRatio: Int = 1
    @Published var devices: [PumpDevice] = []
    @Published var scanning = false
    @Published var selectedID: UUID?

    private let session = PumpSession()

    init() {
        session.onState = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .idle: self?.stateText = "未连接"; self?.scanning = false
                case .bluetoothOff: self?.stateText = "蓝牙未打开"; self?.scanning = false
                case .scanning: self?.stateText = "扫描中…"; self?.scanning = true
                case .connecting: self?.stateText = "连接中…"; self?.scanning = true
                case .ready: self?.stateText = "已连接"; self?.scanning = false
                case .failed(let reason): self?.stateText = "失败：\(reason)"; self?.scanning = false
                }
            }
        }
        session.onMessage = { [weak self] message in
            DispatchQueue.main.async { self?.handle(message) }
        }
        session.onDevices = { [weak self] list in
            DispatchQueue.main.async {
                self?.devices = list
                self?.append("扫描到 \(list.count) 个设备")
            }
        }
        session.onFrame = { [weak self] frame in
            guard !frame.isCRCOK else { return }
            DispatchQueue.main.async { self?.append("校验失败帧：\(frame.encoded().count)B") }
        }
    }

    func scan() { session.scan() }
    func stopScan() { session.stopScan() }
    func connect(_ device: PumpDevice) {
        selectedID = device.id
        session.connect(device)
    }
    func disconnect() { session.disconnect() }

    func readAll() {
        for command in [PumpCommands.readMode(), PumpCommands.readBasalProfile(),
                        PumpCommands.readTemporaryProfile(), PumpCommands.readBolusProfile(),
                        PumpCommands.readSetting()] {
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

    func deliverBolus(total: Double, extended: Double, minutes: Int) {
        let plan = EntityCodec.bolusPlan(totalUnits: total, extendedUnits: extended,
                                         intervalSeconds: minutes * 60, bolusRatio: bolusRatio)
        session.send(PumpCommands.setBolus(plan: plan))
        append(String(format: "大剂量 %.2fU（扩展 %.2fU/%dmin）ratio=%d → a0=%d i0=%d a1=%d i1=%d",
                      total, extended, minutes, bolusRatio,
                      plan.immediateMilliUnits * 25, plan.immediatePulses,
                      plan.extendedMilliUnits, plan.intervalSeconds))
        bolusText = String(format: "已下发 %.2f U", total)
    }

    func stopBolus() {
        session.send(PumpCommands.stopBolus())
        append("停止大剂量")
        bolusText = "已停止"
    }

    func prime(units: Double) {
        session.send(PumpCommands.setPriming(units: units))
        append(String(format: "排气 %.2fU → %d", units, (EntityCodec.milliUnits(units) * 4) / 25))
    }

    func rewind() {
        session.send(PumpCommands.rewind())
        append("回填")
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
            if let parsed = EntityCodec.parseSetting(message.data) {
                settings = parsed
                if let ratio = parsed[.bolusRatio], ratio > 0 { bolusRatio = ratio }
            }
        case (PumpOperation.get, DeliveryParameter.mode.rawValue):
            modeText = "\(Int32(littleEndian: message.data))"
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

private extension Int32 {
    init(littleEndian data: Data) {
        let b = [UInt8](data.prefix(4))
        guard b.count == 4 else { self = 0; return }
        self = Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8
            | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }
}

struct PumpView: View {
    @StateObject private var vm = PumpViewModel()
    @State private var tempRate: Double = 1.0
    @State private var tempMinutes: Double = 30

    @State private var bolusTotal: Double = 0
    @State private var bolusExtended: Double = 0
    @State private var bolusMinutes: Double = 0
    @State private var primeUnits: Double = 2.0
    @State private var pending: PumpAction?

    var body: some View {
        NavigationStack {
            List {
                Section("蓝牙") {
                    HStack { Text("状态"); Spacer(); Text(vm.stateText).foregroundStyle(.secondary) }
                    HStack {
                        Button(vm.scanning ? "停止扫描" : "扫描设备") {
                            if vm.scanning { vm.stopScan() } else { vm.scan() }
                        }
                        Spacer()
                        Button("断开") { vm.disconnect() }
                        Spacer()
                        Button("读状态") { vm.readAll() }
                    }
                    ForEach(vm.devices) { device in
                        Button {
                            vm.connect(device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .foregroundStyle(device.looksLikePump ? Color.primary : Color.secondary)
                                    Text("\(device.rssi) dBm  \(device.id.uuidString.prefix(8))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vm.selectedID == device.id {
                                    Text("已选择").font(.caption).foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    if vm.devices.isEmpty {
                        Text(vm.scanning ? "正在扫描，保持泵在附近…" : "点「扫描设备」开始搜索")
                            .font(.footnote).foregroundStyle(.secondary)
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

                Section("大剂量") {
                    HStack {
                        Text("总量 U")
                        Spacer()
                        TextField("0.00", value: $bolusTotal, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("其中扩展 U")
                        Spacer()
                        TextField("0.00", value: $bolusExtended, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("扩展时长 分钟")
                        Spacer()
                        TextField("0", value: $bolusMinutes, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack { Text("泵内 bolusRatio"); Spacer(); Text("\(vm.bolusRatio)").foregroundStyle(.secondary) }
                    HStack {
                        Button("下发大剂量") {
                            pending = .bolus(total: bolusTotal, extended: bolusExtended,
                                             minutes: Int(bolusMinutes))
                        }
                        Spacer()
                        Button("停止大剂量", role: .destructive) { vm.stopBolus() }
                    }
                    .buttonStyle(.borderless)
                    Text(vm.bolusText).font(.footnote).foregroundStyle(.secondary)
                }

                Section("排气 / 回填") {
                    HStack {
                        Text("排气量 U")
                        Spacer()
                        TextField("2.00", value: $primeUnits, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Button("排气") { pending = .prime(units: primeUnits) }
                        Spacer()
                        Button("回填（换储药器）") { vm.rewind() }
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
            .alert(item: $pending) { action in
                Alert(title: Text(action.title),
                      message: Text(action.detail),
                      primaryButton: .destructive(Text("确认下发")) {
                          switch action {
                          case let .bolus(total, extended, minutes):
                              vm.deliverBolus(total: total, extended: extended, minutes: minutes)
                          case let .prime(units):
                              vm.prime(units: units)
                          }
                      },
                      secondaryButton: .cancel(Text("取消")))
            }
        }
    }
}
