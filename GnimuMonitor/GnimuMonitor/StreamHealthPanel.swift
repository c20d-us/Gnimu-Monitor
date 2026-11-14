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

/// How the device's frame stream is doing: rate by the device's own clock, frames
/// the sequence number says were lost, restarts, and delivery jitter. Then, for a
/// device that reads a vehicle, how often each channel's value changes.
struct StreamHealthPanel: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        ScrollIfNeeded(alignment: .top) { content }
    }

    private var health: StreamHealthReading { ble.streamHealth }

    private var content: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(String(format: "%.1f", health.hz))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("frames per second, by the device's clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(health.status.tint)
            }
            .frame(maxWidth: .infinity)

            section("This Session") {
                row("Frames Received", health.sessionFrames.formatted())
                row("Frames Lost", lostText)
                row("Frames Repeated", health.sessionDuplicates.formatted())
                row("Device Restarts", health.sessionRestarts.formatted())
                row("Notifications Rejected", ble.rejectedNotifications.formatted())
            }

            section("Delivery") {
                row("Arrival Jitter", health.arrivalJitterMs.map { String(format: "%.1f ms", $0) } ?? "—")
            }

            if let header = ble.telemetry?.header {
                section("Device") {
                    row("State", DeviceStateDisplay(raw: header.stateRaw).name)
                    row("Frame Sequence", "\(header.sequence)")
                    row("Device Time", String(format: "%.3f s", Double(header.deviceTimeMs) / 1000))
                    row("Fills", Self.capabilityText(header.capabilities))
                }
            }

            if let vehicle = ble.telemetry?.vehicle {
                channelSection(vehicle)
            }
        }
        .padding()
    }

    // MARK: Pieces

    private var statusLine: String {
        guard let nominal = health.nominalHz, health.status != .noData else { return "waiting for frames" }
        let rate = String(format: "%g Hz nominal", nominal)
        switch health.status {
        case .onRate: return "\(rate) · on rate"
        case .degraded, .offRate:
            var parts: [String] = []
            if health.restarts > 0 { parts.append("device restarted") }
            if health.framesLost > 0 { parts.append("\(health.framesLost) lost") }
            if parts.isEmpty { parts.append("below rate") }
            return "\(rate) · \(parts.joined(separator: ", "))"
        case .noData: return "waiting for frames"
        }
    }

    private var lostText: String {
        let expected = health.sessionFrames + health.sessionLost
        guard expected > 0 else { return "0" }
        let percent = Double(health.sessionLost) / Double(expected) * 100
        return "\(health.sessionLost.formatted()) of \(expected.formatted()) (" + String(format: "%.2f%%)", percent)
    }

    private func channelSection(_ vehicle: VehicleBlock) -> some View {
        let filled = VehicleChannel.filledKeys(in: ble.gnimuSchema)
        let channels = VehicleChannel.all.filter {
            $0.read(vehicle) != nil || (filled?.contains($0.key) ?? false) || ble.channelRates[$0.key] != nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            section("Vehicle Channels") {
                if channels.isEmpty {
                    row("No channels yet", "")
                }
                ForEach(channels, id: \.key) { channel in
                    row(channel.displayLabel(schema: ble.gnimuSchema),
                        String(format: "%.1f changes/s", ble.channelRates[channel.key] ?? 0))
                }
            }
            Text("How often each value changed in the last few seconds. The device repeats the latest value of every channel in each frame, so this is the closest measure of how often the car is answering. A channel that holds steady, such as coolant temperature, reads zero.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    static func capabilityText(_ bits: UInt8) -> String {
        let names = [(1, "GNSS"), (2, "IMU"), (4, "Vehicle"), (8, "Power")]
            .filter { bits & UInt8($0.0) != 0 }.map(\.1)
        return names.isEmpty ? "Nothing" : names.joined(separator: ", ")
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
