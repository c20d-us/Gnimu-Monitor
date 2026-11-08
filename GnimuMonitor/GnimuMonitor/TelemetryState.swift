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

import CoreLocation
import Foundation

// The live state the panels read, independent of which protocol fed it.
//
// Each protocol's decoder turns what it receives into a `TelemetryUpdate`: the
// blocks that arrived, in common units (km/h, metres, degrees, g, degrees per
// second). `TelemetryState` merges updates, so a protocol that delivers GNSS
// and IMU together updates both at once, and one that delivers them in
// separate notifications updates each as it comes.
//
// A field is `nil` when the device says it has no valid value. A protocol that
// has no per-field validity (RaceBox) always fills its fields; `GnssBlock.hasFix`
// is what says whether the position can be trusted.

// MARK: - Time

/// A calendar date in UTC.
nonisolated struct UTCDate: Sendable, Equatable {
    let year: Int
    let month: Int
    let day: Int

    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// A time of day in UTC.
nonisolated struct UTCTime: Sendable, Equatable {
    let hour: Int
    let minute: Int
    let second: Int

    var text: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
}

// MARK: - Blocks

/// Position, motion and receiver quality.
nonisolated struct GnssBlock: Sendable, Equatable {
    /// True when the device reports a usable position fix. Position fields can
    /// hold values without one (RaceBox reports whatever the receiver last had),
    /// so anything that plots or follows a position checks this too.
    var hasFix = false
    /// 0 none, 1 dead reckoning (RaceBox only), 2 2D, 3 3D, 4 GNSS + dead
    /// reckoning, 5 time only.
    var fixType: UInt8?
    var satellites: Int?

    var latitude: Double?          // degrees
    var longitude: Double?         // degrees
    var altitudeMSL: Double?       // metres above mean sea level
    var speedKmh: Double?
    var speedAccuracyKmh: Double?
    var headingDeg: Double?        // degrees clockwise from true north
    var headingAccuracyDeg: Double?
    var horizontalAccuracy: Double?  // metres
    var verticalAccuracy: Double?    // metres
    var pdop: Double?

    var date: UTCDate?
    var time: UTCTime?
    var timeAccuracyNs: UInt32?
    /// The receiver's GNSS time of week, in ms, for protocols that carry it.
    var timeOfWeekMs: UInt32?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var fixTypeString: String? {
        guard let fixType else { return nil }
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

    /// Ground speed in km/h with stationary GPS noise suppressed. A still
    /// receiver still reports a few cm/s of jitter, so speed is reported as zero
    /// unless it clears both its own accuracy estimate and a small floor. Above
    /// that the real (unrounded) speed comes through, preserving resolution.
    var movingSpeedKmh: Double? {
        guard let speedKmh else { return nil }
        let threshold = max(speedAccuracyKmh ?? 0, 0.25 * 3.6)
        return speedKmh > threshold ? speedKmh : 0
    }

    var headingCardinal: String? {
        guard let headingDeg else { return nil }
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        // Normalise into 0..<360 first so a negative or out-of-range heading
        // can't produce a negative (out-of-bounds) index.
        let normalized = headingDeg.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let idx = Int((positive + 22.5) / 45.0) % 8
        return dirs[idx]
    }
}

/// The device's own inertial sensor, filtered, in the device's mounting frame.
///
/// Signs are as the device reports them. The Gnimu protocol follows ISO 8855
/// (x forward, y left, z up; left turn and forward acceleration positive).
/// RaceBox values are passed through unchanged, and have not been checked
/// against that convention.
nonisolated struct ImuBlock: Sendable, Equatable {
    var longitudinalG: Double?
    var lateralG: Double?
    var verticalG: Double?
    var rollRate: Double?          // degrees per second
    var pitchRate: Double?
    var yawRate: Double?
}

/// Battery or supply.
nonisolated struct PowerBlock: Sendable, Equatable {
    var batteryPercent: Int?
    var isCharging: Bool?
    var supplyVolts: Double?
}

/// What the car reports, from OBD-II, a manufacturer identifier or the bus.
/// Metric: km/h, degrees Celsius, kPa. Each field means the same whatever its
/// source (the Gnimu protocol's vehicle block), and is `nil` until the device
/// has a value for it.
nonisolated struct VehicleBlock: Sendable, Equatable {
    var engineSpeedRpm: Double?
    var throttlePercent: Double?
    var acceleratorPedalPercent: Double?
    var speedKmh: Double?
    var coolantTempC: Double?
    var intakeAirTempC: Double?
    var ambientTempC: Double?
    var oilTempC: Double?
    var transmissionTempC: Double?
    var chargeAirCoolerTempC: Double?
    var oilPressureKpa: Double?
    /// Above atmospheric; negative under vacuum.
    var boostKpa: Double?
    var fuelLevelPercent: Double?
    var brakePressureKpa: Double?
    var brakePressed: Bool?
    var clutchPressed: Bool?
    /// Degrees, left positive.
    var steeringAngleDeg: Double?
    /// The car's own sensors (not the device's IMU), left and forward positive.
    var yawRateDegPerSec: Double?
    var lateralG: Double?
    var longitudinalG: Double?
    var wheelSpeedFrontLeftKmh: Double?
    var wheelSpeedFrontRightKmh: Double?
    var wheelSpeedRearLeftKmh: Double?
    var wheelSpeedRearRightKmh: Double?
    /// -1 reverse, 0 neutral, 1 and up forward.
    var gear: Int?
    /// The device's own extra channels, as raw integers; the device's schema
    /// says what each one is and how to scale it.
    var aux: [Double?] = [nil, nil, nil, nil]
}

/// What the device says about itself in every frame, for protocols that have
/// such a header (the Gnimu protocol; RaceBox has none).
nonisolated struct DeviceHeader: Sendable, Equatable {
    /// Milliseconds since the device booted. Wraps after 2^31 ms.
    var deviceTimeMs: Int32
    /// Counts up by one per frame, wrapping at 255; a gap means a lost frame.
    var sequence: UInt8
    /// Raw state byte: 0 unknown, 1 starting, 2 running, 3 waiting, 4 fault.
    var stateRaw: UInt8
    /// Bits for the blocks the device fills: 1 GNSS, 2 IMU, 4 vehicle, 8 power.
    var capabilities: UInt8
}

// MARK: - Updates and state

/// The blocks one decoded notification carried. A block the protocol didn't
/// deliver is `nil`, which leaves the state's copy of it alone.
nonisolated struct TelemetryUpdate: Sendable, Equatable {
    var header: DeviceHeader?
    var gnss: GnssBlock?
    var imu: ImuBlock?
    var vehicle: VehicleBlock?
    var power: PowerBlock?
}

/// What the device has told us, block by block, with when each last arrived.
nonisolated struct TelemetryState: Sendable, Equatable {
    var header: DeviceHeader?
    var gnss: GnssBlock?
    var imu: ImuBlock?
    var vehicle: VehicleBlock?
    var power: PowerBlock?

    private(set) var headerUpdatedAt: Date?
    private(set) var gnssUpdatedAt: Date?
    private(set) var imuUpdatedAt: Date?
    private(set) var vehicleUpdatedAt: Date?
    private(set) var powerUpdatedAt: Date?

    /// Counts merged updates. Views watch it to react to new data, since the
    /// blocks themselves can repeat their values.
    private(set) var revision = 0

    init() {}

    mutating func apply(_ update: TelemetryUpdate, at time: Date) {
        if let block = update.header { header = block; headerUpdatedAt = time }
        if let block = update.gnss { gnss = block; gnssUpdatedAt = time }
        if let block = update.imu { imu = block; imuUpdatedAt = time }
        if let block = update.vehicle { vehicle = block; vehicleUpdatedAt = time }
        if let block = update.power { power = block; powerUpdatedAt = time }
        revision += 1
    }
}
