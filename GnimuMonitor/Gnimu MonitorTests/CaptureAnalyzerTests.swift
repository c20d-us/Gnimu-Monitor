//
//  CaptureAnalyzerTests.swift
//  Gnimu MonitorTests
//
//  Runs the real CaptureAnalyzer over synthetic captures whose contents are
//  known, and checks the result against what was put in. These pin current
//  behaviour: where an expectation here disagrees with what a reader of the
//  analyzer would assume, the comment says so.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

private func analyze(_ capture: SyntheticCapture) throws -> CaptureAnalysis {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("analyzer-test-\(UUID().uuidString).jsonl")
    try capture.data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try CaptureAnalyzer.analyze(url: url)
}

private func check(_ id: String, in analysis: CaptureAnalysis) -> ConsistencyCheck? {
    analysis.checks.first { $0.id == id }
}

// MARK: - A clean drive

struct CleanCaptureAnalysisTests {

    /// 40 s at 25 Hz, no faults, cleanly stopped.
    private let analysis: CaptureAnalysis

    init() throws {
        analysis = try analyze(SyntheticCapture())
    }

    @Test func summaryCountsEveryPacketAndNothingMissing() {
        let s = analysis.summary
        #expect(s.packetsReceived == 1000)
        #expect(s.undecodableLines == 0)
        #expect(s.missedFixes == 0)
        #expect(s.expectedPackets == 1000)
        #expect(s.errorRate == 0)
        #expect(s.lateIntervals == 0)
        #expect(s.anomalousIntervals == 0)
        #expect(s.interruptions == 0)
        #expect(s.nominalChanges.isEmpty)
        #expect(!s.wasInterrupted)
    }

    @Test func intervalsAreAllOnCadenceAtTwentyFiveHertz() {
        let s = analysis.summary
        #expect(s.nominalHz.map { near($0, 25) } == true)
        #expect(s.onCadenceIntervals == 999)             // 1000 packets, 999 intervals
        #expect(near(s.longestGapMs, 40))
        #expect(near(s.medianHz, 25, 1e-6))
        #expect(near(s.meanHz, 1000.0 / 39.96, 1e-6))    // packets over device span
        #expect(analysis.cadence.intervalHistogramMs == [40: 999])
        #expect(analysis.cadence.gaps.isEmpty)
    }

    @Test func bothClocksAgreeOnTheDuration() {
        let s = analysis.summary
        #expect(near(s.deviceDuration, 39.96, 1e-6))
        #expect(near(s.hostDuration, 39.96, 1e-6))
        #expect(near(s.longestCleanRun, 39.96, 1e-6))    // the whole session
        #expect(near(s.longestCleanRunStart, 0))
    }

    @Test func steadyDeliveryShowsNoDriftAndNoBursts() {
        let t = analysis.transport
        #expect(t.clockRatio.map { near($0, 1, 1e-9) } == true)
        #expect(t.clockDriftPPM.map { abs($0) < 0.01 } == true)
        #expect(t.maxDriftMs < 0.2)                       // %.4f rounding of the arrival time
        #expect(near(t.meanBurstSize, 1))
        #expect(t.maxBurstSize == 1)
        #expect(t.attribution.isEmpty)
    }

    @Test func gnssSummaryReflectsTheDrive() {
        let g = analysis.gnss
        #expect(g.fixTypeCounts == [3: 1000])
        #expect(g.numSV.min == 12 && g.numSV.max == 14)
        #expect(near(g.pDOP.min, 1.0, 1e-9) && near(g.pDOP.max, 1.4, 1e-9))
        #expect(g.batteryStart == 80)
        #expect(g.batteryEnd == 77)
        #expect(g.chargingTransitions == 0)
        #expect(near(g.maxSpeedKmh, 54.0, 0.01))          // 15 m/s
        #expect(near(g.distanceMetres, 240, 1))           // 75 m + 120 m + 45 m
        #expect(g.meanSVAtGaps == nil)                    // there were no gaps
    }

