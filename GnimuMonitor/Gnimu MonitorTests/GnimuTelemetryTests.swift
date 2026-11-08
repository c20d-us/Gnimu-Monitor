//
//  GnimuTelemetryTests.swift
//  Gnimu MonitorTests
//
//  The Gnimu protocol's side of the neutral telemetry model: how a frame becomes
//  blocks and fields, the UTC conversion, and the protocol's session.
//

import CoreBluetooth
import Foundation
import Testing
@testable import Gnimu_Monitor

private typealias V1 = GnimuFrameV1

private func bytes(fromHex hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

private func update(named name: String) throws -> TelemetryUpdate {
    let vector = try #require(gnimuFrameV1TestVectors.first { $0.name == name })
    return try V1.Frame(bytes(fromHex: vector.hex)).telemetryUpdate
}

// MARK: - Frame to telemetry

struct GnimuAdapterTests {

    @Test func blocksAppearExactlyWhenTheCapabilitiesSayTheDeviceFillsThem() throws {
        for vector in gnimuFrameV1TestVectors {
            let u = try V1.Frame(bytes(fromHex: vector.hex)).telemetryUpdate
            #expect(u.header != nil, "\(vector.name)")
            #expect((u.gnss != nil) == (vector.capabilities & 1 != 0), "\(vector.name) gnss")
            #expect((u.imu != nil) == (vector.capabilities & 2 != 0), "\(vector.name) imu")
            #expect((u.vehicle != nil) == (vector.capabilities & 4 != 0), "\(vector.name) vehicle")
            #expect((u.power != nil) == (vector.capabilities & 8 != 0), "\(vector.name) power")
        }
    }

    @Test func headerCarriesDeviceTimeSequenceStateAndCapabilities() throws {
        let h = try #require(try update(named: "gnimu-can-running").header)
        #expect(h.deviceTimeMs == 734_120)
        #expect(h.sequence == 201)
        #expect(h.stateRaw == 2)
        #expect(h.capabilities == 12)
    }

    @Test func aGnimuCANFrameFillsTheVehicleAndPowerBlocksOnly() throws {
        let u = try update(named: "gnimu-can-running")
        #expect(u.gnss == nil && u.imu == nil)

        let v = try #require(u.vehicle)
        #expect(v.engineSpeedRpm == 3250)
        #expect(v.throttlePercent == 42.7)
        #expect(v.ambientTempC == 18.5)
        #expect(v.transmissionTempC == 85.5)
        // Everything the vector doesn't carry is nil, not zero.
        #expect(v.coolantTempC == nil && v.speedKmh == nil && v.boostKpa == nil && v.gear == nil)
        #expect(v.brakePressed == nil && v.aux == [nil, nil, nil, nil])

        let p = try #require(u.power)
        #expect(p.supplyVolts == 14.12)
        #expect(p.batteryPercent == nil && p.isCharging == nil)
    }

    @Test func aWaitingFrameHasOnlyTheSupplyVoltage() throws {
        let u = try update(named: "gnimu-can-waiting")
        let v = try #require(u.vehicle)
        #expect(v == VehicleBlock())                          // present, nothing valid
        #expect(u.power?.supplyVolts == 12.48)
        #expect(u.header?.stateRaw == 3)
    }

    @Test func aGnssAndImuFrameFillsPositionMotionAndTheInertialBlock() throws {
        let u = try update(named: "gnimu-parked")
        let g = try #require(u.gnss)
        #expect(g.hasFix)
        #expect(g.fixType == 3)
        #expect(g.satellites == 17)
        #expect(g.latitude == 47.6205063)
        #expect(g.longitude == -122.3492774)
        #expect(g.altitudeMSL == 56.789)
        #expect(g.speedKmh == 0)
        #expect(g.pdop == 1.2)
        #expect(g.horizontalAccuracy == 0.412)
        #expect(g.timeAccuracyNs == 21)
        #expect(g.headingDeg == nil && g.headingAccuracyDeg == nil)
        #expect(g.timeOfWeekMs == nil)                        // the protocol has none
        #expect(g.date == UTCDate(year: 2026, month: 10, day: 30))
        #expect(g.time == UTCTime(hour: 11, minute: 6, second: 57))

        let imu = try #require(u.imu)
        #expect(imu.verticalG == 1.0)
        #expect(imu.longitudinalG == 0 && imu.lateralG == 0)

        let p = try #require(u.power)
        #expect(p.batteryPercent == 87)
        #expect(p.isCharging == false)
        #expect(p.supplyVolts == 4.02)
    }

    @Test func signedFieldsComeThroughNegative() throws {
        let v = try #require(try update(named: "edges").vehicle)
        #expect(v.gear == -1)
        #expect(v.ambientTempC == -12.4)
        #expect(v.steeringAngleDeg == -12.3)
        #expect(v.aux[0] == 1234)                             // raw: the schema scales aux fields
        #expect(try #require(try update(named: "edges").imu).lateralG == -32.768)
    }

    @Test func aGnssDeviceWithoutAFixStillHasAGnssBlock() throws {
        var b = GnimuFrameBuilder()
        b.capabilities = 1
        b.set(.satellites, 4)
        b.set(.fixType, 0)
        let g = try #require(try V1.Frame(b.build()).telemetryUpdate.gnss)
        #expect(!g.hasFix)
        #expect(g.satellites == 4)
        #expect(g.fixType == 0)
        #expect(g.latitude == nil && g.longitude == nil && g.coordinate == nil)
        #expect(g.date == nil && g.time == nil)
    }

    @Test func aFixNeedsBothCoordinatesValid() throws {
        var onlyLatitude = GnimuFrameBuilder()
        onlyLatitude.capabilities = 1
        onlyLatitude.set(.latitude, 10)
        #expect(try #require(try V1.Frame(onlyLatitude.build()).telemetryUpdate.gnss).hasFix == false)

        var both = onlyLatitude
        both.set(.longitude, 20)
        #expect(try #require(try V1.Frame(both.build()).telemetryUpdate.gnss).hasFix)
    }

    @Test func switchesBecomeBooleans() throws {
        var b = GnimuFrameBuilder()
        b.capabilities = 4
        b.set(.brakeSwitch, 1)
        b.set(.clutchSwitch, 0)
        let v = try #require(try V1.Frame(b.build()).telemetryUpdate.vehicle)
        #expect(v.brakePressed == true)
        #expect(v.clutchPressed == false)
    }

    @Test func updatesMergeIntoTheStateByBlock() throws {
        var state = TelemetryState()
        state.apply(try update(named: "gnimu-can-running"), at: Date(timeIntervalSinceReferenceDate: 1))
        #expect(state.vehicle?.engineSpeedRpm == 3250)
        #expect(state.header?.sequence == 201)
        #expect(state.gnss == nil)

        // A later frame replaces the blocks it carries and leaves the rest.
        state.apply(try update(named: "gnimu-parked"), at: Date(timeIntervalSinceReferenceDate: 2))
        #expect(state.gnss?.satellites == 17)
        #expect(state.vehicle?.engineSpeedRpm == 3250)        // not in this frame's blocks
        #expect(state.vehicleUpdatedAt == Date(timeIntervalSinceReferenceDate: 1))
        #expect(state.header?.sequence == 17)
    }
}

// MARK: - UTC conversion

struct UTCInstantTests {
    @Test(arguments: [
        (0.0, "1970-01-01", "00:00:00"),
        (31_536_000_000.0, "1971-01-01", "00:00:00"),
        (951_782_400_000.0, "2000-02-29", "00:00:00"),        // a leap day, in a leap century
        (1_709_164_799_999.0, "2024-02-28", "23:59:59"),      // the millisecond is dropped, not rounded up
        (1_793_358_417_500.0, "2026-10-30", "11:06:57"),
        (4_102_444_800_000.0, "2100-01-01", "00:00:00"),      // not a leap year
        (253_402_300_799_999.0, "9999-12-31", "23:59:59"),
    ])
    func convertsKnownInstants(ms: Double, date: String, time: String) throws {
        let instant = try #require(UTCInstant(unixMilliseconds: ms))
        #expect(instant.date.text == date)
        #expect(instant.time.text == time)
    }

    @Test(arguments: [-1.0, -86_400_000.0, 253_402_300_800_000.0, .infinity, .nan])
    func rejectsInstantsThatArentUsable(ms: Double) {
        #expect(UTCInstant(unixMilliseconds: ms) == nil)
    }

    @Test func everyDayOfALeapYearRoundTrips() throws {
        // 2024-01-01 00:00 UTC, one day at a time, against the calendar's own idea of it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = 1_704_067_200.0
        for day in 0..<366 {
            let seconds = start + Double(day) * 86_400 + 43_210       // 12:00:10
            let expected = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: seconds))
            let instant = try #require(UTCInstant(unixMilliseconds: seconds * 1000))
            #expect(instant.date == UTCDate(year: expected.year!, month: expected.month!, day: expected.day!),
                    "day \(day)")
            #expect(instant.time == UTCTime(hour: 12, minute: 0, second: 10))
        }
    }
}

