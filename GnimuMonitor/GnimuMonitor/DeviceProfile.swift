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

/// What a connected device provides, which decides the panels the Monitor
/// offers. Worked out from the blocks the device fills, not from its protocol,
/// so a GNSS device, a CAN device and an all-in-one device each get the screens
/// that mean something for them. Before the first frame arrives, only the
/// protocol is known, and a RaceBox device is assumed to be GNSS plus IMU, as
/// it always is.
nonisolated struct DeviceProfile: Equatable, Sendable {
    var hasGnss = false
    var hasImu = false
    var hasVehicle = false
    var hasPower = false
    /// The GNSS block carries the receiver's own epoch stamp, which is what the
    /// fix-rate tracker measures cadence from.
    var hasReceiverClock = false
    /// Frames carry a header with device time and a sequence number, so the
    /// stream itself can be checked for rate, gaps and delivery.
    var hasStreamHeader = false

    init() {}

    init(telemetry: TelemetryState?, deviceProtocol: DeviceProtocol) {
        guard let telemetry else {
            if deviceProtocol == .raceBox {
                hasGnss = true
                hasImu = true
                hasPower = true
                hasReceiverClock = true
            }
            return
        }
        hasGnss = telemetry.gnss != nil
        hasImu = telemetry.imu != nil
        hasVehicle = telemetry.vehicle != nil
        hasPower = telemetry.power != nil
        hasReceiverClock = telemetry.gnss?.timeOfWeekMs != nil
        hasStreamHeader = telemetry.header != nil
    }

    /// True when position is the main thing to look at, so the map takes the
    /// main area; otherwise the vehicle panel does.
    var mapIsPrimary: Bool { hasGnss }
}