    @Test func everyConsistencyCheckPasses() {
        for id in ["itow-monotonic", "frame-integrity", "clock-fields", "speed-vs-position",
                   "imu-at-rest", "field-ranges", "battery-monotonic", "capture-complete"] {
            #expect(check(id, in: analysis)?.status == .pass, "check \(id)")
        }
        #expect(analysis.checks.count == 8)
        #expect(check("clock-fields", in: analysis)?.samples == 1000)
        #expect(check("speed-vs-position", in: analysis)?.samples == 999)
    }

    @Test func trackHoldsEveryFixAndEndsAtRest() throws {
        let track = analysis.track
        #expect(track.count == 1000)
        #expect(near(try #require(track.first).latitude, 37.0, 1e-6))
        #expect(try #require(track.first).speedKmh == 0)
        #expect(try #require(track.last).speedKmh == 0)
        #expect(near(track.map(\.speedKmh).max() ?? 0, 54.0, 0.01))
    }

    @Test func headerAndTrailerAreCarriedThrough() throws {
        let h = analysis.header
        #expect(h.schema == 1)
        #expect(h.format == "gnimu-capture-jsonl")
        #expect(h.deviceName == SyntheticCapture.deviceName)
        #expect(h.hostPlatform == "macOS")
        #expect(h.lowPowerMode == false)
        #expect(h.thermalState == "nominal")
        #expect(h.nominalHz == 25)
        #expect(h.frameBytes == 88)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(h.startedAt == iso.date(from: SyntheticCapture.startedAt))

        let trailer = try #require(analysis.trailer)
        #expect(trailer.packets == 1000)
        #expect(trailer.rawBytes == 88_000)
        #expect(near(try #require(trailer.durationSeconds), 39.96, 1e-6))
    }

    @Test func seriesAreBuilt() {
        #expect(!analysis.series.fixRateHz.buckets.isEmpty)
        #expect(!analysis.series.numSV.buckets.isEmpty)
        #expect(!analysis.series.speedKmh.buckets.isEmpty)
        // Fix rate is the instantaneous 1000/delta, so it is 25 Hz throughout.
        for bucket in analysis.series.fixRateHz.buckets {
            #expect(near(bucket.mean, 25, 1e-6))
        }
    }
}

// MARK: - Bursty delivery

struct BurstyCaptureAnalysisTests {

    @Test func packetsDeliveredThreeAtATimeAreSeenAsBursts() throws {
        var capture = SyntheticCapture()
        capture.burst = 3
        let a = try analyze(capture)

        #expect(a.transport.maxBurstSize == 3)
        #expect(near(a.transport.meanBurstSize, 3, 0.05))
        #expect(near(a.transport.burstSpacingMs.mean, 120, 1e-6))
        // Delivery is lumpy but the device's own cadence is untouched.
        #expect(a.summary.missedFixes == 0)
        #expect(a.summary.onCadenceIntervals == 999)
        #expect(a.summary.anomalousIntervals == 0)
    }
}

// MARK: - A drive with faults

struct FaultyCaptureAnalysisTests {

    /// Faults, in nominal session seconds:
    ///   6  a fix missing, arrival gap grows with it   -> attributed "both"
    ///   8  a corrupt packet line                      -> undecodable
    ///   9  a line that isn't JSON                     -> undecodable
    ///   12 a fix missing, arrivals stay on time       -> attributed "device"
    ///   15 battery steps up while not charging
    ///   18 a fix missing, delivery stalls past it     -> attributed "transport"
    ///   20 three packets with the clock 10 s off
    ///   24 one late fix (60 ms interval)
    ///   30 a duplicated iTOW
    ///   36 a 1.5 s interruption                       -> attributed "both"
    /// and no summary line at the end.
    private let analysis: CaptureAnalysis

    init() throws {
        analysis = try analyze(SyntheticCapture.faulty)
    }

