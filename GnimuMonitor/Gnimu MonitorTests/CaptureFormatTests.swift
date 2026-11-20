//
//  CaptureFormatTests.swift
//  Gnimu MonitorTests
//
//  The capture file format (schema 2) as a contract: a small sample written out
//  by hand, as docs/capture-format.md shows it, that the reader must keep
//  understanding; what the reader refuses; and what the recorder writes.
//

import CoreBluetooth
import Foundation
import Testing
@testable import Gnimu_Monitor

/// A hand-written Gnimu-CAN capture: header, three frames, summary. The same
/// text appears in docs/capture-format.md. If this stops parsing, the format
/// has changed, which means a new schema version.
private enum Sample {
    static let frameBytes: [UInt8] = {
        var b = GnimuFrameBuilder()
        b.deviceTimeMs = 1_000
        b.sequence = 0
        b.capabilities = 12
        b.set(.engineSpeed, 900)
        b.set(.supplyVoltage, 12.4)
        return b.build()
    }()

    static func text(frames: Int = 3, header: String? = nil) -> String {
        var lines = [header ?? """
        {"app":{"build":"1","name":"Gnimu Monitor","version":"1.2"},"capture":{"encoding":"base64","nominalHz":20,"protocol":"gnimu","streams":[{"characteristic":"0752D3C3-CEAF-462F-A944-BCC06C57284B","frameBytes":140,"name":"frame"}],"timeBase":"seconds since startedAt, monotonic","unit":"frame"},"device":{"identity":{"firmware":"0.1.0","manufacturer":"Gnimu Labs","model":"Gnimu-CAN","serial":"1958745094"},"info":{"build":{"rev":"9c1e4a7","target":"esp32c6","utc":"2026-11-10T18:22:05Z"},"cfg":{"can_bitrate":500000},"v":1},"name":"Gnimu-CAN 1958745094","peripheralId":"0A1B2C3D","schema":{"d":"Gnimu-CAN","fill":{"power":1,"vehicle":3},"r":20,"v":1}},"format":"gnimu-capture-jsonl","host":{"lowPowerMode":false,"model":"Mac14,2","platform":"macOS","systemVersion":"26","thermalState":"nominal"},"schema":2,"sessionId":"11111111-2222-3333-4444-555555555555","startedAt":"2026-11-15T18:00:00.000Z","timeZone":"UTC","type":"header"}
        """]
        for i in 0..<frames {
            var b = GnimuFrameBuilder()
            b.deviceTimeMs = Int32(1_000 + i * 50)
            b.sequence = UInt8(i)
            b.capabilities = 12
            b.set(.engineSpeed, 900)
            b.set(.supplyVoltage, 12.4)
            lines.append(CaptureLines.frame(t: Double(i) * 0.05, data: Data(b.build())))
        }
        lines.append("""
        {"durationSeconds":0.15,"endedAt":"2026-11-15T18:00:00.150Z","meanHz":20,"packets":3,"rawBytes":420,"rejected":0,"sessionId":"11111111-2222-3333-4444-555555555555","streams":{"frame":{"packets":3,"rawBytes":420}},"type":"summary"}
        """)
        return lines.joined(separator: "\n") + "\n"
    }
}

private func write(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("format-test-\(UUID().uuidString).jsonl")
    try Data(text.utf8).write(to: url)
    return url
}

struct CaptureFormatTests {

