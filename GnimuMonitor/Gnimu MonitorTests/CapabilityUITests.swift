//
//  CapabilityUITests.swift
//  Gnimu MonitorTests
//
//  What a device gets on screen follows from what it provides: the device
//  profile, the panel lists, the state notices, the units, and the vehicle
//  channel table.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private func state(_ configure: (inout TelemetryUpdate) -> Void) -> TelemetryState {
    var update = TelemetryUpdate()
    configure(&update)
    var s = TelemetryState()
    s.apply(update, at: Date(timeIntervalSinceReferenceDate: 0))
    return s
}

private let header = DeviceHeader(deviceTimeMs: 1000, sequence: 1, stateRaw: 2, capabilities: 12)

// MARK: - Device profile

struct DeviceProfileTests {

    @Test func aRaceBoxDeviceIsGnssImuAndPowerBeforeItsFirstFrame() {
        let p = DeviceProfile(telemetry: nil, deviceProtocol: .raceBox)
        #expect(p.hasGnss && p.hasImu && p.hasPower && p.hasReceiverClock)
        #expect(!p.hasVehicle && !p.hasStreamHeader)
        #expect(p.mapIsPrimary)
    }

    @Test func aGnimuDeviceIsNothingUntilItsFirstFrame() {
        let p = DeviceProfile(telemetry: nil, deviceProtocol: .gnimu)
        #expect(p == DeviceProfile())
        #expect(!p.mapIsPrimary)
    }

    @Test func aRaceBoxPacketGivesTheSameProfileAsBeforeItArrived() throws {
        let packet = try #require(RaceBoxPacket.parse(from: RaceBoxPacketBuilder().build()))
        var s = TelemetryState()
        s.apply(packet.telemetryUpdate, at: Date())
        #expect(DeviceProfile(telemetry: s, deviceProtocol: .raceBox)
                == DeviceProfile(telemetry: nil, deviceProtocol: .raceBox))
    }

    @Test func aCANOnlyDeviceHasVehiclePowerAndAStreamButNoPosition() {
        let s = state {
            $0.header = header
            $0.vehicle = VehicleBlock()
            $0.power = PowerBlock()
        }
        let p = DeviceProfile(telemetry: s, deviceProtocol: .gnimu)
        #expect(p.hasVehicle && p.hasPower && p.hasStreamHeader)
        #expect(!p.hasGnss && !p.hasImu && !p.hasReceiverClock)
        #expect(!p.mapIsPrimary)
    }

    @Test func gnssFromTheGnimuProtocolHasNoReceiverClock() {
        let s = state { $0.header = header; $0.gnss = GnssBlock(); $0.imu = ImuBlock() }
        let p = DeviceProfile(telemetry: s, deviceProtocol: .gnimu)
        #expect(p.hasGnss && p.hasImu && p.hasStreamHeader)
        #expect(!p.hasReceiverClock)                    // no iTOW in the protocol
    }
}

// MARK: - Panel lists

struct PanelListTests {
    private let raceBox = DeviceProfile(telemetry: nil, deviceProtocol: .raceBox)

    private func profile(gnss: Bool = false, imu: Bool = false, vehicle: Bool = false,
                         clock: Bool = false, header: Bool = false) -> DeviceProfile {
        var p = DeviceProfile()
        p.hasGnss = gnss; p.hasImu = imu; p.hasVehicle = vehicle
        p.hasReceiverClock = clock; p.hasStreamHeader = header
        return p
    }

