//
//  SyntheticCapture.swift
//  Gnimu MonitorTests
//
//  Test helper: writes a capture file in the app's own JSONL format (header
//  line, one {"t","d"} line per packet, optional summary line) from a scripted
//  drive, with deliberate faults injected at chosen times. Because the drive
//  and the faults are known, the analyzer's output can be checked against what
//  was put in, not just against itself.
//
//  The drive (device seconds): 0-10 stationary; 10-20 accelerate at 1.5 m/s^2
//  to 15 m/s heading north; 20-28 cruise while turning clockwise at 10 deg/s
//  (an 80 degree turn); 28-34 brake at 2.5 m/s^2 to a stop; 34 on stationary.
//  Total distance is 240 m. The sign of the lateral acceleration and yaw rate
//  is arbitrary here; no test depends on it.
//

import Foundation

struct SyntheticCapture {

    enum Kind {
        /// One fix missing from the iTOW sequence, and the arrival gap grows
        /// with it (a fix the device never produced).
        case missedFixBoth
        /// One fix missing from iTOW, but packets keep arriving on time.
        case missedFixDevice
        /// One fix missing from iTOW, and delivery stalls longer than that.
        case missedFixTransport
        /// One interval 50% longer than nominal: a fix produced late.
        case lateFix
        /// A 1.5 s break in both clocks.
        case interruption
        /// The previous packet delivered again, with the same iTOW.
        case duplicateITOW
        /// A packet line whose checksum no longer matches.
        case corruptLine
        /// A line that isn't JSON at all.
        case garbageLine
        /// Battery reading steps up by 2 points while not charging.
        case batteryRise
        /// Three packets whose broken-out clock is 10 s off their iTOW.
        case clockMismatch
    }

    struct Fault {
        /// Nominal session time, seconds, at which it takes effect.
        let at: Double
        let kind: Kind
    }

    var seconds = 40.0
    var hz = 25.0
    /// Packets delivered together per notification burst (1 = steady).
    var burst = 1
    var faults: [Fault] = []
    var includeHeader = true
    var includeTrailer = true
    var finalNewline = true
    /// Extra lines placed after the last packet, before any trailer.
    var extraLines: [String] = []

    /// Device iTOW at the first packet. Chosen so that, less the 18 s leap
    /// offset, the broken-out UTC clock starts at 10:00:00.
    static let itow0 = 295_218_000
    static let startedAt = "2026-11-08T10:00:00.000Z"
    static let deviceName = "Gnimu 0000000001"

    /// The drive with one of every fault and no summary line; the analyzer
    /// tests describe each fault and what it should produce.
    static var faulty: SyntheticCapture {
        var capture = SyntheticCapture()
        capture.faults = [
            Fault(at: 6, kind: .missedFixBoth),
            Fault(at: 8, kind: .corruptLine),
            Fault(at: 9, kind: .garbageLine),
            Fault(at: 12, kind: .missedFixDevice),
            Fault(at: 15, kind: .batteryRise),
            Fault(at: 18, kind: .missedFixTransport),
            Fault(at: 20, kind: .clockMismatch),
            Fault(at: 24, kind: .lateFix),
            Fault(at: 30, kind: .duplicateITOW),
            Fault(at: 36, kind: .interruption),
        ]
        capture.includeTrailer = false
        return capture
    }

    var periodMs: Int { Int((1000 / hz).rounded()) }
    var frameCount: Int { Int(seconds * hz) }

    // MARK: - The drive

    struct Sample {
        var speed = 0.0          // m/s
        var headingDeg = 0.0
        var lat = 0.0
        var lon = 0.0
        var accelX = 0.0         // g
        var accelY = 0.0         // g
        var gyroZ = 0.0          // deg/s
    }

    /// One sample per millisecond of device time, 0...70 s.
    static let drive: [Sample] = {
        let g = 9.80665
        var out: [Sample] = []
        out.reserveCapacity(70_001)
        var lat = 37.0
        var lon = -122.0
        for ms in 0...70_000 {
            let t = Double(ms) / 1000
            var s = Sample()
            var accel = 0.0
            switch t {
            case ..<10:  s.speed = 0
            case ..<20:  accel = 1.5;  s.speed = 1.5 * (t - 10)
            case ..<28:  s.speed = 15
            case ..<34:  accel = -2.5; s.speed = 15 - 2.5 * (t - 28)
            default:     s.speed = 0
            }
            let turning = t >= 20 && t < 28
            s.headingDeg = t < 20 ? 0 : min(80, 10 * (t - 20))
            s.accelX = accel / g
            s.accelY = turning ? -(s.speed * (10 * Double.pi / 180)) / g : 0
            s.gyroZ = turning ? -10 : 0
            s.lat = lat
            s.lon = lon
            out.append(s)

            let h = s.headingDeg * Double.pi / 180
            lat += s.speed * cos(h) * 0.001 / 111_320
            lon += s.speed * sin(h) * 0.001 / (111_320 * cos(lat * Double.pi / 180))
        }
        return out
    }()

    // MARK: - File

