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
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

/// The connected screen. On regular-width displays (Mac, iPad landscape) it's a
/// map alongside the glance box and telemetry; on compact widths (iPhone, iPad
/// Split View) it's a pinned glance box over a swipeable Map/Data deck.
struct MonitorView: View {
    @ObservedObject var ble: BLEManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    var body: some View {
        VStack(spacing: 0) {
            MonitorBar(ble: ble)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            content
        }
        // Keep the screen awake while the live monitor is on-screen. This view
        // only exists while connected, and iOS only honors it in the foreground.
        .onAppear { setKeepAwake(true) }
        .onDisappear { setKeepAwake(false) }
    }

    private func setKeepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        if hSize == .compact {
            CompactMonitor(ble: ble)
        } else {
            splitLayout
        }
        #else
        splitLayout
        #endif
    }

    /// Map on the left, glance box + data in a fixed column on the right.
    private var splitLayout: some View {
        HStack(spacing: 0) {
            MapPanel(packet: ble.latestPacket)
                .frame(minWidth: 400)

            Divider()

            VStack(spacing: 0) {
                GlanceBox(packet: ble.latestPacket)
                    .padding(12)

                Divider()

                DataPanel(packet: ble.latestPacket)
                    .frame(minHeight: 200)
            }
            .frame(width: 340)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

#if os(iOS)
/// Compact layout: a pinned glance box above a paged Map / Data / G-Force deck.
private struct CompactMonitor: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            GlanceBox(packet: ble.latestPacket)
                .padding(12)

            TabView {
                MapPage(packet: ble.latestPacket)
                DataPanel(packet: ble.latestPacket)
                GForcePanel(packet: ble.latestPacket)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
    }
}

/// Full-page g-force meter — a compact-only panel (not shown on Mac/iPad).
private struct GForcePanel: View {
    let packet: GnimuPacket?

    private var gMagnitude: Double {
        let x = packet?.accelX ?? 0, y = packet?.accelY ?? 0
        return (x * x + y * y).squareRoot()
    }

    var body: some View {
        VStack(spacing: 20) {
            // Matches the data-panel axis mapping (x: longitudinal, y: lateral).
            GForceMeter(x: packet?.accelY ?? 0, y: packet?.accelX ?? 0)
                .frame(width: 260, height: 260)
            Text(String(format: "%.2f g", gMagnitude))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A lateral/longitudinal g-force plot: rings at 1 g, crosshairs, and a dot for
/// the current acceleration clamped to the dial edge.
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

            let dot = max(8, min(cx, cy) * 0.1)
            ctx.fill(Path(ellipseIn: CGRect(x: cx + dx - dot / 2, y: cy + dy - dot / 2,
                                            width: dot, height: dot)),
                     with: .color(.green))
        }
    }
}

/// The map page in the compact deck. The map doesn't fill the page — a strip
/// below it stays part of the TabView so a horizontal swipe there flips pages
/// instead of being eaten by the map's own pan gesture.
private struct MapPage: View {
    let packet: GnimuPacket?

    var body: some View {
        VStack(spacing: 0) {
            MapPanel(packet: packet)

            // Empty strip that stays part of the TabView, giving the page dots
            // room and a place to swipe without the map eating the gesture.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.bar)
        }
    }
}
#endif

/// Slim top bar shown while connected: device name and a Disconnect button.
private struct MonitorBar: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 12) {
            if let name = ble.selectedPeripheral?.name {
                Text(name).font(.title3.weight(.semibold))
            }

            Spacer()

            Button("Disconnect") { ble.disconnect() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}
