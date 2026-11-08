//
//  RaceBoxPacketTests.swift
//  Gnimu MonitorTests
//
//  Pins what GnimuPacket.parse accepts and what it makes of each field, so the
//  protocol-neutral refactor can't quietly change RaceBox decoding.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

struct RaceBoxPacketTests {

    // MARK: - Field decoding

    @Test func decodesEveryField() throws {
        var b = RaceBoxPacketBuilder()
        b.iTOW = 123_456_789
        b.year = 2026; b.month = 11; b.day = 8
        b.hour = 14; b.minute = 5; b.second = 59
        b.validityFlags = 0x07
        b.timeAccuracyNs = 42
        b.nanoseconds = -250_000
        b.fixType = 3
        b.fixStatusFlags = 0x01
        b.dateTimeFlags = 0xE0
        b.numSV = 17
        b.latitude = 51.5074
        b.longitude = -0.1278
        b.heightEllipsoidM = 80.456
        b.heightMSLM = 35.123
        b.hAccM = 1.234
        b.vAccM = 2.345
        b.groundSpeedMps = 13.889
        b.headingDeg = 271.5
        b.speedAccMps = 0.123
        b.headingAccDeg = 4.5
        b.pDOP = 1.37
        b.latLonFlags = 0
        b.battery = 87
        b.accelXG = 0.123; b.accelYG = -0.456; b.accelZG = 0.987
        b.gyroXDps = 1.25; b.gyroYDps = -2.5; b.gyroZDps = 3.75

        let p = try #require(GnimuPacket.parse(from: b.build()))

        #expect(p.iTOW == 123_456_789)
        #expect(p.year == 2026)
        #expect(p.month == 11)
        #expect(p.day == 8)
        #expect(p.hour == 14)
        #expect(p.minute == 5)
        #expect(p.second == 59)
        #expect(p.validityFlags == 0x07)
        #expect(p.timeAccuracy == 42)
        #expect(p.nanoseconds == -250_000)
        #expect(p.fixType == 3)
        #expect(p.fixStatusFlags == 0x01)
        #expect(p.dateTimeFlags == 0xE0)
        #expect(p.numSV == 17)
        #expect(near(p.latitude, 51.5074, 1e-7))
        #expect(near(p.longitude, -0.1278, 1e-7))
        #expect(near(p.heightEllipsoid, 80.456))
        #expect(near(p.heightMSL, 35.123))
        #expect(near(p.hAcc, 1.234))
        #expect(near(p.vAcc, 2.345))
        #expect(near(p.groundSpeed, 13.889))
        #expect(near(p.headingOfMotion, 271.5))
        #expect(near(p.speedAccuracy, 0.123))
        #expect(near(p.headingAccuracy, 4.5))
        #expect(near(p.pDOP, 1.37))
        #expect(p.latLonFlags == 0)
        #expect(p.battery == 87)
        #expect(near(p.accelX, 0.123))
        #expect(near(p.accelY, -0.456))
        #expect(near(p.accelZ, 0.987))
        #expect(near(p.gyroX, 1.25))
        #expect(near(p.gyroY, -2.5))
        #expect(near(p.gyroZ, 3.75))
    }

    @Test func decodesSouthernAndWesternHemispheres() throws {
        var b = RaceBoxPacketBuilder()
        b.latitude = -33.8688
        b.longitude = -151.2093
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(near(p.latitude, -33.8688, 1e-7))
        #expect(near(p.longitude, -151.2093, 1e-7))
    }

    @Test func decodesNegativeAltitudeAndRates() throws {
        var b = RaceBoxPacketBuilder()
        b.heightMSLM = -12.345
        b.accelXG = -1.5
        b.gyroZDps = -300.25
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(near(p.heightMSL, -12.345))
        #expect(near(p.accelX, -1.5))
        #expect(near(p.gyroZ, -300.25))
    }

    // MARK: - Rejection

    @Test(arguments: [0, 1, 87, 89, 176])
    func rejectsWrongLength(length: Int) {
        let good = RaceBoxPacketBuilder().build()
        let data = length <= good.count
            ? good.prefix(length)
            : good + Data(repeating: 0, count: length - good.count)
        #expect(GnimuPacket.parse(from: Data(data)) == nil)
    }

    @Test(arguments: [0, 1])
    func rejectsBadSyncByte(index: Int) {
        let bad = RaceBoxPacketBuilder().build().replacing(byteAt: index, with: 0x00)
        #expect(GnimuPacket.parse(from: bad) == nil)
    }

