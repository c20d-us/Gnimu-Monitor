import SwiftUI
import CoreBluetooth  // needed for CBPeripheral tags in Picker

struct ContentView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar(ble: ble)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            HStack(spacing: 0) {
                MapPanel(packet: ble.latestPacket)
                    .frame(minWidth: 400)

                Divider()

                VStack(spacing: 0) {
                    GaugesPanel(packet: ble.latestPacket)
                        .frame(height: 180)

                    Divider()

                    DataPanel(packet: ble.latestPacket)
                        .frame(minHeight: 200)
                }
                .frame(width: 320)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}

struct ConnectionBar: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 12) {
            statusIndicator

            Divider().frame(height: 20)

            Picker("Device", selection: $ble.selectedPeripheral) {
                Text("Select device…").tag(nil as CBPeripheral?)
                ForEach(ble.discoveredDevices, id: \.identifier) { p in
                    Text(p.name ?? p.identifier.uuidString).tag(p as CBPeripheral?)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(ble.isConnected)

            if !ble.isConnected {
                Button(action: { ble.startScanning() }) {
                    HStack(spacing: 4) {
                        if ble.isScanning { ProgressView().scaleEffect(0.65) }
                        Text(ble.isScanning ? "Scanning…" : "Rescan")
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button(ble.isConnected ? "Disconnect" : "Connect") {
                if ble.isConnected {
                    ble.disconnect()
                } else if let device = ble.selectedPeripheral {
                    ble.connect(to: device)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ble.isConnected ? .red : .accentColor)
            .disabled(!ble.isConnected && ble.selectedPeripheral == nil)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if ble.isConnected {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Connected").foregroundStyle(.secondary).font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text(ble.centralStateDescription).foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

#Preview {
    ContentView()
}