    func data() -> Data {
        var lines: [String] = []
        if includeHeader { lines.append(headerLine()) }

        var pending = faults.sorted { $0.at < $1.at }
        var itowOffset = 0
        var arrivalShiftMs = 0.0
        var batteryBonus = 0
        var skewLeft = 0
        var last: (t: Double, data: Data)?
        var written = 0
        var lastT = 0.0
        let period = Double(periodMs)

        for i in 0..<frameCount {
            let nominalSeconds = Double(i) * period / 1000
            var duplicate = false, corrupt = false, garbage = false

            while let fault = pending.first, fault.at <= nominalSeconds + 1e-9 {
                pending.removeFirst()
                switch fault.kind {
                case .missedFixBoth:
                    itowOffset += periodMs
                    arrivalShiftMs += period
                case .missedFixDevice:
                    itowOffset += periodMs
                case .missedFixTransport:
                    itowOffset += periodMs
                    arrivalShiftMs += 150 - period       // arrival gap becomes 150 ms
                case .lateFix:
                    itowOffset += periodMs / 2
                    arrivalShiftMs += period / 2
                case .interruption:
                    itowOffset += 1500 - periodMs        // iTOW gap becomes 1500 ms
                    arrivalShiftMs += 1500 - period
                case .duplicateITOW:  duplicate = true
                case .corruptLine:    corrupt = true
                case .garbageLine:    garbage = true
                case .batteryRise:    batteryBonus = 2
                case .clockMismatch:  skewLeft = 3
                }
            }

            let itow = Self.itow0 + i * periodMs + itowOffset
            let deviceMs = itow - Self.itow0
            let group = (i / burst + 1) * burst - 1
            let t = (Double(group) * period + arrivalShiftMs) / 1000

            var b = RaceBoxPacketBuilder()
            let s = Self.drive[min(deviceMs, Self.drive.count - 1)]
            b.iTOW = UInt32(itow)

            // Broken-out clock: iTOW's time of day less the 18 s leap offset.
            var utc = ((itow / 1000) % 86_400 - 18 + 86_400) % 86_400
            if skewLeft > 0 { utc = (utc + 10) % 86_400; skewLeft -= 1 }
            b.year = 2026; b.month = 11; b.day = 8
            b.hour = UInt8(utc / 3600)
            b.minute = UInt8((utc % 3600) / 60)
            b.second = UInt8(utc % 60)
            b.dateTimeFlags = 0x03

            b.fixType = 3
            b.fixStatusFlags = 0x01
            b.numSV = UInt8(12 + (i / 250) % 3)
            b.pDOP = 1.0 + Double((i / 100) % 5) * 0.1
            b.hAccM = 1.0
            b.vAccM = 1.5
            b.latitude = s.lat
            b.longitude = s.lon
            b.heightMSLM = 20
            b.groundSpeedMps = s.speed
            b.speedAccMps = 0.1
            b.headingDeg = s.headingDeg
            b.battery = UInt8(80 - i / 250 + batteryBonus)
            b.accelXG = s.accelX
            b.accelYG = s.accelY
            b.accelZG = 1
            b.gyroZDps = s.gyroZ
            let packet = b.build()

            if duplicate, let last {
                lines.append(Self.frameLine(t: last.t + 0.02, data: last.data))
                written += 1
            }
            if corrupt {
                lines.append(Self.frameLine(t: t - 0.01, data: packet.replacing(byteAt: 30, with: packet[30] ^ 0xFF)))
            }
            if garbage { lines.append("this is not json") }

            lines.append(Self.frameLine(t: t, data: packet))
            written += 1
            last = (t, packet)
            lastT = t
        }

        lines.append(contentsOf: extraLines)
        if includeTrailer {
            lines.append(trailerLine(packets: written, duration: lastT))
        }

        var text = lines.joined(separator: "\n")
        if finalNewline { text += "\n" }
        return Data(text.utf8)
    }

    // MARK: - Lines

    private static func frameLine(t: Double, data: Data) -> String {
        "{\"t\":\(String(format: "%.4f", t)),\"d\":\"\(data.base64EncodedString())\"}"
    }

    private func headerLine() -> String {
        json([
            "type": "header",
            "schema": 1,
            "format": "gnimu-capture-jsonl",
            "sessionId": "00000000-0000-0000-0000-000000000001",
            "startedAt": Self.startedAt,
            "timeZone": "UTC",
            "device": ["name": Self.deviceName, "peripheralId": "TEST-PERIPHERAL"],
            "app": ["name": "Gnimu Monitor", "version": "1.0", "build": "1"],
            "host": [
                "platform": "macOS", "systemVersion": "Test OS", "model": "TestMac",
                "lowPowerMode": false, "thermalState": "nominal",
            ],
            "capture": [
                "protocol": "racebox", "frameBytes": 88, "encoding": "base64",
                "timeBase": "seconds since startedAt, monotonic", "nominalHz": hz,
            ],
        ])
    }

    private func trailerLine(packets: Int, duration: Double) -> String {
        json([
            "type": "summary",
            "sessionId": "00000000-0000-0000-0000-000000000001",
            "endedAt": "2026-11-08T10:00:42.000Z",
            "durationSeconds": duration,
            "packets": packets,
            "rawBytes": packets * 88,
            "meanHz": duration > 0 ? Double(packets) / duration : 0,
        ])
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
