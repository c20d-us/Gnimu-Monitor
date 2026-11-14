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

import Foundation

/// How temperatures are shown. The protocol and the model are Celsius; this is
/// only presentation. Persisted via @AppStorage("temperatureUnit").
enum TemperatureUnit: String, CaseIterable {
    case celsius
    case fahrenheit

    var label: String { self == .celsius ? "°C" : "°F" }

    func value(fromCelsius c: Double) -> Double {
        self == .celsius ? c : c * 9 / 5 + 32
    }

    var toggled: TemperatureUnit { self == .celsius ? .fahrenheit : .celsius }

    func text(fromCelsius c: Double) -> String {
        String(format: "%.1f %@", value(fromCelsius: c), label)
    }
}

/// How pressures are shown. The protocol and the model are kPa. Persisted via
/// @AppStorage("pressureUnit").
enum PressureUnit: String, CaseIterable {
    case kpa
    case psi
    case bar

    var label: String {
        switch self {
        case .kpa: return "kPa"
        case .psi: return "psi"
        case .bar: return "bar"
        }
    }

    func value(fromKpa kpa: Double) -> Double {
        switch self {
        case .kpa: return kpa
        case .psi: return kpa * 0.145_037_737_7
        case .bar: return kpa / 100
        }
    }

    /// The next unit in kPa, psi, bar order, wrapping round.
    var next: PressureUnit {
        switch self {
        case .kpa: return .psi
        case .psi: return .bar
        case .bar: return .kpa
        }
    }

    func text(fromKpa kpa: Double) -> String {
        let digits = self == .bar ? 2 : 1
        return String(format: "%.\(digits)f %@", value(fromKpa: kpa), label)
    }
}

/// The units chosen for display, gathered so a formatter takes one value.
struct DisplayUnits: Equatable {
    var speed: SpeedUnit = .kmh
    var temperature: TemperatureUnit = .celsius
    var pressure: PressureUnit = .kpa
}
