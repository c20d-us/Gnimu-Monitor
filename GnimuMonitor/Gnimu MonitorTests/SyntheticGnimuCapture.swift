//
//  SyntheticGnimuCapture.swift
//  Gnimu MonitorTests
//
//  Test helper: a Gnimu-CAN capture in the app's JSONL format, for replay and
//  for decoding tests. 30 s at 20 Hz of a car on a short run: the device waits
//  for the vehicle for the first 4 s (only the supply voltage is known), then
//  polls it, with engine speed and throttle from idle up to a rev limit and
//  back, vehicle speed and gear following, and slow channels (coolant, ambient)
//  steady. Frames are built with GnimuFrameBuilder from known values.
//

import Foundation
@testable import Gnimu_Monitor

struct SyntheticGnimuCapture {
    var seconds = 30.0
    var hz = 20.0
    var waitingSeconds = 4.0
    var includeTrailer = true

    static let deviceName = "Gnimu-CAN 0000000001"
    static let startedAt = "2026-11-08T10:00:00.000Z"

    var frameCount: Int { Int(seconds * hz) }

    /// The car's state `t` seconds in, once the device is polling it.
    struct Car {
        var rpm: Double
        var throttle: Double
        var speedKmh: Double
        var gear: Int
    }

    static func car(at t: Double) -> Car {
        // 0-8 s: idle, then full throttle 8-14 s, lift and coast 14-22 s, idle after.
        let throttle: Double
        let rpm: Double
        switch t {
        case ..<8:  throttle = 0;                          rpm = 900
        case ..<14: throttle = 100;                        rpm = 900 + (t - 8) / 6 * 5100        // to 6000
        case ..<22: throttle = 0;                          rpm = 6000 - (t - 14) / 8 * 5100      // back to 900
        default:    throttle = 0;                          rpm = 900
        }
        let speed = max(0, (rpm - 900) / 5100 * 120)
        let gear = speed < 5 ? 0 : min(5, 1 + Int(speed / 25))
        return Car(rpm: rpm, throttle: throttle, speedKmh: speed, gear: gear)
    }

    func data() -> Data {
        var lines: [String] = [headerLine()]
        var lastT = 0.0
        for i in 0..<frameCount {
            let t = Double(i) / hz
            var b = GnimuFrameBuilder()
            b.deviceTimeMs = Int32(1_500 + Int(t * 1000))
            b.sequence = UInt8(i & 0xFF)
            b.capabilities = 12                                   // vehicle + power
            if t < waitingSeconds {
                b.state = 3                                       // waiting for the vehicle
                b.set(.supplyVoltage, 12.4)
            } else {
                let car = Self.car(at: t - waitingSeconds)
                b.state = 2
                b.set(.engineSpeed, car.rpm)
                b.set(.throttlePosition, car.throttle)
                b.set(.vehicleSpeed, car.speedKmh)
                b.set(.coolantTemp, 88.5)
                b.set(.ambientTemp, 21.0)
                b.set(.gear, Double(car.gear))
                b.set(.supplyVoltage, 13.8)
            }
            lines.append(String(format: "{\"t\":%.4f,\"d\":\"", t) + Data(b.build()).base64EncodedString() + "\"}")
            lastT = t
        }
        if includeTrailer { lines.append(trailerLine(packets: frameCount, duration: lastT)) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func headerLine() -> String {
        json([
            "type": "header", "schema": 1, "format": "gnimu-capture-jsonl",
            "sessionId": "00000000-0000-0000-0000-000000000002",
            "startedAt": Self.startedAt, "timeZone": "UTC",
            "device": ["name": Self.deviceName, "peripheralId": "TEST-PERIPHERAL"],
            "app": ["name": "Gnimu Monitor", "version": "1.0", "build": "1"],
            "host": ["platform": "macOS", "systemVersion": "Test OS", "model": "TestMac",
                     "lowPowerMode": false, "thermalState": "nominal"],
            "capture": ["protocol": "gnimu", "frameBytes": 140, "encoding": "base64",
                        "timeBase": "seconds since startedAt, monotonic", "nominalHz": hz],
        ])
    }

    private func trailerLine(packets: Int, duration: Double) -> String {
        json(["type": "summary", "sessionId": "00000000-0000-0000-0000-000000000002",
              "endedAt": "2026-11-08T10:00:31.000Z", "durationSeconds": duration,
              "packets": packets, "rawBytes": packets * 140,
              "meanHz": duration > 0 ? Double(packets) / duration : 0])
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
