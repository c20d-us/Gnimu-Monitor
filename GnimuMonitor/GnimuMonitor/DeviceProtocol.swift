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

import CoreBluetooth
import Foundation

/// A BLE telemetry protocol the Monitor can read: where its data arrives and
/// how the notification bytes become telemetry. Everything protocol-specific
/// about a live connection lives behind this, so BLEManager only moves bytes.
nonisolated enum DeviceProtocol: String, CaseIterable {
    /// The RaceBox data protocol: 88-byte UBX-framed packets over the Nordic
    /// UART service. The raw value is what captures record as their protocol.
    case raceBox = "racebox"
    /// The Gnimu protocol: one fixed 140-byte frame for every Gnimu device,
    /// on its own service. See the Gnimu-protocol repository.
    case gnimu = "gnimu"

    var serviceUUID: CBUUID {
        switch self {
        case .raceBox: return CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        case .gnimu: return CBUUID(string: "9074BEB4-2F1A-4B5F-9818-FE2D2277EF05")
        }
    }

    /// The characteristics the device notifies its data on. Every notification
    /// from one of them goes to the protocol's session.
    var notifyCharacteristicUUIDs: [CBUUID] {
        switch self {
        case .raceBox: return [CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")]
        case .gnimu: return [Self.gnimuFrameCharacteristicUUID]
        }
    }

    /// The Gnimu frame characteristic (v1).
    static let gnimuFrameCharacteristicUUID = CBUUID(string: "0752D3C3-CEAF-462F-A944-BCC06C57284B")
    /// Readable once after connecting: what the device fills, and how it is set up.
    static let gnimuSchemaCharacteristicUUID = CBUUID(string: "1C9B3945-10EB-4FD0-A5A4-B9D80842380D")
    static let gnimuDeviceInfoCharacteristicUUID = CBUUID(string: "6D0ADFEF-8218-488A-A5F9-1BA05F422C22")

    /// The protocol's name as the device picker shows it.
    var displayName: String {
        switch self {
        case .raceBox: return "RaceBox"
        case .gnimu: return "Gnimu"
        }
    }

    /// Size of one frame as captures store it.
    var frameBytes: Int {
        switch self {
        case .raceBox: return RaceBoxFrameDecoder.frameBytes
        case .gnimu: return GnimuFrameV1.frameBytes
        }
    }

    func makeSession() -> any ProtocolSession {
        switch self {
        case .raceBox: return RaceBoxFrameDecoder()
        case .gnimu: return GnimuFrameSession()
        }
    }

    // MARK: Identification

    /// Which protocol a scanned device appears to speak, and how sure that is.
    struct Identification: Equatable {
        let deviceProtocol: DeviceProtocol
        /// True when an advertised service says so. False when it's a guess from
        /// the name, which can be overridden: that is only ever a first label,
        /// replaced when a later advertisement carries a service, and settled
        /// for good by the services the device exposes once connected.
        let isConfirmed: Bool
    }

    /// Advertised-name prefixes that suggest a protocol, most specific first.
    /// `Gnimu-RB` is a Gnimu in RaceBox mode, `Gnimu-CAN` is Gnimu-CAN, and a
    /// bare `Gnimu` followed by its ID is a Gnimu in its own protocol.
    private static let namePrefixes: [(prefix: String, deviceProtocol: DeviceProtocol)] = [
        ("RaceBox", .raceBox),
        ("Gnimu-RB", .raceBox),
        ("Gnimu-CAN", .gnimu),
        ("Gnimu", .gnimu),
    ]

    /// Identifies a scanned device, or returns nil if it isn't one the Monitor
    /// reads. The advertised service is the reliable signal, so it is tried
    /// first, for every protocol, before the name is looked at.
    static func identify(name: String?, advertisedServices: [CBUUID]) -> Identification? {
        for proto in allCases where advertisedServices.contains(proto.serviceUUID) {
            return Identification(deviceProtocol: proto, isConfirmed: true)
        }
        guard let name else { return nil }
        for (prefix, proto) in namePrefixes where name.hasPrefix(prefix) {
            return Identification(deviceProtocol: proto, isConfirmed: false)
        }
        return nil
    }

    /// The protocol of a connected device, from the services it exposes. This is
    /// final, over anything the scan or the name suggested.
    static func resolve(discoveredServices: [CBUUID]) -> DeviceProtocol? {
        allCases.first { discoveredServices.contains($0.serviceUUID) }
    }

    /// Every protocol's service, so a connection can look for all of them and
    /// find the right one even if the scan guessed wrong.
    static var allServiceUUIDs: [CBUUID] { allCases.map(\.serviceUUID) }
}

extension DeviceProtocol.Identification {
    /// The label after another advertisement from the same device. A guess from
    /// the name gives way to a service the advertisement carries; a confirmed
    /// label is never revisited, since a later advertisement may omit the
    /// service an earlier one carried (or, rarely, carry another).
    func refined(byAdvertisedServices services: [CBUUID]) -> DeviceProtocol.Identification {
        guard !isConfirmed,
              let found = DeviceProtocol.identify(name: nil, advertisedServices: services) else { return self }
        return found
    }
}

/// One frame pulled out of the notification stream: the bytes as they arrived
/// (what a capture records) and what they decode to.
nonisolated struct DecodedFrame {
    let raw: Data
    let update: TelemetryUpdate
    /// The receiver's own stamp for the epoch this frame carries, in ms, for
    /// protocols that have one (RaceBox's iTOW). The fix-rate tracker reads it.
    let gnssEpochMs: UInt32?
}

/// Turns what a device notifies into frames. It is told which characteristic
/// each notification came from, so a protocol with several can keep state
/// across them, and it buffers across calls because notifications needn't line
/// up with frames.
nonisolated protocol ProtocolSession {
    /// Adds the bytes of one notification and returns every frame they
    /// completed, oldest first.
    mutating func receive(_ bytes: Data, from characteristic: CBUUID) -> [DecodedFrame]

    /// Drops buffered state, for a new connection.
    mutating func reset()
}

/// The Gnimu protocol's session. Each notification on the frame characteristic
/// is exactly one frame, so there is nothing to reassemble; one that isn't a
/// valid frame (wrong length, or a spec version this build doesn't read) is
/// dropped and counted.
nonisolated struct GnimuFrameSession: ProtocolSession {
    /// Notifications dropped as not valid frames, this connection.
    private(set) var rejected = 0

    mutating func receive(_ bytes: Data, from characteristic: CBUUID) -> [DecodedFrame] {
        guard characteristic == DeviceProtocol.gnimuFrameCharacteristicUUID else { return [] }
        do {
            let frame = try GnimuFrameV1.Frame(bytes)
            return [DecodedFrame(raw: bytes, update: frame.telemetryUpdate, gnssEpochMs: nil)]
        } catch {
            rejected += 1
            return []
        }
    }

    mutating func reset() { rejected = 0 }
}

/// Reassembles RaceBox packets: finds the B5 62 sync, takes 88 bytes, and
/// keeps it only if the checksum holds. A failed candidate costs one byte, so
/// a stray sync pattern inside garbage doesn't swallow a real frame behind it.
nonisolated struct RaceBoxFrameDecoder: ProtocolSession {
    static let frameBytes = 88

    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: Data) -> [DecodedFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [DecodedFrame] = []
        while buffer.count >= Self.frameBytes {
            guard let syncOffset = findSync() else { buffer.removeAll(); break }
            if syncOffset > 0 { buffer.removeFirst(syncOffset) }
            guard buffer.count >= Self.frameBytes else { break }
            let candidate = Data(buffer[0..<Self.frameBytes])
            if let packet = RaceBoxPacket.parse(from: candidate) {
                frames.append(DecodedFrame(raw: candidate, update: packet.telemetryUpdate,
                                           gnssEpochMs: packet.iTOW))
                buffer.removeFirst(Self.frameBytes)
            } else {
                buffer.removeFirst(1)
            }
        }
        return frames
    }

    mutating func receive(_ bytes: Data, from characteristic: CBUUID) -> [DecodedFrame] {
        feed(bytes)
    }

    mutating func reset() {
        buffer.removeAll()
    }

    private func findSync() -> Int? {
        for i in 0..<(buffer.count - 1) where buffer[i] == 0xB5 && buffer[i + 1] == 0x62 {
            return i
        }
        return nil
    }
}
