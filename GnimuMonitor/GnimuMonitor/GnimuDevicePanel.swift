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

/// What a Gnimu-protocol device says about itself, arranged as the sections the
/// Device panel shows. Built from what the Monitor read after connecting (the
/// Device Information Service, the Schema and the Device info), so it is plain
/// data and can be checked without a device. A section with nothing to say is
/// left out, and so is a row the device didn't report.
nonisolated struct GnimuDeviceSummary: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    struct Section: Equatable, Sendable {
        let title: String
        let rows: [Row]
    }

    let sections: [Section]

    var isEmpty: Bool { sections.isEmpty }

    init(identity: DeviceIdentity, schema: GnimuSchema?, info: GnimuDeviceInfo?) {
        var sections: [Section] = []

        func rows(_ pairs: [(String, String?)]) -> [Row] {
            pairs.compactMap { label, value in
                guard let value, !value.isEmpty else { return nil }
                return Row(label: label, value: value)
            }
        }
        func add(_ title: String, _ pairs: [(String, String?)]) {
            let r = rows(pairs)
            if !r.isEmpty { sections.append(Section(title: title, rows: r)) }
        }

        add("Device", [
            ("Product", schema?.product),
            ("Manufacturer", identity.manufacturer),
            ("Model", identity.model),
            ("Serial Number", identity.serial),
            ("Hardware", identity.hardware),
        ])

        add("Firmware", [
            ("Version", identity.firmware),
            ("Build Revision", info?.build.revision),
            ("Build Time (UTC)", info?.build.utc),
            ("Target", info?.build.target),
        ])

        if let schema {
            let blocks = Self.blockNames(in: schema)
            add("Output", [
                ("Frame Rate", schema.rateHz.map { String(format: "%g Hz", $0) }),
                ("Provides", blocks.isEmpty ? nil : blocks.joined(separator: ", ")),
            ])

            let aux = schema.aux.values.sorted { $0.key < $1.key }
            if !aux.isEmpty {
                sections.append(Section(title: "Other Channels", rows: aux.map {
                    Row(label: $0.name, value: $0.unit.isEmpty ? "—" : $0.unit)
                }))
            }
        }

        if let settings = info?.settings, !settings.isEmpty {
            sections.append(Section(title: "Configuration", rows: settings.map {
                Row(label: Self.humanized($0.key), value: $0.value)
            }))
        }

        self.sections = sections
    }

    /// The blocks the schema says the device fills, in frame order, with the
    /// vehicle channel count where there is one.
    private static func blockNames(in schema: GnimuSchema) -> [String] {
        let order: [(key: String, name: String)] = [
            ("gnss", "GNSS"), ("imu", "IMU"), ("vehicle", "Vehicle"), ("power", "Power"),
        ]
        return order.compactMap { block in
            guard let mask = schema.fill[block.key], mask != 0 else { return nil }
            if block.key == "vehicle", let keys = VehicleChannel.filledKeys(in: schema) {
                let count = VehicleChannel.all.filter { keys.contains($0.key) }.count
                return count > 0 ? "Vehicle (\(count) channel\(count == 1 ? "" : "s"))" : "Vehicle"
            }
            return block.name
        }
    }

    /// A setting name as a label: "frame_rate" reads "Frame rate".
    static func humanized(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return key }
        return first.uppercased() + spaced.dropFirst()
    }
}

/// The Device panel for a Gnimu-protocol device: what it is, what firmware it
/// runs, and how it is set up, all read-only. The protocol has no way to send a
/// device commands yet.
struct GnimuDevicePanel: View {
    @ObservedObject var ble: BLEManager

    private var summary: GnimuDeviceSummary {
        GnimuDeviceSummary(identity: ble.deviceIdentity, schema: ble.gnimuSchema,
                           info: ble.gnimuDeviceInfo)
    }

    var body: some View {
        let summary = summary
        ScrollView {
            VStack(spacing: 12) {
                if summary.isEmpty {
                    section("Device") {
                        Text("No device information yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(summary.sections, id: \.title) { s in
                    section(s.title) {
                        ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                            row(r.label, r.value)
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Layout (matches the other panels' cards)

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

/// The Device tab's content: the panel that fits the connected device.
struct DeviceTab: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        if ble.deviceProtocol == .gnimu {
            GnimuDevicePanel(ble: ble)
        } else {
            DevicePanel(ble: ble, recorder: ble.recorder)
        }
    }
}
