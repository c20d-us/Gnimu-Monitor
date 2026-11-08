//
//  FixRateTrackerTests.swift
//  Gnimu MonitorTests
//
//  Pins how FixRateTracker turns a stream of iTOW stamps into a health
//  reading. Streams are synthetic: iTOW advances by the device's period while
//  a simulated arrival clock is passed in explicitly, so every test is
//  deterministic and arrival jitter can be varied independently of iTOW.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private let weekMs = 604_800_000.0

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

/// A simulated fix stream feeding one tracker.
@MainActor
private struct Feed {
    var tracker = FixRateTracker()
    var itow: Double = 100_000
    var arrival = Date(timeIntervalSinceReferenceDate: 1_000)

    /// One fix: iTOW moves on by `itowAdvanceMs`, and the arrival clock by
    /// `arrivalAdvanceMs` (default: the same). `jitterMs` delays only the
    /// time the fix is recorded at, never the underlying schedule.
    mutating func fix(itowAdvanceMs: Double, arrivalAdvanceMs: Double? = nil, jitterMs: Double = 0) {
        itow = (itow + itowAdvanceMs).truncatingRemainder(dividingBy: weekMs)
        arrival = arrival.addingTimeInterval((arrivalAdvanceMs ?? itowAdvanceMs) / 1000)
        tracker.record(itow: UInt32(itow), at: arrival.addingTimeInterval(jitterMs / 1000))
    }

    mutating func run(_ count: Int, periodMs: Double) {
        for _ in 0..<count { fix(itowAdvanceMs: periodMs) }
    }

    /// Runs `count` fixes, evaluating after every `every`th, as the app's
    /// once-a-second timer would. Returns the last reading.
    @discardableResult
    mutating func runEvaluating(_ count: Int, periodMs: Double, every: Int) -> FixRateReading {
        var last = FixRateReading.empty
        for i in 1...count {
            fix(itowAdvanceMs: periodMs)
            if i % every == 0 { last = evaluate() }
        }
        return last
    }

    /// Evaluates `quietFor` seconds after the last fix arrived.
    mutating func evaluate(quietFor: TimeInterval = 0) -> FixRateReading {
        tracker.evaluate(now: arrival.addingTimeInterval(quietFor))
    }

    /// A clean 25 Hz (by default) stream, evaluated once so the tracker has
    /// locked its nominal and drained its counters.
    mutating func establish(periodMs: Double = 40, fixes: Int = 30) {
        run(fixes, periodMs: periodMs)
        _ = evaluate()
    }
}

@MainActor
struct FixRateTrackerTests {

    // MARK: - Establishing a rate

    @Test func reportsNothingBeforeAnyFixes() {
        var feed = Feed()
        let r = feed.evaluate()
        #expect(r.status == .noData)
        #expect(r.hz == 0)
        #expect(r.nominalHz == nil)
    }

    @Test func needsAFewIntervalsBeforeReporting() {
        var three = Feed()
        three.run(3, periodMs: 40)           // two intervals
        #expect(three.evaluate().status == .noData)

        var four = Feed()
        four.run(4, periodMs: 40)            // three intervals
        #expect(four.evaluate().status == .onRate)
    }

    @Test(arguments: [(40.0, 25.0), (50.0, 20.0), (100.0, 10.0), (200.0, 5.0), (1000.0, 1.0)])
    func aCleanStreamReportsItsRateAsOnRate(periodMs: Double, expectedHz: Double) {
        var feed = Feed()
        feed.run(30, periodMs: periodMs)
        let r = feed.evaluate()
        #expect(near(r.hz, expectedHz))
        #expect(r.nominalHz.map { near($0, expectedHz) } == true)
        #expect(r.status == .onRate)
        #expect(r.missedFixes == 0)
        #expect(r.lateIntervals == 0)
        #expect(r.interruptions == 0)
        #expect(near(r.completeness, 1))
    }

