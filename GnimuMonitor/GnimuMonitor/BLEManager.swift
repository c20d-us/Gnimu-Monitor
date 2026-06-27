// Gnimu Monitor
// Copyright (C) 2026 Chris Halstead
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import CoreBluetooth
import Combine

/// A device seen during a scan, with the bookkeeping needed to age it out
/// once it stops advertising. CoreBluetooth has no "disappeared" callback,
/// so freshness is inferred from how recently we last heard an advertisement.
struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    var rssi: Int
    var lastSeen: Date
    /// True once the device hasn't advertised for a while: shown dimmed and
    /// not connectable, but kept briefly in case it comes back.
    var isStale: Bool = false

    var id: UUID { peripheral.identifier }
    var name: String { peripheral.name ?? peripheral.identifier.uuidString }
}

class BLEManager: NSObject, ObservableObject {

    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// How long without an advertisement before a device is dimmed, then removed.
    /// Kept above a couple of advertising intervals so a missed beacon doesn't flicker rows.
    private let staleAfter: TimeInterval = 1.5
    private let removeAfter: TimeInterval = 3
    /// How often the prune timer re-evaluates freshness.
    private let pruneInterval: TimeInterval = 0.5
    /// How long to wait for a connection before giving up on a (possibly gone) device.
    private let connectTimeout: TimeInterval = 10

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var buffer: [UInt8] = []
    private var lastUIUpdate: Date = .distantPast
    private let uiUpdateInterval: TimeInterval = 0.1
    private var pruneTimer: Timer?
    private var connectTimer: Timer?

    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var selectedPeripheral: CBPeripheral?
    @Published var isConnected = false
    @Published var isConnecting = false
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
        // Allow duplicates so the OS keeps re-delivering advertisements; that's
        // how we refresh `lastSeen` and detect when a device drops off.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        startPruneTimer()
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    func connect(to device: CBPeripheral) {
        stopScanning()
        connectedPeripheral = device
        isConnecting = true
        device.delegate = self
        central.connect(device)
        // CoreBluetooth retries indefinitely with no error, so bound the wait
        // in case the device has gone offline since it was selected.
        connectTimer = Timer.scheduledTimer(withTimeInterval: connectTimeout, repeats: false) { [weak self] _ in
            self?.connectAttemptTimedOut()
        }
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    private func cancelConnectTimer() {
        connectTimer?.invalidate()
        connectTimer = nil
    }

    private func connectAttemptTimedOut() {
        cancelConnectTimer()
        if let p = connectedPeripheral { central.cancelPeripheralConnection(p) }
        connectedPeripheral = nil
        selectedPeripheral = nil
        isConnecting = false
    }

    /// Dim devices we haven't heard from recently and drop the long-gone ones.
    private func startPruneTimer() {
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: pruneInterval, repeats: true) { [weak self] _ in
            self?.pruneStaleDevices()
        }
    }

    private func pruneStaleDevices() {
        let now = Date()
        discoveredDevices.removeAll { now.timeIntervalSince($0.lastSeen) > removeAfter }
        for i in discoveredDevices.indices {
            discoveredDevices[i].isStale = now.timeIntervalSince(discoveredDevices[i].lastSeen) > staleAfter
        }
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
        case .poweredOn:    centralStateDescription = "Powered on"; if !isConnected { startScanning() }
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
        let rssi = RSSI.intValue
        if let i = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[i].rssi = rssi
            discoveredDevices[i].lastSeen = Date()
            discoveredDevices[i].isStale = false
        } else {
            discoveredDevices.append(DiscoveredDevice(peripheral: peripheral, rssi: rssi, lastSeen: Date()))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelConnectTimer()
        isConnecting = false
        isConnected = true
        buffer.removeAll()
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimer()
        isConnecting = false
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimer()
        isConnecting = false
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
        latestPacket = nil
        buffer.removeAll()
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
