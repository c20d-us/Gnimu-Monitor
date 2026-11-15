//
//  GnimuCaptureAnalyzerTests.swift
//  Gnimu MonitorTests
//
//  The capture analyzer on Gnimu-protocol captures: a CAN-only device, and an
//  all-in-one device with GNSS, IMU and power whose frames repeat each GNSS
//  solution (frames at 20 Hz, GNSS at 10 Hz).
//

import Foundation
import Testing
@testable import Gnimu_Monitor

/// An all-in-one Gnimu capture built from known values.
private struct GnssGnimuCapture {
    var seconds = 20.0
    var frameHz = 20.0
    var gnssHz = 10.0
    /// Frame indices the device sent but the app never received.
    var dropped: Set<Int> = []
    /// Frame indices after which the device restarts its clock and counter.
    var restartAt: Int?
    /// Frames whose device time is stamped this many ms late, as when the
    /// device sends them late: every tenth frame.
    var sendSlipMs = 0
    /// Position wobble, in metres, alternating either side of the true path on
    /// each solution, as receiver noise does.
    var positionWobbleM = 0.0
    /// The position never moves although the reported speed says it does.
    var freezePosition = false
    /// Frames at the start with no resolved UTC, as on a cold start.
    var coldStartFrames = 0
    var includeTrailer = true

    /// 0-4 s parked, then 10 m/s east.
    static func speedKmh(at t: Double) -> Double { t < 4 ? 0 : 36 }

