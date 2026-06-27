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
/// satellite count, GNSS status (fix/pDOP/battery), and a compact g-force meter.
struct GlanceBox: View {
    let packet: GnimuPacket?
    @AppStorage("speedUnit") private var speedUnit: SpeedUnit = .kmh

    private var gMagnitude: Double {
        let x = packet?.accelX ?? 0, y = packet?.accelY ?? 0
        return (x * x + y * y).squareRoot()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Speed + satellite count
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.0f", speedUnit.value(fromKmh: packet?.speedKmh ?? 0)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(speedUnit.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { speedUnit = speedUnit.toggled }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(packet?.numSV ?? 0)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(satelliteColor)
                    Text("Satellites")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            // GNSS status: fix type (color-coded), pDOP, battery
            VStack(spacing: 6) {
                Text(packet?.fixTypeString ?? "—")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(fixColor)
                stat("pDOP", packet.map { String(format: "%.2f", $0.pDOP) } ?? "—")
                stat("Battery", packet.map { "\($0.battery)%" } ?? "—")
            }

            Spacer(minLength: 4)

            // G-meter — matches the g-plot axis mapping (x: longitudinal, y: lateral).
            VStack(spacing: 2) {
                GForceMeter(x: packet?.accelY ?? 0, y: packet?.accelX ?? 0)
                    .frame(width: 60, height: 60)
                Text(String(format: "%.1fg", gMagnitude))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5)
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

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}

/// A compact lateral/longitudinal g-force plot: rings at 1 g, crosshairs, and a
/// dot for the current acceleration clamped to the dial edge.
private struct GForceMeter: View {
    let x: Double   // horizontal axis g
    let y: Double   // vertical axis g (positive = up/forward)

    private let maxG = 2.0

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let r = min(cx, cy) - 2

            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                       with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            let rr = r / maxG   // 1 g reference ring
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                       with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            var cross = Path()
            cross.move(to: CGPoint(x: cx - r, y: cy)); cross.addLine(to: CGPoint(x: cx + r, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - r)); cross.addLine(to: CGPoint(x: cx, y: cy + r))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            let rawDx = CGFloat(x / maxG) * r
            let rawDy = CGFloat(-y / maxG) * r   // invert so forward = up
            let dist = sqrt(rawDx * rawDx + rawDy * rawDy)
            let scale = dist > r ? r / dist : 1.0
            let dx = rawDx * scale, dy = rawDy * scale

            let dot: CGFloat = 8
            ctx.fill(Path(ellipseIn: CGRect(x: cx + dx - dot / 2, y: cy + dy - dot / 2,
                                            width: dot, height: dot)),
                     with: .color(.green))
        }
    }
}
