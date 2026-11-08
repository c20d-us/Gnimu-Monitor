//
//  ReplayCaptureTests.swift
//  Gnimu MonitorTests
//
//  Covers the debug replay's file reader, and that replayed frames drive the
//  same decoder and state path a live device does. Also holds the one tool for
//  producing the synthetic captures as files, to replay in the running app.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private func write(_ capture: SyntheticCapture) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("replay-test-\(UUID().uuidString).jsonl")
    try capture.data().write(to: url)
    return url
}

struct ReplayCaptureTests {

    @Test func readsTheHeaderAndEveryFrameInOrder() throws {
        let url = try write(SyntheticCapture())
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try ReplayCapture.load(url: url)

        #expect(capture.deviceProtocol == .raceBox)
        #expect(capture.deviceName == SyntheticCapture.deviceName)
        #expect(capture.frames.count == 1000)
        #expect(capture.frames.allSatisfy { $0.data.count == 88 })
        #expect(capture.frames.first?.t == 0)
        #expect(abs((capture.frames.last?.t ?? 0) - 39.96) < 1e-9)
        #expect(capture.frames.map(\.t) == capture.frames.map(\.t).sorted())
    }

    @Test func replayedFramesDriveTheDecoderAndStateLikeALiveDevice() throws {
        let url = try write(SyntheticCapture())
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try ReplayCapture.load(url: url)

        var session = capture.deviceProtocol.makeSession()
        let characteristic = capture.deviceProtocol.notifyCharacteristicUUIDs[0]
        var state = TelemetryState()
        var epochs: [UInt32] = []
        for frame in capture.frames {
            for decoded in session.receive(frame.data, from: characteristic) {
                state.apply(decoded.update, at: Date(timeIntervalSinceReferenceDate: frame.t))
                epochs.append(decoded.gnssEpochMs ?? 0)
            }
        }
        #expect(epochs.count == 1000)
        #expect(epochs.first == UInt32(SyntheticCapture.itow0))
        #expect(state.revision == 1000)

        // The drive ends at rest, 240 m north-and-east of where it began.
        let gnss = try #require(state.gnss)
        #expect(gnss.hasFix)
        #expect(gnss.movingSpeedKmh == 0)
        #expect((gnss.latitude ?? 0) > 37.0)
        #expect(state.power?.batteryPercent == 77)
    }

    @Test func aCorruptFrameLoadsButTheDecoderDropsIt() throws {
        let url = try write(SyntheticCapture.faulty)
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try ReplayCapture.load(url: url)

        // 1000 packets, the duplicate, and the corrupt one. The garbage line is skipped.
        #expect(capture.frames.count == 1002)
        var session = capture.deviceProtocol.makeSession()
        let characteristic = capture.deviceProtocol.notifyCharacteristicUUIDs[0]
        let decoded = capture.frames.flatMap { session.receive($0.data, from: characteristic) }
        #expect(decoded.count == 1001)
    }

    @Test func aFileWithNoFramesIsAnError() throws {
        var empty = SyntheticCapture()
        empty.seconds = 0
        let url = try write(empty)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ReplayCapture.LoadError.self) { try ReplayCapture.load(url: url) }
    }

    @Test func aMissingFileIsAnError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-capture-\(UUID().uuidString).jsonl")
        #expect(throws: ReplayCapture.LoadError.self) { try ReplayCapture.load(url: url) }
    }

    @Test func anUnknownProtocolNameFallsBackToRaceBox() throws {
        var capture = SyntheticCapture()
        capture.seconds = 1
        let text = String(decoding: capture.data(), as: UTF8.self)
            .replacingOccurrences(of: "\"protocol\":\"racebox\"", with: "\"protocol\":\"somethingelse\"")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-test-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ReplayCapture.load(url: url).deviceProtocol == .raceBox)
    }
}

struct GnimuReplayTests {

