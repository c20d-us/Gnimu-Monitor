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

/// Turns a capture file into a `CaptureAnalysis` in a single streaming pass.
///
/// Deliberately knows nothing about presentation: the HTML report and any later
/// PDF renderer both read from the result, so the two can never disagree about
/// the numbers.
///
/// Interval classification uses the same thresholds as `FixRateTracker`, so a
/// report can't contradict what the live panel showed during the session.
nonisolated enum CaptureAnalyzer {

    // MARK: Tuning — mirrors FixRateTracker

    /// An interval is on cadence (or a whole number of missed fixes) when it
    /// lands within this fraction of nominal.
    private static let cadenceTolerance = 0.1
    /// Beyond this many nominal periods a gap is a break in the stream rather
    /// than a run of missed fixes.
    private static let interruptionPeriods = 10.0
    /// Output periods RaceBox devices actually use, in ms: 25, 20, 10, 5, 1 Hz.
    private static let raceBoxPeriodsMs: [Double] = [40, 50, 100, 200, 1000]
    /// Frame periods a Gnimu device is likely to run at, in ms: it streams
    /// frames at its own rate, which can be faster than a GNSS receiver's.
    private static let gnimuPeriodsMs: [Double] = [20, 40, 50, 100, 200, 1000]
    /// Consecutive intervals a new standard period must hold before it replaces
    /// the nominal. A single dropped fix at 20 Hz or 10 Hz lands exactly on the
    /// next standard period (100 / 200 ms), so one interval proves nothing.
    private static let nominalConfirmIntervals = 20

    /// Arrivals closer together than this are one BLE notification burst rather
    /// than separate deliveries.
    private static let burstThresholdMs = 5.0
    /// Below this ground speed the device is treated as stationary, which is
    /// what makes the IMU-at-rest checks meaningful.
    private static let stationarySpeedMs = 0.5
    /// How far the Gnimu UTC timestamp may stray from the device clock's
    /// advance, in ms. The timestamp is the receiver's and the clock is the
    /// device's; the receiver's output delay varies by tens of ms.
    private static let utcOffsetToleranceMs = 500.0

    /// How long a stretch the speed check compares over, in ms of GNSS epoch time.
    private static let speedWindowMs = 1000.0

    private static let maxRetainedGaps = 500
    private static let maxTrackPoints = 5_000

    // MARK: - Entry point

    /// Analyses the capture at `url`. Long-running and pure — call it off the
    /// main thread and hand the result back.
    nonisolated static func analyze(
        url: URL,
        onProgress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> CaptureAnalysis {
        let began = Date()
        var state = State()
        state.fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        try CaptureReader.read(
            url: url,
            onHeader: { state.configure(for: $0) },
            onFrame: { t, stream, bytes in
                // Both protocols send their data on one stream today; a stream
                // this analyzer doesn't read is left out, not counted against
                // the device.
                guard stream == "frame" else { return }
                if let sample = state.sample(from: bytes) {
                    state.ingest(t: t, sample: sample)
                } else {
                    state.undecodableLines += 1
                }
            },
            onUndecodable: { state.undecodableLines += 1 },
            onTrailer: { state.trailer = $0 },
            onProgress: onProgress,
            isCancelled: isCancelled
        )

        // Every frame line was unreadable in the capture's protocol.
        guard state.packets > 0 else { throw CaptureReadError.noPackets }

        return state.finish(url: url, analysisDuration: Date().timeIntervalSince(began))
    }

    // MARK: - Interval classification

    private enum Interval {
        case onCadence
        case late
        case missed(Int)
        case interrupted
        case anomalous
    }

    private static func classify(deltaMs: Double, nominalMs: Double) -> Interval {
        guard deltaMs > 0, nominalMs > 0 else { return .anomalous }
        if deltaMs > interruptionPeriods * nominalMs { return .interrupted }
        let toleranceMs = max(nominalMs * cadenceTolerance, 2)
        let periods = (deltaMs / nominalMs).rounded()
        if periods >= 1, abs(deltaMs - periods * nominalMs) <= toleranceMs {
            return periods == 1 ? .onCadence : .missed(Int(periods) - 1)
        }
        if deltaMs > nominalMs + toleranceMs { return .late }
        return .anomalous
    }

    /// Snap an observed period to the nearest rate the hardware actually uses,
    /// so jitter doesn't invent a nominal of 40.3 ms.
    private static func snapToStandard(_ ms: Double, periods: [Double]) -> Double? {
        guard ms > 0 else { return nil }
        let best = periods.min { abs($0 - ms) < abs($1 - ms) }
        guard let best, abs(best - ms) <= best * 0.25 else { return nil }
        return best
    }

    // MARK: - Accumulator

    /// Everything the pass carries between packets. Held as one struct so the
    /// streaming callbacks stay short and the ordering is obvious.
    private struct State {
        var header = CaptureHeader()
        var isGnimu = false
        var trailer: CaptureTrailer?
        var fileSize = 0
        var undecodableLines = 0

        // Sequence
        var packets = 0
        var previous: AnalysisSample?
        var previousT: Double?
        var firstT: Double?
        var lastT: Double?
        var firstClock: UInt32?
        var lastClock: UInt32?
        var standardPeriods = CaptureAnalyzer.raceBoxPeriodsMs

        // Cadence
        var nominalMs: Double?
        var nominalChanges: [CaptureAnalysis.Summary.NominalChange] = []
        /// Intervals whose classification waits on the nominal being settled.
        struct PendingInterval {
            let t: Double
            let deltaMs: Double
            let arrivalGapMs: Double
            let previousClock: UInt32
            let sample: AnalysisSample
        }
        var pending: [PendingInterval] = []
        /// A standard period other than the nominal, and how many intervals in
        /// a row have held it so far.
        var candidateMs: Double?
        var candidateRun = 0
        var candidateStartT = 0.0
        var intervalHistogram: [Int: Int] = [:]
        var intervalStats = RunningStats()
        var onCadence = 0, late = 0, anomalous = 0, interruptions = 0
        var missedFixes = 0
        var receivedIntervals = 0
        var longestGapMs = 0.0
        var gaps: [CaptureGap] = []
        var truncatedGaps = 0
        /// Host time of the run's start, for placing it on the report timeline…
        var cleanRunStart: Double?
        /// …but the run is measured on the device's own clock. It's a claim
        /// about the device holding cadence, so BLE delivery timing must not
        /// be able to lengthen or shorten it.
        var cleanRunStartClock: UInt32?
        var longestCleanRun = 0.0
        var longestCleanRunStart = 0.0

        // Transport
        var arrivalDeltaStats = RunningStats()
        var burstSize = 0
        var burstSizes: [Int] = []
        var burstSpacing = RunningStats()
        var lastBurstStart: Double?
        var maxDriftMs = 0.0
        var attribution: [GapAttribution: Int] = [:]

        // GNSS
        var numSV = RunningStats(), pDOP = RunningStats()
        var hAcc = RunningStats(), vAcc = RunningStats()
        var fixTypeCounts: [UInt8: Int] = [:]
        var svAtGaps = RunningStats(), pdopAtGaps = RunningStats()
        var batteryStart: Int?, batteryEnd: Int?
        var wasCharging: Bool?
        var chargingTransitions = 0
        var distanceMetres = 0.0
        var maxSpeedKmh = 0.0

        // Consistency
        var clockBackwards = 0, clockDuplicate = 0
        var firstClockViolation: Double?
        var clockViolationExample: String?
        /// Gnimu frame counter: frames the counter says were lost, and steps
        /// that aren't losses (repeats, or a jump back, as after a restart).
        var sequenceSamples = 0
        var sequenceLost = 0, sequenceOther = 0
        var firstSequenceProblem: Double?
        var sequenceExample: String?
        /// UTC timestamp minus the solution's device-clock time, taken from
        /// the first frame that has both; later frames should keep to it.
        var utcOffsetReferenceMs: Double?
        /// The last frame that carried a new GNSS epoch, for the distance and
        /// speed checks.
        var previousEpoch: AnalysisSample?
        /// The stretch the speed check is accumulating over, from its first fix.
        struct SpeedWindow {
            let epoch: UInt32
            let latitude: Double
            let longitude: Double
            var speedSum: Double
            var accuracySum: Double
            var count: Int
        }
        var speedWindow: SpeedWindow?
        /// Device times of the frames in the last second, for the Gnimu rate trace.
        var rateWindow: [UInt32] = []
        var cadenceReference: CadenceReference?
        /// Frames from a GNSS device that carried no epoch yet.
        var framesWithoutEpoch = 0
        var clockFieldMismatches = 0, clockFieldSamples = 0
        var firstClockMismatch: Double?
        var clockMismatchExample: String?
        var speedMismatches = 0, speedSamples = 0
        var firstSpeedMismatch: Double?
        var speedMismatchExample: String?
        var restAccelStats = RunningStats(), restGyroStats = RunningStats()
        var rangeViolations = 0
        var firstRangeViolation: Double?
        var rangeViolationExample: String?
        var batteryIncreases = 0

        // Track
        var track: [TrackPoint] = []
        var trackStride = 1
        var trackCounter = 0

        // Series
        var sFixRate = TimeSeries(name: "Fix rate", unit: "Hz")
        var sMissed = TimeSeries(name: "Missed fixes", unit: "fixes")
        var sNumSV = TimeSeries(name: "Satellites", unit: "SV")
        var sPDOP = TimeSeries(name: "pDOP", unit: "")
        var sHAcc = TimeSeries(name: "Horizontal accuracy", unit: "m")
        var sArrival = TimeSeries(name: "Arrival interval", unit: "ms")
        var sSpeed = TimeSeries(name: "Ground speed", unit: "km/h")
        var sDrift = TimeSeries(name: "Host vs device clock", unit: "ms")

        // MARK: Ingest

        /// Reads the capture's protocol from its header. A capture that names
        /// none predates the field and is RaceBox.
        mutating func configure(for header: CaptureHeader) {
            self.header = header
            isGnimu = header.protocolName == DeviceProtocol.gnimu.rawValue
            standardPeriods = isGnimu ? CaptureAnalyzer.gnimuPeriodsMs
                                      : CaptureAnalyzer.raceBoxPeriodsMs
        }

        /// Decodes one frame's bytes in the capture's protocol, or `nil` if
        /// they aren't a valid frame.
        func sample(from bytes: Data) -> AnalysisSample? {
            if isGnimu {
                guard let frame = try? GnimuFrameV1.Frame(bytes) else { return nil }
                return AnalysisSample(frame)
            }
            guard let packet = RaceBoxPacket.parse(from: bytes) else { return nil }
            return AnalysisSample(packet)
        }

        mutating func ingest(t: Double, sample: AnalysisSample) {
            packets += 1
            if firstT == nil {
                firstT = t
                firstClock = sample.clockMs
                cleanRunStart = t
                cleanRunStartClock = sample.clockMs
            }
            lastT = t
            lastClock = sample.clockMs

            ingestQuality(t: t, sample: sample)
            ingestTransport(t: t, sample: sample)
            ingestCadence(t: t, sample: sample)
            ingestConsistency(t: t, sample: sample)
            ingestTrack(t: t, sample: sample)

            previous = sample
            previousT = t
        }

        // MARK: Quality

        private mutating func ingestQuality(t: Double, sample: AnalysisSample) {
            if let n = sample.numSV {
                numSV.add(Double(n))
                sNumSV.add(t: t, value: Double(n))
            }
            if let v = sample.pDOP {
                pDOP.add(v)
                sPDOP.add(t: t, value: v)
            }
            if let v = sample.hAcc {
                hAcc.add(v)
                sHAcc.add(t: t, value: v)
            }
            if let v = sample.vAcc { vAcc.add(v) }
            if let type = sample.fixType { fixTypeCounts[type, default: 0] += 1 }
            if let speed = sample.speedKmh {
                sSpeed.add(t: t, value: speed)
                maxSpeedKmh = max(maxSpeedKmh, speed)
            }

            if let battery = sample.batteryPercent {
                if batteryStart == nil { batteryStart = battery }
                if let last = batteryEnd, battery > last, sample.isCharging == false {
                    // Charge rising while not charging is a reporting fault.
                    batteryIncreases += 1
                }
                batteryEnd = battery
            }
            if let charging = sample.isCharging {
                if let was = wasCharging, was != charging { chargingTransitions += 1 }
                wasCharging = charging
            }
        }

        // MARK: Transport

        private mutating func ingestTransport(t: Double, sample: AnalysisSample) {
            guard let prevT = previousT else {
                lastBurstStart = t
                burstSize = 1
                return
            }
            let deltaMs = (t - prevT) * 1000
            arrivalDeltaStats.add(deltaMs)
            sArrival.add(t: t, value: deltaMs)

            // BLE delivers several packets per connection interval, so arrivals
            // land in bursts. Burst size and spacing describe the link, not the
            // device.
            if deltaMs <= CaptureAnalyzer.burstThresholdMs {
                burstSize += 1
            } else {
                burstSizes.append(burstSize)
                if let start = lastBurstStart { burstSpacing.add((t - start) * 1000) }
                lastBurstStart = t
                burstSize = 1
            }

            // Divergence between the two clocks: how far host elapsed time has
            // drifted from the device's own elapsed time.
            if let firstT, let firstClock {
                let hostMs = (t - firstT) * 1000
                let deviceMs = Double(sample.clockMs) - Double(firstClock)
                if deviceMs >= 0 {
                    let drift = hostMs - deviceMs
                    sDrift.add(t: t, value: drift)
                    maxDriftMs = max(maxDriftMs, abs(drift))
                }
            }
        }

        // MARK: Cadence

        /// What the previous cadence measurement was taken from.
        struct CadenceReference {
            let clock: UInt32
            let deviceClock: UInt32
            let t: Double
            let usesEpoch: Bool
        }

        /// Cadence is measured on the GNSS epoch where a frame has one: the
        /// receiver's own stamp (iTOW for RaceBox, the UTC timestamp for a Gnimu
        /// device) steps by exactly one period per solution. A Gnimu frame's
        /// device time is stamped as the frame is sent and wobbles by several
        /// ms, so it only serves for a device with no GNSS. A frame repeating
        /// the previous solution adds no interval.
        private mutating func ingestCadence(t: Double, sample: AnalysisSample) {
            // A GNSS device with no resolved time yet (a cold start) has no
            // epoch, and its device time is the stamp that wobbles, so these
            // frames take no part in the cadence. They are counted instead.
            if isGnimu && sample.hasGnssBlock && sample.gnssEpochMs == nil {
                framesWithoutEpoch += 1
                cadenceReference = nil
                rateWindow.removeAll()
                return
            }
            let epoch = isGnimu ? sample.gnssEpochMs : nil
            let clock = epoch ?? sample.clockMs
            let usesEpoch = epoch != nil
            let reference = CadenceReference(clock: clock, deviceClock: sample.clockMs,
                                             t: t, usesEpoch: usesEpoch)
            guard let ref = cadenceReference, ref.usesEpoch == usesEpoch else {
                cadenceReference = reference
                rateWindow.removeAll()
                return
            }
            if usesEpoch && clock == ref.clock { return }
            cadenceReference = reference

            let deltaMs = Double(clock) - Double(ref.clock)

            if deltaMs > 0 {
                intervalHistogram[Int(deltaMs.rounded()), default: 0] += 1
                intervalStats.add(deltaMs)
                if isGnimu {
                    addWindowedRate(t: t, clockMs: clock)
                } else {
                    sFixRate.add(t: t, value: 1000 / deltaMs)
                }
            } else {
                rateWindow.removeAll()
            }
            longestGapMs = max(longestGapMs, deltaMs)

            settleNominal(PendingInterval(t: t, deltaMs: deltaMs,
                                          arrivalGapMs: (t - ref.t) * 1000,
                                          previousClock: ref.deviceClock, sample: sample))
        }

        /// The Gnimu frame rate trace: frames over the last second of device
        /// time. A Gnimu device stamps each frame as it sends it, so one frame
        /// can go out a few ms late and the next on time; the rate from a single
        /// interval then swings either side of the true rate. The histogram
        /// still shows that timing spread.
        private mutating func addWindowedRate(t: Double, clockMs: UInt32) {
            rateWindow.append(clockMs)
            while rateWindow.count > 3, let first = rateWindow.first,
                  Double(clockMs) - Double(first) > 1000 {
                rateWindow.removeFirst()
            }
            guard rateWindow.count >= 3, let first = rateWindow.first else { return }
            let span = Double(clockMs) - Double(first)
            if span > 0 { sFixRate.add(t: t, value: Double(rateWindow.count - 1) / (span / 1000)) }
        }

        /// Holds intervals back while a different standard period is proving
        /// itself, so a single dropped fix can't redefine the nominal it should
        /// be judged by.
        private mutating func settleNominal(_ interval: PendingInterval) {
            let onStandard = interval.deltaMs > 0
                ? CaptureAnalyzer.snapToStandard(interval.deltaMs, periods: standardPeriods)
                    .flatMap { abs(interval.deltaMs - $0) <= $0 * 0.1 ? $0 : nil }
                : nil

            guard let period = onStandard, period != nominalMs else {
                // Not a new period, so any held run was just a drop. Once a
                // nominal exists, everything held belongs to it.
                candidateMs = nil
                candidateRun = 0
                pending.append(interval)
                if nominalMs != nil { flushPending() }
                return
            }

            if period != candidateMs {
                if nominalMs != nil { flushPending() }   // the previous run broke
                candidateMs = period
                candidateRun = 0
                candidateStartT = interval.t
            }
            pending.append(interval)
            candidateRun += 1

            if candidateRun >= CaptureAnalyzer.nominalConfirmIntervals {
                if let current = nominalMs {
                    nominalChanges.append(.init(t: candidateStartT,
                                                fromHz: 1000 / current,
                                                toHz: 1000 / period))
                }
                nominalMs = period
                candidateMs = nil
                candidateRun = 0
                flushPending()
            }
        }

        /// Classifies everything held, oldest first, against the settled nominal.
        private mutating func flushPending() {
            guard let nominal = nominalMs else { return }
            for interval in pending { classify(interval, nominal: nominal) }
            pending.removeAll(keepingCapacity: true)
        }

        private mutating func classify(_ iv: PendingInterval, nominal: Double) {
            switch CaptureAnalyzer.classify(deltaMs: iv.deltaMs, nominalMs: nominal) {
            case .onCadence:
                onCadence += 1
                receivedIntervals += 1
            case .late:
                late += 1
                receivedIntervals += 1
            case .missed(let n):
                receivedIntervals += 1
                missedFixes += n
                sMissed.add(t: iv.t, value: Double(n))
                noteGap(t: iv.t, deviceGapMs: iv.deltaMs, arrivalGapMs: iv.arrivalGapMs,
                        missed: n, interruption: false, sample: iv.sample, nominal: nominal)
                endCleanRun(endedAt: iv.previousClock, resumingAt: iv.t, clock: iv.sample.clockMs)
            case .interrupted:
                interruptions += 1
                sMissed.add(t: iv.t, value: Double(Int(iv.deltaMs / nominal) - 1))
                noteGap(t: iv.t, deviceGapMs: iv.deltaMs, arrivalGapMs: iv.arrivalGapMs,
                        missed: 0, interruption: true, sample: iv.sample, nominal: nominal)
                endCleanRun(endedAt: iv.previousClock, resumingAt: iv.t, clock: iv.sample.clockMs)
            case .anomalous:
                anomalous += 1
                // A duplicate or out-of-order timestamp is a device fault too.
                // Letting it slide would report the stretches either side of it
                // as one unbroken clean run.
                endCleanRun(endedAt: iv.previousClock, resumingAt: iv.t, clock: iv.sample.clockMs)
            }
        }

        /// The two-clock verdict. A device-side gap moves both clocks together;
        /// a transport stall moves only the host's.
        private mutating func noteGap(t: Double, deviceGapMs: Double, arrivalGapMs: Double,
                                      missed: Int, interruption: Bool,
                                      sample: AnalysisSample, nominal: Double) {
            let tolerance = max(nominal * 0.5, 20)
            let attribution: GapAttribution
            if deviceGapMs > nominal + tolerance && arrivalGapMs < nominal + tolerance {
                // The device skipped fixes but kept streaming on time.
                attribution = .device
            } else if arrivalGapMs > deviceGapMs + tolerance {
                // Delivery lagged further than the device's own clock did.
                attribution = .transport
            } else if deviceGapMs > nominal + tolerance {
                attribution = .both
            } else {
                attribution = .indeterminate
            }
            self.attribution[attribution, default: 0] += 1

            if let n = sample.numSV { svAtGaps.add(Double(n)) }
            if let v = sample.pDOP { pdopAtGaps.add(v) }

            // Bounded: a pathological capture shouldn't be able to grow this
            // without limit, and a report can't show 100,000 gaps anyway.
            if gaps.count < CaptureAnalyzer.maxRetainedGaps {
                gaps.append(CaptureGap(t: t, deviceGapMs: deviceGapMs,
                                       arrivalGapMs: arrivalGapMs, missedFixes: missed,
                                       isInterruption: interruption,
                                       attribution: attribution))
            } else {
                truncatedGaps += 1
            }
        }

        /// Closes the clean run at the last fix that arrived on cadence, then
        /// opens a new one at the fix that resumed the stream.
        private mutating func endCleanRun(endedAt lastGoodClock: UInt32,
                                          resumingAt t: Double, clock: UInt32) {
            if let startClock = cleanRunStartClock, let start = cleanRunStart {
                let duration = (Double(lastGoodClock) - Double(startClock)) / 1000
                if duration > longestCleanRun {
                    longestCleanRun = duration
                    longestCleanRunStart = start
                }
            }
            cleanRunStart = t
            cleanRunStartClock = clock
        }

        // MARK: Consistency

        private var clockName: String { isGnimu ? "Device time" : "iTOW" }

        private mutating func ingestConsistency(t: Double, sample: AnalysisSample) {
            if let previous {
                let delta = Double(sample.clockMs) - Double(previous.clockMs)
                if delta < 0 {
                    clockBackwards += 1
                    // A restart resets the device clock, so what the UTC
                    // timestamp is measured against starts over.
                    utcOffsetReferenceMs = nil
                    if firstClockViolation == nil {
                        firstClockViolation = t
                        clockViolationExample =
                            "\(clockName) went backwards: \(previous.clockMs) → \(sample.clockMs) ms"
                    }
                } else if delta == 0 {
                    clockDuplicate += 1
                    if firstClockViolation == nil {
                        firstClockViolation = t
                        clockViolationExample = "\(clockName) repeated: \(sample.clockMs) ms"
                    }
                }

                if let seq = sample.sequence, let prevSeq = previous.sequence {
                    sequenceSamples += 1
                    let step = Int(seq &- prevSeq)
                    if step != 1 {
                        // A jump of more than half the counter is a repeat or a
                        // step back rather than a run of lost frames.
                        if step == 0 || step > 128 {
                            sequenceOther += 1
                            if firstSequenceProblem == nil {
                                firstSequenceProblem = t
                                sequenceExample = "sequence went \(prevSeq) → \(seq)"
                            }
                        } else {
                            sequenceLost += step - 1
                            if firstSequenceProblem == nil {
                                firstSequenceProblem = t
                                sequenceExample = "sequence went \(prevSeq) → \(seq): \(step - 1) frame\(step == 2 ? "" : "s") lost"
                            }
                        }
                    }
                }
            }

            // The clock fields describe one instant two ways; they must agree.
            if let result = sample.clockFieldResult {
                clockFieldSamples += 1
                if case .mismatch(let example) = result {
                    clockFieldMismatches += 1
                    if firstClockMismatch == nil {
                        firstClockMismatch = t
                        clockMismatchExample = example
                    }
                }
            } else if let utc = sample.utcMs, let age = sample.epochAgeMs {
                // The UTC timestamp is when the solution was computed, so it
                // advances with the device clock: its offset from the solution's
                // device time stays put.
                let offset = utc - (Double(sample.clockMs) - age)
                if let reference = utcOffsetReferenceMs {
                    clockFieldSamples += 1
                    if abs(offset - reference) > CaptureAnalyzer.utcOffsetToleranceMs {
                        clockFieldMismatches += 1
                        if firstClockMismatch == nil {
                            firstClockMismatch = t
                            clockMismatchExample = String(
                                format: "UTC and device time drifted apart by %.0f ms",
                                offset - reference)
                        }
                    }
                } else {
                    utcOffsetReferenceMs = offset
                }
            }

            // Distance covered between GNSS epochs, and the speed the device
            // reported over the same stretch — two independently derived
            // quantities that must agree. Only a new epoch counts: a Gnimu
            // frame can repeat the last solution, which says nothing about speed.
            if let epoch = sample.gnssEpochMs {
                if let prevEpoch = previousEpoch?.gnssEpochMs, epoch != prevEpoch {
                    if let previousEpoch, previousEpoch.hasFix, sample.hasFix,
                       let lat1 = previousEpoch.latitude, let lon1 = previousEpoch.longitude,
                       let lat2 = sample.latitude, let lon2 = sample.longitude {
                        let dtSeconds = (Double(epoch) - Double(prevEpoch)) / 1000
                        if dtSeconds > 0, dtSeconds < 2 {
                            distanceMetres += CaptureAnalyzer.distance(lat1, lon1, lat2, lon2)
                        }
                    }
                }
                if previousEpoch?.gnssEpochMs != epoch {
                    previousEpoch = sample
                    compareSpeedWithPosition(t: t, epoch: epoch, sample: sample)
                }
            }

            // At rest the accelerometer should read one gravity and the gyros
            // should read nothing — the cleanest IMU sanity test available.
            if let speed = sample.groundSpeedMs, speed < CaptureAnalyzer.stationarySpeedMs,
               let a = sample.accelG {
                restAccelStats.add((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
                if let g = sample.gyroDps {
                    restGyroStats.add((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
                }
            }

            if let rangeProblem = sample.rangeProblem {
                rangeViolations += 1
                if firstRangeViolation == nil {
                    firstRangeViolation = t
                    rangeViolationExample = rangeProblem
                }
            }
        }

        /// Judges the reported speed against how far the position moved, over a
        /// stretch of about a second rather than from one fix to the next. At
        /// 20 Hz a quarter metre of ordinary position noise between two fixes
        /// reads as several m/s, so a pair-by-pair comparison flags noise; over
        /// a second the same noise is a fraction of a m/s. The stretch is
        /// measured on the GNSS epoch clock, so a device that sends frames
        /// faster than it solves, or a Bluetooth stall, doesn't change it.
        private mutating func compareSpeedWithPosition(t: Double, epoch: UInt32, sample: AnalysisSample) {
            guard sample.hasFix, let lat = sample.latitude, let lon = sample.longitude,
                  let speed = sample.groundSpeedMs else {
                speedWindow = nil           // no fix: the stretch is broken
                return
            }
            guard var window = speedWindow else {
                speedWindow = SpeedWindow(epoch: epoch, latitude: lat, longitude: lon,
                                          speedSum: speed, accuracySum: sample.speedAccuracyMs ?? 0, count: 1)
                return
            }
            window.speedSum += speed
            window.accuracySum += sample.speedAccuracyMs ?? 0
            window.count += 1

            let dtMs = Double(epoch) - Double(window.epoch)
            guard dtMs >= CaptureAnalyzer.speedWindowMs else {
                speedWindow = window
                return
            }
            // A stretch with a hole in it (a stall) says nothing: start again.
            if dtMs <= CaptureAnalyzer.speedWindowMs * 2.5 {
                let implied = CaptureAnalyzer.distance(window.latitude, window.longitude, lat, lon) / (dtMs / 1000)
                let reported = window.speedSum / Double(window.count)
                // Generous: only gross disagreement counts.
                let allowance = max(window.accuracySum / Double(window.count) * 5, 3.0) + reported * 0.5
                speedSamples += 1
                if abs(implied - reported) > allowance {
                    speedMismatches += 1
                    if firstSpeedMismatch == nil {
                        firstSpeedMismatch = t
                        speedMismatchExample = String(
                            format: "position implies %.1f m/s, packet reports %.1f m/s (over %.1f s)",
                            implied, reported, dtMs / 1000)
                    }
                }
            }
            speedWindow = SpeedWindow(epoch: epoch, latitude: lat, longitude: lon,
                                      speedSum: speed, accuracySum: sample.speedAccuracyMs ?? 0, count: 1)
        }

        // MARK: Track

        private mutating func ingestTrack(t: Double, sample: AnalysisSample) {
            guard sample.hasFix, let lat = sample.latitude, let lon = sample.longitude else { return }
            trackCounter += 1
            guard trackCounter % trackStride == 0 else { return }
            track.append(TrackPoint(t: t, latitude: lat, longitude: lon,
                                    speedKmh: sample.movingSpeedKmh ?? 0))
            // Halve the resolution rather than grow without bound, the same way
            // the series accumulators do.
            if track.count >= CaptureAnalyzer.maxTrackPoints {
                track = track.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
                trackStride *= 2
            }
        }

        // MARK: Finish

        mutating func finish(url: URL, analysisDuration: TimeInterval) -> CaptureAnalysis {
            // A capture can end partway through a candidate run. One too short
            // to ever settle a nominal takes the period it was running at.
            if nominalMs == nil { nominalMs = candidateMs }
            flushPending()

            // A session that never dropped a fix has its clean run still open.
            if let startClock = cleanRunStartClock, let lastClock, let start = cleanRunStart {
                let duration = (Double(lastClock) - Double(startClock)) / 1000
                if duration > longestCleanRun {
                    longestCleanRun = duration
                    longestCleanRunStart = start
                }
            }
            if burstSize > 0 { burstSizes.append(burstSize) }

            sFixRate.finalize(); sMissed.finalize(); sNumSV.finalize(); sPDOP.finalize()
            sHAcc.finalize(); sArrival.finalize(); sSpeed.finalize(); sDrift.finalize()

            let hostDuration = (lastT ?? 0) - (firstT ?? 0)
            let deviceDuration = firstClock.flatMap { first in
                lastClock.map { (Double($0) - Double(first)) / 1000 }
            } ?? 0

            let expected = packets + missedFixes
            let errorRate = expected > 0 ? Double(missedFixes) / Double(expected) * 100 : 0

            let clockRatio = deviceDuration > 0 ? hostDuration / deviceDuration : nil
            let driftPPM = clockRatio.map { ($0 - 1) * 1_000_000 }

            return CaptureAnalysis(
                source: url,
                fileSize: fileSize,
                header: header,
                trailer: trailer,
                summary: .init(
                    packetsReceived: packets,
                    framesWithoutEpoch: framesWithoutEpoch,
                    undecodableLines: undecodableLines,
                    expectedPackets: expected,
                    missedFixes: missedFixes,
                    errorRate: errorRate,
                    nominalHz: nominalMs.map { 1000 / $0 },
                    nominalChanges: nominalChanges,
                    deviceDuration: deviceDuration,
                    hostDuration: hostDuration,
                    // Measured on the device clock, like medianHz: this is the
                    // rate the device produced fixes at, not the rate the phone
                    // happened to receive them.
                    meanHz: deviceDuration > 0 ? Double(packets) / deviceDuration : 0,
                    medianHz: intervalStats.median > 0 ? 1000 / intervalStats.median : 0,
                    onCadenceIntervals: onCadence,
                    lateIntervals: late,
                    anomalousIntervals: anomalous,
                    interruptions: interruptions,
                    longestGapMs: longestGapMs,
                    longestCleanRun: longestCleanRun,
                    longestCleanRunStart: longestCleanRunStart,
                    wasInterrupted: trailer == nil
                ),
                cadence: .init(
                    intervalHistogramMs: intervalHistogram,
                    intervalStatsMs: intervalStats,
                    gaps: gaps
                ),
                transport: .init(
                    arrivalDeltaMs: arrivalDeltaStats,
                    clockRatio: clockRatio,
                    clockDriftPPM: driftPPM,
                    maxDriftMs: maxDriftMs,
                    meanBurstSize: burstSizes.isEmpty ? 0
                        : Double(burstSizes.reduce(0, +)) / Double(burstSizes.count),
                    maxBurstSize: burstSizes.max() ?? 0,
                    burstSpacingMs: burstSpacing,
                    attribution: attribution
                ),
                gnss: .init(
                    numSV: numSV, pDOP: pDOP, hAcc: hAcc, vAcc: vAcc,
                    fixTypeCounts: fixTypeCounts,
                    meanSVAtGaps: svAtGaps.isEmpty ? nil : svAtGaps.mean,
                    meanPDOPAtGaps: pdopAtGaps.isEmpty ? nil : pdopAtGaps.mean,
                    batteryStart: batteryStart,
                    batteryEnd: batteryEnd,
                    chargingTransitions: chargingTransitions,
                    distanceMetres: distanceMetres,
                    maxSpeedKmh: maxSpeedKmh
                ),
                checks: buildChecks(),
                track: track,
                series: .init(fixRateHz: sFixRate, missedFixes: sMissed, numSV: sNumSV,
                              pDOP: sPDOP, hAcc: sHAcc, arrivalDeltaMs: sArrival,
                              speedKmh: sSpeed, clockDriftMs: sDrift),
                analysisDuration: analysisDuration
            )
        }

        /// Every check is reported whether it passed or failed — "we looked and
        /// it was fine" is a result, and a silently absent check isn't.
        private func buildChecks() -> [ConsistencyCheck] {
            var checks: [ConsistencyCheck] = []

            let clockFailures = clockBackwards + clockDuplicate
            checks.append(ConsistencyCheck(
                id: isGnimu ? "clock-monotonic" : "itow-monotonic",
                title: isGnimu ? "Device time sequence" : "iTOW sequence",
                detail: isGnimu
                    ? "Device time must increase on every frame; duplicates and backward steps indicate the device repeated a frame or restarted."
                    : "Time-of-week must increase on every fix; duplicates and backward steps indicate the device restated or reordered a fix.",
                status: clockFailures == 0 ? .pass : .fail,
                failures: clockFailures, samples: max(packets - 1, 0),
                firstFailureAt: firstClockViolation, example: clockViolationExample))

            if isGnimu {
                let problems = sequenceLost + sequenceOther
                checks.append(ConsistencyCheck(
                    id: "frame-sequence",
                    title: "Frame sequence",
                    detail: "The frame counter must go up by one on every frame; a gap is a frame the device sent and the app never received.",
                    status: problems == 0 ? .pass
                        : (problems > sequenceSamples / 100 ? .fail : .warn),
                    failures: problems, samples: sequenceSamples,
                    firstFailureAt: firstSequenceProblem, example: sequenceExample))
            }

            checks.append(ConsistencyCheck(
                id: "frame-integrity",
                title: "Frame integrity",
                detail: isGnimu
                    ? "Every line must hold a complete 140-byte Gnimu frame of a spec version this app reads."
                    : "Every line must hold a complete 88-byte frame with a valid RaceBox checksum.",
                status: undecodableLines == 0 ? .pass : (undecodableLines > packets / 100 ? .fail : .warn),
                failures: undecodableLines, samples: packets + undecodableLines,
                firstFailureAt: nil, example: nil))

            checks.append(ConsistencyCheck(
                id: "clock-fields",
                title: isGnimu ? "UTC against device time" : "Clock field agreement",
                detail: isGnimu
                    ? "The GNSS UTC timestamp must advance in step with the device clock; a steady offset between them, to within half a second, means both are sound."
                    : "The packet's broken-out UTC clock must match the instant its own iTOW describes, allowing for the 18-second GPS-UTC offset.",
                status: clockFieldSamples == 0 ? .notApplicable
                    : (clockFieldMismatches == 0 ? .pass
                       : (clockFieldMismatches > clockFieldSamples / 100 ? .fail : .warn)),
                failures: clockFieldMismatches, samples: clockFieldSamples,
                firstFailureAt: firstClockMismatch, example: clockMismatchExample))

            checks.append(ConsistencyCheck(
                id: "speed-vs-position",
                title: "Speed against position",
                detail: "Distance covered between consecutive fixes must agree with the ground speed reported for the same interval.",
                status: speedSamples == 0 ? .notApplicable
                    : (speedMismatches == 0 ? .pass
                       : (speedMismatches > speedSamples / 50 ? .fail : .warn)),
                failures: speedMismatches, samples: speedSamples,
                firstFailureAt: firstSpeedMismatch, example: speedMismatchExample))

            if restAccelStats.isEmpty {
                checks.append(ConsistencyCheck(
                    id: "imu-at-rest", title: "IMU at rest",
                    detail: "With the device stationary the accelerometer should read one gravity and the gyroscopes should read nothing.",
                    status: .notApplicable, failures: 0, samples: 0,
                    firstFailureAt: nil, example: "The device never came to rest in this capture."))
            } else {
                let deviation = abs(restAccelStats.mean - 1.0)
                checks.append(ConsistencyCheck(
                    id: "imu-at-rest", title: "IMU at rest",
                    detail: "With the device stationary the accelerometer should read one gravity and the gyroscopes should read nothing.",
                    status: deviation < 0.05 ? .pass : (deviation < 0.15 ? .warn : .fail),
                    failures: 0, samples: restAccelStats.count, firstFailureAt: nil,
                    example: String(format: "mean %.3f g at rest, gyro %.2f °/s",
                                    restAccelStats.mean, restGyroStats.mean)))
            }

            checks.append(ConsistencyCheck(
                id: "field-ranges",
                title: "Field ranges",
                detail: "Latitude, longitude, heading, pDOP, battery and satellite count must all fall inside their defined ranges.",
                status: rangeViolations == 0 ? .pass : .fail,
                failures: rangeViolations, samples: packets,
                firstFailureAt: firstRangeViolation, example: rangeViolationExample))

            checks.append(ConsistencyCheck(
                id: "battery-monotonic",
                title: "Battery reporting",
                detail: "Charge should not rise while the device reports it is not charging.",
                status: batteryIncreases == 0 ? .pass : .warn,
                failures: batteryIncreases, samples: packets,
                firstFailureAt: nil, example: nil))

            checks.append(ConsistencyCheck(
                id: "capture-complete",
                title: "Capture completeness",
                detail: "A cleanly stopped capture ends with a summary line; its absence means the app was killed mid-session.",
                status: trailer == nil ? .warn : .pass,
                failures: trailer == nil ? 1 : 0, samples: 1,
                firstFailureAt: nil,
                example: trailer == nil ? "No summary line — this capture was interrupted." : nil))

            return checks
        }
    }

    /// Great-circle distance in metres.
    private static func distance(_ lat1: Double, _ lon1: Double,
                                 _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
