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

/// How a Gnimu-protocol device's state is put to the person looking at it. The
/// state describes the device, not its data: Running says the device is doing
/// its job, and whether a field holds a value is for the valid masks.
nonisolated enum DeviceStateDisplay: Equatable, Sendable {
    case unknown, starting, running, waiting, fault

    init(raw: UInt8) {
        switch raw {
        case 1: self = .starting
        case 2: self = .running
        case 3: self = .waiting
        case 4: self = .fault
        default: self = .unknown
        }
    }

    /// A short name for the state, always available.
    var name: String {
        switch self {
        case .unknown: return "Unknown"
        case .starting: return "Starting"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .fault: return "Fault"
        }
    }

    /// What to say prominently, for a device that reads a vehicle, when the
    /// state is one the person should notice. Nil when all is well.
    var vehicleNotice: (title: String, detail: String)? {
        switch self {
        case .waiting:
            return ("Waiting for vehicle",
                    "The device is up, but the car isn't answering. Values appear when it does.")
        case .fault:
            return ("Device fault", "The device reports a fault and isn't retrying.")
        case .starting:
            return ("Starting", "The device is booting. Data isn't expected yet.")
        case .running, .unknown:
            return nil
        }
    }
}
