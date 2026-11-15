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

/// One recorded frame in the form the capture analyzer reads, whichever
/// protocol it came from. A field the protocol or the device doesn't provide
/// is `nil`, and the checks that need it are skipped.
nonisolated struct AnalysisSample {
    /// The device's own clock for this frame, in ms: RaceBox's iTOW, or the
    /// Gnimu protocol's device time. Cadence is measured on it.
    var clockMs: UInt32
    /// The frame counter (Gnimu protocol only).
    var sequence: UInt8?
    /// The device's stamp for the GNSS epoch the frame carries, in ms on the
    /// same clock as `clockMs`. A Gnimu frame can repeat the previous frame's
    /// solution, which shows up as an unchanged value.
    var gnssEpochMs: UInt32?

    /// The device has a GNSS block in this frame (a receiver, whether or not it
    /// has resolved a time or a position yet).
    var hasGnssBlock = false
    var hasFix = false
    var latitude: Double?
    var longitude: Double?
    var speedKmh: Double?
    /// Speed with receiver noise at standstill suppressed, for the track.
    var movingSpeedKmh: Double?
    var groundSpeedMs: Double?
    var speedAccuracyMs: Double?
    var numSV: Int?
    var pDOP: Double?
    var hAcc: Double?
    var vAcc: Double?
    var fixType: UInt8?

    var accelG: (x: Double, y: Double, z: Double)?
    var gyroDps: (x: Double, y: Double, z: Double)?

    var batteryPercent: Int?
    var isCharging: Bool?

    /// What is wrong with a field's range, if anything.
    var rangeProblem: String?

    /// RaceBox: whether the packet's broken-out UTC clock agrees with its
    /// iTOW, decided per packet. `nil` when the packet has no valid clock.
    var clockFieldResult: ClockFieldResult?
    /// Gnimu protocol: the GNSS UTC timestamp (ms since 1970) and how old the
    /// solution is, which the analyzer checks for steadiness against the
    /// device clock.
    var utcMs: Double?
    var epochAgeMs: Double?

    enum ClockFieldResult {
        case agrees
        case mismatch(String)
    }
}

// MARK: - RaceBox

nonisolated extension AnalysisSample {
    /// GPS-UTC offset, constant at 18 s since 2017.
    private static let gpsUtcLeapSeconds = 18.0

    init(_ packet: RaceBoxPacket) {
        self.init(clockMs: packet.iTOW)
        hasGnssBlock = true
        sequence = nil
        gnssEpochMs = packet.iTOW
        hasFix = packet.hasValidFix
        latitude = packet.latitude
        longitude = packet.longitude
        speedKmh = packet.speedKmh
        movingSpeedKmh = packet.movingSpeedKmh
        groundSpeedMs = packet.groundSpeed
        speedAccuracyMs = packet.speedAccuracy
        numSV = Int(packet.numSV)
        pDOP = packet.pDOP
        hAcc = packet.hAcc
        vAcc = packet.vAcc
        fixType = packet.fixType
        accelG = (packet.accelX, packet.accelY, packet.accelZ)
        gyroDps = (packet.gyroX, packet.gyroY, packet.gyroZ)
        batteryPercent = packet.batteryPercent
        isCharging = packet.isCharging

        // The packet reports both a time-of-week and a broken-out clock; they
        // should describe the same instant.
        if packet.dateTimeFlags & 0x03 != 0 {
            let secondsOfDay = (Double(packet.iTOW) / 1000).truncatingRemainder(dividingBy: 86_400)
            let expected = (secondsOfDay - Self.gpsUtcLeapSeconds + 86_400)
                .truncatingRemainder(dividingBy: 86_400)
            let actual = Double(packet.hour) * 3600 + Double(packet.minute) * 60 + Double(packet.second)
            var diff = abs(expected - actual)
            if diff > 43_200 { diff = 86_400 - diff }   // wrap at midnight
            if diff > 2 {
                clockFieldResult = .mismatch(String(
                    format: "iTOW implies %02d:%02d:%02.0f UTC, packet says %02d:%02d:%02d",
                    Int(expected / 3600),
                    Int(expected.truncatingRemainder(dividingBy: 3600) / 60),
                    expected.truncatingRemainder(dividingBy: 60),
                    Int(packet.hour), Int(packet.minute), Int(packet.second)))
            } else {
                clockFieldResult = .agrees
            }
        }

        if packet.latitude < -90 || packet.latitude > 90 {
            rangeProblem = String(format: "latitude %.6f out of range", packet.latitude)
        } else if packet.longitude < -180 || packet.longitude > 180 {
            rangeProblem = String(format: "longitude %.6f out of range", packet.longitude)
        } else if packet.headingOfMotion < -360 || packet.headingOfMotion > 360 {
            rangeProblem = String(format: "heading %.2f° out of range", packet.headingOfMotion)
        } else if packet.pDOP < 0 || packet.pDOP > 100 {
            rangeProblem = String(format: "pDOP %.2f out of range", packet.pDOP)
        } else if packet.batteryPercent > 100 {
            rangeProblem = "battery \(packet.batteryPercent)% out of range"
        } else if packet.numSV > 64 {
            rangeProblem = "\(packet.numSV) satellites is implausible"
        }
    }
}

