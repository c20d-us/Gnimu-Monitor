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

/// What a Gnimu-protocol device reports about the car, grouped, with a notice
/// when the device is waiting for the car or has a fault. Shows the channels the
/// device says it can provide (from its schema), plus any that currently hold a
/// value; one that is provided but not valid right now reads as a dash.
struct VehiclePanel: View {
    @ObservedObject var ble: BLEManager
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh
    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage("pressureUnit") private var pressureUnit: PressureUnit = .kpa

    private var units: DisplayUnits {
        DisplayUnits(speed: speedUnit, temperature: temperatureUnit, pressure: pressureUnit)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let telemetry = ble.telemetry {
                    if let notice = notice(telemetry) { noticeView(notice) }
                    if let vehicle = telemetry.vehicle {
                        channelSections(vehicle)
                    }
                    if let power = telemetry.power { powerSection(power) }
                    Text("Tap a speed, temperature or pressure to change its unit.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("No data — connect to a device")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Notice

    private func notice(_ telemetry: TelemetryState) -> (title: String, detail: String, state: DeviceStateDisplay)? {
        guard telemetry.vehicle != nil, let header = telemetry.header else { return nil }
        let state = DeviceStateDisplay(raw: header.stateRaw)
        return state.vehicleNotice.map { ($0.title, $0.detail, state) }
    }

    private func noticeView(_ notice: (title: String, detail: String, state: DeviceStateDisplay)) -> some View {
        let color: Color = notice.state == .fault ? .red : notice.state == .waiting ? .orange : .secondary
        return VStack(alignment: .leading, spacing: 2) {
            Text(notice.title)
                .font(.headline)
                .foregroundStyle(color)
            Text(notice.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45), lineWidth: 1))
    }

    // MARK: Channels

    /// The channels to list: everything the schema says the device provides, and
    /// anything that holds a value right now (which covers a device whose schema
    /// hasn't been read).
    private func visibleChannels(in vehicle: VehicleBlock) -> [VehicleChannel] {
        let filled = VehicleChannel.filledKeys(in: ble.gnimuSchema)
        return VehicleChannel.all.filter { channel in
            channel.read(vehicle) != nil || (filled?.contains(channel.key) ?? false)
        }
    }

    @ViewBuilder
    private func channelSections(_ vehicle: VehicleBlock) -> some View {
        let visible = visibleChannels(in: vehicle)
        if visible.isEmpty {
            Text("No vehicle channels yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ForEach(VehicleChannel.Group.allCases, id: \.rawValue) { group in
                let channels = visible.filter { $0.group == group }
                if !channels.isEmpty {
                    section(group.title) {
                        ForEach(channels, id: \.key) { channel in
                            row(channel.displayLabel(schema: ble.gnimuSchema),
                                channel.text(in: vehicle, units: units, schema: ble.gnimuSchema))
                                .contentShape(Rectangle())
                                .onTapGesture { cycleUnit(for: channel.quantity) }
                        }
                    }
                }
            }
        }
    }

    private func cycleUnit(for quantity: VehicleChannel.Quantity) {
        switch quantity {
        case .speed: speedUnit = speedUnit.toggled
        case .temperature: temperatureUnit = temperatureUnit.toggled
        case .pressure: pressureUnit = pressureUnit.next
        default: break
        }
    }

    private func powerSection(_ power: PowerBlock) -> some View {
        section("Power") {
            if let volts = power.supplyVolts { row("Supply Voltage", String(format: "%.2f V", volts)) }
            else { row("Supply Voltage", "—") }
            if let percent = power.batteryPercent { row("Battery", "\(percent) %") }
            if let charging = power.isCharging { row("Charging", charging ? "Yes" : "No") }
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
