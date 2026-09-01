// Gnimu Monitor
// Copyright (C) 2026 Chris Halstead
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

/// How the fix cadence we're seeing compares with what the device should be
/// emitting.
enum FixRateStatus {
    /// Not enough recent fixes to say anything.
    case noData
    /// Cadence at nominal, nothing missing.
    case onRate
    /// Isolated dropouts, or the cadence slipping slightly.
    case degraded
    /// Sustained slow cadence or heavy dropouts.
    case offRate

    /// Only a problem draws the eye: on-rate is deliberately unremarkable.
    var tint: Color {
        switch self {
        case .noData, .onRate: return .secondary
        case .degraded:        return .orange
        case .offRate:         return .red
        }
    }
}

/// A snapshot of fix-rate health, recomputed once per second.
struct FixRateReading {
    /// Cadence the device is emitting at, in Hz. Whole-fix dropouts are
    /// excluded, so an occasional lost packet doesn't read as a slower device;
    /// a device that is genuinely running late pulls this down.
    var hz: Double = 0
    /// The cadence the device is expected to hold, inferred from its own
    /// output. `nil` until enough fixes have arrived to establish it.
    var nominalHz: Double?
    /// Fixes absent from the iTOW sequence since the previous reading — either
    /// skipped by the device or lost in transport; the two are indistinguishable
    /// from iTOW alone. Only runs short enough to still be fixes: a longer gap
    /// is reported as an interruption instead.
    var missedFixes: Int = 0
    /// Breaks in the stream since the previous reading — long enough that
    /// calling them missed fixes would say more than we know.
    var interruptions: Int = 0
    /// Intervals longer than nominal but not a whole missed fix: the device
    /// producing a fix late.
    var lateIntervals: Int = 0
    /// Fraction of the fixes expected since the previous reading that arrived.
    var completeness: Double = 1
    var status: FixRateStatus = .noData

    /// Totals since the connection opened, for a session-long view of health.
    var sessionMissed: Int = 0
    var sessionIntervals: Int = 0
    var sessionInterruptions: Int = 0

    static let empty = FixRateReading()
}

/// Derives fix-rate health from the iTOW timestamps the device stamps into each
/// packet, rather than from packet arrival times — iTOW is the device's own
/// clock, so it is immune to BLE transport jitter.
///
/// Each interval between consecutive fixes is classified against an inferred
/// nominal period: on cadence, late (the device bogging), or a whole fix
/// missing. The headline rate is built from the first two only; missing fixes
/// are reported separately so one lost packet can't masquerade as a device
/// that has slowed down.
struct FixRateTracker {

    // MARK: Tuning

    /// Cadence is averaged over this much history…
    private let windowDuration: TimeInterval = 2.0
    /// …but never fewer than this many fixes, so slow rates (1 Hz) still have
    /// enough intervals to work with.
    private let minimumWindowSamples = 8
    /// Hard bound on retained samples, so a very high rate can't grow the window
    /// without limit.
    private let maximumWindowSamples = 128
    /// Intervals needed before any rate is reported at all.
    private let minimumIntervals = 3
    /// An interval counts as on-cadence (or as a whole number of missed fixes)
    /// when it lands within this fraction of nominal.
    private let cadenceTolerance = 0.1
    /// A gap longer than this many nominal periods is a break in the stream
    /// rather than a run of missed fixes. Past this point the ±tolerance test
    /// for "a whole number of periods" stops meaning anything — the tolerance
    /// stays a few ms while the gap runs to seconds — so whether a stall landed
    /// near an exact multiple would otherwise decide, at random, between a huge
    /// missed-fix count and one enormous late interval.
    private let interruptionPeriods = 10.0
    /// A new nominal is only adopted when this share of recent intervals agree
    /// on it — otherwise a bogging device would redefine its own degraded
    /// cadence as normal.
    private let nominalMajority = 0.6
    /// Output periods RaceBox devices actually use, in ms: 25, 20, 10, 5, 1 Hz.
    private let standardPeriodsMs: [Double] = [40, 50, 100, 200, 1000]

    // MARK: State

    private var window: [(arrival: Date, itow: UInt32)] = []
    private var previousITOW: UInt32?
    private var nominalMs: Double?
    /// A different nominal must show up twice running before it's adopted.
    private var candidateNominalMs: Double?