    @Test func summaryCountsEachFaultOnce() {
        let s = analysis.summary
        #expect(s.packetsReceived == 1001)               // 1000 + the duplicate
        #expect(s.undecodableLines == 2)
        #expect(s.missedFixes == 3)
        #expect(s.expectedPackets == 1004)
        #expect(near(s.errorRate, 3.0 / 1004.0 * 100, 1e-9))
        #expect(s.lateIntervals == 1)
        #expect(s.anomalousIntervals == 1)               // the duplicate
        #expect(s.interruptions == 1)
        // 1000 intervals less 3 missed, 1 late, 1 anomalous and 1 interrupted.
        #expect(s.onCadenceIntervals == 994)
        #expect(near(s.longestGapMs, 1500))
        #expect(s.nominalHz.map { near($0, 25) } == true)
        #expect(s.wasInterrupted)                        // no summary line
    }

    @Test func theTwoClocksDisagreeByExactlyWhatWasInjected() {
        let s = analysis.summary
        // iTOW skipped 40 + 40 + 40 + 20 + 1460 ms; arrivals 40 + 110 + 20 + 1460 ms.
        #expect(near(s.deviceDuration, 41.56, 1e-6))
        #expect(near(s.hostDuration, 41.59, 1e-6))
        #expect(s.meanHz > 0 && near(s.meanHz, 1001.0 / 41.56, 1e-6))
        #expect(analysis.transport.clockRatio.map { near($0, 41.59 / 41.56, 1e-9) } == true)
        #expect(analysis.transport.clockDriftPPM.map { near($0, (41.59 / 41.56 - 1) * 1e6, 1e-3) } == true)
    }

    @Test func maximumDriftIsSetByTheDuplicatePacket() {
        // The "device" gap leaves the host 40 ms behind the device clock. The
        // duplicate then arrives 20 ms after its twin with no device time at all,
        // pushing host-minus-device to +50 ms, the session maximum.
        #expect(near(analysis.transport.maxDriftMs, 50, 0.2))
    }

    @Test func gapsAreListedInOrderWithTheirCauses() {
        let gaps = analysis.cadence.gaps
        #expect(gaps.count == 4)
        guard gaps.count == 4 else { return }

        #expect(gaps.map(\.attribution) == [.both, .device, .transport, .both])
        #expect(gaps.map(\.missedFixes) == [1, 1, 1, 0])
        #expect(gaps.map(\.isInterruption) == [false, false, false, true])
        #expect(gaps.map { Int($0.deviceGapMs.rounded()) } == [80, 80, 80, 1500])
        #expect(gaps.map { Int($0.arrivalGapMs.rounded()) } == [80, 40, 150, 1500])
        #expect(near(gaps[0].t, 6.04, 1e-3))
        #expect(near(gaps[1].t, 12.04, 1e-3))
        #expect(near(gaps[2].t, 18.15, 1e-3))
        #expect(near(gaps[3].t, 37.63, 1e-3))
    }

    @Test func attributionTotalsMatchTheGapList() {
        #expect(analysis.transport.attribution == [.both: 2, .device: 1, .transport: 1])
    }

    @Test func theLongestCleanRunIgnoresLateFixesButNotMissedOnes() {
        // 18.15 s to just before the duplicate at 30 s: 299 intervals of 40 ms
        // plus the 20 ms of lateness at 24 s. The late fix does not break a run;
        // missed fixes, interruptions and the duplicate do.
        #expect(near(analysis.summary.longestCleanRun, 11.98, 1e-6))
        #expect(near(analysis.summary.longestCleanRunStart, 18.15, 1e-3))
    }