    @Test func aRaceBoxDeviceGetsExactlyTheOriginalPanels() {
        #expect(MonitorPanel.stripTabs(profile: raceBox, hasDevice: false) == [.data, .fixRate, .level, .capture])
        #expect(MonitorPanel.stripTabs(profile: raceBox, hasDevice: true) == [.data, .fixRate, .level, .capture, .device])
        #expect(MonitorPanel.deckPages(profile: raceBox, hasDevice: false)
                == [.map, .data, .fixRate, .gForce, .level, .capture])
        #expect(MonitorPanel.deckPages(profile: raceBox, hasDevice: true)
                == [.map, .data, .fixRate, .gForce, .level, .capture, .device])
    }

    @Test func aCANOnlyDeviceGetsVehicleStreamAndCapture() {
        let p = profile(vehicle: true, header: true)
        // The vehicle panel fills the main area, so it isn't a tab; it is a deck page.
        #expect(MonitorPanel.stripTabs(profile: p, hasDevice: false) == [.streamHealth, .capture])
        #expect(MonitorPanel.deckPages(profile: p, hasDevice: false) == [.vehicle, .streamHealth, .capture])
    }

    @Test func aCANDeviceBeforeItsFirstFrameStillOffersCapture() {
        let p = DeviceProfile(telemetry: nil, deviceProtocol: .gnimu)
        #expect(MonitorPanel.stripTabs(profile: p, hasDevice: false) == [.capture])
        #expect(MonitorPanel.deckPages(profile: p, hasDevice: false) == [.capture])
    }

    @Test func anAllInOneDeviceGetsEverythingWithTheMapFirst() {
        let p = profile(gnss: true, imu: true, vehicle: true, header: true)
        #expect(MonitorPanel.stripTabs(profile: p, hasDevice: false)
                == [.vehicle, .data, .streamHealth, .level, .capture])
        #expect(MonitorPanel.deckPages(profile: p, hasDevice: false)
                == [.map, .vehicle, .data, .streamHealth, .gForce, .level, .capture])
    }

    @Test func aGnimuProtocolGnssDeviceGetsStreamHealthNotFixRate() {
        let p = profile(gnss: true, imu: true, header: true)
        #expect(MonitorPanel.stripTabs(profile: p, hasDevice: false) == [.data, .streamHealth, .level, .capture])
        #expect(!MonitorPanel.deckPages(profile: p, hasDevice: false).contains(.fixRate))
    }

    @Test func noImuMeansNoLevelOrGForce() {
        let p = profile(gnss: true, clock: true)
        #expect(MonitorPanel.stripTabs(profile: p, hasDevice: false) == [.data, .fixRate, .capture])
        #expect(MonitorPanel.deckPages(profile: p, hasDevice: false) == [.map, .data, .fixRate, .capture])
    }

    @Test func theMapIsNeverATab() {
        for p in [raceBox, profile(gnss: true, vehicle: true, header: true), profile(vehicle: true)] {
            #expect(!MonitorPanel.stripTabs(profile: p, hasDevice: true).contains(.map))
        }
    }

    @Test func everyPanelAppearsAtMostOnce() {
        for p in [raceBox, profile(gnss: true, imu: true, vehicle: true, clock: true, header: true)] {
            for list in [MonitorPanel.stripTabs(profile: p, hasDevice: true), MonitorPanel.deckPages(profile: p, hasDevice: true)] {
                #expect(Set(list).count == list.count)
            }
        }
    }
}

// MARK: - State notices

struct DeviceStateDisplayTests {
    @Test(arguments: [
        (UInt8(0), DeviceStateDisplay.unknown), (1, .starting), (2, .running),
        (3, .waiting), (4, .fault), (5, .unknown), (255, .unknown),
    ])
    func mapsTheStateByte(raw: UInt8, expected: DeviceStateDisplay) {
        #expect(DeviceStateDisplay(raw: raw) == expected)
    }

    @Test func onlyWaitingFaultAndStartingNeedNoticing() {
        #expect(DeviceStateDisplay.waiting.vehicleNotice?.title == "Waiting for vehicle")
        #expect(DeviceStateDisplay.fault.vehicleNotice?.title == "Device fault")
        #expect(DeviceStateDisplay.starting.vehicleNotice?.title == "Starting")
        #expect(DeviceStateDisplay.running.vehicleNotice == nil)
        #expect(DeviceStateDisplay.unknown.vehicleNotice == nil)
    }

    @Test func everyStateHasAName() {
        #expect([DeviceStateDisplay.unknown, .starting, .running, .waiting, .fault].map(\.name)
                == ["Unknown", "Starting", "Running", "Waiting", "Fault"])
    }
}

// MARK: - Units

struct UnitTests {
    @Test func temperatureConvertsAndFormats() {
        #expect(TemperatureUnit.celsius.value(fromCelsius: 90) == 90)
        #expect(TemperatureUnit.fahrenheit.value(fromCelsius: 100) == 212)
        #expect(TemperatureUnit.fahrenheit.value(fromCelsius: -40) == -40)
        #expect(TemperatureUnit.fahrenheit.value(fromCelsius: 0) == 32)
        #expect(TemperatureUnit.celsius.text(fromCelsius: 88.5) == "88.5 °C")
        #expect(TemperatureUnit.fahrenheit.text(fromCelsius: 88.5) == "191.3 °F")
        #expect(TemperatureUnit.celsius.toggled == .fahrenheit && TemperatureUnit.fahrenheit.toggled == .celsius)
    }

