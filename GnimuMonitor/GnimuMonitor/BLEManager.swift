import Foundation
import CoreBluetooth
import Combine

class BLEManager: NSObject, ObservableObject {

    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var buffer: [UInt8] = []
    private var lastUIUpdate: Date = .distantPast
    private let uiUpdateInterval: TimeInterval = 0.1

    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var selectedPeripheral: CBPeripheral?
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var latestPacket: GnimuPacket?
    @Published var centralStateDescription = "Initializing…"

    override init() {
        super.init()
        // queue: .main means every delegate callback arrives on the main thread,
        // so @Published mutations are always on the main thread as SwiftUI requires.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        discoveredDevices = []
        central.scanForPeripherals(withServices: nil)
        isScanning = true
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
    }

    func connect(to device: CBPeripheral) {
        stopScanning()
        connectedPeripheral = device
        device.delegate = self
        central.connect(device)
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    private func processBuffer() {
        var newestPacket: GnimuPacket?
        while buffer.count >= 88 {
            guard let syncOffset = findSync() else { buffer.removeAll(); return }
            if syncOffset > 0 { buffer.removeFirst(syncOffset) }
            guard buffer.count >= 88 else { break }
            let candidate = Data(buffer[0..<88])
            if let packet = GnimuPacket.parse(from: candidate) {
                newestPacket = packet
                buffer.removeFirst(88)
            } else {
                buffer.removeFirst(1)
            }
        }
        if let packet = newestPacket {
            let now = Date()
            if now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval {
                latestPacket = packet
                lastUIUpdate = now
            }
        }
    }

    private func findSync() -> Int? {
        for i in 0..<(buffer.count - 1) where buffer[i] == 0xB5 && buffer[i + 1] == 0x62 {
            return i
        }
        return nil
    }
}

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    centralStateDescription = "Powered on"; startScanning()
        case .poweredOff:   centralStateDescription = "Bluetooth is off"
        case .unauthorized: centralStateDescription = "Bluetooth permission denied"
        case .unsupported:  centralStateDescription = "Bluetooth not supported"
        case .resetting:    centralStateDescription = "Bluetooth resetting"
        default:            centralStateDescription = "Unknown state"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, name.hasPrefix("RaceBox") else { return }
        guard !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        discoveredDevices.append(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        buffer.removeAll()
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
        latestPacket = nil
        buffer.removeAll()
        startScanning()
    }
}

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([txCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars where char.uuid == txCharUUID {
            peripheral.setNotifyValue(true, for: char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        buffer.append(contentsOf: value)
        processBuffer()
    }
}
