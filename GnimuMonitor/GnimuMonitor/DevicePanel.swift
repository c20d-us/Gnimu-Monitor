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

/// What the connected device was built with, and the commands it accepts.
/// Shown only for devices that offer both (see `BLEManager.supportsDeviceControl`).
struct DevicePanel: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var recorder: SessionRecorder

    /// The command awaiting confirmation, if any.
    @State private var pending: DeviceCommand?
    /// Set briefly after a re-trim so the click visibly did something: the
    /// device sends no reply.
    @State private var retrimSent = false

    /// A restart or shutdown would cut the capture short, and a re-trim would
    /// change the IMU zero partway through it.
    private var commandsDisabled: Bool { recorder.isRecording || recorder.isFinishing }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                commandButtons

                if let config = ble.deviceConfig {
                    configSections(config)
                } else {
                    section("Configuration") {
                        Text("Reading configuration…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(dialogTitle, isPresented: confirming, titleVisibility: .visible) {
            if let command = pending {
                Button(command == .shutdown ? "Shut Down" : "Restart", role: .destructive) {
                    ble.send(command)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private func configSections(_ config: DeviceConfig) -> some View {
        if !config.build.isEmpty || config.deviceID != nil {
            section("Firmware") {
                if let id = config.deviceID { row("Device ID", id) }
                ForEach(config.build) { row($0.label, $0.value) }
            }
        }
        if !config.settings.isEmpty {
            section("Configuration") {
                ForEach(config.settings) { row($0.label, $0.value) }
            }
        }
    }

    // MARK: - Commands

    /// Three icon-over-label tiles in one row: big, easy touch targets that
    /// take little height. They sit above the read-only configuration so they
    /// never scroll out of reach.
    private var commandButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                commandButton(retrimSent ? "Sent" : "Re-trim",
                              systemImage: retrimSent ? "checkmark" : "level") {
                    ble.send(.retrim)
                    retrimSent = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        retrimSent = false
                    }
                }

                commandButton("Restart", systemImage: "arrow.clockwise") { pending = .restart }

                commandButton("Shut Down", systemImage: "power", tint: .red) { pending = .shutdown }
            }

            if commandsDisabled {
                Text("Commands are disabled while data recording is in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(commandsDisabled)
    }

    private func commandButton(_ title: String, systemImage: String, tint: Color = .accentColor,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title)
                    .frame(height: 32)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(CommandTileStyle(tint: tint))
        .accessibilityLabel(title == "Sent" ? "Re-trim sent" : title)
    }

    private var confirming: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var dialogTitle: String {
        pending == .shutdown ? "Shut down the device?" : "Restart the device?"
    }

    private var dialogMessage: String {
        pending == .shutdown
            ? "The connection will drop and the device will power off. It must be power-cycled or woken to come back."
            : "The connection will drop while the device restarts. Reconnect once it is advertising again."
    }

    // MARK: - Layout (matches DataPanel's cards)

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            VStack(spacing: 3) {
                content()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A tinted rounded tile drawn the same on every platform. The system's
/// bordered style renders a paler fill and smaller type on macOS than on iOS.
private struct CommandTileStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.30 : 0.18),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
