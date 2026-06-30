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
    let packet: GnimuPacket?
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    var body: some View {
        ScrollView {
            if let p = packet {
                VStack(spacing: 12) {
                    section("Position") {
                        row("Latitude",                 String(format: "%.7f °", p.latitude))
                        row("Longitude",                String(format: "%.7f °", p.longitude))
                        row("Altitude Above Sea Level", String(format: "%.1f m", p.heightMSL))
                        row("Horizontal Accuracy",      String(format: "%.2f m", p.hAcc))
                        row("Vertical Accuracy",        String(format: "%.2f m", p.vAcc))
                    }

                    section("Motion") {
                        row("Ground Speed",     String(format: "%.1f %@", speedUnit.value(fromKmh: p.movingSpeedKmh), speedUnit.label))
                        row("Speed Accuracy",   String(format: "%.2f %@", speedUnit.value(fromKmh: p.speedAccuracy * 3.6), speedUnit.label))
                        row("Heading",          String(format: "%@ %.2f °", p.headingCardinal, p.headingOfMotion))
                        row("Heading Accuracy", String(format: "%.2f °", p.headingAccuracy))
                    }

                    section("IMU") {
                        row("Lateral Acceleration",      String(format: "%.3f g", p.accelX))
                        row("Longitudinal Acceleration", String(format: "%.3f g", p.accelY))
                        row("Vertical Acceleration",     String(format: "%.3f g", p.accelZ))
                        row("Roll Rate",                 String(format: "%.2f °/s", p.gyroX))
                        row("Pitch Rate",                String(format: "%.2f °/s", p.gyroY))
                        row("Yaw Rate",                  String(format: "%.2f °/s", p.gyroZ))
                    }

                    section("Time") {
                        row("UTC Date",          utcDateString(p))
                        row("UTC Time",          utcTimeString(p))
                        row("GNSS Time of Week", "\(p.iTOW) ms")
                        row("Time Accuracy",     "\(p.timeAccuracy) ns")
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
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func utcDateString(_ p: GnimuPacket) -> String {
        let validDate = (p.validityFlags & 0x01) != 0
        return validDate
            ? String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
            : "invalid"
    }

    private func utcTimeString(_ p: GnimuPacket) -> String {
        let validTime = (p.validityFlags & 0x02) != 0
        return validTime
            ? String(format: "%02d:%02d:%02d", p.hour, p.minute, p.second)
            : "invalid"
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