// MARK: - Gnimu protocol

nonisolated extension AnalysisSample {
    /// The device time is read as unsigned: the protocol's counter wraps after
    /// 2^31 ms, and the analyzer measures differences on it.
    init(_ frame: GnimuFrameV1.Frame) {
        self.init(clockMs: UInt32(bitPattern: frame.deviceTimeMs))
        sequence = frame.sequence

        if frame.capabilities.contains(.gnss) {
            hasGnssBlock = true
            let lat = frame.value(.latitude)
            let lon = frame.value(.longitude)
            hasFix = lat != nil && lon != nil
            latitude = lat
            longitude = lon
            speedKmh = frame.value(.groundSpeed)
            movingSpeedKmh = speedKmh
            groundSpeedMs = speedKmh.map { $0 / 3.6 }
            speedAccuracyMs = frame.value(.speedAccuracy).map { $0 / 3.6 }
            numSV = frame.value(.satellites).map { Int($0.rounded()) }
            pDOP = frame.value(.pdop)
            hAcc = frame.value(.horizontalAccuracy)
            vAcc = frame.value(.verticalAccuracy)
            fixType = frame.value(.fixType).map { UInt8(max(0, min($0, 255))) }
            utcMs = frame.value(.utcTimestamp)

            // The receiver's UTC timestamp is the epoch stamp: it steps by
            // exactly one period per solution, as iTOW does.
            gnssEpochMs = GnimuFrameSession.epochMs(of: frame)
            // The age saturates at 65535, where it is only a lower bound.
            if let age = frame.value(.gnssEpochAge), age < 65_535 { epochAgeMs = age }

            if let lat, lat < -90 || lat > 90 {
                rangeProblem = String(format: "latitude %.6f out of range", lat)
            } else if let lon, lon < -180 || lon > 180 {
                rangeProblem = String(format: "longitude %.6f out of range", lon)
            } else if let heading = frame.value(.heading), heading < 0 || heading > 360 {
                rangeProblem = String(format: "heading %.2f° out of range", heading)
            } else if let pDOP, pDOP < 0 || pDOP > 100 {
                rangeProblem = String(format: "pDOP %.2f out of range", pDOP)
            } else if let numSV, numSV > 64 {
                rangeProblem = "\(numSV) satellites is implausible"
            }
        }

        if frame.capabilities.contains(.imu),
           let x = frame.value(.accelX), let y = frame.value(.accelY), let z = frame.value(.accelZ) {
            accelG = (x, y, z)
            if let rx = frame.value(.rollRate), let ry = frame.value(.pitchRate),
               let rz = frame.value(.yawRate) {
                gyroDps = (rx, ry, rz)
            }
        }

        if frame.capabilities.contains(.power) {
            batteryPercent = frame.value(.batteryCharge).map { Int($0.rounded()) }
            isCharging = frame.value(.charging).map { $0 != 0 }
            if rangeProblem == nil, let batteryPercent, batteryPercent > 100 {
                rangeProblem = "battery \(batteryPercent)% out of range"
            }
        }
    }
}
