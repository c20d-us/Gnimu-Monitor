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
/// Compact layout: a pinned glance box above a paged Map / Data swipe deck.
private struct CompactMonitor: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            GlanceBox(packet: ble.latestPacket)
                .padding(12)

            TabView {
                MapPage(packet: ble.latestPacket)
                DataPanel(packet: ble.latestPacket)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
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