    // Counted as fixes arrive, drained by `evaluate()`, so each event is
    // reported exactly once rather than once per overlapping window.
    private var pendingIntervals = 0
    private var pendingMissed = 0
    private var pendingLate = 0
    private var pendingInterruptions = 0
    private var sessionIntervals = 0
    private var sessionMissed = 0
    private var sessionInterruptions = 0

    // MARK: Interval classification

    private enum Interval {
        case onCadence
        case late
        case missed(Int)   // number of fixes absent from the sequence
        case interrupted   // stream broke off and resumed
        case anomalous     // duplicate iTOW, week rollover, or out-of-order
    }

    /// Classify one iTOW delta against the nominal period.
    private func classify(deltaMs: Double, nominalMs: Double) -> Interval {
        guard deltaMs > 0, nominalMs > 0 else { return .anomalous }
        // Checked before anything else: an oversized gap must not reach the
        // tests below, which would read it as either a run of missed fixes or a
        // single enormous late interval — the latter wrecking the cadence
        // average it gets folded into.
        if deltaMs > interruptionPeriods * nominalMs { return .interrupted }
        let toleranceMs = max(nominalMs * cadenceTolerance, 2)
        let periods = (deltaMs / nominalMs).rounded()
        if periods >= 1, abs(deltaMs - periods * nominalMs) <= toleranceMs {
            return periods == 1 ? .onCadence : .missed(Int(periods) - 1)
        }
        // Long, but not a whole number of periods: the device produced a fix,
        // just not on time.
        if deltaMs > nominalMs + toleranceMs { return .late }
        // Shorter than nominal and not explainable as jitter.
        return .anomalous
    }

    // MARK: Ingest

    mutating func reset() {
        window = []
        previousITOW = nil
        nominalMs = nil
        candidateNominalMs = nil
        pendingIntervals = 0
        pendingMissed = 0
        pendingLate = 0
        pendingInterruptions = 0
        sessionIntervals = 0
        sessionMissed = 0
        sessionInterruptions = 0
    }

    /// Record one received fix. Classification happens here, against the nominal
    /// established by the previous evaluation, so counters stay non-overlapping.
    mutating func record(itow: UInt32, at now: Date = Date()) {
        window.append((now, itow))
        trim(now: now)

        defer { previousITOW = itow }
        guard let previous = previousITOW, let nominal = nominalMs else { return }

        switch classify(deltaMs: Double(itow) - Double(previous), nominalMs: nominal) {
        case .onCadence:
            pendingIntervals += 1
            sessionIntervals += 1
        case .late:
            pendingIntervals += 1
            pendingLate += 1
            sessionIntervals += 1
        case .missed(let n):
            pendingIntervals += 1
            pendingMissed += n
            sessionIntervals += 1
            sessionMissed += n
        case .interrupted:
            // Deliberately kept out of the interval counts: an outage is not a
            // low completeness score, it's an absence of data to score.
            pendingInterruptions += 1
            sessionInterruptions += 1
        case .anomalous:
            break
        }
    }

    /// Age out old samples, keeping enough to measure slow cadences.
    private mutating func trim(now: Date) {
        while window.count > minimumWindowSamples,
              let first = window.first,
              now.timeIntervalSince(first.arrival) > windowDuration {
            window.removeFirst()
        }
        if window.count > maximumWindowSamples {
            window.removeFirst(window.count - maximumWindowSamples)
        }
    }

    // MARK: Evaluation

