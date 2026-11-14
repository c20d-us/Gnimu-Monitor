//
//  StreamHealthTests.swift
//  Gnimu Monitor
//
//  Stream health is judged from each frame's device time and sequence number:
//  rate, loss, repeats, restarts, delivery jitter; and per-channel value
//  changes. Streams are synthetic with the arrival clock passed in, so every
//  test is deterministic.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

/// A simulated stream from one device, 20 Hz unless told otherwise.
@MainActor
private struct Stream {
    var tracker = StreamHealthTracker()
    var deviceMs: Int64 = 1_500
    var sequence: UInt8 = 0
    var arrival = Date(timeIntervalSinceReferenceDate: 1_000)

    mutating func frame(deviceStepMs: Int64 = 50, sequenceStep: UInt8 = 1, arrivalStep: Double? = nil, jitterMs: Double = 0) {
        deviceMs += deviceStepMs
        sequence &+= sequenceStep
        arrival = arrival.addingTimeInterval((arrivalStep ?? Double(deviceStepMs) / 1000))
        tracker.record(deviceTimeMs: Int32(truncatingIfNeeded: deviceMs), sequence: sequence,
                       at: arrival.addingTimeInterval(jitterMs / 1000))
    }

    mutating func run(_ n: Int) { for _ in 0..<n { frame() } }

    mutating func evaluate(nominal: Double? = 20, quietFor: TimeInterval = 0) -> StreamHealthReading {
        tracker.evaluate(nominalHz: nominal, now: arrival.addingTimeInterval(quietFor))
    }
}

@MainActor
struct StreamHealthTrackerTests {

    @Test func nothingIsReportedBeforeAnyFrames() {
        var s = Stream()
        let r = s.evaluate()
        #expect(r.status == .noData)
        #expect(r.hz == 0)
        #expect(r.nominalHz == nil)
    }

    @Test func needsAFewFramesBeforeReportingARate() {
        var three = Stream()
        three.run(3)
        #expect(three.evaluate().status == .noData)
        var four = Stream()
        four.run(4)
        #expect(four.evaluate().status == .onRate)
    }

    @Test(arguments: [(50, 20.0), (40, 25.0), (100, 10.0), (33, 1000.0 / 33.0)])
    func aSteadyStreamReportsItsRateFromTheDeviceClock(stepMs: Int, expectedHz: Double) {
        var s = Stream()
        for _ in 0..<60 { s.frame(deviceStepMs: Int64(stepMs)) }
        let r = s.evaluate(nominal: expectedHz)
        #expect(near(r.hz, expectedHz, 1e-6))
        #expect(r.status == .onRate)
        #expect(r.framesLost == 0 && r.duplicates == 0 && r.restarts == 0)
        #expect(r.arrivalJitterMs.map { near($0, 0, 1e-6) } == true)
    }

    @Test func theNominalIsInferredWhenTheDeviceDeclaresNone() {
        var s = Stream()
        s.run(30)
        let r = s.evaluate(nominal: nil)
        #expect(r.nominalHz.map { near($0, 20) } == true)
        #expect(r.status == .onRate)
    }

    @Test func aDeclaredNominalIsReportedAsIs() {
        var s = Stream()
        s.run(30)
        #expect(s.evaluate(nominal: 25).nominalHz == 25)
    }

    @Test func aStreamBelowItsNominalIsOffRate() {
        var s = Stream()
        for _ in 0..<60 { s.frame(deviceStepMs: 100) }       // 10 Hz, declared 20
        let r = s.evaluate(nominal: 20)
        #expect(near(r.hz, 10))
        #expect(r.status == .offRate)
    }

    // MARK: Loss

    @Test func skippedSequenceNumbersAreLostFrames() {
        var s = Stream()
        s.run(30)
        _ = s.evaluate()                                     // drain
        s.run(10)
        s.frame(deviceStepMs: 150, sequenceStep: 4)           // three frames never arrived
        s.run(10)
        let r = s.evaluate()
        #expect(r.framesLost == 3)
        #expect(r.sessionLost == 3)
        #expect(r.status != .onRate)
    }

    @Test func eachEventIsReportedOnceThenDrained() {
        var s = Stream()
        s.run(30)
        s.frame(deviceStepMs: 100, sequenceStep: 2)
        s.run(10)
        #expect(s.evaluate().framesLost == 1)
        s.run(10)
        let next = s.evaluate()
        #expect(next.framesLost == 0)
        #expect(next.sessionLost == 1)                       // the session total keeps it
    }

    @Test func theSequenceWrapsAt255WithoutLoss() {
        var s = Stream()
        s.sequence = 250
        s.run(20)                                            // crosses 255 to 0
        let r = s.evaluate()
        #expect(r.framesLost == 0)
        #expect(r.status == .onRate)
    }

    @Test func aRepeatedFrameIsNotLoss() {
        var s = Stream()
        s.run(30)
        s.frame(deviceStepMs: 0, sequenceStep: 0, arrivalStep: 0.01)
        s.run(10)
        let r = s.evaluate()
        #expect(r.duplicates == 1)
        #expect(r.framesLost == 0)
        #expect(r.sessionDuplicates == 1)
    }

    @Test func anOutOfOrderFrameIsIgnoredNotCountedAsAHugeLoss() {
        var s = Stream()
        s.run(30)
        s.frame(sequenceStep: 200)                            // a jump of 200 can't be 199 lost frames
        let r = s.evaluate()
        #expect(r.framesLost == 0)
    }

