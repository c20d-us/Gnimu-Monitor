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

import CoreBluetooth
import Foundation

/// What a Gnimu device offers beyond telemetry: a readable description of how
/// it was built, and three commands. Both arrive only on newer firmware, so a
/// device that lacks the Gnimu service simply has no Device panel.
nonisolated enum GnimuDevice {
    /// The service that holds the configuration. Not advertised: found by
    /// discovering services after connecting.
    static let serviceUUID = CBUUID(string: "20D21CDE-F59E-41F1-9BCA-5BDE69876C8B")
    static let configCharacteristicUUID = CBUUID(string: "689E54CD-60B0-473A-B049-A5E02A2716E0")

    /// Commands are written to the telemetry service's RX characteristic.
    static let commandCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
}

/// An action the device carries out when it sees the matching eight-byte frame.
/// The device sends no reply: a restart or shutdown shows as the disconnect.
nonisolated enum DeviceCommand {
    case retrim, restart, shutdown

    /// UBX-style frame of class 0x47 with no payload, checksum included.
    var frame: Data {
        switch self {
        case .retrim:   return Data([0xB5, 0x62, 0x47, 0x01, 0x00, 0x00, 0x48, 0x1F])
        case .restart:  return Data([0xB5, 0x62, 0x47, 0x02, 0x00, 0x00, 0x49, 0x22])
        case .shutdown: return Data([0xB5, 0x62, 0x47, 0x03, 0x00, 0x00, 0x4A, 0x25])
        }
    }

    /// True for the commands that end the connection.
    var dropsConnection: Bool { self != .retrim }
}

/// The device's configuration text, split into what the panel shows. The text
/// is the console's `V` output: a BUILD line, a Device ID line, then `Config:`
/// lines. Lines it doesn't recognise are ignored, as the firmware asks.
nonisolated struct DeviceConfig: Equatable {
    struct Entry: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Fields of the BUILD line, in the order they appeared, minus the
    /// uncommitted-changes flag.
    var build: [Entry] = []
    var deviceID: String?
    /// The `Config:` lines broken into one labelled row per setting the panel
    /// shows. Board and name details are left out: the Firmware card and the
    /// device picker already carry them.
    var settings: [Entry] = []

    init?(text: String) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("BUILD,") {
                build = Self.parseBuild(String(line.dropFirst("BUILD,".count)))
            } else if line.hasPrefix("Device ID:") {
                deviceID = line.dropFirst("Device ID:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Config:") {
                let body = line.dropFirst("Config:".count).trimmingCharacters(in: .whitespaces)
                settings.append(contentsOf: Self.parseSetting(body))
            }
        }
        if build.isEmpty && deviceID == nil && settings.isEmpty { return nil }
    }

    private static func parseBuild(_ body: String) -> [Entry] {
        body.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let label = buildLabel(String(parts[0])) else { return nil }
            return Entry(label: label, value: String(parts[1]))
        }
    }

    /// Nil for fields the panel doesn't show.
    private static func buildLabel(_ key: String) -> String? {
        switch key {
        case "version":  return "Version"
        case "revision": return "Revision"
        case "utc":      return "Built"
        case "target":   return "Target"
        default:         return nil
        }
    }

    /// Turns one `Config:` body into its rows. Each topic's line is a comma
    /// list; parts are recognised by their content rather than position so a
    /// reordered or extended line still reads correctly.
    private static func parseSetting(_ body: String) -> [Entry] {
        let topic = body.prefix { $0 != " " }
        let rest = body.dropFirst(topic.count).trimmingCharacters(in: .whitespaces)
        let parts = rest.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }

        func value(_ part: String, after prefix: String) -> String? {
            part.hasPrefix(prefix) ? String(part.dropFirst(prefix.count)) : nil
        }

        var rows: [Entry] = []
        func add(_ label: String, _ value: String?) {
            if let value { rows.append(Entry(label: label, value: value)) }
        }

        switch topic {
        case "GNSS":
            // Constellations and dynamic model are the two parts with no
            // other marker: constellations come first.
            let plain = parts.filter { !$0.hasSuffix("Hz") && !$0.hasPrefix("min elevation") }
            add("GNSS Constellations", plain.first)
            add("GNSS Dynamic Mode", plain.dropFirst().first.map { $0.prefix(1).uppercased() + $0.dropFirst() })
            add("GNSS Fix Rate", parts.first { $0.hasSuffix("Hz") })
            add("GNSS Minimum SV Elevation", parts.compactMap { value($0, after: "min elevation ") }.first)
        case "IMU":
            add("IMU Axes Orientation", parts.compactMap { value($0, after: "axes ") }.first)
            let smoothing = parts.first { $0.hasPrefix("smoothing") } ?? ""
            add("IMU Accel Smoothing", token(after: "accel", in: smoothing))
            add("IMU Gyro Smoothing", token(after: "gyro", in: smoothing))
        case "BLE":
            add("BLE Protocol", parts.first)
            add("BLE Tx Power", parts.compactMap { value($0, after: "TX power ") }.first)
        case "battery":
            add("Battery Cutoff", parts.compactMap { value($0, after: "cutoff ") }.first)
            add("Battery Critical", parts.compactMap { value($0, after: "critical ") }.first)
            add("Battery Warning", parts.compactMap { value($0, after: "warning ") }.first)
            add("Battery Full", parts.compactMap { value($0, after: "100% at ") }.first)
        default:
            break   // board, and anything a later firmware adds
        }
        return rows
    }

    /// The word following `key` in a space-separated string.
    private static func token(after key: String, in text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(of: key), i + 1 < words.count else { return nil }
        return words[i + 1]
    }
}
