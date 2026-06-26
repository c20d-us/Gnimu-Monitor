import SwiftUI

struct GaugesPanel: View {
    let packet: GnimuPacket?

    var body: some View {
        HStack(spacing: 0) {
            SpeedGauge(speedKmh: packet?.speedKmh ?? 0)
                .frame(maxWidth: .infinity)

            Divider()

            CompassGauge(heading: packet?.headingOfMotion ?? 0,
                         cardinal: packet?.headingCardinal ?? "—")
                .frame(maxWidth: .infinity)

            Divider()

            GForcePlot(x: packet?.accelY ?? 0, y: packet?.accelX ?? 0)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Speed

private struct SpeedGauge: View {
    let speedKmh: Double
    private let maxSpeed: Double = 300

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let r = min(cx, cy) - 6.0
                let startAngle = Angle.degrees(140)
                let endAngle   = Angle.degrees(40)    // wraps through 360

                // Track arc (background)
                var track = Path()
                track.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                             startAngle: startAngle, endAngle: endAngle, clockwise: false)
                ctx.stroke(track, with: .color(.secondary.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 8, lineCap: .round))

                // Value arc
                let fraction = min(speedKmh / maxSpeed, 1.0)
                let span = 360.0 - 140.0 + 40.0   // 260 degrees of travel
                let valueEnd = Angle.degrees(140 + fraction * span)
                var fill = Path()
                fill.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                            startAngle: startAngle, endAngle: valueEnd, clockwise: false)
                let color: Color = speedKmh < 150 ? .blue : speedKmh < 240 ? .orange : .red
                ctx.stroke(fill, with: .color(color),
                           style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }
            .frame(width: 100, height: 100)
            .overlay {
                VStack(spacing: 1) {
                    Text(String(format: "%.0f", speedKmh))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("km/h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Speed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compass

private struct CompassGauge: View {
    let heading: Double
    let cardinal: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    .frame(width: 100, height: 100)

                // Tick marks
                ForEach(0..<36, id: \.self) { i in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: i % 9 == 0 ? 8 : 4)
                        .offset(y: -(50 - 2))
                        .rotationEffect(.degrees(Double(i) * 10))
                }

                // Cardinal labels (fixed — do not rotate)
                ForEach([("N", 0.0, Color.red), ("E", 90.0, Color.primary),
                         ("S", 180.0, Color.primary), ("W", 270.0, Color.primary)],
                        id: \.0) { label, deg, color in
                    let rad = (deg - 90) * .pi / 180
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                        .offset(x: cos(rad) * 32, y: sin(rad) * 32)
                }

                // Needle (rotates)
                ZStack {
                    // Red tip (pointing toward heading)
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 3, height: 32)
                        .offset(y: -16)
                    // Grey tail
                    Capsule()
                        .fill(Color.gray)
                        .frame(width: 3, height: 20)
                        .offset(y: 10)
                }
                .frame(width: 100, height: 100)
                .rotationEffect(.degrees(heading))

                Circle()
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
            }

            Text(String(format: "%@ %.1f°", cardinal, heading))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - G-Force

private struct GForcePlot: View {
    let x: Double   // lateral G  (positive = right)
    let y: Double   // longitudinal G (positive = forward/braking depends on mount)

    private let maxG = 3.0

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let r = min(cx, cy) - 6.0

                // Reference circles at 1 g and 2 g
                for ring in [1.0, 2.0] {
                    let rr = r * ring / maxG
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                        with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                }

                // Cross-hairs
                var cross = Path()
                cross.move(to: CGPoint(x: cx - r, y: cy)); cross.addLine(to: CGPoint(x: cx + r, y: cy))
                cross.move(to: CGPoint(x: cx, y: cy - r)); cross.addLine(to: CGPoint(x: cx, y: cy + r))
                ctx.stroke(cross, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

                // Dot — clamp to circle boundary
                let rawDx = CGFloat(x / maxG) * r
                let rawDy = CGFloat(-y / maxG) * r   // invert Y so forward = up
                let dist  = sqrt(rawDx * rawDx + rawDy * rawDy)
                let scale = dist > r ? r / dist : 1.0
                let dx = rawDx * scale, dy = rawDy * scale

                let dotSize: CGFloat = 10
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx + dx - dotSize/2, y: cy + dy - dotSize/2,
                                          width: dotSize, height: dotSize)),
                    with: .color(.blue))
            }
            .frame(width: 100, height: 100)

            Text(String(format: "G  %.2f / %.2f", x, y))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
