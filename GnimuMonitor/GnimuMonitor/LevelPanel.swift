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

/// A real-time bubble level for installing the device. Uses the IMU's X/Y
/// gravity components as the tilt signal; ±15° full-scale sensitivity keeps
/// the bubble responsive during typical vehicle-mount adjustments.
struct LevelPanel: View {
    let packet: GnimuPacket?

    /// Exponential moving average of the tilt vector, in g. Held in @State
    /// so successive packets smoothly damp jitter while stationary.
    @State private var smoothedX: Double = 0
    @State private var smoothedY: Double = 0

    private let fullScaleDegrees: Double = 15
    private let toleranceDegrees: Double = 0.5

    var body: some View {
        VStack(spacing: 20) {
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let r = min(cx, cy) - 8

                // Bezel
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                           with: .color(.secondary.opacity(0.6)), lineWidth: 2)

                // Reference rings at 2° and 5°
                for deg in [2.0, 5.0] {
                    let rr = r * deg / fullScaleDegrees
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                        with: .color(.secondary.opacity(0.25)), lineWidth: 0.5
                    )
                }

                // Crosshairs
                var cross = Path()
                cross.move(to: CGPoint(x: cx - r, y: cy)); cross.addLine(to: CGPoint(x: cx + r, y: cy))
                cross.move(to: CGPoint(x: cx, y: cy - r)); cross.addLine(to: CGPoint(x: cx, y: cy + r))
                ctx.stroke(cross, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)

                // Center dot
                let dotR: CGFloat = 3
                ctx.fill(Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)),
                         with: .color(.secondary))

                // Bubble — position derived from tilt, clamped to bezel.
                // The device's X axis is longitudinal (top-of-screen direction),
                // Y is lateral, matching the G-meter's axis convention.
                let pitchDeg = Self.tiltDegrees(smoothedX)   // fore/aft tilt (accelX)
                let rollDeg  = Self.tiltDegrees(smoothedY)   // side-to-side tilt (accelY)
                let rawDx = CGFloat(rollDeg / fullScaleDegrees) * r      // roll → horizontal
                let rawDy = CGFloat(-pitchDeg / fullScaleDegrees) * r    // pitch → vertical, invert so +X = up
                let dist = sqrt(rawDx * rawDx + rawDy * rawDy)
                let scale = dist > r ? r / dist : 1
                let bx = cx + rawDx * scale, by = cy + rawDy * scale

                let bubbleR: CGFloat = min(cx, cy) * 0.13
                let centered = abs(rollDeg) <= toleranceDegrees && abs(pitchDeg) <= toleranceDegrees
                let bubbleColor: Color = centered ? .green : .blue
                ctx.fill(Path(ellipseIn: CGRect(x: bx - bubbleR, y: by - bubbleR,
                                                width: bubbleR * 2, height: bubbleR * 2)),
                         with: .color(bubbleColor.opacity(0.85)))
                ctx.stroke(Path(ellipseIn: CGRect(x: bx - bubbleR, y: by - bubbleR,
                                                  width: bubbleR * 2, height: bubbleR * 2)),
                           with: .color(bubbleColor), lineWidth: 2)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 320)

            HStack(spacing: 32) {
                readout("Pitch", degrees: Self.tiltDegrees(smoothedX))
                readout("Roll",  degrees: Self.tiltDegrees(smoothedY))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: packet?.iTOW) { _, _ in
            guard let p = packet else { return }
            // EMA smoothing (~0.3 s time constant at 10 Hz UI updates).
            let alpha = 0.35
            smoothedX = smoothedX * (1 - alpha) + p.accelX * alpha
            smoothedY = smoothedY * (1 - alpha) + p.accelY * alpha
        }
    }

    private func readout(_ label: String, degrees: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f°", degrees))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Convert a horizontal gravity component (g) to tilt angle in degrees,
    /// clamped to the linear range of asin.
    private static func tiltDegrees(_ g: Double) -> Double {
        let clamped = min(max(g, -1), 1)
        return asin(clamped) * 180.0 / .pi
    }
}