// MARK: - The protocol's session

struct GnimuSessionTests {
    private let frameUUID = DeviceProtocol.gnimuFrameCharacteristicUUID

    private func goodFrame() -> Data {
        var b = GnimuFrameBuilder()
        b.capabilities = 12
        b.sequence = 7
        b.set(.engineSpeed, 2500)
        return Data(b.build())
    }

    @Test func eachNotificationIsOneFrame() throws {
        var session = DeviceProtocol.gnimu.makeSession()
        let data = goodFrame()
        let out = session.receive(data, from: frameUUID)
        #expect(out.count == 1)
        #expect(out.first?.raw == data)
        #expect(out.first?.gnssEpochMs == nil)
        #expect(out.first?.update.vehicle?.engineSpeedRpm == 2500)
        #expect(out.first?.update.header?.sequence == 7)
    }

    @Test(arguments: [0, 20, 88, 139, 141, 182])
    func aNotificationOfAnyOtherLengthIsDropped(length: Int) {
        var session = GnimuFrameSession()
        #expect(session.receive(Data(repeating: 0, count: length), from: frameUUID).isEmpty)
        #expect(session.rejected == 1)
    }

    @Test func anotherSpecVersionIsDropped() {
        var session = GnimuFrameSession()
        var data = [UInt8](goodFrame())
        data[V1.specVersionOffset] = 2
        #expect(session.receive(Data(data), from: frameUUID).isEmpty)
        #expect(session.rejected == 1)
    }