    @Test func consistencyChecksFlagExactlyTheInjectedProblems() throws {
        func status(_ id: String) -> ConsistencyCheck.Status? { check(id, in: analysis)?.status }

        #expect(status("itow-monotonic") == .fail)
        #expect(status("frame-integrity") == .warn)       // 2 bad lines is under 1% of packets
        #expect(status("clock-fields") == .warn)          // 3 of 1001 is under 1%
        #expect(status("battery-monotonic") == .warn)
        #expect(status("capture-complete") == .warn)
        #expect(status("speed-vs-position") == .pass)
        #expect(status("imu-at-rest") == .pass)
        #expect(status("field-ranges") == .pass)

        let itow = try #require(check("itow-monotonic", in: analysis))
        #expect(itow.failures == 1)
        #expect(itow.samples == 1000)
        #expect(itow.example?.hasPrefix("iTOW repeated") == true)

        #expect(check("frame-integrity", in: analysis)?.failures == 2)
        #expect(check("frame-integrity", in: analysis)?.samples == 1003)
        #expect(check("clock-fields", in: analysis)?.failures == 3)
        #expect(check("clock-fields", in: analysis)?.samples == 1001)
        #expect(check("battery-monotonic", in: analysis)?.failures == 1)
        #expect(check("capture-complete", in: analysis)?.example?.contains("interrupted") == true)
    }

    @Test func satelliteAndBatteryReadingsSurviveTheFaults() {
        #expect(analysis.gnss.batteryStart == 80)
        #expect(analysis.gnss.batteryEnd == 79)           // 80 - 3 + the 2-point rise
        #expect(analysis.gnss.fixTypeCounts == [3: 1001])
        #expect(near(analysis.gnss.distanceMetres, 240, 1))
        #expect(analysis.gnss.meanSVAtGaps != nil)
    }
}

// MARK: - Reading the file

struct CaptureReadingTests {

    private func readError(_ capture: SyntheticCapture) -> CaptureReadError? {
        do {
            _ = try analyze(capture)
            return nil
        } catch let error as CaptureReadError {
            return error
        } catch {
            return .unreadable("\(error)")
        }
    }

    @Test func aFileWithNoHeaderIsRejected() {
        var capture = SyntheticCapture()
        capture.includeHeader = false
        guard case .missingHeader? = readError(capture) else {
            Issue.record("expected missingHeader")
            return
        }
    }

    @Test func aFileWithNoPacketsIsRejected() {
        var capture = SyntheticCapture()
        capture.seconds = 0
        guard case .noPackets? = readError(capture) else {
            Issue.record("expected noPackets")
            return
        }
    }

    @Test func aFinalLineWithoutANewlineIsStillRead() throws {
        var capture = SyntheticCapture()
        capture.seconds = 4                                // 100 packets
        capture.includeTrailer = false
        capture.finalNewline = false                       // as if killed mid-write
        let a = try analyze(capture)
        #expect(a.summary.packetsReceived == 100)
        #expect(a.summary.undecodableLines == 0)
    }

    @Test func aTypedLineFromANewerSchemaIsSkippedNotCountedAgainstTheDevice() throws {
        var capture = SyntheticCapture()
        capture.seconds = 4
        capture.extraLines = ["{\"type\":\"note\",\"text\":\"from a newer app\"}"]
        let a = try analyze(capture)
        #expect(a.summary.packetsReceived == 100)
        #expect(a.summary.undecodableLines == 0)
    }

    @Test func aLongReadCanBeCancelled() {
        var capture = SyntheticCapture()
        capture.seconds = 200                              // 5000 packets
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try capture.data().write(to: url)
            _ = try CaptureAnalyzer.analyze(url: url, isCancelled: { true })
            Issue.record("expected the read to be cancelled")
        } catch let error as CaptureReadError {
            guard case .cancelled = error else {
                Issue.record("expected cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func progressRisesToOne() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticCapture().data().write(to: url)

        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        _ = try CaptureAnalyzer.analyze(url: url, onProgress: { box.values.append($0) })
        #expect(!box.values.isEmpty)
        #expect(box.values == box.values.sorted())
        #expect(box.values.last == 1)
    }
}
