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

import Foundation

// MARK: - Statistics

/// Running statistics over a stream of values.
///
/// Count, extremes and mean are exact. Quantiles come from a bounded reservoir
/// sample: a multi-hour capture holds hundreds of thousands of values per
/// metric, and keeping them all to sort would cost far more memory than a
/// report's worth of percentiles is worth.
nonisolated struct RunningStats: Sendable {
    private(set) var count = 0
    private(set) var min = Double.infinity
    private(set) var max = -Double.infinity
    private var sum = 0.0
    private var sumOfSquares = 0.0

    /// Reservoir of sampled values, kept sorted only on demand.
    private var reservoir: [Double] = []
    private var seen = 0
    private let capacity = 20_000
    /// Deterministic so the same capture always yields the same report.
    private var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    var standardDeviation: Double {
        guard count > 1 else { return 0 }
        let variance = (sumOfSquares - sum * sum / Double(count)) / Double(count - 1)
        return variance > 0 ? variance.squareRoot() : 0
    }

    var isEmpty: Bool { count == 0 }

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        sum += value
        sumOfSquares += value * value
        if value < min { min = value }
        if value > max { max = value }

        // Reservoir sampling: every value has an equal chance of being kept,
        // so the percentiles stay representative however long the capture runs.
        if reservoir.count < capacity {
            reservoir.append(value)
        } else {
            let j = Int(rng.next() % UInt64(seen + 1))
            if j < capacity { reservoir[j] = value }
        }
        seen += 1
    }

    /// Approximate quantile in 0...1. Exact while the capture fits the
    /// reservoir, which covers most sessions.
    func quantile(_ q: Double) -> Double {
        guard !reservoir.isEmpty else { return 0 }
        let sorted = reservoir.sorted()
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    var median: Double { quantile(0.5) }
}

/// Small deterministic generator, so a report is reproducible from its capture.
nonisolated private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Series

/// One bucket of a downsampled series: the envelope plus the mean, so a chart
/// can show the spread rather than a line through averaged-away spikes.
nonisolated struct SeriesBucket: Sendable {
    let t: Double
    let min: Double
    let max: Double
    let mean: Double
    let count: Int
}

/// A time series held at bounded resolution.
///
/// Bucket width doubles whenever the session outgrows the bucket budget, so
/// memory is flat whether the capture is ten seconds or ten hours, and the
/// resolution is always the best that fits.
nonisolated struct TimeSeries: Sendable {
    let name: String
    let unit: String
    private(set) var buckets: [SeriesBucket] = []
    private(set) var bucketWidth: Double

    private var sums: [Double] = []
    private var mins: [Double] = []
    private var maxes: [Double] = []
    private var counts: [Int] = []
    private let capacity: Int

    init(name: String, unit: String, initialWidth: Double = 0.5, capacity: Int = 2_000) {
        self.name = name
        self.unit = unit
        self.bucketWidth = initialWidth
        self.capacity = capacity
    }

    mutating func add(t: Double, value: Double) {
        guard t >= 0, value.isFinite else { return }
        var index = Int(t / bucketWidth)
        while index >= capacity {
            collapse()
            index = Int(t / bucketWidth)
        }
        while counts.count <= index {
            sums.append(0); mins.append(.infinity); maxes.append(-.infinity); counts.append(0)
        }
        sums[index] += value
        if value < mins[index] { mins[index] = value }
        if value > maxes[index] { maxes[index] = value }
        counts[index] += 1
    }

    /// Halve the resolution by merging adjacent bucket pairs.
    private mutating func collapse() {
        let merged = (counts.count + 1) / 2
        var s = [Double](repeating: 0, count: merged)
        var lo = [Double](repeating: .infinity, count: merged)
        var hi = [Double](repeating: -.infinity, count: merged)
        var c = [Int](repeating: 0, count: merged)
        for i in counts.indices where counts[i] > 0 {
            let j = i / 2
            s[j] += sums[i]
            lo[j] = Swift.min(lo[j], mins[i])
            hi[j] = Swift.max(hi[j], maxes[i])
            c[j] += counts[i]
        }
        sums = s; mins = lo; maxes = hi; counts = c
        bucketWidth *= 2
    }

    /// Materialise the populated buckets. Empty ones are dropped rather than
    /// plotted as zero, which would draw a stream outage as a value of 0 Hz.
    mutating func finalize() {
        buckets = counts.indices.compactMap { i in
            guard counts[i] > 0 else { return nil }
            return SeriesBucket(t: Double(i) * bucketWidth,
                                min: mins[i], max: maxes[i],
                                mean: sums[i] / Double(counts[i]),
                                count: counts[i])
        }
    }
}

// MARK: - Findings

/// A gap in the iTOW sequence: either a run of fixes the device never
/// produced, or a break in the stream.
nonisolated struct CaptureGap: Sendable, Identifiable {
    let id = UUID()
    /// Seconds since session start, host clock.
    let t: Double
    let deviceGapMs: Double
    let arrivalGapMs: Double
    let missedFixes: Int
    let isInterruption: Bool
    /// Which side of the link the evidence points at.
    let attribution: GapAttribution
}

