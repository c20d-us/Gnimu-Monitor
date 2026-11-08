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

extension GnimuFrameV1.Frame {
    /// This frame in the protocol-neutral form the panels read.
    ///
    /// A block is present when the device's capabilities say it fills it, even
    /// if none of its fields are valid yet (a GNSS device without a fix still
    /// has a GNSS block). Within a block, a field whose valid bit is clear is
    /// `nil`. Values are already metric in the units the model uses; the
    /// protocol's speeds are km/h.
    nonisolated var telemetryUpdate: TelemetryUpdate {
        func v(_ field: GnimuFrameV1.Field) -> Double? { value(field) }
        func i(_ field: GnimuFrameV1.Field) -> Int? { value(field).map { Int($0.rounded()) } }
        func flag(_ field: GnimuFrameV1.Field) -> Bool? { value(field).map { $0 != 0 } }

        var update = TelemetryUpdate(
            header: DeviceHeader(deviceTimeMs: deviceTimeMs, sequence: sequence,
                                 stateRaw: stateRaw, capabilities: capabilities.rawValue))

        if capabilities.contains(.gnss) {
            let utc = v(.utcTimestamp).flatMap(UTCInstant.init(unixMilliseconds:))
            update.gnss = GnssBlock(
                // Latitude and longitude are valid only with a usable fix.
                hasFix: isValid(.latitude) && isValid(.longitude),
                fixType: v(.fixType).map { UInt8($0) },
                satellites: i(.satellites),
                latitude: v(.latitude),
                longitude: v(.longitude),
                altitudeMSL: v(.altitudeMsl),
                speedKmh: v(.groundSpeed),
                speedAccuracyKmh: v(.speedAccuracy),
                headingDeg: v(.heading),
                headingAccuracyDeg: nil,      // the protocol has no heading accuracy
                horizontalAccuracy: v(.horizontalAccuracy),
                verticalAccuracy: v(.verticalAccuracy),
                pdop: v(.pdop),
                date: utc?.date,
                time: utc?.time,
                timeAccuracyNs: v(.timeAccuracy).map { UInt32($0) },
                timeOfWeekMs: nil)            // nor GNSS time of week
        }

        if capabilities.contains(.imu) {
            update.imu = ImuBlock(
                longitudinalG: v(.accelX), lateralG: v(.accelY), verticalG: v(.accelZ),
                rollRate: v(.rollRate), pitchRate: v(.pitchRate), yawRate: v(.yawRate))
        }

        if capabilities.contains(.vehicle) {
            update.vehicle = VehicleBlock(
                engineSpeedRpm: v(.engineSpeed),
                throttlePercent: v(.throttlePosition),
                acceleratorPedalPercent: v(.acceleratorPedal),
                speedKmh: v(.vehicleSpeed),
                coolantTempC: v(.coolantTemp),
                intakeAirTempC: v(.intakeAirTemp),
                ambientTempC: v(.ambientTemp),
                oilTempC: v(.oilTemp),
                transmissionTempC: v(.transmissionTemp),
                chargeAirCoolerTempC: v(.chargeAirCoolerTemp),
                oilPressureKpa: v(.oilPressure),
                boostKpa: v(.boost),
                fuelLevelPercent: v(.fuelLevel),
                brakePressureKpa: v(.brakePressure),
                brakePressed: flag(.brakeSwitch),
                clutchPressed: flag(.clutchSwitch),
                steeringAngleDeg: v(.steeringAngle),
                yawRateDegPerSec: v(.carYawRate),
                lateralG: v(.carLateralAccel),
                longitudinalG: v(.carLongitudinalAccel),
                wheelSpeedFrontLeftKmh: v(.wheelSpeedFl),
                wheelSpeedFrontRightKmh: v(.wheelSpeedFr),
                wheelSpeedRearLeftKmh: v(.wheelSpeedRl),
                wheelSpeedRearRightKmh: v(.wheelSpeedRr),
                gear: i(.gear),
                aux: [v(.aux1), v(.aux2), v(.aux3), v(.aux4)])
        }

        if capabilities.contains(.power) {
            update.power = PowerBlock(
                batteryPercent: i(.batteryCharge),
                isCharging: flag(.charging),
                supplyVolts: v(.supplyVoltage))
        }
        return update
    }
}

/// A UTC instant split into the calendar date and time of day the panels show.
nonisolated struct UTCInstant {
    let date: UTCDate
    let time: UTCTime

    /// From milliseconds since 1970-01-01 00:00 UTC (the protocol's UTC
    /// timestamp, which counts no leap seconds). Nil if it isn't a usable time.
    init?(unixMilliseconds ms: Double) {
        guard ms.isFinite, ms >= 0, ms < 253_402_300_800_000 else { return nil }   // year 1970...9999
        let seconds = Int((ms / 1000).rounded(.down))
        let days = seconds / 86_400
        let secondOfDay = seconds % 86_400

        // Civil date from a day count (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = z / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        date = UTCDate(year: year, month: month, day: day)
        time = UTCTime(hour: secondOfDay / 3600, minute: (secondOfDay % 3600) / 60, second: secondOfDay % 60)
    }
}
