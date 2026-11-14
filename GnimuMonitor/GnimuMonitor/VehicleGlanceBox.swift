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

/// The glance box for a device that reads a vehicle and has no position: engine
/// speed in the middle, throttle, speed, gear and supply voltage around it, and
/// the frame rate along the bottom edge. When the device is waiting for the car,
/// or has a fault, that takes the place of the engine speed.
struct VehicleGlanceBox: View {
    let telemetry: TelemetryState?
    let streamHealth: StreamHealthReading
    /// What the device says it provides, so a corner for a channel it never
    /// sends (a device that reads only engine speed and throttle has no gear)
    /// is left out instead of sitting at a dash for the whole session.
    var schema: GnimuSchema?
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    /// The corner channels, with the vehicle channel each one shows.
    enum Corner: CaseIterable {
        case throttle, speed, gear

        var key: String {
            switch self {
            case .throttle: return "throttle_position"
            case .speed: return "vehicle_speed"
            case .gear: return "gear"
            }
        }

        /// True when the corner should be shown: the device has a value for it,
        /// says in its schema that it provides it, or hasn't said (schema not
        /// read yet), in which case it's shown rather than guessed away.
        func isShown(vehicle: VehicleBlock?, schema: GnimuSchema?) -> Bool {
            if let vehicle, let channel = VehicleChannel.all.first(where: { $0.key == key }),
               channel.read(vehicle) != nil { return true }
            guard let filled = VehicleChannel.filledKeys(in: schema) else { return true }
            return filled.contains(key)
        }
    }

    private func shows(_ corner: Corner) -> Bool { corner.isShown(vehicle: vehicle, schema: schema) }

    private var vehicle: VehicleBlock? { telemetry?.vehicle }
    private var state: DeviceStateDisplay {
        telemetry?.header.map { DeviceStateDisplay(raw: $0.stateRaw) } ?? .unknown
    }

    var body: some View {
        ZStack {
            centre
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if shows(.throttle) {
                corner(vehicle?.throttlePercent.map { String(format: "%.0f%%", $0) } ?? "—", "Throttle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if shows(.speed) {
                corner(vehicle?.speedKmh.map { String(format: "%.0f", speedUnit.value(fromKmh: $0)) } ?? "—",
                       speedUnit.label)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { speedUnit = speedUnit.toggled } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if shows(.gear) {
                corner(vehicle?.gear.map { VehicleChannel.gearText($0) } ?? "—", "Gear")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            corner(telemetry?.power?.supplyVolts.map { String(format: "%.1f", $0) } ?? "—", "Supply (V)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // Quiet while the stream holds its rate, amber or red when it doesn't.
            Text(String(format: "%.1f Hz", streamHealth.hz))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(streamHealth.status.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, minHeight: 115, maxHeight: 115)
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch state {
        case .waiting:
            notice("Waiting", "for vehicle", .orange)
        case .fault:
            notice("Fault", "device fault", .red)
        case .starting:
            notice("Starting", "device booting", .secondary)
        case .running, .unknown:
            VStack(spacing: 2) {
                Text(vehicle?.engineSpeedRpm.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("rpm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func notice(_ title: String, _ caption: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// A value-over-label stat used in the box corners.
    private func corner(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == "—" ? Color.secondary : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
