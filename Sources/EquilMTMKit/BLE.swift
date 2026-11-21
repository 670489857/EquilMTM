import CoreBluetooth
import Foundation

/// 扫描到的设备
public struct PumpDevice: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var serviceUUIDs: [String]

    /// 安卓端过滤条件是名字大写后包含 "EQUIL"；这里放宽到几个常见前缀，只用于排序提示
    public var looksLikePump: Bool {
        let n = name.uppercased()
        return n.contains("EQUIL") || n.contains("MTM") || n.contains("MICROTECH")
            || n.contains("WEITAI") || n.contains("微泰")
    }
}

/// 微泰泵 BLE 通道：Service F000 / Characteristic F001
public final class PumpBLE: NSObject {
    public static let serviceUUID = CBUUID(string: "0000F000-0000-1000-8000-00805F9B34FB")
    public static let characteristicUUID = CBUUID(string: "0000F001-0000-1000-8000-00805F9B34FB")

    public enum State {
        case idle
        case bluetoothOff
        case scanning
        case connecting
        case ready
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?
    public var onDevices: (([PumpDevice]) -> Void)?
    public var onReceive: ((Data) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse

    private var found: [UUID: (peripheral: CBPeripheral, device: PumpDevice)] = [:]
    private var lastPublish = Date.distantPast
    private var pendingScan = false
    private var scanTimer: Timer?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 不过滤 service：泵的广播包里不一定带 F000，靠名字和用户选择
    public func startScan() {
        guard central.state == .poweredOn else {
            pendingScan = true
            onStateChange?(central.state == .unauthorized ? .failed("蓝牙权限被拒绝") : .bluetoothOff)
            return
        }
        pendingScan = false
        found.removeAll()
        publishDevices(force: true)
        onStateChange?(.scanning)
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    public func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        central.stopScan()
        if central.state == .poweredOn { onStateChange?(.idle) }
    }

    public func connect(_ device: PumpDevice) {
        guard let entry = found[device.id] else {
            onStateChange?(.failed("设备已失效，请重新扫描"))
            return
        }
        stopScan()
        self.peripheral = entry.peripheral
        entry.peripheral.delegate = self
        onStateChange?(.connecting)
        central.connect(entry.peripheral, options: nil)
    }

    public func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        characteristic = nil
        peripheral = nil
        onStateChange?(.idle)
    }

    /// 按帧逐包写入；若特征只支持 write-with-response 则逐包等待回调（由上层节流）
    public func write(_ frame: Data) {
        guard let peripheral, let characteristic else { return }
        peripheral.writeValue(frame, for: characteristic, type: writeType)
    }

    private func publishDevices(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) > 0.8 else { return }
        lastPublish = now
        let list = found.values
            .map(\.device)
            .sorted { a, b in
                if a.looksLikePump != b.looksLikePump { return a.looksLikePump }
                return a.rssi > b.rssi
            }
        onDevices?(list)
    }
}

public enum BLEError: Error {
    case bluetoothUnavailable
    case characteristicNotFound
    case notConnected
}

extension PumpBLE: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onStateChange?(.idle)
            if pendingScan { startScan() }
        case .unauthorized:
            onStateChange?(.failed("蓝牙权限被拒绝，去设置里打开"))
        case .poweredOff:
            onStateChange?(.bluetoothOff)
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "未命名设备"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        let device = PumpDevice(id: peripheral.identifier, name: name,
                                rssi: RSSI.intValue, serviceUUIDs: services)
        found[peripheral.identifier] = (peripheral, device)
        publishDevices()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onStateChange?(.failed("连接失败：\(error?.localizedDescription ?? "未知原因")"))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristic = nil
        onStateChange?(.idle)
    }
}

extension PumpBLE: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            onStateChange?(.failed("没有发现 F000 服务"))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        // 优先精确匹配 F001；否则退一步取第一个可写特征
        let exact = chars.first { $0.uuid == Self.characteristicUUID }
        let writable = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
        guard let ch = exact ?? writable else {
            onStateChange?(.failed("服务 \(service.uuid.uuidString) 下没有可写特征"))
            return
        }
        characteristic = ch
        writeType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: ch)
        }
        onStateChange?(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        onReceive?(data)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            onStateChange?(.failed("订阅通知失败：\(error.localizedDescription)"))
        }
    }
}
