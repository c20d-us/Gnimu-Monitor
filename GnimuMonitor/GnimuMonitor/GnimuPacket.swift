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
import CoreLocation

/// User-selectable speed unit, persisted via @AppStorage("speedUnit").
enum SpeedUnit: String, CaseIterable {
    case kmh
    case mph

    var label: String { self == .kmh ? "km/h" : "mph" }

    /// Converts a km/h value into this unit.
    func value(fromKmh kmh: Double) -> Double {
        self == .kmh ? kmh : kmh * 0.621371
    }

    var toggled: SpeedUnit { self == .kmh ? .mph : .kmh }
}

struct GnimuPacket {
    let iTOW: UInt32
    let year: UInt16
    let month: UInt8
    let day: UInt8
    let hour: UInt8
    let minute: UInt8
    let second: UInt8
    let validityFlags: UInt8
    let timeAccuracy: UInt32    // nanoseconds
    let nanoseconds: Int32
    let fixType: UInt8
    let fixStatusFlags: UInt8
    let dateTimeFlags: UInt8
    let numSV: UInt8
    let longitude: Double       // degrees
    let latitude: Double        // degrees
    let heightEllipsoid: Double // metres
    let heightMSL: Double       // metres
    let hAcc: Double            // metres
    let vAcc: Double            // metres
    let groundSpeed: Double     // m/s
    let headingOfMotion: Double // degrees 0-360
    let speedAccuracy: Double   // m/s
    let headingAccuracy: Double // degrees
    let pDOP: Double
    let latLonFlags: UInt8
    let battery: UInt8          // percent
    let accelX: Double          // g  (lateral)
    let accelY: Double          // g  (longitudinal)
    let accelZ: Double          // g  (vertical)
    let gyroX: Double           // deg/s
    let gyroY: Double           // deg/s
    let gyroZ: Double           // deg/s

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasValidFix: Bool {
        fixType >= 2 && (latLonFlags & 0x01) == 0
    }

    var fixTypeString: String {
        switch fixType {
        case 0: return "No Fix"
        case 1: return "Dead Reckoning"
        case 2: return "2D Fix"
        case 3: return "3D Fix"
        case 4: return "GNSS + DR"
        case 5: return "Time Only"
        default: return "Unknown (\(fixType))"
        }
    }

    var speedKmh: Double { groundSpeed * 3.6 }

    /// Ground speed in km/h with stationary GPS noise suppressed. A still
    /// receiver still reports a few cm/s of jitter, so speed is reported as zero
    /// unless it clears both its own accuracy estimate and a small floor — above
    /// that the real (unrounded) speed comes through, preserving resolution.
    var movingSpeedKmh: Double {
        let threshold = max(speedAccuracy, 0.2)   // m/s
        return groundSpeed > threshold ? speedKmh : 0
    }

    /// Battery charge percentage. The RaceBox protocol packs charging state into
    /// bit 7 of the battery byte and the charge level into the low 7 bits, so we
    /// mask off bit 7 (and clamp) — otherwise a charging device reads as >100%.
    var batteryPercent: Int { min(Int(battery & 0x7F), 100) }

    /// True when the device reports it is charging (bit 7 of the battery byte).
    var isCharging: Bool { (battery & 0x80) != 0 }

    var headingCardinal: String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int((headingOfMotion + 22.5) / 45.0) % 8
        return dirs[idx]
    }

    // Full packet is 88 bytes: 2 sync + 2 class/id + 2 length + 80 payload + 2 checksum
    static func parse(from data: Data) -> GnimuPacket? {
        guard data.count == 88 else { return nil }
        let b = [UInt8](data)
        guard b[0] == 0xB5, b[1] == 0x62 else { return nil }
        guard b[2] == 0xFF, b[3] == 0x01 else { return nil }

        // Validate checksum over class, id, length bytes, and payload
        var ckA: UInt8 = 0, ckB: UInt8 = 0
        for i in 2..<86 {
            ckA = ckA &+ b[i]
            ckB = ckB &+ ckA
        }
        guard ckA == b[86], ckB == b[87] else { return nil }

        let p = 6  // payload base offset

        func u8(_ o: Int) -> UInt8  { b[p + o] }
        func u16(_ o: Int) -> UInt16 {
            UInt16(b[p+o]) | UInt16(b[p+o+1]) << 8
        }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[p+o]) | UInt32(b[p+o+1]) << 8 |
            UInt32(b[p+o+2]) << 16 | UInt32(b[p+o+3]) << 24
        }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }

        return GnimuPacket(
            iTOW:            u32(0),
            year:            u16(4),
            month:           u8(6),
            day:             u8(7),
            hour:            u8(8),
            minute:          u8(9),
            second:          u8(10),
            validityFlags:   u8(11),
            timeAccuracy:    u32(12),
            nanoseconds:     i32(16),
            fixType:         u8(20),
            fixStatusFlags:  u8(21),
            dateTimeFlags:   u8(22),
            numSV:           u8(23),
            longitude:       Double(i32(24)) * 1e-7,
            latitude:        Double(i32(28)) * 1e-7,
            heightEllipsoid: Double(i32(32)) / 1000.0,
            heightMSL:       Double(i32(36)) / 1000.0,
            hAcc:            Double(u32(40)) / 1000.0,
            vAcc:            Double(u32(44)) / 1000.0,
            groundSpeed:     Double(i32(48)) / 1000.0,
            headingOfMotion: Double(i32(52)) * 1e-5,
            speedAccuracy:   Double(u32(56)) / 1000.0,
            headingAccuracy: Double(u32(60)) * 1e-5,
            pDOP:            Double(u16(64)) / 100.0,
            latLonFlags:     u8(66),
            battery:         u8(67),
            accelX:          Double(i16(68)) / 1000.0,
            accelY:          Double(i16(70)) / 1000.0,
            accelZ:          Double(i16(72)) / 1000.0,
            gyroX:           Double(i16(74)) / 100.0,
            gyroY:           Double(i16(76)) / 100.0,
            gyroZ:           Double(i16(78)) / 100.0
        )
    }
}