    @Test func anIrregularStreamDoesNotEstablishARate() {
        var feed = Feed()
        for i in 0..<30 { feed.fix(itowAdvanceMs: i % 2 == 0 ? 40 : 70) }
        let r = feed.evaluate()
        #expect(r.nominalHz == nil)
        #expect(r.status == .noData)
    }

    @Test func aNonStandardRateIsAcceptedWhenThereIsNothingToCompareItTo() {
        var feed = Feed()
        feed.run(40, periodMs: 33)
        let r = feed.evaluate()
        #expect(r.nominalHz.map { near($0, 1000.0 / 33.0) } == true)
    }

    // MARK: - Missed, late and interrupted fixes

    @Test func oneMissedFixIsCountedAndMarksTheStreamDegraded() {
        var feed = Feed()
        feed.establish()
        feed.run(10, periodMs: 40)
        feed.fix(itowAdvanceMs: 80)          // one fix absent from the sequence
        feed.run(10, periodMs: 40)

        let r = feed.evaluate()
        #expect(r.missedFixes == 1)
        #expect(r.status == .degraded)
        #expect(near(r.hz, 25))              // the dropout doesn't read as a slower device
        #expect(near(r.completeness, 21.0 / 22.0))
        #expect(r.sessionMissed == 1)
    }

    @Test func eachEventIsReportedOnceThenDrained() {
        var feed = Feed()
        feed.establish()
        feed.fix(itowAdvanceMs: 80)
        feed.run(10, periodMs: 40)
        #expect(feed.evaluate().missedFixes == 1)

        feed.run(10, periodMs: 40)
        let next = feed.evaluate()
        #expect(next.missedFixes == 0)
        #expect(next.sessionMissed == 1)     // the session total keeps it
    }

    @Test func heavyDropoutsMakeTheStreamOffRate() {
        var feed = Feed()
        feed.establish()
        for _ in 0..<10 { feed.fix(itowAdvanceMs: 80) }   // every other fix missing

        let r = feed.evaluate()
        #expect(r.missedFixes == 10)
        #expect(near(r.completeness, 0.5))
        #expect(r.status == .offRate)
    }

    @Test func aLateFixIsNotAMissedFix() {
        var feed = Feed()
        feed.establish()
        feed.run(10, periodMs: 40)
        feed.fix(itowAdvanceMs: 60)          // produced, but late
        feed.run(10, periodMs: 40)

        let r = feed.evaluate()
        #expect(r.lateIntervals == 1)
        #expect(r.missedFixes == 0)
        #expect(near(r.completeness, 1))     // a late fix still arrived
    }

    @Test func lateFixesCountAsDeliveredInCompleteness() {
        var feed = Feed()
        feed.establish()
        feed.run(10, periodMs: 40)
        feed.fix(itowAdvanceMs: 60)          // late: delivered
        feed.fix(itowAdvanceMs: 80)          // one fix missing
        feed.run(10, periodMs: 40)

        let r = feed.evaluate()
        #expect(r.lateIntervals == 1)
        #expect(r.missedFixes == 1)
        // 22 intervals delivered (the late one among them) out of 23 expected.
        #expect(near(r.completeness, 22.0 / 23.0))
        #expect(r.sessionIntervals == 22)
    }

    @Test func aDeviceRunningLateDoesNotRedefineItsOwnNormal() {
        var feed = Feed()
        feed.establish()                      // locks 25 Hz
        let r = feed.runEvaluating(100, periodMs: 60, every: 17)

        #expect(r.nominalHz.map { near($0, 25) } == true)   // still 25 Hz...
        #expect(near(r.hz, 1000.0 / 60.0, 0.01))           // ...while delivering 16.7
        #expect(r.status == .offRate)
        #expect(r.lateIntervals > 0)
    }

    @Test func aRateChangeTheUserMadeIsAdoptedOnceTwoEvaluationsAgree() {
        var feed = Feed()
        feed.establish()                      // 25 Hz
        let r = feed.runEvaluating(100, periodMs: 50, every: 20)   // five seconds at 20 Hz

        #expect(r.nominalHz.map { near($0, 20) } == true)
        #expect(near(r.hz, 20, 0.01))
        #expect(r.status == .onRate)
    }

