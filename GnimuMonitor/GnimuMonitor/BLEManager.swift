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
#if canImport(UIKit)
import UIKit
#endif

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

    /// What the scan says the device speaks. A label from the name alone is only
    /// a first guess (`isProtocolConfirmed` false): an advertisement that carries
    /// a service replaces it, and once confirmed it never changes, since a later
    /// advertisement may omit the service the earlier one carried. Connecting
    /// settles it for good, from the services the device actually exposes.
    var deviceProtocol: DeviceProtocol
    var isProtocolConfirmed: Bool

    /// The name from the latest advertisement. `peripheral.name` is the OS's
    /// cached copy, which keeps a device's old name until the next connection.
    var advertisedName: String?

    var id: UUID { peripheral.identifier }
    var name: String { advertisedName ?? peripheral.name ?? peripheral.identifier.uuidString }
}

/// One sample in the fix-rate history: satellite count paired with the iTOW
/// rate at that moment, so the chart can correlate the two.
struct FixRateSample {
    let sv: Int
    let hz: Double
    /// Fixes missing from the iTOW sequence during this sample, so the chart can
    /// mark where the stream broke rather than only where the rate sagged.
    let missed: Int
}

class BLEManager: NSObject, ObservableObject {

    /// The protocol of the device being read.
    /// The protocol of the device being read. Set from the scan, and corrected
    /// when the connected device's services say otherwise.
    private(set) var deviceProtocol = DeviceProtocol.raceBox

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
    /// Where commands are written, once discovered on the connected device.
    private var commandCharacteristic: CBCharacteristic?
    private var configCharacteristic: CBCharacteristic?
    private var session = DeviceProtocol.raceBox.makeSession()
    private var lastUIUpdate: Date = .distantPast
    private let uiUpdateInterval: TimeInterval = 0.1
    private var pruneTimer: Timer?
    private var connectTimer: Timer?
    private var rateTimer: Timer?
    #if DEBUG
    /// The debug replay in progress, if any. See `startReplay`.
    private var replayTask: Task<Void, Never>?
    /// How many advertisements of each device `-logAdvertisements` has printed.
    private var loggedAdvertisements: [UUID: Int] = [:]
    #endif

    /// Derives fix-rate health from the iTOW timestamps of every parsed packet
    /// (not just those that pass the UI throttle).
    private var rateTracker = FixRateTracker()

    /// Owns capture-to-disk. Held here rather than in a view so recording
    /// survives the user swiping between panels.
    let recorder = SessionRecorder()

    /// Analysis lives here for the same reason: a run started when a capture
    /// finishes has to outlive whichever panel happened to be on screen.
    let analysisRunner = AnalysisRunner()

    private var cancellables = Set<AnyCancellable>()
    private let rateHistoryCapacity = 60   // ~1 sample per second

    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var selectedPeripheral: CBPeripheral?
    /// The selected device's name as the picker showed it, for the title and
    /// capture header: `selectedPeripheral?.name` can still be a stale cached name.
    @Published var selectedDeviceName: String?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var isScanning = false
    /// What the connected device has reported, merged across notifications and
    /// published at the UI throttle. Nil until the first frame arrives.
    @Published var telemetry: TelemetryState?
    /// The same state, kept current on every frame between UI updates.
    private var liveState = TelemetryState()

    /// How a Gnimu-protocol stream is doing, judged from its frame headers and
    /// refreshed once a second. Empty for a protocol with no such header.
    @Published var streamHealth: StreamHealthReading = .empty
    /// Value changes per second by vehicle channel key (see ChannelChangeTracker).
    @Published var channelRates: [String: Double] = [:]
    /// Notifications this connection dropped as not valid frames.
    @Published var rejectedNotifications = 0
    private var streamTracker = StreamHealthTracker()
    private var channelTracker = ChannelChangeTracker()
    @Published var centralStateDescription = "Initializing…"

    /// True once the connected device is found to offer the configuration
    /// characteristic and a way to take commands: that is, newer Gnimu
    /// firmware. The Device panel appears only then.
    @Published var supportsDeviceControl = false