    @Test func heavyLossIsOffRate() {
        var s = Stream()
        s.run(30)
        _ = s.evaluate()
        for _ in 0..<10 { s.frame(deviceStepMs: 100, sequenceStep: 2) }     // every other frame lost
        let r = s.evaluate()
        #expect(r.framesLost == 10)
        #expect(r.status == .offRate)
    }

    // MARK: Restarts and wraps

    @Test func theDeviceClockGoingBackIsARestartNotLoss() {
        var s = Stream()
        s.run(30)
        _ = s.evaluate()
        s.deviceMs = 100                                      // rebooted; sequence starts over too
        s.sequence = 7
        s.frame()
        s.run(10)
        let r = s.evaluate()
        #expect(r.restarts == 1)
        #expect(r.sessionRestarts == 1)
        #expect(r.framesLost == 0)
        #expect(near(r.hz, 20))                               // the window was cleared, not poisoned
    }

    @Test func theTwoToThe31ClockWrapIsNotARestart() {
        var s = Stream()
        s.deviceMs = Int64(Int32.max) - 500                   // half a second before the wrap
        s.run(40)                                             // two seconds, across it
        let r = s.evaluate()
        #expect(r.restarts == 0)
        #expect(near(r.hz, 20))
        #expect(r.status == .onRate)
    }

    // MARK: Quiet, jitter, reset

    @Test func stopsReportingARateOnceFramesStopArriving() {
        var s = Stream()
        s.run(30)
        #expect(s.evaluate().hz > 0)
        let quiet = s.evaluate(quietFor: 2)
        #expect(quiet.hz == 0)
        #expect(quiet.status == .noData)
        #expect(quiet.sessionFrames == 30)                    // totals survive
    }

    @Test func burstDeliveryShowsAsArrivalJitterNotAsADeviceProblem() {
        var s = Stream()
        // Frames sent every 50 ms by the device, delivered in pairs every 100 ms.
        for i in 0..<60 {
            s.frame(deviceStepMs: 50, arrivalStep: i % 2 == 0 ? 0.0 : 0.1)
        }
        let r = s.evaluate()
        #expect(near(r.hz, 20))                               // the device's rate is fine
        #expect(r.status == .onRate)
        #expect((r.arrivalJitterMs ?? 0) > 40)                // delivery is lumpy
    }

    @Test func resetForgetsEverything() {
        var s = Stream()
        s.run(30)
        s.frame(deviceStepMs: 100, sequenceStep: 2)
        s.tracker.reset()
        let r = s.evaluate()
        #expect(r == StreamHealthReading(nominalHz: nil))
    }

    @Test func sessionCountersAccumulateAcrossEvaluations() {
        var s = Stream()
        s.run(30)
        _ = s.evaluate()
        s.run(20)
        let r = s.evaluate()
        #expect(r.sessionFrames == 50)
    }
}

@MainActor
struct ChannelChangeTrackerTests {
    private func time(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: 1_000 + s) }

    @Test func aChannelThatChangesEveryFrameShowsTheFrameRate() {
        var t = ChannelChangeTracker()
        for i in 0..<200 { t.record(["engine_speed": 900 + Double(i)], at: time(Double(i) * 0.05)) }
        let rate = t.rates(now: time(9.95))["engine_speed"] ?? 0
        #expect(abs(rate - 20) < 0.5)
    }

    @Test func aChannelThatChangesEveryFifthFrameShowsAFourthOfIt() {
        var t = ChannelChangeTracker()
        for i in 0..<200 { t.record(["throttle_position": Double(i / 5)], at: time(Double(i) * 0.05)) }
        let rate = t.rates(now: time(9.95))["throttle_position"] ?? -1
        #expect(abs(rate - 4) < 0.5)
    }

    @Test func aSteadyChannelReadsZeroButIsStillListed() {
        var t = ChannelChangeTracker()
        for i in 0..<200 { t.record(["coolant_temp": 88.5], at: time(Double(i) * 0.05)) }
        let rates = t.rates(now: time(9.95))
        #expect(rates["coolant_temp"] != nil)
        #expect((rates["coolant_temp"] ?? 1) < 0.3)               // its appearance, long since aged out
    }

    @Test func aChannelThatDropsOutAndReturnsWithTheSameValueIsNotAChange() {
        var t = ChannelChangeTracker()
        t.record(["engine_speed": 900], at: time(0))
        t.record([:], at: time(1))
        t.record(["engine_speed": 900], at: time(2))
        let changes = t.rates(now: time(2)).values.first ?? -1
        // One change (its first appearance) over the 2 s seen.
        #expect(abs(changes - 0.5) < 0.01)
    }

    @Test func nothingIsReportedBeforeAnyRecording() {
        #expect(ChannelChangeTracker().rates().isEmpty)
    }

    @Test func resetClearsIt() {
        var t = ChannelChangeTracker()
        t.record(["engine_speed": 900], at: time(0))
        t.reset()
        #expect(t.rates(now: time(1)).isEmpty)
    }

    @Test func eachChannelIsTrackedIndependently() {
        var t = ChannelChangeTracker()
        for i in 0..<100 {
            t.record(["a": Double(i), "b": 1], at: time(Double(i) * 0.05))
        }
        let rates = t.rates(now: time(4.95))
        #expect((rates["a"] ?? 0) > 15)
        #expect((rates["b"] ?? 1) < 0.5)
    }
}
