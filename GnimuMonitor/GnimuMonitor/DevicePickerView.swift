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

/// The unconnected screen: a compact portrait panel for finding and
/// selecting a device, then connecting to it.
struct DevicePickerView: View {
    @ObservedObject var ble: BLEManager
    @State private var selectedID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            deviceList

            Divider()

            footer
        }
        .frame(minWidth: 400, idealWidth: 700, minHeight: 600, idealHeight: 1200)
        .onAppear { ble.startScanning() }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground: restart the scan for a fresh list.
            // This adds no background scanning — iOS still suspends the scan
            // when backgrounded; this only refreshes once we're active again.
            if phase == .active { ble.startScanning() }
        }
    }

    // MARK: Header — title

    private var header: some View {
        Text("Devices")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    // MARK: Device list

    @ViewBuilder
    private var deviceList: some View {
        if ble.discoveredDevices.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: ble.isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List(selection: $selectedID) {
                ForEach(ble.discoveredDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundStyle(.secondary)
                        Text(device.name)
                        Spacer()
                        SignalBars(rssi: device.rssi)
                    }
                    .foregroundStyle(device.isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .tag(device.id)
                    .selectionDisabled(device.isStale)
                }
            }
        }
    }

    private var emptyMessage: String {
        if ble.isScanning { return "Scanning for devices…" }
        // Not scanning while on the picker means Bluetooth isn't ready.
        return ble.centralStateDescription
    }

    // MARK: Footer — Connect

    private var footer: some View {
        Button(action: connect) {
            HStack(spacing: 6) {
                if ble.isConnecting { ProgressView().scaleEffect(0.6) }
                Text(ble.isConnecting ? "Connecting…" : "Connect")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canConnect)
        .padding(16)
    }

    /// The currently selected device, if it's still present and reachable.
    private var selectedDevice: DiscoveredDevice? {
        ble.discoveredDevices.first { $0.id == selectedID && !$0.isStale }
    }

    private var canConnect: Bool {
        selectedDevice != nil && !ble.isConnecting
    }

    // MARK: Actions

    private func connect() {
        guard let device = selectedDevice?.peripheral else { return }
        ble.selectedPeripheral = device
        ble.connect(to: device)
    }
}

/// A four-bar signal-strength indicator derived from RSSI (dBm).
struct SignalBars: View {
    let rssi: Int

    private var activeBars: Int {
        switch rssi {
        case ..<(-85): return 1
        case ..<(-75): return 2
        case ..<(-65): return 3
        default:       return 4
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < activeBars ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 4 + CGFloat(i) * 3)
            }
        }
        .accessibilityLabel("Signal \(activeBars) of 4")
    }
}