    @Test(arguments: [2, 3])
    func rejectsWrongClassOrId(index: Int) {
        // Only the checksum would catch it otherwise, so rebuild a valid one
        // around the wrong class or id: the class/id check must stand alone.
        var bytes = [UInt8](RaceBoxPacketBuilder().build())
        bytes[index] = 0x7E
        let (a, b) = RaceBoxPacketBuilder.checksum(of: bytes)
        bytes[86] = a
        bytes[87] = b
        #expect(GnimuPacket.parse(from: Data(bytes)) == nil)
    }

    @Test(arguments: [6, 30, 60, 85])
    func rejectsCorruptedPayload(index: Int) {
        let good = RaceBoxPacketBuilder().build()
        let bad = good.replacing(byteAt: index, with: good[index] ^ 0x01)
        #expect(GnimuPacket.parse(from: bad) == nil)
    }

    @Test(arguments: [86, 87])
    func rejectsCorruptedChecksum(index: Int) {
        let good = RaceBoxPacketBuilder().build()
        let bad = good.replacing(byteAt: index, with: good[index] ^ 0xFF)
        #expect(GnimuPacket.parse(from: bad) == nil)
    }

    // MARK: - Battery byte

    @Test func batteryByteSplitsLevelAndChargingBit() throws {
        var b = RaceBoxPacketBuilder()

        b.battery = 55
        var p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(p.batteryPercent == 55)
        #expect(!p.isCharging)

        b.battery = 0x80 | 55
        p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(p.batteryPercent == 55)
        #expect(p.isCharging)
    }

    @Test func batteryPercentClampsToOneHundred() throws {
        var b = RaceBoxPacketBuilder()
        b.battery = 0x7F   // 127 in the low seven bits
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(p.batteryPercent == 100)
    }

    // MARK: - Derived values

    @Test func validFixNeedsFixTypeAndClearLatLonFlag() throws {
        func packet(fixType: UInt8, latLonFlags: UInt8) throws -> GnimuPacket {
            var b = RaceBoxPacketBuilder()
            b.fixType = fixType
            b.latLonFlags = latLonFlags
            return try #require(GnimuPacket.parse(from: b.build()))
        }
        #expect(try packet(fixType: 3, latLonFlags: 0).hasValidFix)
        #expect(try packet(fixType: 2, latLonFlags: 0).hasValidFix)
        #expect(try !packet(fixType: 3, latLonFlags: 1).hasValidFix)   // lat/lon invalid
        #expect(try !packet(fixType: 1, latLonFlags: 0).hasValidFix)
        #expect(try !packet(fixType: 0, latLonFlags: 0).hasValidFix)
    }

    @Test(arguments: [
        (UInt8(0), "No Fix"), (1, "Dead Reckoning"), (2, "2D Fix"), (3, "3D Fix"),
        (4, "GNSS + DR"), (5, "Time Only"), (9, "Unknown (9)"),
    ])
    func fixTypeStrings(fixType: UInt8, expected: String) throws {
        var b = RaceBoxPacketBuilder()
        b.fixType = fixType
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(p.fixTypeString == expected)
    }

    @Test func speedConvertsMetresPerSecondToKmh() throws {
        var b = RaceBoxPacketBuilder()
        b.groundSpeedMps = 10
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(near(p.speedKmh, 36.0))
    }

    @Test func movingSpeedSuppressesStationaryNoise() throws {
        func moving(speed: Double, accuracy: Double) throws -> Double {
            var b = RaceBoxPacketBuilder()
            b.groundSpeedMps = speed
            b.speedAccMps = accuracy
            return try #require(GnimuPacket.parse(from: b.build())).movingSpeedKmh
        }
        // Below the 0.25 m/s floor: zero.
        #expect(try moving(speed: 0.2, accuracy: 0.05) == 0)
        // Above the floor and its own accuracy: the real speed comes through.
        #expect(try near(moving(speed: 0.3, accuracy: 0.05), 0.3 * 3.6))
        // The accuracy estimate raises the threshold above the floor.
        #expect(try moving(speed: 0.9, accuracy: 1.0) == 0)
        #expect(try near(moving(speed: 1.1, accuracy: 1.0), 1.1 * 3.6))
    }

    @Test(arguments: [
        (0.0, "N"), (22.4, "N"), (22.6, "NE"), (90.0, "E"), (180.0, "S"),
        (270.0, "W"), (337.4, "NW"), (337.6, "N"), (359.9, "N"),
        (-90.0, "W"), (-10.0, "N"),
    ])
    func headingCardinals(heading: Double, expected: String) throws {
        var b = RaceBoxPacketBuilder()
        b.headingDeg = heading
        let p = try #require(GnimuPacket.parse(from: b.build()))
        #expect(p.headingCardinal == expected)
    }
}
