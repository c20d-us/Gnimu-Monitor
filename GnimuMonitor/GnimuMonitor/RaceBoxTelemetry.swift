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

extension RaceBoxPacket {
    /// This packet in the protocol-neutral form the panels read. RaceBox has no
    /// per-field validity, so every field is filled; `hasFix` carries the
    /// receiver's judgement of whether the position is usable. Values pass
    /// through unchanged apart from units: speed is m/s on the wire and km/h
    /// here.
    nonisolated var telemetryUpdate: TelemetryUpdate {
        let validDate = (validityFlags & 0x01) != 0
        let validTime = (validityFlags & 0x02) != 0
        return TelemetryUpdate(
            gnss: GnssBlock(
                hasFix: hasValidFix,
                fixType: fixType,
                satellites: Int(numSV),
                latitude: latitude,
                longitude: longitude,
                altitudeMSL: heightMSL,
                speedKmh: speedKmh,
                speedAccuracyKmh: speedAccuracy * 3.6,
                headingDeg: headingOfMotion,
                headingAccuracyDeg: headingAccuracy,
                horizontalAccuracy: hAcc,
                verticalAccuracy: vAcc,
                pdop: pDOP,
                date: validDate
                    ? UTCDate(year: Int(year), month: Int(month), day: Int(day)) : nil,
                time: validTime
                    ? UTCTime(hour: Int(hour), minute: Int(minute), second: Int(second)) : nil,
                timeAccuracyNs: timeAccuracy,
                timeOfWeekMs: iTOW),
            imu: ImuBlock(
                longitudinalG: accelX,
                lateralG: accelY,
                verticalG: accelZ,
                rollRate: gyroX,
                pitchRate: gyroY,
                yawRate: gyroZ),
            power: PowerBlock(
                batteryPercent: batteryPercent,
                isCharging: isCharging,
                supplyVolts: nil))
    }
}