    @Test func pressureConvertsAndFormats() {
        #expect(PressureUnit.kpa.value(fromKpa: 250) == 250)
        #expect(PressureUnit.bar.value(fromKpa: 250) == 2.5)
        #expect(abs(PressureUnit.psi.value(fromKpa: 100) - 14.5037738) < 1e-6)
        #expect(PressureUnit.kpa.text(fromKpa: 250) == "250.0 kPa")
        #expect(PressureUnit.psi.text(fromKpa: 100) == "14.5 psi")
        #expect(PressureUnit.bar.text(fromKpa: 250) == "2.50 bar")
        #expect(PressureUnit.bar.text(fromKpa: -55.3) == "-0.55 bar")      // vacuum
    }

    @Test func pressureCyclesThroughAllThree() {
        #expect(PressureUnit.kpa.next == .psi)
        #expect(PressureUnit.psi.next == .bar)
        #expect(PressureUnit.bar.next == .kpa)
    }

    @Test func unitsAreStoredByRawValue() {
        #expect(TemperatureUnit(rawValue: "fahrenheit") == .fahrenheit)
        #expect(PressureUnit(rawValue: "psi") == .psi)
        #expect(DisplayUnits() == DisplayUnits(speed: .kmh, temperature: .celsius, pressure: .kpa))
    }
}

// MARK: - The vehicle channel table

struct VehicleChannelTests {

    @Test func theTableCoversEveryVehicleFieldTheSpecDefines() {
        let specKeys = GnimuFrameV1.fields.filter { $0.block == .vehicle }.map(\.key)
        #expect(specKeys.count == 29)
        #expect(Set(VehicleChannel.all.map(\.key)) == Set(specKeys))
        #expect(VehicleChannel.all.count == specKeys.count)            // each once
    }

    @Test func everyChannelReadsTheFieldItsKeyNames() throws {
        // Build a frame with each vehicle field set to a distinct value, decode it,
        // and check the channel reads that value back.
        var b = GnimuFrameBuilder()
        b.capabilities = 4
        var expected: [String: Double] = [:]
        for (i, info) in GnimuFrameV1.fields.filter({ $0.block == .vehicle }).enumerated() {
            let field = GnimuFrameV1.Field(rawValue: GnimuFrameV1.fields.firstIndex { $0.key == info.key }!)!
            let value = info.key.hasSuffix("_switch") ? 1.0 : Double(i + 1)
            b.set(field, value)
            expected[info.key] = value
        }
        let vehicle = try #require(try GnimuFrameV1.Frame(b.build()).telemetryUpdate.vehicle)
        for channel in VehicleChannel.all {
            #expect(channel.read(vehicle) == expected[channel.key], "\(channel.key)")
        }
    }

    @Test func textUsesTheChosenUnits() {
        var v = VehicleBlock()
        v.engineSpeedRpm = 3250
        v.coolantTempC = 100
        v.boostKpa = 100
        v.speedKmh = 100
        v.gear = -1
        v.brakePressed = true
        v.clutchPressed = false
        let metric = DisplayUnits()
        let imperial = DisplayUnits(speed: .mph, temperature: .fahrenheit, pressure: .psi)
        func text(_ key: String, _ units: DisplayUnits) -> String {
            VehicleChannel.all.first { $0.key == key }!.text(in: v, units: units, schema: nil)
        }
        #expect(text("engine_speed", metric) == "3250 rpm")
        #expect(text("coolant_temp", metric) == "100.0 °C")
        #expect(text("coolant_temp", imperial) == "212.0 °F")
        #expect(text("boost", imperial) == "14.5 psi")
        #expect(text("vehicle_speed", metric) == "100.0 km/h")
        #expect(text("vehicle_speed", imperial) == "62.1 mph")
        #expect(text("gear", metric) == "R")
        #expect(text("brake_switch", metric) == "Pressed")
        #expect(text("clutch_switch", metric) == "Released")
        #expect(text("oil_temp", metric) == "—")                       // no value
    }

    @Test func auxChannelsGoByTheDevicesSchema() throws {
        var v = VehicleBlock()
        v.aux = [855, nil, nil, nil]
        let schema = try #require(GnimuSchema.parse(Data(
            #"{"v":1,"aux":{"aux_1":{"k":"Ethanol content","u":"%","s":10}}}"#.utf8)))
        let aux1 = VehicleChannel.all.first { $0.key == "aux_1" }!
        #expect(aux1.text(in: v, units: DisplayUnits(), schema: schema) == "85.5 %")
        #expect(aux1.displayLabel(schema: schema) == "Ethanol content")
        // Without the schema, raw and generic.
        #expect(aux1.text(in: v, units: DisplayUnits(), schema: nil) == "855 (raw)")
        #expect(aux1.displayLabel(schema: nil) == "Aux 1")
    }

