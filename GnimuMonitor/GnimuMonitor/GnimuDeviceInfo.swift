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

// What a Gnimu-protocol device says about itself, read once after connecting:
// the Schema and Device info characteristics (compact JSON) and the standard
// Device Information Service. Parsing is tolerant: keys it doesn't know are
// ignored, so a device can add settings without breaking this build.

/// The Schema characteristic: what the device fills, and what its aux fields mean.
nonisolated struct GnimuSchema: Equatable, Sendable {
    /// What one of the device's own extra vehicle channels is.
    struct Aux: Equatable, Sendable {
        let key: String      // "aux_1" ... "aux_4"
        let name: String
        let unit: String
        /// Divide the raw integer by this to get the value in `unit`.
        let scale: Int

        func value(fromRaw raw: Double) -> Double { scale > 0 ? raw / Double(scale) : raw }
    }

    let version: Int
    let product: String?
    let rateHz: Double?
    /// Per block (`gnss`, `imu`, `vehicle`, `power`), a mask of the fields the
    /// device can provide at all, in the same bit layout as the block's valid mask.
    let fill: [String: UInt32]
    let aux: [String: Aux]

    static func parse(_ data: Data) -> GnimuSchema? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["v"] as? Int else { return nil }

        var fill: [String: UInt32] = [:]
        for (block, mask) in (json["fill"] as? [String: Any]) ?? [:] {
            if let n = mask as? NSNumber { fill[block] = n.uint32Value }
        }

        var aux: [String: Aux] = [:]
        for (key, entry) in (json["aux"] as? [String: Any]) ?? [:] {
            guard let e = entry as? [String: Any], let name = e["k"] as? String else { continue }
            aux[key] = Aux(key: key, name: name, unit: e["u"] as? String ?? "",
                           scale: (e["s"] as? Int) ?? 1)
        }

        return GnimuSchema(version: version, product: json["d"] as? String,
                           rateHz: (json["r"] as? NSNumber)?.doubleValue, fill: fill, aux: aux)
    }
}

/// The Device info characteristic: the build the device runs and its settings.
nonisolated struct GnimuDeviceInfo: Equatable, Sendable {
    struct Build: Equatable, Sendable {
        let revision: String?
        let utc: String?
        let target: String?
    }

    /// One entry of `cfg`, with its value as text.
    struct Setting: Equatable, Sendable {
        let key: String
        let value: String
    }

    let version: Int
    let build: Build
    /// The device's settings, sorted by name. What they are is up to each device.
    let settings: [Setting]

    static func parse(_ data: Data) -> GnimuDeviceInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["v"] as? Int else { return nil }

        let b = json["build"] as? [String: Any] ?? [:]
        let build = Build(revision: b["rev"] as? String, utc: b["utc"] as? String,
                          target: b["target"] as? String)

        var settings: [Setting] = []
        for (key, value) in (json["cfg"] as? [String: Any]) ?? [:] {
            if let text = text(for: value) { settings.append(Setting(key: key, value: text)) }
        }
        settings.sort { $0.key < $1.key }
        return GnimuDeviceInfo(version: version, build: build, settings: settings)
    }

    /// A setting as it would be shown. The spec allows strings, numbers and booleans.
    private static func text(for value: Any) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    }
}

/// The standard Device Information Service, which generic BLE tools show too.
nonisolated struct DeviceIdentity: Equatable, Sendable {
    var manufacturer: String?
    var model: String?
    var serial: String?
    var firmware: String?
    var hardware: String?

    static let serviceUUID = CBUUID(string: "180A")
    static let manufacturerUUID = CBUUID(string: "2A29")
    static let modelUUID = CBUUID(string: "2A24")
    static let serialUUID = CBUUID(string: "2A25")
    static let firmwareUUID = CBUUID(string: "2A26")
    static let hardwareUUID = CBUUID(string: "2A27")
    static let characteristicUUIDs = [manufacturerUUID, modelUUID, serialUUID, firmwareUUID, hardwareUUID]

    /// Records a characteristic's value; false if it isn't one of these.
    mutating func record(_ data: Data, for characteristic: CBUUID) -> Bool {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        switch characteristic {
        case Self.manufacturerUUID: manufacturer = text
        case Self.modelUUID: model = text
        case Self.serialUUID: serial = text
        case Self.firmwareUUID: firmware = text
        case Self.hardwareUUID: hardware = text
        default: return false
        }
        return true
    }
}