    func data() -> Data {
        var lines = [header()]
        let count = Int(seconds * frameHz)
        var bootOffsetMs = 5_000
        var sequenceBase = 0
        var east = 0.0                      // metres east of the origin
        var lastSolutionT = -1.0
        var solutionTimeMs = 0
        var solutionCount = -1
        var lastT = 0.0
        for i in 0..<count {
            let t = Double(i) / frameHz
            if let restartAt, i == restartAt {
                bootOffsetMs = -Int(t * 1000) + 300    // clock starts again near zero
                sequenceBase = -i
            }
            // A new GNSS solution lands every 1/gnssHz s; frames in between
            // repeat it.
            if t - lastSolutionT >= 1 / gnssHz - 1e-9 {
                if lastSolutionT >= 0 { east += Self.speedKmh(at: t) / 3.6 / gnssHz }
                lastSolutionT = t
                solutionCount += 1
                solutionTimeMs = Int(t * 1000) + bootOffsetMs - 12   // arrived 12 ms before this frame
            }
            if dropped.contains(i) { continue }

            var b = GnimuFrameBuilder()
            let deviceTime = Int(t * 1000) + bootOffsetMs + (i % 10 == 9 ? sendSlipMs : 0)
            b.deviceTimeMs = Int32(deviceTime)
            b.sequence = UInt8(truncatingIfNeeded: i + sequenceBase)
            b.capabilities = 1 | 2 | 8
            b.set(.latitude, 51.5)
            let wobble = (solutionCount % 2 == 0 ? 1.0 : -1.0) * positionWobbleM
            let along = freezePosition ? 0 : east
            b.set(.longitude, -0.1 + (along + wobble) / 111_320 / cos(51.5 * .pi / 180))
            b.set(.groundSpeed, Self.speedKmh(at: t))
            b.set(.speedAccuracy, 0.5)
            b.set(.satellites, 14)
            b.set(.pdop, 1.1)
            b.set(.horizontalAccuracy, 0.8)
            b.set(.verticalAccuracy, 1.2)
            b.set(.fixType, 3)
            // The receiver steps its timestamp by exactly one period per solution.
            if i >= coldStartFrames {
                b.set(.utcTimestamp, 1_780_000_000_000 + Double(solutionCount) * 1000 / gnssHz)
            }
            b.set(.gnssEpochAge, Double(deviceTime - solutionTimeMs))
            b.set(.accelX, 0.01); b.set(.accelY, -0.02); b.set(.accelZ, 1.0)
            b.set(.rollRate, 0.1); b.set(.pitchRate, -0.1); b.set(.yawRate, 0.2)
            b.set(.batteryCharge, 87)
            b.set(.charging, 0)
            lines.append(CaptureLines.frame(t: t, data: Data(b.build())))
            lastT = t
        }
        if includeTrailer {
            lines.append("{\"type\":\"summary\",\"packets\":\(count - dropped.count),\"durationSeconds\":\(lastT)}")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func header() -> String {
        CaptureLines.headerText(for: .gnimu, nominalHz: frameHz, deviceName: "Gnimu 0000000002")
    }
}

private func analyze(_ data: Data) throws -> CaptureAnalysis {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gnimu-analyzer-test-\(UUID().uuidString).jsonl")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try CaptureAnalyzer.analyze(url: url)
}

private func check(_ a: CaptureAnalysis, _ id: String) -> ConsistencyCheck? {
    a.checks.first { $0.id == id }
}

struct GnimuCaptureAnalyzerTests {

    @Test func aCanOnlyCaptureAnalysesCleanly() throws {
        let a = try analyze(SyntheticGnimuCapture().data())
        #expect(a.summary.packetsReceived == 600)
        #expect(a.summary.undecodableLines == 0)
        #expect(a.summary.missedFixes == 0)
        #expect(a.summary.nominalHz == 20)
        #expect(a.summary.interruptions == 0)
        #expect(!a.hasGnss)
        #expect(a.summary.framesWithoutEpoch == 0)
        #expect(a.isGnimu)
        #expect(a.checks.allSatisfy { $0.status != .fail })
        #expect(check(a, "frame-sequence")?.status == .pass)
        #expect(check(a, "clock-monotonic")?.status == .pass)
        #expect(check(a, "clock-fields")?.status == .notApplicable)
        #expect(check(a, "speed-vs-position")?.status == .notApplicable)
    }

    @Test func anAllInOneCaptureAnalysesCleanly() throws {
        let a = try analyze(GnssGnimuCapture().data())
        #expect(a.summary.packetsReceived == 400)
        // Frames come at 20 Hz but the receiver solves at 10 Hz, and cadence
        // follows the receiver.
        #expect(a.summary.nominalHz == 10)
        #expect(a.summary.missedFixes == 0)
        #expect(a.hasGnss)
        #expect(a.gnss.numSV.mean == 14)
        #expect(a.gnss.fixTypeCounts[3] == 400)
        #expect(a.gnss.batteryStart == 87)
        #expect(!a.track.isEmpty)
        for c in a.checks where c.status == .fail || c.status == .warn {
            Issue.record("\(c.id) \(c.status): \(c.example ?? "")")
        }
        #expect(check(a, "speed-vs-position")?.status == .pass)
        #expect(check(a, "clock-fields")?.status == .pass)
        #expect(check(a, "imu-at-rest")?.status == .pass)
    }

    @Test func repeatedSolutionsAreNotMistakenForStandingStill() throws {
        // Frames at 20 Hz repeat each 10 Hz solution, so every other frame has
        // the same position; judging that against the reported speed would call
        // the moving car stationary.
        let a = try analyze(GnssGnimuCapture().data())
        let c = try #require(check(a, "speed-vs-position"))
        #expect(c.samples >= 15)                 // about one comparison per second of the 20 s drive
        #expect(c.failures == 0)
        #expect(abs(a.gnss.distanceMetres - 160) < 15)     // 16 s at 10 m/s
    }

    @Test func ordinaryPositionNoiseAtTwentyHertzIsNotASpeedMismatch() throws {
        // A quarter metre of wobble between fixes 50 ms apart reads as 5 m/s
        // pair by pair; over a second it is nothing.
        var capture = GnssGnimuCapture()
        capture.gnssHz = 20
        capture.positionWobbleM = 0.25
        let a = try analyze(capture.data())
        let c = try #require(check(a, "speed-vs-position"))
        #expect(c.status == .pass)
        #expect(c.failures == 0)
        #expect(c.samples >= 15)                        // about one per second
    }

    @Test func aRealDisagreementBetweenSpeedAndPositionIsStillCaught() throws {
        // The device says it is doing 36 km/h from 4 s on, but the position
        // never moves.
        var capture = GnssGnimuCapture()
        capture.gnssHz = 20
        capture.freezePosition = true
        let a = try analyze(capture.data())
        let c = try #require(check(a, "speed-vs-position"))
        #expect(c.failures >= 10)
        #expect(c.status != .pass)
        #expect(c.example?.contains("over 1.0 s") == true)
    }

    @Test func droppedFramesAreFoundByCadenceAndByTheCounter() throws {
        var capture = GnssGnimuCapture()
        capture.gnssHz = 20          // a new solution in every frame
        capture.dropped = [100, 200, 201]
        let a = try analyze(capture.data())
        #expect(a.summary.packetsReceived == 397)
        #expect(a.summary.missedFixes == 3)
        let sequence = try #require(check(a, "frame-sequence"))
        #expect(sequence.failures == 3)
        #expect(sequence.status != .pass)
        #expect(sequence.example?.contains("lost") == true)
        #expect(a.summary.longestCleanRun < 10.5)
    }

    @Test func sendTimeJitterIsNotReportedAsAnIrregularFixRate() throws {
        // Device time slips 10 ms on every tenth frame; the receiver's epochs
        // stay exactly 50 ms apart, so the fix cadence is one clean spike.
        var capture = GnssGnimuCapture()
        capture.gnssHz = 20
        capture.sendSlipMs = 10
        let a = try analyze(capture.data())
        #expect(a.cadence.intervalHistogramMs.keys.sorted() == [50])
        #expect(a.summary.nominalHz == 20)
        #expect(a.summary.missedFixes == 0)
        #expect(a.summary.lateIntervals == 0)
        #expect(a.series.fixRateHz.buckets.allSatisfy { abs($0.min - 20) < 0.01 && abs($0.max - 20) < 0.01 })
    }

    @Test func aColdStartIsCountedNotMeasured() throws {
        // The first 40 frames have no resolved UTC and their device times
        // wobble; they must not show up as late or out-of-sequence intervals.
        var capture = GnssGnimuCapture()
        capture.gnssHz = 20
        capture.sendSlipMs = 10
        capture.coldStartFrames = 40
        let a = try analyze(capture.data())
        #expect(a.summary.framesWithoutEpoch == 40)
        #expect(a.summary.lateIntervals == 0)
        #expect(a.summary.anomalousIntervals == 0)
        #expect(a.cadence.intervalHistogramMs.keys.sorted() == [50])
        #expect(a.summary.nominalHz == 20)
        #expect(check(a, "frame-sequence")?.status == .pass)
        // The cold-start frames break nothing, so the run covers the capture.
        #expect(a.summary.longestCleanRun > 15)
        let html = String(decoding: try HTMLReportRenderer().render(a), as: UTF8.self)
        #expect(html.contains("before the receiver had resolved UTC"))
    }

    @Test func aDeviceWithNoUtcAtAllHasNoCadenceToMeasure() throws {
        var capture = GnssGnimuCapture()
        capture.coldStartFrames = 10_000
        let a = try analyze(capture.data())
        #expect(a.summary.framesWithoutEpoch == a.summary.packetsReceived)
        #expect(a.cadence.intervalHistogramMs.isEmpty)
        #expect(a.summary.nominalHz == nil)
    }

    @Test func aRestartIsFlaggedWithoutBreakingTheUtcCheck() throws {
        var capture = GnssGnimuCapture()
        capture.restartAt = 200
        let a = try analyze(capture.data())
        let clock = try #require(check(a, "clock-monotonic"))
        #expect(clock.status == .fail)
        #expect(clock.failures == 1)
        // The reference offset starts over, so one restart isn't a run of
        // mismatches.
        #expect(check(a, "clock-fields")?.failures == 0)
    }

    @Test func aCaptureWithoutATrailerWasInterrupted() throws {
        var capture = GnssGnimuCapture()
        capture.includeTrailer = false
        let a = try analyze(capture.data())
        #expect(a.summary.wasInterrupted)
        #expect(check(a, "capture-complete")?.status == .warn)
    }

    @Test func aRaceBoxCaptureStillSaysITOW() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnimu-analyzer-test-\(UUID().uuidString).jsonl")
        var capture = SyntheticCapture()
        capture.seconds = 4
        try capture.data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CaptureAnalyzer.analyze(url: url)
        #expect(!a.isGnimu)
        #expect(a.protocolLabel == "RaceBox protocol")
        let html = String(decoding: try HTMLReportRenderer().render(a), as: UTF8.self)
        #expect(html.contains("(RaceBox protocol)"))
        #expect(a.checks.contains { $0.id == "itow-monotonic" })
        #expect(!a.checks.contains { $0.id == "frame-sequence" })
    }
}

struct GnimuReportTests {
    private func canAnalysis() throws -> CaptureAnalysis {
        try analyze(SyntheticGnimuCapture().data())
    }