    /// Produce the current reading and drain the per-interval counters.
    mutating func evaluate(now: Date = Date()) -> FixRateReading {
        trim(now: now)
        let deltas = windowDeltas()
        updateNominal(from: deltas)

        var reading = FixRateReading(interruptions: pendingInterruptions,
                                     sessionMissed: sessionMissed,
                                     sessionIntervals: sessionIntervals,
                                     sessionInterruptions: sessionInterruptions)
        defer { drainPending() }

        guard let nominal = nominalMs, deltas.count >= minimumIntervals else { return reading }

        // Stop reporting a rate once fixes stop arriving, rather than coasting
        // on a window that no longer reflects anything live.
        let quietFor = window.last.map { now.timeIntervalSince($0.arrival) } ?? .infinity
        guard quietFor <= max(1.0, 3 * nominal / 1000) else { return reading }

        // Cadence: mean over the intervals the device actually delivered, with
        // whole-fix dropouts left out.
        var counted = 0
        var totalMs = 0.0
        for delta in deltas {
            switch classify(deltaMs: delta, nominalMs: nominal) {
            case .onCadence, .late:
                counted += 1
                totalMs += delta
            case .missed, .interrupted, .anomalous:
                continue
            }
        }
        guard counted > 0, totalMs > 0 else { return reading }

        let nominalHz = 1000 / nominal
        let expected = pendingIntervals + pendingMissed

        reading.hz = Double(counted) / (totalMs / 1000)
        reading.nominalHz = nominalHz
        reading.missedFixes = pendingMissed
        reading.lateIntervals = pendingLate
        reading.completeness = expected > 0 ? Double(pendingIntervals) / Double(expected) : 1
        reading.status = status(hz: reading.hz,
                                nominalHz: nominalHz,
                                missed: pendingMissed,
                                completeness: reading.completeness,
                                interruptions: pendingInterruptions)
        return reading
    }

    private mutating func drainPending() {
        pendingIntervals = 0
        pendingMissed = 0
        pendingLate = 0
        pendingInterruptions = 0
    }

    /// iTOW deltas between consecutive fixes in the window, in ms. Negative
    /// deltas (week rollover, reordering) are dropped rather than poisoning the
    /// average.
    private func windowDeltas() -> [Double] {
        guard window.count >= 2 else { return [] }
        var deltas: [Double] = []
        deltas.reserveCapacity(window.count - 1)
        for i in 1..<window.count {
            let delta = Double(window[i].itow) - Double(window[i - 1].itow)
            if delta > 0 { deltas.append(delta) }
        }
        return deltas
    }

    /// Infer the period the device is meant to be holding, from the interval it
    /// hits most often. Deliberately sticky: a clear majority, confirmed twice,
    /// is required to move it.
    private mutating func updateNominal(from deltas: [Double]) {
        guard deltas.count >= minimumIntervals else { return }

        var counts: [Int: Int] = [:]
        for delta in deltas { counts[Int(delta.rounded()), default: 0] += 1 }

        // Deterministic tiebreak on the shorter period, so equally common
        // deltas can't flip the nominal between evaluations.
        var modeMs = 0
        var modeCount = 0
        for (ms, count) in counts where count > modeCount || (count == modeCount && ms < modeMs) {
            modeMs = ms
            modeCount = count
        }
        guard modeCount > 0,
              Double(modeCount) / Double(deltas.count) >= nominalMajority else { return }

        let standard = standardPeriod(near: Double(modeMs))

        // Once locked onto one of the device's real output rates, only another
        // real output rate may replace it. Without this, a device bogging at a
        // steady 60 ms would make 60 ms the new normal within a couple of
        // seconds and go back to reporting itself healthy.
        if standard == nil, let current = nominalMs, standardPeriod(near: current) != nil {
            candidateNominalMs = nil
            return
        }

        let candidate = standard ?? Double(modeMs)
        guard candidate != nominalMs else {
            candidateNominalMs = nil
            return
        }
        // A rate change the user actually made still needs to land, so allow it
        // once two consecutive evaluations agree.
        if nominalMs == nil || candidateNominalMs == candidate {
            nominalMs = candidate
            candidateNominalMs = nil
        } else {
            candidateNominalMs = candidate
        }
    }

    /// The standard output period this measurement is close enough to be, or
    /// `nil` if it doesn't correspond to a rate the device can be set to.
    private func standardPeriod(near ms: Double) -> Double? {
        standardPeriodsMs.first { abs(ms - $0) <= $0 * 0.05 }
    }

    private func status(hz: Double, nominalHz: Double, missed: Int,
                        completeness: Double, interruptions: Int) -> FixRateStatus {
        guard hz > 0, nominalHz > 0 else { return .noData }
        if interruptions > 0 { return .offRate }
        let ratio = hz / nominalHz
        if ratio < 0.90 || completeness < 0.90 { return .offRate }
        if missed > 0 || ratio < 0.98 { return .degraded }
        return .onRate
    }
}
