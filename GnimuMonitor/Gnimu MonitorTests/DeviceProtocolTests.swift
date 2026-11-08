//
//  DeviceProtocolTests.swift
//  Gnimu MonitorTests
//
//  How a scanned device is labelled, and how the services a connected device
//  exposes settle it. The advertised service is the identity; the name is only a
//  hint, because names can be overridden.
//

import CoreBluetooth
import Testing
@testable import Gnimu_Monitor

private let gnimuService = DeviceProtocol.gnimu.serviceUUID
private let nordicUART = DeviceProtocol.raceBox.serviceUUID
private let deviceInformation = CBUUID(string: "180A")

struct IdentificationTests {

    @Test func anAdvertisedServiceIdentifiesTheDeviceAndIsConfirmed() {
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: [gnimuService])
                == .init(deviceProtocol: .gnimu, isConfirmed: true))
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: [nordicUART])
                == .init(deviceProtocol: .raceBox, isConfirmed: true))
    }

    @Test func theServiceOutranksTheName() {
        // A Gnimu-RB name on a device advertising the Gnimu service, and the reverse.
        #expect(DeviceProtocol.identify(name: "Gnimu-RB 1120954722", advertisedServices: [gnimuService])
                == .init(deviceProtocol: .gnimu, isConfirmed: true))
        #expect(DeviceProtocol.identify(name: "Gnimu 0000000000", advertisedServices: [nordicUART])
                == .init(deviceProtocol: .raceBox, isConfirmed: true))
    }

    @Test func otherAdvertisedServicesDontGetInTheWay() {
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: [deviceInformation, gnimuService])
                == .init(deviceProtocol: .gnimu, isConfirmed: true))
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: [deviceInformation]) == nil)
    }

    @Test(arguments: [
        ("RaceBox Mini 1234567890", DeviceProtocol.raceBox),
        ("RaceBox Micro 1234567890", .raceBox),
        ("Gnimu-RB 1120954722", .raceBox),          // a Gnimu in RaceBox mode
        ("Gnimu-CAN 0301821570", .gnimu),
        ("Gnimu 0000000000", .gnimu),               // a Gnimu in its own protocol
    ])
    func aNameAloneGivesAProvisionalLabel(name: String, expected: DeviceProtocol) {
        #expect(DeviceProtocol.identify(name: name, advertisedServices: [])
                == .init(deviceProtocol: expected, isConfirmed: false))
    }

    @Test func theMoreSpecificGnimuPrefixWins() {
        // "Gnimu-RB" and "Gnimu-CAN" both start with "Gnimu".
        #expect(DeviceProtocol.identify(name: "Gnimu-RB 1", advertisedServices: [])?.deviceProtocol == .raceBox)
        #expect(DeviceProtocol.identify(name: "Gnimu-CAN 1", advertisedServices: [])?.deviceProtocol == .gnimu)
    }

    @Test(arguments: ["Polar H10", "", "gnimu 0000000000", "My Gnimu"])
    func otherNamesAreNotListed(name: String) {
        #expect(DeviceProtocol.identify(name: name, advertisedServices: []) == nil)
    }

    @Test func aDeviceWithNeitherNameNorServiceIsNotListed() {
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: []) == nil)
    }

    @Test func aDeviceAdvertisingBothServicesIsReadAsRaceBox() {
        // Not a case that exists today. Pinned so a change to it is deliberate.
        #expect(DeviceProtocol.identify(name: nil, advertisedServices: [gnimuService, nordicUART])?.deviceProtocol
                == .raceBox)
    }
}

struct LabelRefinementTests {
    private typealias Identification = DeviceProtocol.Identification

    @Test func aGuessFromTheNameGivesWayToAnAdvertisedService() {
        let guess = Identification(deviceProtocol: .raceBox, isConfirmed: false)
        #expect(guess.refined(byAdvertisedServices: [gnimuService])
                == Identification(deviceProtocol: .gnimu, isConfirmed: true))
        #expect(guess.refined(byAdvertisedServices: [nordicUART])
                == Identification(deviceProtocol: .raceBox, isConfirmed: true))
    }

    @Test func aGuessStaysAGuessWithoutAKnownService() {
        let guess = Identification(deviceProtocol: .gnimu, isConfirmed: false)
        #expect(guess.refined(byAdvertisedServices: []) == guess)
        #expect(guess.refined(byAdvertisedServices: [deviceInformation]) == guess)
    }

    @Test func aConfirmedLabelIsNeverRevisited() {
        let confirmed = Identification(deviceProtocol: .gnimu, isConfirmed: true)
        #expect(confirmed.refined(byAdvertisedServices: [nordicUART]) == confirmed)
        #expect(confirmed.refined(byAdvertisedServices: []) == confirmed)
    }
}

struct ResolutionTests {

    @Test func theServicesAConnectedDeviceExposesSettleItsProtocol() {
        #expect(DeviceProtocol.resolve(discoveredServices: [gnimuService, deviceInformation]) == .gnimu)
        #expect(DeviceProtocol.resolve(discoveredServices: [nordicUART, deviceInformation]) == .raceBox)
    }

    @Test func aDeviceWithNoKnownServiceHasNoProtocol() {
        #expect(DeviceProtocol.resolve(discoveredServices: []) == nil)
        #expect(DeviceProtocol.resolve(discoveredServices: [deviceInformation]) == nil)
    }

    @Test func connectingLooksForEveryProtocolsService() {
        #expect(Set(DeviceProtocol.allServiceUUIDs) == [gnimuService, nordicUART])
    }
}

struct ProtocolConstantsTests {

    @Test func theGnimuUUIDsMatchTheSpec() {
        #expect(DeviceProtocol.gnimu.serviceUUID == CBUUID(string: "9074beb4-2f1a-4b5f-9818-fe2d2277ef05"))
        #expect(DeviceProtocol.gnimuFrameCharacteristicUUID == CBUUID(string: "0752d3c3-ceaf-462f-a944-bcc06c57284b"))
        #expect(DeviceProtocol.gnimuSchemaCharacteristicUUID == CBUUID(string: "1c9b3945-10eb-4fd0-a5a4-b9d80842380d"))
        #expect(DeviceProtocol.gnimuDeviceInfoCharacteristicUUID == CBUUID(string: "6d0adfef-8218-488a-a5f9-1ba05f422c22"))
        #expect(DeviceProtocol.gnimu.notifyCharacteristicUUIDs == [DeviceProtocol.gnimuFrameCharacteristicUUID])
    }

    @Test func framesAreTheirProtocolsSize() {
        #expect(DeviceProtocol.raceBox.frameBytes == 88)
        #expect(DeviceProtocol.gnimu.frameBytes == 140)
    }

    @Test func capturesRecordTheProtocolByRawValue() {
        #expect(DeviceProtocol.raceBox.rawValue == "racebox")
        #expect(DeviceProtocol.gnimu.rawValue == "gnimu")
        #expect(DeviceProtocol(rawValue: "gnimu") == .gnimu)
    }
}