/// The two-clock verdict for a gap. Only possible offline, where the device's
/// own iTOW and the host's arrival time can be compared against each other.
nonisolated enum GapAttribution: String, Sendable {
    /// iTOW jumped and arrival jumped with it — the fix was never produced.
    case device
    /// iTOW stayed clean but arrivals stalled — produced, but not delivered.
    case transport
    /// Both moved, disproportionately: produced late and delivered late.
    case both
    case indeterminate

    var label: String {
        switch self {
        case .device:        return "Device didn't produce the fix"
        case .transport:     return "Fix produced, delivery stalled"
        case .both:          return "Late on both sides"
        case .indeterminate: return "Inconclusive"
        }
    }
}

/// One self-consistency test over the decoded stream.
nonisolated struct ConsistencyCheck: Sendable, Identifiable {
    enum Status: String, Sendable {
        case pass, warn, fail, notApplicable
    }

    let id: String
    let title: String
    /// What the check looked for, in a sentence — the report shows this whether
    /// the check passed or failed.
    let detail: String
    let status: Status
    let failures: Int
    let samples: Int
    /// Seconds since session start of the first violation, for the timeline.
    let firstFailureAt: Double?
    /// A concrete example, so a failure is actionable rather than a count.
    let example: String?
}

/// A point on the recorded track.
nonisolated struct TrackPoint: Sendable {
    let t: Double
    let latitude: Double
    let longitude: Double
    let speedKmh: Double
}

// MARK: - Result

/// Everything the report needs, and nothing about how it's rendered — so the
/// HTML and any later PDF renderer read from exactly the same numbers.
nonisolated struct CaptureAnalysis: Sendable {
    let source: URL
    let fileSize: Int
    let header: CaptureHeader
    let trailer: CaptureTrailer?
    let summary: Summary
    let cadence: Cadence
    let transport: Transport
    let gnss: GNSS
    let checks: [ConsistencyCheck]
    let track: [TrackPoint]
    let series: Series
    /// Wall-clock cost of producing this analysis.
    let analysisDuration: TimeInterval

    /// Tier 1: the headline numbers.
    struct Summary: Sendable {
        let packetsReceived: Int
        let undecodableLines: Int
        /// Received plus the fixes the device should have sent but didn't.
        let expectedPackets: Int
        let missedFixes: Int
        /// Percent of expected fixes that never arrived.
        let errorRate: Double
        let nominalHz: Double?
        let nominalChanges: [NominalChange]
        /// Span measured on the device's own clock.
        let deviceDuration: TimeInterval
        /// Span measured by the host's arrival times.
        let hostDuration: TimeInterval
        let meanHz: Double
        let medianHz: Double
        let onCadenceIntervals: Int
        let lateIntervals: Int
        let anomalousIntervals: Int
        let interruptions: Int
        let longestGapMs: Double
        /// The most informative single health number: the longest stretch the
        /// device held cadence with no missed fix, interruption, or
        /// out-of-sequence timestamp. Measured on the device's own clock, so
        /// BLE delivery timing can't lengthen or shorten it.
        let longestCleanRun: TimeInterval
        let longestCleanRunStart: Double
        /// No trailer line — the capture was killed rather than stopped.
        let wasInterrupted: Bool

        struct NominalChange: Sendable {
            let t: Double
            let fromHz: Double
            let toHz: Double
        }
    }

    /// Tier 2: how the cadence behaved over time.
    struct Cadence: Sendable {
        /// iTOW deltas, keyed by millisecond. Discrete by nature — a clean
        /// device is one spike, drops are spikes at whole multiples.
        let intervalHistogramMs: [Int: Int]
        let intervalStatsMs: RunningStats
        let gaps: [CaptureGap]
    }

    /// Tier 3: transport against generation — the two-clock analysis.
    struct Transport: Sendable {
        let arrivalDeltaMs: RunningStats
        /// Host seconds elapsed per device second. 1.0 is perfect agreement;
        /// a steady offset is a clock-rate error, steps are buffering.
        let clockRatio: Double?
        let clockDriftPPM: Double?
        /// Worst divergence between the two clocks over the session.
        let maxDriftMs: Double
        /// Packets per BLE notification burst, and how far apart bursts land.
        let meanBurstSize: Double
        let maxBurstSize: Int
        let burstSpacingMs: RunningStats
        let attribution: [GapAttribution: Int]
    }

    /// Tier 4: fix quality, and whether it explains the drops.
    struct GNSS: Sendable {
        let numSV: RunningStats
        let pDOP: RunningStats
        let hAcc: RunningStats
        let vAcc: RunningStats
        let fixTypeCounts: [UInt8: Int]
        /// The correlation that turns "it dropped fixes" into a cause.
        let meanSVAtGaps: Double?
        let meanPDOPAtGaps: Double?
        let batteryStart: Int?
        let batteryEnd: Int?
        let chargingTransitions: Int
        let distanceMetres: Double
        let maxSpeedKmh: Double
    }

    /// Downsampled traces for the report's charts.
    struct Series: Sendable {
        let fixRateHz: TimeSeries
        let missedFixes: TimeSeries
        let numSV: TimeSeries
        let pDOP: TimeSeries
        let hAcc: TimeSeries
        let arrivalDeltaMs: TimeSeries
        let speedKmh: TimeSeries
        let clockDriftMs: TimeSeries
    }
}