    @Test func theSampleCaptureIsReadInFull() throws {
        let url = try write(Sample.text())
        defer { try? FileManager.default.removeItem(at: url) }

        var header: CaptureHeader?
        var frames: [(Double, String, Int)] = []
        var trailer: CaptureTrailer?
        try CaptureReader.read(url: url,
                               onHeader: { header = $0 },
                               onFrame: { frames.append(($0, $1, $2.count)) },
                               onUndecodable: { Issue.record("a line was undecodable") },
                               onTrailer: { trailer = $0 })

        let h = try #require(header)
        #expect(h.schema == 2)
        #expect(h.unit == "frame")
        #expect(h.protocolName == "gnimu")
        #expect(h.streams == [.init(name: "frame", characteristic: "0752D3C3-CEAF-462F-A944-BCC06C57284B",
                                    frameBytes: 140)])
        #expect(h.deviceName == "Gnimu-CAN 1958745094")
        #expect(h.identity.serial == "1958745094")
        #expect(h.identity.model == "Gnimu-CAN")
        #expect(GnimuSchema.parse(try #require(h.deviceSchemaJSON))?.product == "Gnimu-CAN")
        #expect(GnimuDeviceInfo.parse(try #require(h.deviceInfoJSON))?.build.revision == "9c1e4a7")
        #expect(frames.map(\.1) == ["frame", "frame", "frame"])
        #expect(frames.allSatisfy { $0.2 == 140 })
        #expect(trailer?.packets == 3)
    }

    @Test func theSampleCaptureAnalyses() throws {
        let url = try write(Sample.text(frames: 40))
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CaptureAnalyzer.analyze(url: url)
        #expect(a.summary.packetsReceived == 40)
        #expect(a.header.identity.serial == "1958745094")
    }

    @Test(arguments: [0, 1])
    func anOlderCaptureIsRefusedWithAClearMessage(version: Int) throws {
        let old = #"{"type":"header","schema":\#(version),"capture":{"protocol":"racebox"}}"#
        let url = try write(old + "\n" + CaptureLines.frame(t: 0, data: Data(count: 88)) + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try CaptureAnalyzer.analyze(url: url)
            Issue.record("expected the capture to be refused")
        } catch let error as CaptureReadError {
            guard case .unsupportedSchema(let found) = error else {
                Issue.record("expected unsupportedSchema, got \(error)"); return
            }
            #expect(found == version)
            #expect(error.errorDescription?.contains("older version") == true)
        }
    }

    @Test func aNewerSchemaIsRefused() throws {
        let url = try write(#"{"type":"header","schema":3,"capture":{"protocol":"gnimu","unit":"frame"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: CaptureReadError.self) { try CaptureAnalyzer.analyze(url: url) }
    }

    @Test func aLineUnitTheReaderDoesNotKnowIsRefused() throws {
        let header = CaptureLines.headerText(for: .gnimu)
            .replacingOccurrences(of: "\"unit\":\"frame\"", with: "\"unit\":\"notification\"")
        let url = try write(Sample.text(header: header))
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try CaptureAnalyzer.analyze(url: url)
            Issue.record("expected the capture to be refused")
        } catch let error as CaptureReadError {
            guard case .unsupportedUnit(let unit) = error else {
                Issue.record("expected unsupportedUnit, got \(error)"); return
            }
            #expect(unit == "notification")
        }
    }

    @Test func aLineNamingAStreamTheHeaderDoesNotListIsUndecodable() throws {
        var text = Sample.text(frames: 5)
        text += CaptureLines.frame(t: 1, data: Data(Sample.frameBytes), stream: "imu_stream") + "\n"
        let url = try write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        var undecodable = 0
        var frames = 0
        try CaptureReader.read(url: url, onHeader: { _ in }, onFrame: { _, _, _ in frames += 1 },
                               onUndecodable: { undecodable += 1 }, onTrailer: { _ in })
        #expect(frames == 5)
        #expect(undecodable == 1)
    }

    @Test func aFrameLineWithNoStreamIsUndecodable() throws {
        var text = Sample.text(frames: 2)
        text += "{\"t\":1.0,\"d\":\"\(Data(Sample.frameBytes).base64EncodedString())\"}\n"
        let url = try write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        var undecodable = 0
        try CaptureReader.read(url: url, onHeader: { _ in }, onFrame: { _, _, _ in },
                               onUndecodable: { undecodable += 1 }, onTrailer: { _ in })
        #expect(undecodable == 1)
    }

    @Test func aStreamTheAnalyzerDoesNotReadIsLeftOutNotCounted() throws {
        let header = CaptureLines.headerText(for: .gnimu)
            .replacingOccurrences(of: "\"streams\":[", with: "\"streams\":[{\"name\":\"imu_stream\",\"frameBytes\":20},")
        var text = Sample.text(frames: 10, header: header)
        text += CaptureLines.frame(t: 2, data: Data(count: 20), stream: "imu_stream") + "\n"
        let url = try write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CaptureAnalyzer.analyze(url: url)
        #expect(a.summary.packetsReceived == 10)
        #expect(a.summary.undecodableLines == 0)
    }
}

/// Every test that records a real capture lives here, run one at a time: a
/// capture's scratch file is named by the second it started in, so two
/// recordings begun together would write to the same file. The app has one
/// recorder, so it can't happen there.
@Suite(.serialized)
@MainActor
struct RecorderFileTests {
    @Test func aRecordingIsStoppedAndFiledBeforeTheQuitBlockRuns() async throws {
        let recorder = SessionRecorder()
        recorder.start(deviceName: "Quit test", peripheralID: nil, nominalHz: 20, deviceProtocol: .gnimu)
        try #require(recorder.isRecording)
        recorder.record(frame: Data(repeating: 1, count: 140), stream: "frame")

        await withCheckedContinuation { continuation in
            recorder.whenIdle { continuation.resume() }
        }

        #expect(!recorder.isRecording)
        #expect(!recorder.isFinishing)
        let capture = try #require(recorder.lastCapture)
        #expect(FileManager.default.fileExists(atPath: capture.url.path))
        #expect(capture.packets == 1)
        try? FileManager.default.removeItem(at: capture.url)
    }