    @Test func theSchemasFillMaskNamesTheChannelsTheDeviceProvides() throws {
        let schema = try #require(GnimuSchema.parse(Data(#"{"v":1,"fill":{"vehicle":3,"power":1}}"#.utf8)))
        #expect(VehicleChannel.filledKeys(in: schema) == ["engine_speed", "throttle_position"])
        #expect(VehicleChannel.filledKeys(in: nil) == nil)
        #expect(VehicleChannel.filledKeys(in: try #require(GnimuSchema.parse(Data(#"{"v":1}"#.utf8)))) == nil)
    }

    @Test func valuesListsOnlyTheValidChannels() {
        var v = VehicleBlock()
        v.engineSpeedRpm = 900
        v.brakePressed = false
        #expect(VehicleChannel.values(in: v) == ["engine_speed": 900, "brake_switch": 0])
        #expect(VehicleChannel.values(in: VehicleBlock()).isEmpty)
    }

    @Test func everyChannelIsInOneGroupAndEveryGroupHasATitle() {
        #expect(VehicleChannel.Group.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(VehicleChannel.all.allSatisfy { VehicleChannel.Group.allCases.contains($0.group) })
    }
}

// MARK: - Glance box corners

struct VehicleGlanceCornerTests {
    private func vehicle(_ configure: (inout VehicleBlock) -> Void = { _ in }) -> VehicleBlock {
        var v = VehicleBlock()
        configure(&v)
        return v
    }

    private func schema(fill: UInt32) throws -> GnimuSchema {
        try #require(GnimuSchema.parse(Data(#"{"v":1,"fill":{"vehicle":\#(fill)}}"#.utf8)))
    }

    @Test func withNoSchemaEveryCornerIsShown() {
        for corner in VehicleGlanceBox.Corner.allCases {
            #expect(corner.isShown(vehicle: vehicle(), schema: nil))
            #expect(corner.isShown(vehicle: nil, schema: nil))
        }
    }

    @Test func aDeviceThatReadsOnlyEngineSpeedAndThrottleShowsOnlyThrottle() throws {
        let s = try schema(fill: 3)                           // engine speed + throttle position
        #expect(VehicleGlanceBox.Corner.throttle.isShown(vehicle: vehicle(), schema: s))
        #expect(!VehicleGlanceBox.Corner.speed.isShown(vehicle: vehicle(), schema: s))
        #expect(!VehicleGlanceBox.Corner.gear.isShown(vehicle: vehicle(), schema: s))
    }

    @Test func aChannelWithAValueIsShownWhateverTheSchemaSays() throws {
        let s = try schema(fill: 3)
        let v = vehicle { $0.gear = 3; $0.speedKmh = 50 }
        #expect(VehicleGlanceBox.Corner.gear.isShown(vehicle: v, schema: s))
        #expect(VehicleGlanceBox.Corner.speed.isShown(vehicle: v, schema: s))
    }

    @Test func aSchemaThatFillsSpeedAndGearShowsThemBeforeTheyHaveValues() throws {
        // vehicle_speed is bit 3 and gear bit 24 in the vehicle block.
        let s = try schema(fill: (1 << 3) | (1 << 24))
        #expect(VehicleGlanceBox.Corner.speed.isShown(vehicle: vehicle(), schema: s))
        #expect(VehicleGlanceBox.Corner.gear.isShown(vehicle: vehicle(), schema: s))
        #expect(!VehicleGlanceBox.Corner.throttle.isShown(vehicle: vehicle(), schema: s))
    }

    @Test func aSchemaThatSaysNothingAboutTheVehicleShowsEveryCorner() throws {
        let s = try #require(GnimuSchema.parse(Data(#"{"v":1,"fill":{"power":1}}"#.utf8)))
        #expect(VehicleGlanceBox.Corner.allCases.allSatisfy { $0.isShown(vehicle: vehicle(), schema: s) })
    }

    @Test func everyCornerKeyIsARealVehicleChannel() {
        let keys = Set(VehicleChannel.all.map(\.key))
        #expect(VehicleGlanceBox.Corner.allCases.allSatisfy { keys.contains($0.key) })
    }
}