    @Test func theHTMLReportOfACanCaptureSpeaksOfFramesAndSkipsGnss() throws {
        let html = String(decoding: try HTMLReportRenderer().render(try canAnalysis()), as: UTF8.self)
        #expect(html.contains("Gnimu-CAN 0000000001 (Gnimu protocol)"))
        #expect(html.contains("Frame cadence"))
        #expect(html.contains("Frames received"))
        #expect(html.contains("Device time sequence"))
        #expect(!html.contains("GNSS quality"))
        #expect(!html.contains("iTOW"))
    }

    @Test func theMarkdownReportOfACanCaptureSkipsGnss() throws {
        let text = String(decoding: try MarkdownReportRenderer().render(try canAnalysis()), as: UTF8.self)
        #expect(text.contains("Frames received"))
        #expect(!text.contains("GNSS quality"))
    }

    @Test func theHTMLReportOfAGnssCaptureKeepsItsGnssSection() throws {
        let html = String(decoding: try HTMLReportRenderer().render(try analyze(GnssGnimuCapture().data())),
                          as: UTF8.self)
        #expect(html.contains("GNSS quality"))
        #expect(!html.contains("iTOW"))
    }
}

struct GnimuRateTraceTests {
    @Test func sendTimeJitterDoesNotSwingTheFrameRateTrace() throws {
        // Every tenth frame goes out 10 ms late and the next 10 ms early, the
        // device's stamp following the send. Intervals of 60 and 40 ms would
        // plot as 17 and 25 Hz; over a second the rate is 20.
        var lines = [CaptureLines.headerText(for: .gnimu)]
        for i in 0..<400 {
            var b = GnimuFrameBuilder()
            // Frame i is stamped at 50 ms × i, except frame 9 mod 10 is 10 ms late.
            b.deviceTimeMs = Int32(1000 + i * 50 + (i % 10 == 9 ? 10 : 0))
            b.sequence = UInt8(truncatingIfNeeded: i)
            b.capabilities = 8
            b.set(.supplyVoltage, 12.5)
            lines.append(CaptureLines.frame(t: Double(i) * 0.05, data: Data(b.build())))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnimu-rate-test-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CaptureAnalyzer.analyze(url: url)
        let buckets = a.series.fixRateHz.buckets
        #expect(!buckets.isEmpty)
        #expect(buckets.allSatisfy { $0.min > 18.5 && $0.max < 21.5 })
        // The spread is still visible where it belongs.
        #expect((a.cadence.intervalHistogramMs[60] ?? 0) > 0)
        #expect((a.cadence.intervalHistogramMs[40] ?? 0) > 0)
    }
}

struct CaptureProtocolListingTests {
    private func protocolOf(_ data: Data) throws -> DeviceProtocol? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listing-test-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return CaptureStore.deviceProtocol(ofCaptureAt: url)
    }

    @Test func theProtocolComesFromTheCaptureHeader() throws {
        #expect(try protocolOf(SyntheticGnimuCapture().data()) == .gnimu)
        #expect(try protocolOf(SyntheticCapture().data()) == .raceBox)
    }

    @Test func aHeaderWithoutAProtocolHasNone() throws {
        let data = Data("{\"type\":\"header\",\"schema\":2}\n".utf8)
        #expect(try protocolOf(data) == nil)
    }

    @Test func anUnreadableOrUnknownCaptureHasNoProtocol() throws {
        #expect(try protocolOf(Data("not json\n".utf8)) == nil)
        #expect(try protocolOf(Data()) == nil)
        let unknown = Data("{\"type\":\"header\",\"capture\":{\"protocol\":\"mystery\"}}\n".utf8)
        #expect(try protocolOf(unknown) == nil)
    }
}
