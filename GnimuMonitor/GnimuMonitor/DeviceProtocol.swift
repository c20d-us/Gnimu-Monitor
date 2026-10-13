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
/// how the notification bytes become packets. Everything protocol-specific
/// about a live connection lives behind this, so BLEManager only moves bytes.
nonisolated enum DeviceProtocol: String, CaseIterable {
    /// The RaceBox data protocol: 88-byte UBX-framed packets over the Nordic
    /// UART service. The raw value is what captures record as their protocol.
    case raceBox = "racebox"

    var serviceUUID: CBUUID {
        switch self {
        case .raceBox: return CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        }
    }

    /// The characteristic the device notifies its data on.
    var notifyCharacteristicUUID: CBUUID {
        switch self {
        case .raceBox: return CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        }
    }

    /// The protocol's name as the device picker shows it.
    var displayName: String {
        switch self {
        case .raceBox: return "RaceBox"
        }
    }

    /// Advertised-name prefixes of devices known to speak this protocol.
    private var namePrefixes: [String] {
        switch self {
        case .raceBox: return ["Gnimu", "RaceBox"]
        }
    }

    /// Which protocol a scanned device speaks, or nil if it isn't one the
    /// Monitor reads. An advertised service is the reliable signal: it holds
    /// whatever the device is named. The name only catches a device whose
    /// advertisement didn't carry the service. Several protocols may share a
    /// service, so this is where a future one tells itself apart.
    static func identify(name: String?, advertisedServices: [CBUUID]) -> DeviceProtocol? {
        allCases.first { proto in
            advertisedServices.contains(proto.serviceUUID)
                || (name.map { n in proto.namePrefixes.contains { n.hasPrefix($0) } } ?? false)
        }
    }

    /// Size of one frame as captures store it.
    var frameBytes: Int {
        switch self {
        case .raceBox: return RaceBoxFrameDecoder.frameBytes
        }
    }

    func makeDecoder() -> any FrameDecoder {
        switch self {
        case .raceBox: return RaceBoxFrameDecoder()
        }
    }
}

/// One frame pulled out of the notification stream: the bytes as they arrived
/// (what a capture records) and what they decode to.
nonisolated struct DecodedFrame {
    let raw: Data
    let packet: GnimuPacket
}

/// Turns the notification stream into frames. Notifications don't line up
/// with frames, so a decoder buffers across calls.
nonisolated protocol FrameDecoder {
    /// Adds the bytes of one notification and returns every frame they
    /// completed, oldest first.
    mutating func feed(_ bytes: Data) -> [DecodedFrame]

    /// Drops buffered bytes, for a new connection.
    mutating func reset()
}

/// Reassembles RaceBox packets: finds the B5 62 sync, takes 88 bytes, and
/// keeps it only if the checksum holds. A failed candidate costs one byte, so
/// a stray sync pattern inside garbage doesn't swallow a real frame behind it.
nonisolated struct RaceBoxFrameDecoder: FrameDecoder {
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
            if let packet = GnimuPacket.parse(from: candidate) {
                frames.append(DecodedFrame(raw: candidate, packet: packet))
                buffer.removeFirst(Self.frameBytes)
            } else {
                buffer.removeFirst(1)
            }
        }
        return frames
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
