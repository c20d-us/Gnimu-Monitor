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

/// The unconnected screen: find and connect a device, or work with the
/// captures already recorded.
///
/// Analysis lives here rather than in the connected monitor because it needs no
/// device at all — and on Mac and iPad this is the only place it appears.
struct DevicePickerView: View {
    @ObservedObject var ble: BLEManager
    @State private var selectedID: UUID?
    @State private var mode: Mode = .devices
    @Environment(\.scenePhase) private var scenePhase

    enum Mode: String, CaseIterable, Identifiable {
        case devices, captures
        var id: String { rawValue }
        var label: String { self == .devices ? "Devices" : "Captures" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            switch mode {
            case .devices:
                deviceList
                Divider()
                footer
            case .captures:
                AnalysisPanel(runner: ble.analysisRunner)
            }
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

    // MARK: Header — mode switch

    /// Doubles as the screen's title: it names what's on screen and what else
    /// is available, without spending a second row on a heading.
    @ViewBuilder
    private var header: some View {
        #if os(macOS)
        // AppKit draws a segmented picker as joined buttons rather than the
        // iOS pill, and segments can't be spaced apart. Rather than hand-roll
        // the pill, use the separated bordered/prominent pair the connected
        // layout's tab strip already uses — consistent within the Mac app.
        HStack(spacing: 10) {
            ForEach(Mode.allCases) { modeButton($0) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #else
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #endif
    }

    #if os(macOS)
    /// Equal-width so the pair spans the header the way the segmented control
    /// does on iOS.
    @ViewBuilder
    private func modeButton(_ candidate: Mode) -> some View {
        if mode == candidate {
            Button { mode = candidate } label: {
                Text(candidate.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { mode = candidate } label: {
                Text(candidate.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
    #endif

    // MARK: Device list

    @ViewBuilder
    private var deviceList: some View {
        if ble.discoveredDevices.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: ble.isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 64))
                    .foregroundStyle(ble.isScanning ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: ble.isScanning)
                Text(emptyMessage)
                    .font(.system(size: 16))
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
                            .fontWeight(.semibold)
                        Spacer()
                        SignalBars(rssi: device.rssi)
                    }
                    .foregroundStyle(device.isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .tag(device.id)
                    .selectionDisabled(device.isStale)
                    // The whole row, not just the text, answers the gesture.
                    .contentShape(Rectangle())
                    // simultaneousGesture rather than onTapGesture: the List's
                    // own single-tap selection has to keep working alongside it.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { connect(device) }
                    )
                }
            }
        }
    }

    private var emptyMessage: String {
        if ble.isScanning { return "Scanning" }
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

    /// The footer button: connects to whatever is selected.
    private func connect() {
        guard let device = selectedDevice else { return }
        connect(device)
    }

    /// Connects to one device directly — the double-tap shortcut.
    ///
    /// Takes the device it was given rather than reading the selection, so a
    /// double tap can't race the selection it just set.
    private func connect(_ device: DiscoveredDevice) {
        guard !device.isStale, !ble.isConnecting else { return }
        // Keep the row highlighted to match what's being connected.
        selectedID = device.id
        ble.selectedPeripheral = device.peripheral
        ble.connect(to: device.peripheral)
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