    private func record(deviceInfo: CapturedDeviceInfo, protocol deviceProtocol: DeviceProtocol,
                        frame: Data, rejected: Int = 0) async throws -> (header: [String: Any], lines: [[String: Any]], summary: [String: Any]) {
        let recorder = SessionRecorder()
        var rejectedNow = 0
        recorder.rejectedNotifications = { rejectedNow }
        recorder.start(deviceName: "Format test", peripheralID: "PERIPHERAL", nominalHz: 20,
                       deviceProtocol: deviceProtocol, deviceInfo: deviceInfo)
        try #require(recorder.isRecording)
        recorder.record(frame: frame, stream: "frame")
        recorder.record(frame: frame, stream: "frame")
        rejectedNow = rejected
        await withCheckedContinuation { c in recorder.whenIdle { c.resume() } }
        let capture = try #require(recorder.lastCapture)
        defer { try? FileManager.default.removeItem(at: capture.url) }

        let text = try String(contentsOf: capture.url, encoding: .utf8)
        let objects = try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        return (objects[0], Array(objects.dropFirst().dropLast()), objects.last ?? [:])
    }

    @Test func aRecordingWritesSchemaTwo() async throws {
        let schema = Data(#"{"v":1,"d":"Gnimu-CAN","r":20,"fill":{"vehicle":3}}"#.utf8)
        let info = Data(#"{"v":1,"build":{"rev":"abc"}}"#.utf8)
        let id = DeviceIdentity(manufacturer: "Gnimu Labs", model: "Gnimu-CAN", serial: "SER123",
                                firmware: "0.1.0", hardware: "HW")
        let r = try await record(deviceInfo: CapturedDeviceInfo(identity: id, schemaJSON: schema, infoJSON: info),
                                 protocol: .gnimu, frame: Data(Sample.frameBytes), rejected: 3)

        #expect(r.header["schema"] as? Int == 2)
        let capture = try #require(r.header["capture"] as? [String: Any])
        #expect(capture["unit"] as? String == "frame")
        let streams = try #require(capture["streams"] as? [[String: Any]])
        #expect(streams.first?["name"] as? String == "frame")
        #expect(streams.first?["characteristic"] as? String == DeviceProtocol.gnimuFrameCharacteristicUUID.uuidString)
        #expect(streams.first?["frameBytes"] as? Int == 140)

        let device = try #require(r.header["device"] as? [String: Any])
        let identity = try #require(device["identity"] as? [String: String])
        #expect(identity["serial"] == "SER123")
        #expect(identity["model"] == "Gnimu-CAN")
        #expect((device["schema"] as? [String: Any])?["d"] as? String == "Gnimu-CAN")
        #expect(((device["info"] as? [String: Any])?["build"] as? [String: Any])?["rev"] as? String == "abc")

        #expect(r.lines.count == 2)
        #expect(r.lines.allSatisfy { $0["c"] as? String == "frame" })

        #expect(r.summary["type"] as? String == "summary")
        #expect(r.summary["packets"] as? Int == 2)
        #expect(r.summary["rejected"] as? Int == 3)
        let perStream = try #require(r.summary["streams"] as? [String: [String: Int]])
        #expect(perStream["frame"]?["packets"] == 2)
        #expect(perStream["frame"]?["rawBytes"] == 280)
    }

    @Test func aDeviceThatHasReportedNothingYetLeavesItsFieldsOut() async throws {
        let r = try await record(deviceInfo: .none, protocol: .raceBox, frame: Data(count: 88))
        let device = try #require(r.header["device"] as? [String: Any])
        #expect(device["identity"] == nil)
        #expect(device["schema"] == nil)
        #expect(device["info"] == nil)
        #expect(device["name"] as? String == "Format test")
    }

    @Test func aRecordedCaptureReadsBackThroughTheReader() async throws {
        let recorder = SessionRecorder()
        recorder.start(deviceName: "Round trip", peripheralID: nil, nominalHz: 20, deviceProtocol: .gnimu,
                       deviceInfo: CapturedDeviceInfo(identity: DeviceIdentity(serial: "RT1")))
        for _ in 0..<5 { recorder.record(frame: Data(Sample.frameBytes), stream: "frame") }
        await withCheckedContinuation { c in recorder.whenIdle { c.resume() } }
        let capture = try #require(recorder.lastCapture)
        defer { try? FileManager.default.removeItem(at: capture.url) }

        var header: CaptureHeader?
        var count = 0
        try CaptureReader.read(url: capture.url, onHeader: { header = $0 },
                               onFrame: { _, stream, bytes in
                                   if stream == "frame", bytes.count == 140 { count += 1 }
                               },
                               onUndecodable: { Issue.record("undecodable line") }, onTrailer: { _ in })
        #expect(count == 5)
        #expect(header?.identity.serial == "RT1")
    }
}
