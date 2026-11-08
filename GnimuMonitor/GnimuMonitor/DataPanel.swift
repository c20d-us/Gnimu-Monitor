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

struct DataPanel: View {
    let telemetry: TelemetryState?
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    var body: some View {
        ScrollView {
            if let telemetry {
                let g = telemetry.gnss
                let imu = telemetry.imu
                VStack(spacing: 12) {
                    section("Position") {
                        row("Latitude", text(g?.latitude, "%.7f °"))
                        row("Longitude", text(g?.longitude, "%.7f °"))
                        row("Altitude Above Sea Level", text(g?.altitudeMSL, "%.1f m"))
                        row("Horizontal Accuracy", text(g?.horizontalAccuracy, "%.2f m"))
                        row("Vertical Accuracy", text(g?.verticalAccuracy, "%.2f m"))
                    }

                    section("Motion") {
                        row(
                            "Ground Speed",
                            speed(g?.movingSpeedKmh, "%.1f %@"))
                        row(
                            "Speed Accuracy",
                            speed(g?.speedAccuracyKmh, "%.2f %@"))
                        row("Heading", heading(g))
                        row("Heading Accuracy", text(g?.headingAccuracyDeg, "%.2f °"))
                    }

                    section("IMU") {
                        row("Lateral Acceleration", text(imu?.lateralG, "%.3f g"))
                        row("Longitudinal Acceleration", text(imu?.longitudinalG, "%.3f g"))
                        row("Vertical Acceleration", text(imu?.verticalG, "%.3f g"))
                        row("Roll Rate", text(imu?.rollRate, "%.2f °/s"))
                        row("Pitch Rate", text(imu?.pitchRate, "%.2f °/s"))
                        row("Yaw Rate", text(imu?.yawRate, "%.2f °/s"))
                    }

                    section("Time") {
                        row("UTC Date", g?.date?.text ?? "invalid")
                        row("UTC Time", g?.time?.text ?? "invalid")
                        row("GNSS Time of Week", g?.timeOfWeekMs.map { "\($0) ms" } ?? "—")
                        row("Time Accuracy", g?.timeAccuracyNs.map { "\($0) ns" } ?? "—")
                    }
                }
                .padding(12)
            } else {
                Text("No data — connect to a device")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        // Only bounce/scroll when the data actually overflows (windowed iPad,
        // small Mac window, iPhone); when it all fits, the panel stays put.
        .scrollBounceBehavior(.basedOnSize)
    }

    /// One titled, light-gray rounded card: label at top-left, rows centered.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            VStack(spacing: 3) {
                content()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A number in the given format, or a dash where the device has no value.
    private func text(_ value: Double?, _ format: String) -> String {
        value.map { String(format: format, $0) } ?? "—"
    }

    /// A speed in the chosen unit; `format` takes the number, then the unit label.
    private func speed(_ kmh: Double?, _ format: String) -> String {
        kmh.map { String(format: format, speedUnit.value(fromKmh: $0), speedUnit.label) } ?? "—"
    }

    private func heading(_ gnss: GnssBlock?) -> String {
        guard let cardinal = gnss?.headingCardinal, let degrees = gnss?.headingDeg else { return "—" }
        return String(format: "%@ %.2f °", cardinal, degrees)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer(minLength: 12)
            // Pinned to the trailing edge, so a changing value width grows
            // leftward and the right edge never moves — no jitter.
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
        }
    }
}