    @Test func aGapOfExactlyTenPeriodsIsStillNineMissedFixes() {
        var feed = Feed()
        feed.establish()
        feed.fix(itowAdvanceMs: 400)

        let r = feed.evaluate()
        #expect(r.missedFixes == 9)
        #expect(r.interruptions == 0)
        #expect(r.status == .offRate)         // 1 of 10 expected fixes arrived
    }

    @Test func aLongerGapIsAnInterruptionNotAMissedFixCount() {
        var feed = Feed()
        feed.establish()
        feed.fix(itowAdvanceMs: 440)

        let r = feed.evaluate()
        #expect(r.interruptions == 1)
        #expect(r.sessionInterruptions == 1)
        #expect(r.sessionMissed == 0)
        #expect(r.status == .offRate)
    }

    @Test func anInterruptionIsKeptOutOfTheIntervalCounts() {
        var feed = Feed()
        feed.establish()
        feed.run(10, periodMs: 40)
        let before = feed.evaluate().sessionIntervals

        feed.fix(itowAdvanceMs: 2000)         // a two-second stall
        let r = feed.evaluate()
        #expect(r.interruptions == 1)
        #expect(r.sessionInterruptions == 1)
        #expect(r.sessionMissed == 0)
        #expect(r.sessionIntervals == before)
    }

    // MARK: - Odd input

    @Test func aRepeatedITOWIsIgnored() {
        var feed = Feed()
        feed.establish()
        feed.fix(itowAdvanceMs: 0, arrivalAdvanceMs: 40)   // same iTOW again
        feed.run(10, periodMs: 40)

        let r = feed.evaluate()
        #expect(r.sessionIntervals == 10)     // the repeat is not an interval
        #expect(r.sessionMissed == 0)
        #expect(r.sessionInterruptions == 0)
    }

    @Test func theWeekRolloverIsNotCountedAsAnOutage() {
        var feed = Feed()
        feed.itow = weekMs - 2000
        feed.establish()                      // 1.2 s in, 0.8 s before the wrap
        feed.run(40, periodMs: 40)            // crosses the wrap

        let r = feed.evaluate()
        #expect(r.interruptions == 0)
        #expect(r.sessionInterruptions == 0)
        #expect(r.sessionMissed == 0)
        #expect(near(r.completeness, 1))
        #expect(near(r.hz, 25))
        #expect(r.status == .onRate)
    }

    // MARK: - Independence from the transport

    @Test func arrivalJitterDoesNotAffectTheMeasuredRate() {
        var feed = Feed()
        for i in 0..<60 {
            feed.fix(itowAdvanceMs: 40, jitterMs: i % 2 == 0 ? 0 : 30)
        }
        let r = feed.evaluate()
        #expect(near(r.hz, 25))
        #expect(r.status == .onRate)
        #expect(r.lateIntervals == 0)
    }

    @Test func stopsReportingARateOnceFixesStopArriving() {
        var feed = Feed()
        feed.establish()
        feed.run(30, periodMs: 40)
        let live = feed.evaluate()
        #expect(live.status == .onRate)

        let quiet = feed.evaluate(quietFor: 2)
        #expect(quiet.hz == 0)
        #expect(quiet.status == .noData)
        #expect(quiet.sessionIntervals == 30)  // the session totals survive
    }

    // MARK: - Reset

    @Test func resetForgetsEverything() {
        var feed = Feed()
        feed.establish()
        feed.run(30, periodMs: 40)
        feed.fix(itowAdvanceMs: 80)
        _ = feed.evaluate()

        feed.tracker.reset()
        let r = feed.evaluate()
        #expect(r.status == .noData)
        #expect(r.nominalHz == nil)
        #expect(r.sessionIntervals == 0)
        #expect(r.sessionMissed == 0)
        #expect(r.sessionInterruptions == 0)
    }
}