    /// What the device says about itself, read once after connecting. The
    /// identity comes from the standard Device Information Service; the schema
    /// and device info are the Gnimu protocol's own characteristics.
    @Published var deviceIdentity = DeviceIdentity()
    @Published var gnimuSchema: GnimuSchema?
    @Published var gnimuDeviceInfo: GnimuDeviceInfo?
    /// The device's configuration text, parsed. Nil until the read returns.
    @Published var deviceConfig: DeviceConfig?

    /// Why the connection just ended, when the app caused it on purpose. The
    /// picker shows it so a restart or shutdown doesn't look like a crash.
    @Published var deviceNotice: DeviceNotice?
    private var noticeTimer: Timer?

    /// Fix-rate health derived from iTOW deltas — actual GNSS fix generation,
    /// unaffected by BLE transport jitter.
    @Published var fixRate: FixRateReading = .empty
    /// Rolling history of `(sv count, iTOW-rate Hz)` samples, one per second,
    /// newest last. Charted together to correlate fix rate with SV count.
    @Published var rateHistory: [FixRateSample] = []

    override init() {
        super.init()
        // queue: .main means every delegate callback arrives on the main thread,
        // so @Published mutations are always on the main thread as SwiftUI requires.
        central = CBCentralManager(delegate: self, queue: .main)
        #if DEBUG
        if Self.logsAdvertisements { NSLog("Gnimu Monitor: advertisement logging is on") }
        #endif

        // A finished capture is analysed straight away. The parse takes seconds,
        // and a report that's already waiting beats one the user has to
        // remember to ask for.
        recorder.$lastCapture
            .compactMap { $0 }
            .sink { [weak self] capture in self?.autoAnalyze(capture) }
            .store(in: &cancellables)
    }

    /// Kicks off analysis of a capture that has just been filed.
    private func autoAnalyze(_ capture: CompletedCapture) {
        #if os(iOS)
        // Recording also stops when the app is backgrounded, and an analysis
        // started there would be cancelled before it got anywhere. Leave those
        // for the Analysis panel to offer.
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        analysisRunner.analyze(url: capture.url)
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        #if DEBUG
        if Self.logsAdvertisements { NSLog("Gnimu Monitor: scanning started") }
        #endif
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

    func connect(to device: DiscoveredDevice) {
        dismissNotice()
        stopScanning()
        deviceProtocol = device.deviceProtocol
        session = deviceProtocol.makeSession()
        selectedDeviceName = device.name
        connectedPeripheral = device.peripheral
        isConnecting = true
        device.peripheral.delegate = self
        central.connect(device.peripheral)
        // CoreBluetooth retries indefinitely with no error, so bound the wait
        // in case the device has gone offline since it was selected.
        connectTimer = Timer.scheduledTimer(withTimeInterval: connectTimeout, repeats: false) { [weak self] _ in
            self?.connectAttemptTimedOut()
        }
    }

    /// The rate the device is meant to hold, for a capture's header: what the
    /// fix-rate tracker has inferred for RaceBox, or what a Gnimu-protocol
    /// device declares in its schema.
    var captureNominalHz: Double? {
        switch deviceProtocol {
        case .raceBox: return fixRate.nominalHz
        case .gnimu: return gnimuSchema?.rateHz
        }
    }

    func disconnect() {
        #if DEBUG
        if replayTask != nil { stopReplay(); return }
        #endif
        guard let p = connectedPeripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Sends a command to the device. Written without response: the device
    /// never replies, and a restart or shutdown simply drops the connection.
    func send(_ command: DeviceCommand) {
        guard let p = connectedPeripheral, let char = commandCharacteristic else { return }
        if command.dropsConnection {
            setNotice(DeviceNotice(command: command, deviceName: selectedDeviceName))
        }
        p.writeValue(command.frame, for: char, type: .withoutResponse)
    }

    func dismissNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        deviceNotice = nil
    }

    /// Shows a notice, and takes it down again after a while: a restarted
    /// device is back within seconds, and a message that lingers is worse than none.
    private func setNotice(_ notice: DeviceNotice) {
        dismissNotice()
        deviceNotice = notice
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.dismissNotice()
        }
    }

    private func clearDeviceControl() {
        commandCharacteristic = nil
        configCharacteristic = nil
        supportsDeviceControl = false
        deviceConfig = nil
        deviceIdentity = DeviceIdentity()
        gnimuSchema = nil
        gnimuDeviceInfo = nil
    }

