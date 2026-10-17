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

#if DEBUG
import SwiftUI

/// Sample data for exercising the connected screen without a device: Xcode
/// previews at several window sizes, and a debug launch mode. Compiled into
/// debug builds only.
///
/// Launch arguments (Edit Scheme > Run > Arguments):
///   -demoMonitor        show the connected screen with sample data
///   -demoNotice         show the picker with the "device is restarting" notice
///   GNIMU_FAKE_LOCATION=1   (environment variable; preferred)
///   -fakeLocation           keep the real, live device data but report a made-up
///                           position, so screenshots don't show where you are.
///                           Set the variable to "36.5844,-121.7534" (or pass
///                           -fakeLat and -fakeLon) to choose the spot.
///   -demoSize 744x1133  also pin the screen to that size, in points, to see
///                       how a layout looks without resizing a window
enum DemoLaunch {
    static var isDemo: Bool { CommandLine.arguments.contains("-demoMonitor") }

    /// The position shown by `-fakeLocation` and by the sample packet: a public
    /// place (a racetrack), never anywhere the author has been testing.
    static let defaultLatitude = 36.5844
    static let defaultLongitude = -121.7534

    /// The made-up position to report in place of the device's, if requested.
    /// Asked for with the GNIMU_FAKE_LOCATION environment variable ("1" for the
    /// default spot, or "lat,lon"), or with the -fakeLocation launch argument.
    /// The variable is the more reliable of the two when launching on a device.
    static var fakeLocation: (latitude: Double, longitude: Double)? {
        if let raw = ProcessInfo.processInfo.environment["GNIMU_FAKE_LOCATION"],
           !raw.isEmpty, raw != "0" {
            let parts = raw.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            return parts.count == 2 ? (parts[0], parts[1]) : (defaultLatitude, defaultLongitude)
        }

        let args = CommandLine.arguments
        guard args.contains("-fakeLocation") || args.contains("-fakeLat") || args.contains("-fakeLon") else {
            return nil
        }
        func value(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        return (value(after: "-fakeLat") ?? defaultLatitude,
                value(after: "-fakeLon") ?? defaultLongitude)
    }

    /// The packet with its latitude and longitude swapped for the made-up
    /// position, when one is requested. Everything else stays live.
    static func relocated(_ p: GnimuPacket) -> GnimuPacket {
        guard let fake = fakeLocation else { return p }
        return p.moved(toLatitude: fake.latitude, longitude: fake.longitude)
    }

    /// The size requested with `-demoSize WxH`, if any.
    static var size: CGSize? {
        guard let i = CommandLine.arguments.firstIndex(of: "-demoSize"),
              i + 1 < CommandLine.arguments.count else { return nil }
        let parts = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    static func makeBLE() -> BLEManager {
        if CommandLine.arguments.contains("-demoNotice") {
            // The picker as it looks just after a restart command.
            let ble = BLEManager()
            ble.deviceNotice = DeviceNotice(command: .restart, deviceName: "Gnimu-RB 1120954722")
            return ble
        }
        return isDemo ? .demo() : BLEManager()
    }
}

extension BLEManager {
    /// A manager that looks connected to a device with a 3D fix, for previews
    /// and the demo launch mode.
    static func demo() -> BLEManager {
        let ble = BLEManager()
        ble.selectedDeviceName = "Gnimu-RB 1120954722"
        ble.latestPacket = .demo
        ble.supportsDeviceControl = true
        ble.deviceConfig = DeviceConfig(text: """
            BUILD,version=2.0.0,revision=48c22c7e04c5,dirty=0,utc=2026-10-14T21:04:57Z,target=nrf52840
            Device ID: 1120954722
            Config: board nrf52840, wiring V2
            Config: GNSS GPS+Galileo, 20 Hz, automotive, min elevation 5°
            Config: IMU axes X=+x Y=+y Z=+z, smoothing accel 0.33 gyro 0.33
            Config: BLE RaceBox, name "Gnimu-RB 1120954722", TX power -12 dBm
            Config: battery cutoff 3.30V, critical 3.35V, warning 3.40V, 100% at 4.10V, charged at 4.10V
            """)
        ble.isConnected = true
        return ble
    }
}

extension GnimuPacket {
    /// A copy at another latitude and longitude, all other fields unchanged.
    func moved(toLatitude lat: Double, longitude lon: Double) -> GnimuPacket {
        GnimuPacket(
            iTOW: iTOW, year: year, month: month, day: day, hour: hour, minute: minute,
            second: second, validityFlags: validityFlags, timeAccuracy: timeAccuracy,
            nanoseconds: nanoseconds, fixType: fixType, fixStatusFlags: fixStatusFlags,
            dateTimeFlags: dateTimeFlags, numSV: numSV, longitude: lon, latitude: lat,
            heightEllipsoid: heightEllipsoid, heightMSL: heightMSL, hAcc: hAcc, vAcc: vAcc,
            groundSpeed: groundSpeed, headingOfMotion: headingOfMotion,
            speedAccuracy: speedAccuracy, headingAccuracy: headingAccuracy, pDOP: pDOP,
            latLonFlags: latLonFlags, battery: battery, accelX: accelX, accelY: accelY,
            accelZ: accelZ, gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ)
    }

    /// A stationary 3D fix with sixteen satellites.
    static let demo = GnimuPacket(
        iTOW: 1_000_000, year: 2026, month: 10, day: 16, hour: 9, minute: 30, second: 0,
        validityFlags: 0x03, timeAccuracy: 25, nanoseconds: 0,
        fixType: 3, fixStatusFlags: 0x01, dateTimeFlags: 0, numSV: 16,
        longitude: DemoLaunch.defaultLongitude, latitude: DemoLaunch.defaultLatitude,
        heightEllipsoid: 100, heightMSL: 78.4,
        hAcc: 0.48, vAcc: 0.70, groundSpeed: 0, headingOfMotion: 326.25,
        speedAccuracy: 0.13, headingAccuracy: 32.26, pDOP: 1.2, latLonFlags: 0,
        battery: 91, accelX: 0, accelY: 0, accelZ: 1,
        gyroX: 0, gyroY: 0, gyroZ: 0)
}

#Preview("iPad landscape", traits: .fixedLayout(width: 1180, height: 820)) {
    MonitorView(ble: .demo())
}

#Preview("iPad portrait", traits: .fixedLayout(width: 820, height: 1180)) {
    MonitorView(ble: .demo())
}

#Preview("Narrow window", traits: .fixedLayout(width: 640, height: 780)) {
    MonitorView(ble: .demo())
}

#Preview("iPhone", traits: .fixedLayout(width: 393, height: 852)) {
    MonitorView(ble: .demo())
}
#endif
