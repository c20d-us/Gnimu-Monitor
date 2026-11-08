//
//  TelemetryStateTests.swift
//  Gnimu MonitorTests
//
//  The RaceBox adapter must hand the panels exactly what they showed when they
//  read RaceBoxPacket directly. These tests compare every converted value, and
//  every derived one, with the packet's own accessors, then cover how updates
//  merge into the state.
//

import CoreLocation
import Foundation
import Testing
@testable import Gnimu_Monitor

private func packet(_ configure: (inout RaceBoxPacketBuilder) -> Void = { _ in }) throws -> RaceBoxPacket {
    var b = RaceBoxPacketBuilder()
    configure(&b)
    return try #require(RaceBoxPacket.parse(from: b.build()))
}

private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

// MARK: - The RaceBox adapter

struct RaceBoxAdapterTests {

    @Test func everyFieldIsCarriedAcrossInCommonUnits() throws {
        let p = try packet {
            $0.iTOW = 123_456
            $0.year = 2026; $0.month = 11; $0.day = 8
            $0.hour = 14; $0.minute = 5; $0.second = 59
            $0.validityFlags = 0x03
            $0.timeAccuracyNs = 42
            $0.fixType = 3
            $0.numSV = 17
            $0.latitude = 51.5074; $0.longitude = -0.1278
            $0.heightMSLM = 35.123
            $0.hAccM = 1.234; $0.vAccM = 2.345
            $0.groundSpeedMps = 13.889
            $0.speedAccMps = 0.123
            $0.headingDeg = 271.5; $0.headingAccDeg = 4.5
            $0.pDOP = 1.37
            $0.battery = 0x80 | 87
            $0.accelXG = 0.123; $0.accelYG = -0.456; $0.accelZG = 0.987
            $0.gyroXDps = 1.25; $0.gyroYDps = -2.5; $0.gyroZDps = 3.75
        }
        let u = p.telemetryUpdate
        let g = try #require(u.gnss)
        let imu = try #require(u.imu)
        let power = try #require(u.power)

        #expect(g.hasFix)
        #expect(g.fixType == 3)
        #expect(g.satellites == 17)
        #expect(near(g.latitude, 51.5074, 1e-7))
        #expect(near(g.longitude, -0.1278, 1e-7))
        #expect(near(g.altitudeMSL, 35.123, 1e-6))
        #expect(near(g.horizontalAccuracy, 1.234, 1e-6))
        #expect(near(g.verticalAccuracy, 2.345, 1e-6))
        #expect(near(g.speedKmh, 13.889 * 3.6, 1e-6))        // m/s on the wire, km/h here
        #expect(near(g.speedAccuracyKmh, 0.123 * 3.6, 1e-6))
        #expect(near(g.headingDeg, 271.5, 1e-6))
        #expect(near(g.headingAccuracyDeg, 4.5, 1e-6))
        #expect(near(g.pdop, 1.37, 1e-6))
        #expect(g.date == UTCDate(year: 2026, month: 11, day: 8))
        #expect(g.time == UTCTime(hour: 14, minute: 5, second: 59))
        #expect(g.timeAccuracyNs == 42)
        #expect(g.timeOfWeekMs == 123_456)

        #expect(near(imu.longitudinalG, 0.123, 1e-6))        // RaceBox X
        #expect(near(imu.lateralG, -0.456, 1e-6))            // RaceBox Y
        #expect(near(imu.verticalG, 0.987, 1e-6))            // RaceBox Z
        #expect(near(imu.rollRate, 1.25, 1e-6))              // RaceBox gyro X
        #expect(near(imu.pitchRate, -2.5, 1e-6))
        #expect(near(imu.yawRate, 3.75, 1e-6))

        #expect(power.batteryPercent == 87)
        #expect(power.isCharging == true)
        #expect(power.supplyVolts == nil)                    // RaceBox has no supply voltage

        #expect(g.coordinate?.latitude == g.latitude)
        #expect(g.coordinate?.longitude == g.longitude)
    }

    @Test func aRaceBoxPacketFillsEveryBlock() throws {
        let u = try packet().telemetryUpdate
        #expect(u.gnss != nil && u.imu != nil && u.power != nil)
    }

    // MARK: Derived values match the packet's own