    private func updateDeviceControlSupport() {
        supportsDeviceControl = commandCharacteristic != nil && configCharacteristic != nil
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
        selectedDeviceName = nil
        isConnecting = false
    }

    /// Dim devices we haven't heard from recently and drop the long-gone ones.
    private func startPruneTimer() {
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: pruneInterval, repeats: true) { [weak self] _ in
            self?.pruneStaleDevices()
        }
    }

    // MARK: - Fix-rate tracking

    private func recordPacketArrival(itow: UInt32) {
        rateTracker.record(itow: itow)
    }

    private func startRateTimer() {
        rateTimer?.invalidate()
        rateHistory = []
        fixRate = .empty
        rateTracker.reset()
        resetStreamHealth()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleRates()
        }
    }

    private func stopRateTimer() {
        rateTimer?.invalidate()
        rateTimer = nil
        rateTracker.reset()
        resetStreamHealth()
        fixRate = .empty
        rateHistory = []
    }

    private func resetStreamHealth() {
        streamTracker.reset()
        channelTracker.reset()
        streamHealth = .empty
        channelRates = [:]
        rejectedNotifications = 0
    }

    private func sampleRates() {
        let reading = rateTracker.evaluate()
        fixRate = reading

        if liveState.header != nil {
            streamHealth = streamTracker.evaluate(nominalHz: gnimuSchema?.rateHz)
            channelRates = channelTracker.rates()
            rejectedNotifications = session.rejectedNotifications
        }

        rateHistory.append(FixRateSample(sv: telemetry?.gnss?.satellites ?? 0,
                                         hz: reading.hz,
                                         missed: reading.missedFixes))
        if rateHistory.count > rateHistoryCapacity {
            rateHistory.removeFirst(rateHistory.count - rateHistoryCapacity)
        }
    }

    private func pruneStaleDevices() {
        let now = Date()
        discoveredDevices.removeAll { now.timeIntervalSince($0.lastSeen) > removeAfter }
        for i in discoveredDevices.indices {
            discoveredDevices[i].isStale = now.timeIntervalSince(discoveredDevices[i].lastSeen) > staleAfter
        }
    }

    private func ingest(_ notification: Data, from characteristic: CBUUID) {
        let now = Date()
        var received = false
        for frame in session.receive(notification, from: characteristic) {
            // Record every frame for rate tracking and capture (not just
            // those that survive the UI throttle below).
            if let epoch = frame.gnssEpochMs { recordPacketArrival(itow: epoch) }
            recorder.record(frame: frame.raw)
            liveState.apply(frame.update, at: now)
            if let header = frame.update.header {
                streamTracker.record(deviceTimeMs: header.deviceTimeMs, sequence: header.sequence, at: now)
            }
            if let vehicle = frame.update.vehicle {
                channelTracker.record(VehicleChannel.values(in: vehicle), at: now)
            }
            received = true
        }
        if received, now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval {
            #if DEBUG
            telemetry = DemoLaunch.relocated(liveState)   // -fakeLocation, for screenshots
            #else
            telemetry = liveState
            #endif
            lastUIUpdate = now
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    centralStateDescription = "Powered on"; if !isConnected { startScanning() }
        case .poweredOff:   centralStateDescription = "Bluetooth is off"; handleBluetoothUnavailable()
        case .unauthorized: centralStateDescription = "Bluetooth permission denied"; handleBluetoothUnavailable()
        case .unsupported:  centralStateDescription = "Bluetooth not supported"; handleBluetoothUnavailable()
        case .resetting:    centralStateDescription = "Bluetooth resetting"; handleBluetoothUnavailable()
        default:            centralStateDescription = "Unknown state"; handleBluetoothUnavailable()
        }
    }

    /// Bluetooth became unavailable (e.g. user turned it off): stop reflecting a
    /// scan that can no longer run and clear the now-defunct device list.
    private func handleBluetoothUnavailable() {
        isScanning = false
        pruneTimer?.invalidate()
        pruneTimer = nil
        discoveredDevices = []
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        #if DEBUG
        logAdvertisement(of: peripheral, advertisementData, rssi: rssi)
        #endif
        // Only some advertisements carry the name (it rides in the scan
        // response), so a missing one says nothing about the name.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let i = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[i].rssi = rssi
            discoveredDevices[i].lastSeen = Date()
            discoveredDevices[i].isStale = false
            if let advertisedName, advertisedName != discoveredDevices[i].advertisedName {
                discoveredDevices[i].advertisedName = advertisedName
                sortDiscoveredDevices()
            }
            // A guess from the name gives way to an advertisement that carries
            // a service; a confirmed label is never revisited.
            if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                let label = DeviceProtocol.Identification(
                    deviceProtocol: discoveredDevices[i].deviceProtocol,
                    isConfirmed: discoveredDevices[i].isProtocolConfirmed)
                    .refined(byAdvertisedServices: services)
                discoveredDevices[i].deviceProtocol = label.deviceProtocol
                discoveredDevices[i].isProtocolConfirmed = label.isConfirmed
            }
        } else {
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard let found = DeviceProtocol.identify(name: advertisedName ?? peripheral.name,
                                                      advertisedServices: services) else { return }
            discoveredDevices.append(DiscoveredDevice(peripheral: peripheral, rssi: rssi, lastSeen: Date(),
                                                      deviceProtocol: found.deviceProtocol,
                                                      isProtocolConfirmed: found.isConfirmed,
                                                      advertisedName: advertisedName))
            sortDiscoveredDevices()
        }
    }

    /// Advertisements arrive in an arbitrary order, so keep the list sorted by
    /// name for a stable picker. `localizedStandardCompare` orders embedded
    /// numbers naturally ("Gnimu-RB 2" before "Gnimu-RB 10"); the UUID
    /// tiebreak keeps identically named devices from shuffling between sorts.
    private func sortDiscoveredDevices() {
        discoveredDevices.sort {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelConnectTimer()
        isConnecting = false
        isConnected = true
        session.reset()
        clearDeviceControl()
        recorder.beginSession()
        startRateTimer()
        // Ask for every protocol's service, not just the one the scan guessed,
        // so the right one is found even if the guess was wrong.
        peripheral.discoverServices(DeviceProtocol.allServiceUUIDs
                                    + [GnimuDevice.serviceUUID, DeviceIdentity.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimer()
        isConnecting = false
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
        selectedDeviceName = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimer()
        stopRateTimer()
        // Flush and file whatever was captured rather than losing the tail.
        recorder.stop()
        isConnecting = false
        isConnected = false
        connectedPeripheral = nil
        selectedPeripheral = nil
        selectedDeviceName = nil
        telemetry = nil
        liveState = TelemetryState()
        session.reset()
        clearDeviceControl()
    }
}

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        // The services the device actually exposes are the last word on what it
        // speaks. If the scan guessed otherwise (a name can be overridden), go
        // with the services.
        if let actual = DeviceProtocol.resolve(discoveredServices: services.map(\.uuid)),
           actual != deviceProtocol {
            deviceProtocol = actual
            session = actual.makeSession()
        }

        for service in services {
            switch service.uuid {
            case deviceProtocol.serviceUUID:
                switch deviceProtocol {
                case .raceBox:
                    peripheral.discoverCharacteristics(
                        deviceProtocol.notifyCharacteristicUUIDs + [GnimuDevice.commandCharacteristicUUID],
                        for: service)
                case .gnimu:
                    peripheral.discoverCharacteristics(
                        deviceProtocol.notifyCharacteristicUUIDs
                            + [DeviceProtocol.gnimuSchemaCharacteristicUUID,
                               DeviceProtocol.gnimuDeviceInfoCharacteristicUUID],
                        for: service)
                }
            case GnimuDevice.serviceUUID:
                peripheral.discoverCharacteristics([GnimuDevice.configCharacteristicUUID], for: service)
            case DeviceIdentity.serviceUUID:
                peripheral.discoverCharacteristics(DeviceIdentity.characteristicUUIDs, for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if deviceProtocol.notifyCharacteristicUUIDs.contains(char.uuid) {
                peripheral.setNotifyValue(true, for: char)
                continue
            }
            switch char.uuid {
            case GnimuDevice.commandCharacteristicUUID:
                commandCharacteristic = char
            case GnimuDevice.configCharacteristicUUID:
                configCharacteristic = char
                // Fixed at boot, so one read is enough.
                peripheral.readValue(for: char)
            case DeviceProtocol.gnimuSchemaCharacteristicUUID,
                 DeviceProtocol.gnimuDeviceInfoCharacteristicUUID:
                // Both describe the device as set up, and don't change while
                // connected: one read each.
                peripheral.readValue(for: char)
            default:
                if DeviceIdentity.characteristicUUIDs.contains(char.uuid) {
                    peripheral.readValue(for: char)
                }
            }
        }
        updateDeviceControlSupport()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        if deviceProtocol.notifyCharacteristicUUIDs.contains(uuid) {
            ingest(value, from: uuid)
        } else if uuid == GnimuDevice.configCharacteristicUUID {
            deviceConfig = String(data: value, encoding: .utf8).flatMap { DeviceConfig(text: $0) }
        } else if uuid == DeviceProtocol.gnimuSchemaCharacteristicUUID {
            gnimuSchema = GnimuSchema.parse(value)
        } else if uuid == DeviceProtocol.gnimuDeviceInfoCharacteristicUUID {
            gnimuDeviceInfo = GnimuDeviceInfo.parse(value)
        } else {
            var identity = deviceIdentity
            if identity.record(value, for: uuid) { deviceIdentity = identity }
        }
    }
}


#if DEBUG
// MARK: - Replay (debug builds only)

extension BLEManager {
    /// Plays `capture` back through the live path, as if a device of its
    /// protocol were connected and sending at the recorded times. Each frame
    /// goes through `ingest` like a real notification, so the decoder, the
    /// state merge and the throttle are all exercised. Ends at the last frame,
    /// leaving the final state on screen, or loops.
    func startReplay(_ capture: ReplayCapture, speed: Double = 1, loop: Bool = false) {
        stopReplay()
        deviceProtocol = capture.deviceProtocol
        session = capture.deviceProtocol.makeSession()
        liveState = TelemetryState()
        telemetry = nil
        selectedDeviceName = capture.deviceName.map { "\($0) (replay)" } ?? "Replay"
        isConnecting = false
        isConnected = true
        startRateTimer()

        let pace = max(speed, 0.01)
        replayTask = Task { [weak self] in
            repeat {
                let clock = ContinuousClock()
                let start = clock.now
                for frame in capture.frames {
                    let due = start + .seconds(frame.t / pace)
                    if due > clock.now { try? await Task.sleep(until: due, clock: clock) }
                    guard let self, !Task.isCancelled else { return }
                    self.ingest(frame.data, from: capture.deviceProtocol.notifyCharacteristicUUIDs[0])
                }
            } while loop && !Task.isCancelled
        }
    }

    func stopReplay() {
        guard replayTask != nil else { return }
        replayTask?.cancel()
        replayTask = nil
        stopRateTimer()
        telemetry = nil
        liveState = TelemetryState()
        session.reset()
        selectedDeviceName = nil
        isConnected = false
    }
}

// MARK: - Advertisement logging (debug builds only)

extension BLEManager {
    /// True when launched with `-logAdvertisements`.
    fileprivate static var logsAdvertisements: Bool {
        CommandLine.arguments.contains("-logAdvertisements")
    }

    /// With `-logAdvertisements`, logs the first few advertisements of each
    /// device exactly as CoreBluetooth delivered them: which keys each callback
    /// carried, and whether the service and the name arrive together or apart.
    /// For checking how a device's advertising packet and scan response reach
    /// the app.
    fileprivate func logAdvertisement(of peripheral: CBPeripheral, _ data: [String: Any], rssi: Int) {
        guard Self.logsAdvertisements else { return }
        let count = loggedAdvertisements[peripheral.identifier, default: 0]
        guard count < 8 else { return }
        loggedAdvertisements[peripheral.identifier] = count + 1

        let services = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let name = data[CBAdvertisementDataLocalNameKey] as? String
        let keys = data.keys.sorted().joined(separator: ", ")
        NSLog("Gnimu Monitor: Advert \(count + 1) of \(peripheral.identifier.uuidString.prefix(8)) rssi \(rssi): "
              + "name \(name.map { "\"\($0)\"" } ?? "none"), services \(services.isEmpty ? "none" : services.joined(separator: " ")), "
              + "cached name \(peripheral.name.map { "\"\($0)\"" } ?? "none"), keys [\(keys)]")
    }
}
#endif
