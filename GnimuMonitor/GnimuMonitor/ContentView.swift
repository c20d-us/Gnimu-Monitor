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

/// Root view: shows the compact device picker until a device is connected,
/// then swaps to the full monitor layout. Disconnecting returns to the picker.
struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if ble.isConnected {
                MonitorView(ble: ble)
            } else {
                DevicePickerView(ble: ble)
            }
        }
        .sizesWindow(connected: ble.isConnected)
        // Blank the macOS window title (no "Gnimu Monitor" in the title bar).
        .navigationTitle("")
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            // Don't hold the connection while suspended: drop it when fully
            // backgrounded so we return to the picker and rescan on next launch.
            // (.background only — not the transient .inactive from Control Center.)
            if phase == .background, ble.isConnected {
                ble.disconnect()
            }
            #endif
        }
    }
}

#Preview {
    ContentView()
}
