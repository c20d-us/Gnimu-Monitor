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

/// The shared "instrument" box used across iPhone, iPad, and Mac: speed and
/// satellite count alongside GNSS status (fix type, pDOP, battery).
struct GlanceBox: View {
    let packet: GnimuPacket?
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    var body: some View {
        ZStack {
            // Center: speed (tap to toggle units)
            VStack(spacing: 2) {
                Text(String(format: "%.0f", speedUnit.value(fromKmh: packet?.movingSpeedKmh ?? 0)))
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(speedUnit.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { speedUnit = speedUnit.toggled }
            }

            // Top-left: battery fill icon with the numeric percentage below it
            // (nudged down to line up with the Fix text, whose glyphs sit lower
            // than the icon's top edge)
            VStack(alignment: .center, spacing: 2) {
                BatteryGauge(percent: packet?.batteryPercent, charging: packet?.isCharging ?? false)
                Text(packet.map { "\($0.batteryPercent)%" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            .padding(.leading, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Top-right: fix type (color-coded), same size as the corner values
            Text(packet?.fixTypeString ?? "—")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(fixColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Bottom-left: satellites
            corner("\(packet?.numSV ?? 0)", "Satellites", color: satelliteColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Bottom-right: pDOP
            corner(packet.map { String(format: "%.1f", $0.pDOP) } ?? "—", "pDOP", color: pdopColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        // Fixed height so the corner items (which fill vertically) spread to the
        // corners instead of inflating the whole box.
        .frame(maxWidth: .infinity, minHeight: 115, maxHeight: 115)
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5)
        }
    }

    /// A value-over-label stat used in the box corners.
    private func corner(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Fix quality color: green = 3D/GNSS+DR, amber = 2D/dead reckoning, red = none.
    private var fixColor: Color {
        guard let fix = packet?.fixType else { return .secondary }
        switch fix {
        case 3, 4: return .green
        case 1, 2: return .orange
        default:   return .red
        }
    }

    /// Satellite-count color: red < 4, amber 4–8, green ≥ 9.
    private var satelliteColor: Color {
        guard let n = packet?.numSV else { return .secondary }
        switch n {
        case ..<4:  return .red
        case 4...8: return .orange
        default:    return .green
        }
    }

    /// pDOP color: red ≥ 3, amber ≥ 2, green < 2 (lower is better).
    private var pdopColor: Color {
        guard let d = packet?.pDOP else { return .secondary }
        if d >= 3 { return .red }
        if d >= 2 { return .orange }
        return .green
    }
}

/// A battery outline filled proportionally to charge — green, amber under 20%.
private struct BatteryGauge: View {
    let percent: Int?    // 0–100, nil = unknown
    let charging: Bool

    private let bodyWidth: CGFloat = 40
    private let bodyHeight: CGFloat = 18

    var body: some View {
        // Clamp defensively so the fill can never extend past the outline.
        let fraction = min(max(Double(percent ?? 0) / 100.0, 0), 1)
        let fillColor: Color = (percent ?? 100) < 20 ? .orange : .green
        let innerWidth = bodyWidth - 6

        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary, lineWidth: 2)
                    .frame(width: bodyWidth, height: bodyHeight)
                RoundedRectangle(cornerRadius: 2)
                    .fill(percent == nil ? Color.secondary.opacity(0.3) : fillColor)
                    .frame(width: max(0, innerWidth * fraction), height: bodyHeight - 6)
                    .padding(.leading, 3)

                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: bodyWidth, height: bodyHeight)
                }
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary)
                .frame(width: 3, height: 7)
        }
        .accessibilityLabel("Battery \(percent.map { "\($0) percent" } ?? "unknown")\(charging ? ", charging" : "")")
    }
}
