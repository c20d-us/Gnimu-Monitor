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

/// One thing a Gnimu-protocol device can report about the car, with how to
/// show it. The table is the single list the Vehicle panel, the stream-health
/// panel and the change tracker all work from; a test checks it covers every
/// vehicle field the spec defines.
nonisolated struct VehicleChannel: Sendable {
    enum Group: Int, CaseIterable, Sendable {
        case engine, drivetrain, chassis, environment, aux

        var title: String {
            switch self {
            case .engine:      return "Engine"
            case .drivetrain:  return "Drivetrain"
            case .chassis:     return "Chassis"
            case .environment: return "Environment"
            case .aux:         return "Other Channels"
            }
        }
    }

    enum Quantity: Sendable {
        case rpm, percent, speed, temperature, pressure, degrees, degreesPerSecond
        case acceleration, gear, pedal, aux
    }

    /// The spec's name for the field, as the device's schema and the protocol
    /// repository use it.
    let key: String
    let label: String
    let group: Group
    let quantity: Quantity
    /// The channel's value as a number: switches as 0 or 1, gear as its number.
    let read: @Sendable (VehicleBlock) -> Double?

    /// The value as text in the chosen units, or a dash if the device has none.
    func text(in vehicle: VehicleBlock, units: DisplayUnits, schema: GnimuSchema?) -> String {
        guard let value = read(vehicle) else { return "—" }
        switch quantity {
        case .rpm:              return String(format: "%.0f rpm", value)
        case .percent:          return String(format: "%.1f %%", value)
        case .speed:            return String(format: "%.1f %@", units.speed.value(fromKmh: value), units.speed.label)
        case .temperature:      return units.temperature.text(fromCelsius: value)
        case .pressure:         return units.pressure.text(fromKpa: value)
        case .degrees:          return String(format: "%.1f °", value)
        case .degreesPerSecond: return String(format: "%.1f °/s", value)
        case .acceleration:     return String(format: "%.3f g", value)
        case .pedal:            return value != 0 ? "Pressed" : "Released"
        case .gear:             return Self.gearText(Int(value))
        case .aux:
            guard let aux = schema?.aux[key] else { return String(format: "%g (raw)", value) }
            return String(format: "%g", aux.value(fromRaw: value)) + (aux.unit.isEmpty ? "" : " \(aux.unit)")
        }
    }

    /// The label to show: an aux channel goes by the name the device gives it.
    func displayLabel(schema: GnimuSchema?) -> String {
        if quantity == .aux, let name = schema?.aux[key]?.name { return name }
        return label
    }

    static func gearText(_ gear: Int) -> String {
        switch gear {
        case -1: return "R"
        case 0: return "N"
        default: return "\(gear)"
        }
    }

    /// The vehicle channels this device can provide, per its schema, or nil if
    /// the schema hasn't been read (or says nothing about the vehicle block).
    static func filledKeys(in schema: GnimuSchema?) -> Set<String>? {
        guard let mask = schema?.fill["vehicle"] else { return nil }
        let keys = GnimuFrameV1.fields
            .filter { $0.block == .vehicle && mask & (1 << UInt32($0.bit)) != 0 }
            .map(\.key)
        return Set(keys)
    }

    // MARK: The table

    private static func c(_ key: String, _ label: String, _ group: Group, _ quantity: Quantity,
                          _ read: @escaping @Sendable (VehicleBlock) -> Double?) -> VehicleChannel {
        VehicleChannel(key: key, label: label, group: group, quantity: quantity, read: read)
    }

    static let all: [VehicleChannel] = [
        c("engine_speed", "Engine Speed", .engine, .rpm) { $0.engineSpeedRpm },
        c("throttle_position", "Throttle Position", .engine, .percent) { $0.throttlePercent },
        c("accelerator_pedal", "Accelerator Pedal", .engine, .percent) { $0.acceleratorPedalPercent },
        c("boost", "Boost", .engine, .pressure) { $0.boostKpa },
        c("oil_pressure", "Oil Pressure", .engine, .pressure) { $0.oilPressureKpa },
        c("coolant_temp", "Coolant Temperature", .engine, .temperature) { $0.coolantTempC },
        c("oil_temp", "Oil Temperature", .engine, .temperature) { $0.oilTempC },
        c("intake_air_temp", "Intake Air Temperature", .engine, .temperature) { $0.intakeAirTempC },
        c("charge_air_cooler_temp", "Charge Air Cooler Temperature", .engine, .temperature) { $0.chargeAirCoolerTempC },

        c("vehicle_speed", "Vehicle Speed", .drivetrain, .speed) { $0.speedKmh },
        c("gear", "Gear", .drivetrain, .gear) { $0.gear.map(Double.init) },
        c("clutch_switch", "Clutch", .drivetrain, .pedal) { $0.clutchPressed.map { $0 ? 1 : 0 } },
        c("transmission_temp", "Transmission Temperature", .drivetrain, .temperature) { $0.transmissionTempC },
        c("wheel_speed_fl", "Wheel Speed, Front Left", .drivetrain, .speed) { $0.wheelSpeedFrontLeftKmh },
        c("wheel_speed_fr", "Wheel Speed, Front Right", .drivetrain, .speed) { $0.wheelSpeedFrontRightKmh },
        c("wheel_speed_rl", "Wheel Speed, Rear Left", .drivetrain, .speed) { $0.wheelSpeedRearLeftKmh },
        c("wheel_speed_rr", "Wheel Speed, Rear Right", .drivetrain, .speed) { $0.wheelSpeedRearRightKmh },

        c("brake_switch", "Brake", .chassis, .pedal) { $0.brakePressed.map { $0 ? 1 : 0 } },
        c("brake_pressure", "Brake Pressure", .chassis, .pressure) { $0.brakePressureKpa },
        c("steering_angle", "Steering Angle", .chassis, .degrees) { $0.steeringAngleDeg },
        c("car_yaw_rate", "Yaw Rate (car)", .chassis, .degreesPerSecond) { $0.yawRateDegPerSec },
        c("car_lateral_accel", "Lateral Acceleration (car)", .chassis, .acceleration) { $0.lateralG },
        c("car_longitudinal_accel", "Longitudinal Acceleration (car)", .chassis, .acceleration) { $0.longitudinalG },

        c("ambient_temp", "Ambient Air Temperature", .environment, .temperature) { $0.ambientTempC },
        c("fuel_level", "Fuel Level", .environment, .percent) { $0.fuelLevelPercent },

        c("aux_1", "Aux 1", .aux, .aux) { $0.aux[0] },
        c("aux_2", "Aux 2", .aux, .aux) { $0.aux[1] },
        c("aux_3", "Aux 3", .aux, .aux) { $0.aux[2] },
        c("aux_4", "Aux 4", .aux, .aux) { $0.aux[3] },
    ]

    /// The valid channel values of a frame, by key, for the change tracker.
    static func values(in vehicle: VehicleBlock) -> [String: Double] {
        var out: [String: Double] = [:]
        for channel in all { if let v = channel.read(vehicle) { out[channel.key] = v } }
        return out
    }
}
