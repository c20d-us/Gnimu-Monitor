//
//  GnimuDeviceInfoTests.swift
//  Gnimu MonitorTests
//
//  Parsing of what a Gnimu-protocol device reports about itself: the Schema and
//  Device info characteristics, and the Device Information Service. The JSON
//  examples are the ones in the protocol spec.
//

import CoreBluetooth
import Foundation
import Testing
@testable import Gnimu_Monitor

private func data(_ text: String) -> Data { Data(text.utf8) }

struct GnimuSchemaTests {

    @Test func readsTheSpecsExample() throws {
        let schema = try #require(GnimuSchema.parse(data("""
            {"v":1,"d":"Gnimu-CAN","r":20,
             "fill":{"vehicle":3,"power":1},
             "aux":{"aux_1":{"k":"Ethanol content","u":"%","s":10}}}
            """)))
        #expect(schema.version == 1)
        #expect(schema.product == "Gnimu-CAN")
        #expect(schema.rateHz == 20)
        #expect(schema.fill == ["vehicle": 3, "power": 1])
        let aux = try #require(schema.aux["aux_1"])
        #expect(aux.name == "Ethanol content")
        #expect(aux.unit == "%")
        #expect(aux.scale == 10)
        #expect(aux.value(fromRaw: 855) == 85.5)
    }

    @Test func aSchemaWithOnlyTheRequiredKeysParses() throws {
        let schema = try #require(GnimuSchema.parse(data(#"{"v":1}"#)))
        #expect(schema.product == nil && schema.rateHz == nil)
        #expect(schema.fill.isEmpty && schema.aux.isEmpty)
    }

    @Test func unknownKeysAreIgnored() throws {
        let schema = try #require(GnimuSchema.parse(data(
            #"{"v":1,"d":"X","r":10,"future":{"a":1},"fill":{"gnss":16383,"newblock":5}}"#)))
        #expect(schema.fill["gnss"] == 16383)
        #expect(schema.fill["newblock"] == 5)                  // kept, harmlessly
    }

    @Test func aFractionalRateIsKept() throws {
        #expect(try #require(GnimuSchema.parse(data(#"{"v":1,"r":12.5}"#))).rateHz == 12.5)
    }

    @Test func anAuxEntryWithoutAScaleDefaultsToOne() throws {
        let schema = try #require(GnimuSchema.parse(data(#"{"v":1,"aux":{"aux_2":{"k":"Lambda"}}}"#)))
        #expect(schema.aux["aux_2"]?.scale == 1)
        #expect(schema.aux["aux_2"]?.unit == "")
    }

    @Test func anAuxEntryWithoutANameIsDropped() throws {
        let schema = try #require(GnimuSchema.parse(data(#"{"v":1,"aux":{"aux_1":{"u":"%"}}}"#)))
        #expect(schema.aux.isEmpty)
    }

    @Test(arguments: ["", "not json", "[]", #"{"d":"Gnimu-CAN"}"#, #"{"v":"1"}"#])
    func somethingThatIsntASchemaIsNil(text: String) {
        #expect(GnimuSchema.parse(data(text)) == nil)
    }
}

struct GnimuDeviceInfoParsingTests {

    @Test func readsTheSpecsExample() throws {
        let info = try #require(GnimuDeviceInfo.parse(data("""
            {"v":1,
             "build":{"rev":"7f7efe5f4d6a","utc":"2026-10-30T17:27:43Z","target":"esp32c6"},
             "cfg":{"vehicle":"obd2","can":"auto 500/250","emit_hz":20,"run_v":13.2,"cutoff_v":11.8}}
            """)))
        #expect(info.version == 1)
        #expect(info.build == .init(revision: "7f7efe5f4d6a", utc: "2026-10-30T17:27:43Z", target: "esp32c6"))
        #expect(info.settings.map(\.key) == ["can", "cutoff_v", "emit_hz", "run_v", "vehicle"])   // sorted
        let byKey = Dictionary(uniqueKeysWithValues: info.settings.map { ($0.key, $0.value) })
        #expect(byKey["vehicle"] == "obd2")
        #expect(byKey["can"] == "auto 500/250")
        #expect(byKey["emit_hz"] == "20")
        #expect(byKey["run_v"] == "13.2")
        #expect(byKey["cutoff_v"] == "11.8")
    }

    @Test func booleansAreNotMistakenForNumbers() throws {
        let info = try #require(GnimuDeviceInfo.parse(data(#"{"v":1,"cfg":{"a":true,"b":false,"c":1,"d":0}}"#)))
        let byKey = Dictionary(uniqueKeysWithValues: info.settings.map { ($0.key, $0.value) })
        #expect(byKey == ["a": "true", "b": "false", "c": "1", "d": "0"])
    }

    @Test func settingsThatArentStringsNumbersOrBooleansAreSkipped() throws {
        let info = try #require(GnimuDeviceInfo.parse(data(#"{"v":1,"cfg":{"ok":"x","list":[1,2],"nested":{"a":1},"none":null}}"#)))
        #expect(info.settings == [.init(key: "ok", value: "x")])
    }

    @Test func buildAndConfigAreOptional() throws {
        let info = try #require(GnimuDeviceInfo.parse(data(#"{"v":1}"#)))
        #expect(info.build == .init(revision: nil, utc: nil, target: nil))
        #expect(info.settings.isEmpty)
    }

    @Test(arguments: ["", "{", "[1]", #"{"build":{}}"#])
    func somethingThatIsntDeviceInfoIsNil(text: String) {
        #expect(GnimuDeviceInfo.parse(data(text)) == nil)
    }
}

struct DeviceIdentityTests {

    @Test func recordsEachDeviceInformationCharacteristic() {
        var identity = DeviceIdentity()
        let claimed = [
            identity.record(data("Gnimu"), for: DeviceIdentity.manufacturerUUID),
            identity.record(data("Gnimu-CAN"), for: DeviceIdentity.modelUUID),
            identity.record(data("0301821570"), for: DeviceIdentity.serialUUID),
            identity.record(data("0.1.0"), for: DeviceIdentity.firmwareUUID),
            identity.record(data("XIAO ESP32C6, 12V carrier v1.0"), for: DeviceIdentity.hardwareUUID),
        ]
        #expect(claimed == [true, true, true, true, true])
        #expect(identity == DeviceIdentity(manufacturer: "Gnimu", model: "Gnimu-CAN", serial: "0301821570",
                                           firmware: "0.1.0", hardware: "XIAO ESP32C6, 12V carrier v1.0"))
    }

    @Test func trailingControlCharactersAreTrimmed() {
        var identity = DeviceIdentity()
        _ = identity.record(Data("0.1.0\0".utf8), for: DeviceIdentity.firmwareUUID)
        #expect(identity.firmware == "0.1.0")
    }

    @Test func otherCharacteristicsAreNotClaimed() {
        var identity = DeviceIdentity()
        let claimed = identity.record(data("x"), for: CBUUID(string: "2A00"))
        #expect(!claimed)
        #expect(identity == DeviceIdentity())
    }

    @Test func allFiveCharacteristicsAreAsked() {
        #expect(Set(DeviceIdentity.characteristicUUIDs) == [
            CBUUID(string: "2A29"), CBUUID(string: "2A24"), CBUUID(string: "2A25"),
            CBUUID(string: "2A26"), CBUUID(string: "2A27"),
        ])
    }
}
