//
//  GnimuDevicePanelTests.swift
//  Gnimu MonitorTests
//
//  The read-only Device panel for Gnimu-protocol devices: what its summary
//  holds for a full device, a sparse one and none at all, and when the tab is
//  offered.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

struct GnimuDeviceSummaryTests {
    private let identity = DeviceIdentity(manufacturer: "Gnimu Labs", model: "Gnimu-CAN", serial: "1958745094",
                                          firmware: "0.1.0", hardware: "XIAO ESP32C6, 12V carrier v1.0")
    private let schema = GnimuSchema.parse(Data(
        #"{"v":1,"d":"Gnimu-CAN","r":20,"fill":{"vehicle":3,"power":1},"aux":{"aux_1":{"k":"Boost target","u":"kPa","s":10}}}"#.utf8))
    private let info = GnimuDeviceInfo.parse(Data(
        #"{"v":1,"build":{"rev":"9c1e4a7","utc":"2026-11-10T18:22:05Z","target":"esp32c6"},"cfg":{"frame_rate_hz":20,"obd_polling":true,"can_bitrate":500000}}"#.utf8))

    private func section(_ title: String, in summary: GnimuDeviceSummary) -> GnimuDeviceSummary.Section? {
        summary.sections.first { $0.title == title }
    }

    @Test func aFullDeviceFillsEverySection() throws {
        let s = GnimuDeviceSummary(identity: identity, schema: schema, info: info)
        #expect(s.sections.map(\.title) == ["Device", "Firmware", "Output", "Other Channels", "Configuration"])

        let device = try #require(section("Device", in: s))
        #expect(device.rows.map(\.label) == ["Product", "Manufacturer", "Model", "Serial Number", "Hardware"])
        #expect(device.rows.first?.value == "Gnimu-CAN")

        let firmware = try #require(section("Firmware", in: s))
        #expect(firmware.rows.map(\.value) == ["0.1.0", "9c1e4a7", "2026-11-10T18:22:05Z", "esp32c6"])

        let output = try #require(section("Output", in: s))
        #expect(output.rows.first == .init(label: "Frame Rate", value: "20 Hz"))
        #expect(output.rows.last?.label == "Provides")
        #expect(output.rows.last?.value.contains("Vehicle") == true)
        #expect(output.rows.last?.value.contains("Power") == true)
        #expect(output.rows.last?.value.contains("GNSS") == false)

        let aux = try #require(section("Other Channels", in: s))
        #expect(aux.rows == [.init(label: "Boost target", value: "kPa")])
    }

    @Test func settingsAreListedByNameWithReadableLabels() throws {
        let s = GnimuDeviceSummary(identity: identity, schema: schema, info: info)
        let config = try #require(section("Configuration", in: s))
        #expect(config.rows == [.init(label: "Can bitrate", value: "500000"),
                                .init(label: "Frame rate hz", value: "20"),
                                .init(label: "Obd polling", value: "true")])
    }

    @Test func aSparseDeviceShowsOnlyWhatItReported() throws {
        // Identity only, as from a device that has no schema or device info.
        let s = GnimuDeviceSummary(identity: DeviceIdentity(manufacturer: "Gnimu Labs", serial: "42"),
                                   schema: nil, info: nil)
        #expect(s.sections.map(\.title) == ["Device"])
        #expect(s.sections[0].rows.map(\.label) == ["Manufacturer", "Serial Number"])
    }

    @Test func aDeviceWithNothingToReportIsEmpty() {
        let s = GnimuDeviceSummary(identity: DeviceIdentity(), schema: nil, info: nil)
        #expect(s.isEmpty)
    }

    @Test func emptyValuesAreLeftOut() {
        let s = GnimuDeviceSummary(identity: DeviceIdentity(manufacturer: "", model: "M"), schema: nil, info: nil)
        #expect(s.sections.first?.rows.map(\.label) == ["Model"])
    }

    @Test func aGnssAllInOneNamesItsBlocks() throws {
        let schema = GnimuSchema.parse(Data(#"{"v":1,"r":20,"fill":{"gnss":8191,"imu":127,"power":7}}"#.utf8))
        let s = GnimuDeviceSummary(identity: DeviceIdentity(), schema: schema, info: nil)
        let output = try #require(section("Output", in: s))
        #expect(output.rows.last?.value == "GNSS, IMU, Power")
    }

    @Test func aBlockWithAnEmptyFillMaskIsNotListed() throws {
        let schema = GnimuSchema.parse(Data(#"{"v":1,"fill":{"gnss":0,"power":1}}"#.utf8))
        let s = GnimuDeviceSummary(identity: DeviceIdentity(), schema: schema, info: nil)
        let output = try #require(section("Output", in: s))
        #expect(output.rows.map(\.value) == ["Power"])
    }

    @Test func settingNamesBecomeLabels() {
        #expect(GnimuDeviceSummary.humanized("frame_rate") == "Frame rate")
        #expect(GnimuDeviceSummary.humanized("name") == "Name")
        #expect(GnimuDeviceSummary.humanized("") == "")
    }
}

@MainActor
struct DeviceTabOfferTests {
    @Test func aConnectedGnimuProtocolDeviceGetsTheDeviceTab() {
        let ble = BLEManager()
        ble.presentAs(.gnimu)
        #expect(!ble.hasDevicePanel)            // not connected yet
        ble.isConnected = true
        #expect(ble.hasDevicePanel)
        #expect(MonitorPanel.stripTabs(profile: DeviceProfile(), hasDevice: ble.hasDevicePanel).contains(.device))
    }

    @Test func aRaceBoxDeviceWithoutCommandsDoesNot() {
        let ble = BLEManager()
        ble.isConnected = true
        #expect(!ble.hasDevicePanel)
        ble.supportsDeviceControl = true
        #expect(ble.hasDevicePanel)
    }
}
