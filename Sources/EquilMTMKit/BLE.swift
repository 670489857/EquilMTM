import CoreBluetooth
import Foundation

/// 微泰泵 BLE 通道：Service F000 / Characteristic F001
public final class PumpBLE: NSObject {
    public static let serviceUUID = CBUUID(string: "0000F000-0000-1000-8000-00805F9B34FB")
    public static let characteristicUUID = CBUUID(string: "0000F001-0000-1000-8000-00805F9B34FB")

    public enum State { case idle, scanning, connecting, ready, failed(Error) }

    public var onStateChange: ((State) -> Void)?
    public var onReceive: ((Data) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func startScan() {
        guard central.state == .poweredOn else {
            onStateChange?(.failed(BLEError.bluetoothUnavailable))
            return
        }
        onStateChange?(.scanning)
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    public func stopScan() {
        central.stopScan()
    }

    public func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        characteristic = nil
        self.peripheral = nil
        onStateChange?(.idle)
    }

    /// 按帧逐包写入；若特征只支持 write-with-response 则逐包等待回调（由上层节流）
    public func write(_ frame: Data) {
        guard let peripheral, let characteristic else { return }
        peripheral.writeValue(frame, for: characteristic, type: writeType)
    }

    private func handle(_ data: Data) {
        onReceive?(data)
    }
}

public enum BLEError: Error {
    case bluetoothUnavailable
    case characteristicNotFound
    case notConnected
}

extension PumpBLE: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { onStateChange?(.failed(BLEError.bluetoothUnavailable)) }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        onStateChange?(.connecting)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onStateChange?(.failed(error ?? BLEError.notConnected))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristic = nil
        onStateChange?(.idle)
    }
}

extension PumpBLE: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics,
              let ch = chars.first(where: { $0.uuid == Self.characteristicUUID }) else {
            onStateChange?(.failed(BLEError.characteristicNotFound))
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
        handle(data)
    }
}