    private func load(_ capture: SyntheticGnimuCapture) throws -> ReplayCapture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-test-\(UUID().uuidString).jsonl")
        try capture.data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ReplayCapture.load(url: url)
    }

    @Test func aGnimuCaptureReplaysAsTheGnimuProtocol() throws {
        let capture = try load(SyntheticGnimuCapture())
        #expect(capture.deviceProtocol == .gnimu)
        #expect(capture.deviceName == SyntheticGnimuCapture.deviceName)
        #expect(capture.frames.count == 600)
        #expect(capture.frames.allSatisfy { $0.data.count == 140 })
    }

    @Test func theDeviceWaitsThenPollsTheCar() throws {
        let capture = try load(SyntheticGnimuCapture())
        var session = capture.deviceProtocol.makeSession()
        let characteristic = capture.deviceProtocol.notifyCharacteristicUUIDs[0]
        var states: [(t: Double, state: TelemetryState)] = []
        var state = TelemetryState()
        for frame in capture.frames {
            for decoded in session.receive(frame.data, from: characteristic) {
                state.apply(decoded.update, at: Date(timeIntervalSinceReferenceDate: frame.t))
                states.append((frame.t, state))
            }
        }
        #expect(states.count == 600)

        // Waiting: the device is up, the car isn't answering, only the supply is live.
        let waiting = try #require(states.first { $0.t >= 1 }).state
        #expect(waiting.header?.stateRaw == 3)
        #expect(waiting.vehicle == VehicleBlock())
        #expect(waiting.power?.supplyVolts == 12.4)

        // Polling at full throttle.
        let running = try #require(states.first { $0.t >= 4 + 11 }).state
        #expect(running.header?.stateRaw == 2)
        #expect((running.vehicle?.engineSpeedRpm ?? 0) > 3000)
        #expect(running.vehicle?.throttlePercent == 100)
        #expect(running.vehicle?.coolantTempC == 88.5)
        #expect(running.power?.supplyVolts == 13.8)

        // The sequence counts up by one a frame.
        let sequences = states.compactMap { $0.state.header?.sequence }
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { UInt8(truncatingIfNeeded: Int($0) + 1) == $1 })
    }

    @Test func aGnimuCaptureIsNotAnalysedAsRaceBox() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-test-\(UUID().uuidString).jsonl")
        try SyntheticGnimuCapture().data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: CaptureReadError.self) { try CaptureAnalyzer.analyze(url: url) }
    }
}

/// Writes the synthetic captures to disk so they can be replayed in the app.
///
///     TEST_RUNNER_GNIMU_WRITE_SYNTHETIC_CAPTURES=1 xcodebuild test ...
///
/// puts them in the app's Documents folder, which is the folder the app's
/// `-replay` can read even in the Mac sandbox (on the Mac that is
/// ~/Library/Containers/us.c20d.GnimuMonitor/Data/Documents/Synthetic). A value
/// that is a path puts them there instead; that only works where the test host
/// may write outside its container, as on the iOS Simulator. Launch the app with
/// `-replay <folder>/clean-drive.jsonl`. Does nothing, and is reported as skipped,
/// when the variable isn't set.
struct SyntheticCaptureFiles {
    private static var setting: String? {
        ProcessInfo.processInfo.environment["GNIMU_WRITE_SYNTHETIC_CAPTURES"]
    }

    @Test(.enabled(if: SyntheticCaptureFiles.setting != nil))
    func writeTheSyntheticCaptures() throws {
        let setting = try #require(Self.setting)
        let folder: URL
        if setting.hasPrefix("/") {
            folder = URL(fileURLWithPath: setting, isDirectory: true)
        } else {
            let documents = try #require(
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            folder = documents.appendingPathComponent("Synthetic", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SyntheticCapture().data().write(to: folder.appendingPathComponent("clean-drive.jsonl"))
        try SyntheticCapture.faulty.data().write(to: folder.appendingPathComponent("faulty-drive.jsonl"))
        try SyntheticGnimuCapture().data().write(to: folder.appendingPathComponent("gnimu-can-drive.jsonl"))
        print("Synthetic captures written to \(folder.path)")
    }
}
