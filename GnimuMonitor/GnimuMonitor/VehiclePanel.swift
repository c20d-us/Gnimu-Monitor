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

import SwiftUI

/// Everything a Gnimu-protocol device reports about the car and about itself,
/// as plain rows: the device header, every vehicle field (a dash where the
/// device has no value), the power block, and what the device says it is.
/// A first view of the data, to be replaced by designed panels.
struct VehiclePanel: View {
    @ObservedObject var ble: BLEManager
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    private struct Channel {
        let label: String
        let value: KeyPath<VehicleBlock, Double?>
        let format: String
        let unit: String
        var isSpeed = false
    }

    private static let channels: [Channel] = [
        Channel(label: "Engine Speed", value: \.engineSpeedRpm, format: "%.0f", unit: "rpm"),
        Channel(label: "Throttle Position", value: \.throttlePercent, format: "%.1f", unit: "%"),
        Channel(label: "Accelerator Pedal", value: \.acceleratorPedalPercent, format: "%.1f", unit: "%"),
        Channel(label: "Vehicle Speed", value: \.speedKmh, format: "%.1f", unit: "", isSpeed: true),
        Channel(label: "Coolant Temperature", value: \.coolantTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Intake Air Temperature", value: \.intakeAirTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Ambient Air Temperature", value: \.ambientTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Oil Temperature", value: \.oilTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Transmission Temperature", value: \.transmissionTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Charge Air Cooler Temperature", value: \.chargeAirCoolerTempC, format: "%.1f", unit: "°C"),
        Channel(label: "Oil Pressure", value: \.oilPressureKpa, format: "%.1f", unit: "kPa"),
        Channel(label: "Boost", value: \.boostKpa, format: "%.1f", unit: "kPa"),
        Channel(label: "Fuel Level", value: \.fuelLevelPercent, format: "%.0f", unit: "%"),
        Channel(label: "Brake Pressure", value: \.brakePressureKpa, format: "%.0f", unit: "kPa"),
        Channel(label: "Steering Angle", value: \.steeringAngleDeg, format: "%.1f", unit: "°"),
        Channel(label: "Yaw Rate (car)", value: \.yawRateDegPerSec, format: "%.1f", unit: "°/s"),
        Channel(label: "Lateral Acceleration (car)", value: \.lateralG, format: "%.3f", unit: "g"),
        Channel(label: "Longitudinal Acceleration (car)", value: \.longitudinalG, format: "%.3f", unit: "g"),
        Channel(label: "Wheel Speed, Front Left", value: \.wheelSpeedFrontLeftKmh, format: "%.1f", unit: "", isSpeed: true),
        Channel(label: "Wheel Speed, Front Right", value: \.wheelSpeedFrontRightKmh, format: "%.1f", unit: "", isSpeed: true),
        Channel(label: "Wheel Speed, Rear Left", value: \.wheelSpeedRearLeftKmh, format: "%.1f", unit: "", isSpeed: true),
        Channel(label: "Wheel Speed, Rear Right", value: \.wheelSpeedRearRightKmh, format: "%.1f", unit: "", isSpeed: true),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let telemetry = ble.telemetry {
                    deviceSection(telemetry.header)
                    if let vehicle = telemetry.vehicle { vehicleSection(vehicle) }
                    if let power = telemetry.power { powerSection(power) }
                } else {
                    Text("No data — connect to a device")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                identitySection
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Sections

    @ViewBuilder
    private func deviceSection(_ header: DeviceHeader?) -> some View {
        if let header {
            section("Device") {
                row("State", Self.stateText(header.stateRaw))
                row("Frame Sequence", "\(header.sequence)")
                row("Device Time", String(format: "%.3f s", Double(header.deviceTimeMs) / 1000))
                row("Fills", Self.capabilityText(header.capabilities))
            }
        }
    }

    private func vehicleSection(_ vehicle: VehicleBlock) -> some View {
        section("Vehicle") {
            ForEach(Array(Self.channels.enumerated()), id: \.offset) { _, channel in
                row(channel.label, text(for: channel, in: vehicle))
            }
            row("Brake Switch", Self.pressedText(vehicle.brakePressed))
            row("Clutch Switch", Self.pressedText(vehicle.clutchPressed))
            row("Gear", Self.gearText(vehicle.gear))
            ForEach(0..<4, id: \.self) { i in
                if let line = auxText(i, vehicle.aux[i]) { row(line.label, line.value) }
            }
        }
    }

    private func powerSection(_ power: PowerBlock) -> some View {
        section("Power") {
            row("Supply Voltage", power.supplyVolts.map { String(format: "%.2f V", $0) } ?? "—")
            row("Battery", power.batteryPercent.map { "\($0) %" } ?? "—")
            row("Charging", power.isCharging.map { $0 ? "Yes" : "No" } ?? "—")
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        let id = ble.deviceIdentity
        if id != DeviceIdentity() || ble.gnimuSchema != nil || ble.gnimuDeviceInfo != nil {
            section("Device Info") {
                if let model = id.model { row("Model", model) }
                if let serial = id.serial { row("Device ID", serial) }
                if let firmware = id.firmware { row("Firmware", firmware) }
                if let hardware = id.hardware { row("Hardware", hardware) }
                if let schema = ble.gnimuSchema, let rate = schema.rateHz {
                    row("Frame Rate", String(format: "%g Hz", rate))
                }
                if let build = ble.gnimuDeviceInfo?.build {
                    if let rev = build.revision { row("Revision", rev) }
                    if let utc = build.utc { row("Built", utc) }
                    if let target = build.target { row("Target", target) }
                }
                ForEach(ble.gnimuDeviceInfo?.settings ?? [], id: \.key) { row($0.key, $0.value) }
            }
        }
    }

    // MARK: Formatting

    private func text(for channel: Channel, in vehicle: VehicleBlock) -> String {
        guard let value = vehicle[keyPath: channel.value] else { return "—" }
        if channel.isSpeed {
            return String(format: "\(channel.format) %@", speedUnit.value(fromKmh: value), speedUnit.label)
        }
        return String(format: channel.format, value) + (channel.unit.isEmpty ? "" : " \(channel.unit)")
    }

    /// An aux channel by what the device's schema calls it, or raw if it hasn't
    /// said. Nil when there is nothing to show.
    private func auxText(_ index: Int, _ raw: Double?) -> (label: String, value: String)? {
        let key = "aux_\(index + 1)"
        if let aux = ble.gnimuSchema?.aux[key] {
            let value = raw.map { String(format: "%g", aux.value(fromRaw: $0)) + (aux.unit.isEmpty ? "" : " \(aux.unit)") }
            return (aux.name, value ?? "—")
        }
        guard let raw else { return nil }
        return ("Aux \(index + 1) (raw)", String(format: "%g", raw))
    }

    static func stateText(_ raw: UInt8) -> String {
        switch raw {
        case 1: return "Starting"
        case 2: return "Running"
        case 3: return "Waiting"
        case 4: return "Fault"
        default: return "Unknown"
        }
    }

    static func capabilityText(_ bits: UInt8) -> String {
        let names = [(1, "GNSS"), (2, "IMU"), (4, "Vehicle"), (8, "Power")]
            .filter { bits & UInt8($0.0) != 0 }.map(\.1)
        return names.isEmpty ? "Nothing" : names.joined(separator: ", ")
    }

    static func pressedText(_ pressed: Bool?) -> String {
        pressed.map { $0 ? "Pressed" : "Released" } ?? "—"
    }

    static func gearText(_ gear: Int?) -> String {
        guard let gear else { return "—" }
        switch gear {
        case -1: return "R"
        case 0: return "N"
        default: return "\(gear)"
        }
    }

    // MARK: Layout (the Data panel's)

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            VStack(spacing: 3) { content() }
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
        }
    }
}