    @Test func movingSpeedAgreesWithThePacketAtEveryThresholdEdge() throws {
        let speeds = [0, 0.05, 0.2, 0.24, 0.25, 0.26, 0.3, 0.5, 0.9, 1.0, 1.1, 2.0, 13.889, 40, 80]
        let accuracies = [0.0, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0]
        for speed in speeds {
            for accuracy in accuracies {
                let p = try packet { $0.groundSpeedMps = speed; $0.speedAccMps = accuracy }
                let g = try #require(p.telemetryUpdate.gnss)
                #expect(g.movingSpeedKmh == p.movingSpeedKmh,
                        "speed \(speed) m/s, accuracy \(accuracy) m/s")
            }
        }
    }

    @Test func headingCardinalAgreesWithThePacketAroundTheCompass() throws {
        var heading = -400.0
        while heading <= 400 {
            let p = try packet { $0.headingDeg = heading }
            let g = try #require(p.telemetryUpdate.gnss)
            #expect(g.headingCardinal == p.headingCardinal, "heading \(heading)")
            heading += 7.5
        }
        // The compass edges themselves.
        for heading in [22.4, 22.5, 22.6, 67.4, 67.5, 337.4, 337.5, 359.99] {
            let p = try packet { $0.headingDeg = heading }
            #expect(try #require(p.telemetryUpdate.gnss).headingCardinal == p.headingCardinal)
        }
    }

    @Test func fixDescriptionAndValidityAgreeWithThePacket() throws {
        for fixType in 0...9 {
            for latLonFlags in [UInt8(0), 1] {
                let p = try packet { $0.fixType = UInt8(fixType); $0.latLonFlags = latLonFlags }
                let g = try #require(p.telemetryUpdate.gnss)
                #expect(g.fixTypeString == p.fixTypeString, "fix \(fixType)")
                #expect(g.hasFix == p.hasValidFix, "fix \(fixType), flags \(latLonFlags)")
            }
        }
    }

    @Test func everyBatteryByteAgreesWithThePacket() throws {
        for byte in 0...255 {
            let p = try packet { $0.battery = UInt8(byte) }
            let power = try #require(p.telemetryUpdate.power)
            #expect(power.batteryPercent == p.batteryPercent, "byte \(byte)")
            #expect(power.isCharging == p.isCharging, "byte \(byte)")
        }
    }

    @Test func dateAndTimeAreValidIndependentlyAndPrintAsTheyDid() throws {
        for flags in UInt8(0)...3 {
            let p = try packet {
                $0.validityFlags = flags
                $0.year = 2026; $0.month = 3; $0.day = 9
                $0.hour = 7; $0.minute = 4; $0.second = 2
            }
            let g = try #require(p.telemetryUpdate.gnss)
            #expect((g.date != nil) == ((flags & 0x01) != 0), "flags \(flags)")
            #expect((g.time != nil) == ((flags & 0x02) != 0), "flags \(flags)")
            if flags & 0x01 != 0 { #expect(g.date?.text == "2026-03-09") }
            if flags & 0x02 != 0 { #expect(g.time?.text == "07:04:02") }
        }
    }

    // MARK: Block-level helpers

    @Test func missingFieldsGiveNilDerivedValues() {
        let g = GnssBlock()
        #expect(g.coordinate == nil)
        #expect(g.fixTypeString == nil)
        #expect(g.movingSpeedKmh == nil)
        #expect(g.headingCardinal == nil)
        #expect(!g.hasFix)
    }

    @Test func movingSpeedWithoutAnAccuracyUsesTheFloor() {
        var g = GnssBlock()
        g.speedKmh = 0.8
        #expect(g.movingSpeedKmh == 0)                       // under 0.25 m/s
        g.speedKmh = 1.0
        #expect(g.movingSpeedKmh == 1.0)
    }
}

// MARK: - Merging updates

struct TelemetryStateTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 100)
    private let t1 = Date(timeIntervalSinceReferenceDate: 101)

    @Test func startsEmpty() {
        let s = TelemetryState()
        #expect(s.gnss == nil && s.imu == nil && s.power == nil)
        #expect(s.gnssUpdatedAt == nil && s.imuUpdatedAt == nil && s.powerUpdatedAt == nil)
        #expect(s.revision == 0)
    }

    @Test func anUpdateFillsTheBlocksItCarriesAndStampsThem() throws {
        var s = TelemetryState()
        s.apply(try packet().telemetryUpdate, at: t0)
        #expect(s.gnss != nil && s.imu != nil && s.power != nil)
        #expect(s.gnssUpdatedAt == t0 && s.imuUpdatedAt == t0 && s.powerUpdatedAt == t0)
        #expect(s.revision == 1)
    }

    @Test func aPartialUpdateLeavesTheOtherBlocksAlone() throws {
        var s = TelemetryState()
        let full = try packet { $0.latitude = 10; $0.accelXG = 0.5 }.telemetryUpdate
        s.apply(full, at: t0)

        var imuOnly = TelemetryUpdate()
        imuOnly.imu = ImuBlock(longitudinalG: 0.9)
        s.apply(imuOnly, at: t1)

        #expect(s.gnss == full.gnss)                         // untouched
        #expect(s.gnssUpdatedAt == t0)
        #expect(s.imu == ImuBlock(longitudinalG: 0.9))       // replaced whole, not merged field by field
        #expect(s.imuUpdatedAt == t1)
        #expect(s.power == full.power)
        #expect(s.powerUpdatedAt == t0)
    }

    @Test func eachUpdateAdvancesTheRevisionEvenWhenValuesRepeat() throws {
        var s = TelemetryState()
        let same = try packet().telemetryUpdate
        s.apply(same, at: t0)
        s.apply(same, at: t0)
        s.apply(TelemetryUpdate(), at: t0)                   // even an empty one
        #expect(s.revision == 3)
    }

    @Test func aLaterUpdateReplacesAnEarlierOne() throws {
        var s = TelemetryState()
        s.apply(try packet { $0.numSV = 8 }.telemetryUpdate, at: t0)
        s.apply(try packet { $0.numSV = 15 }.telemetryUpdate, at: t1)
        #expect(s.gnss?.satellites == 15)
        #expect(s.gnssUpdatedAt == t1)
    }
}