    @Test func aRaceBoxPacketOnTheFrameCharacteristicIsDropped() throws {
        var session = GnimuFrameSession()
        let packet = RaceBoxPacketBuilder().build()
        #expect(session.receive(packet, from: frameUUID).isEmpty)
    }

    @Test func otherCharacteristicsAreIgnored() {
        var session = GnimuFrameSession()
        let other = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(session.receive(goodFrame(), from: other).isEmpty)
        #expect(session.rejected == 0)
    }

    @Test func resetClearsTheCount() {
        var session = GnimuFrameSession()
        _ = session.receive(Data(count: 5), from: frameUUID)
        #expect(session.rejected == 1)
        session.reset()
        #expect(session.rejected == 0)
    }

    @Test func theRaceBoxSessionStillWorksThroughTheSameInterface() throws {
        var session = DeviceProtocol.raceBox.makeSession()
        let characteristic = DeviceProtocol.raceBox.notifyCharacteristicUUIDs[0]
        var b = RaceBoxPacketBuilder()
        b.iTOW = 4242
        let packet = b.build()
        let out = session.receive(packet.prefix(50), from: characteristic)
            + session.receive(packet.suffix(from: 50), from: characteristic)
        #expect(out.map(\.gnssEpochMs) == [4242])
    }
}
