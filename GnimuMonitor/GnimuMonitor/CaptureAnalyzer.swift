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
    private static let standardPeriodsMs: [Double] = [40, 50, 100, 200, 1000]

    /// Arrivals closer together than this are one BLE notification burst rather
    /// than separate deliveries.
    private static let burstThresholdMs = 5.0
    /// Below this ground speed the device is treated as stationary, which is
    /// what makes the IMU-at-rest checks meaningful.
    private static let stationarySpeedMs = 0.5
    /// GPS-UTC offset, constant at 18 s since 2017. Used to check the packet's
    /// broken-out clock against its own iTOW.
    private static let gpsUtcLeapSeconds = 18.0

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
            onHeader: { state.header = $0 },
            onFrame: { t, packet in state.ingest(t: t, packet: packet) },
            onUndecodable: { state.undecodableLines += 1 },
            onTrailer: { state.trailer = $0 },
            onProgress: onProgress,
            isCancelled: isCancelled
        )

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
    private static func snapToStandard(_ ms: Double) -> Double? {
        guard ms > 0 else { return nil }
        let best = standardPeriodsMs.min { abs($0 - ms) < abs($1 - ms) }
        guard let best, abs(best - ms) <= best * 0.25 else { return nil }
        return best
    }

    // MARK: - Accumulator

    /// Everything the pass carries between packets. Held as one struct so the
    /// streaming callbacks stay short and the ordering is obvious.
    private struct State {
        var header = CaptureHeader()
        var trailer: CaptureTrailer?
        var fileSize = 0
        var undecodableLines = 0

        // Sequence
        var packets = 0
        var previous: GnimuPacket?
        var previousT: Double?
        var firstT: Double?
        var lastT: Double?
        var firstITOW: UInt32?
        var lastITOW: UInt32?

        // Cadence
        var nominalMs: Double?
        var nominalChanges: [CaptureAnalysis.Summary.NominalChange] = []
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
        var cleanRunStartITOW: UInt32?
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
        var itowBackwards = 0, itowDuplicate = 0
        var firstITOWViolation: Double?
        var itowViolationExample: String?
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

        mutating func ingest(t: Double, packet: GnimuPacket) {
            packets += 1
            if firstT == nil {
                firstT = t
                firstITOW = packet.iTOW
                cleanRunStart = t
                cleanRunStartITOW = packet.iTOW
            }
            lastT = t
            lastITOW = packet.iTOW

            ingestQuality(t: t, packet: packet)
            ingestTransport(t: t, packet: packet)
            ingestCadence(t: t, packet: packet)
            ingestConsistency(t: t, packet: packet)
            ingestTrack(t: t, packet: packet)

            previous = packet
            previousT = t
        }

        // MARK: Quality

        private mutating func ingestQuality(t: Double, packet: GnimuPacket) {
            numSV.add(Double(packet.numSV))
            pDOP.add(packet.pDOP)
            hAcc.add(packet.hAcc)
            vAcc.add(packet.vAcc)
            fixTypeCounts[packet.fixType, default: 0] += 1

            sNumSV.add(t: t, value: Double(packet.numSV))
            sPDOP.add(t: t, value: packet.pDOP)
            sHAcc.add(t: t, value: packet.hAcc)
            sSpeed.add(t: t, value: packet.speedKmh)
            maxSpeedKmh = max(maxSpeedKmh, packet.speedKmh)

            let battery = packet.batteryPercent
            if batteryStart == nil { batteryStart = battery }
            if let last = batteryEnd, battery > last, packet.isCharging == false {
                // Charge rising while not charging is a reporting fault.
                batteryIncreases += 1
            }
            batteryEnd = battery
            if let was = wasCharging, was != packet.isCharging { chargingTransitions += 1 }
            wasCharging = packet.isCharging
        }

        // MARK: Transport

        private mutating func ingestTransport(t: Double, packet: GnimuPacket) {
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
            if let firstT, let firstITOW {
                let hostMs = (t - firstT) * 1000
                let deviceMs = Double(packet.iTOW) - Double(firstITOW)
                if deviceMs >= 0 {
                    let drift = hostMs - deviceMs
                    sDrift.add(t: t, value: drift)
                    maxDriftMs = max(maxDriftMs, abs(drift))
                }
            }
        }

        // MARK: Cadence

        private mutating func ingestCadence(t: Double, packet: GnimuPacket) {
            guard let previous, let prevT = previousT else { return }
            let deltaMs = Double(packet.iTOW) - Double(previous.iTOW)

            // Establish nominal from the first plausible interval, then adopt a
            // change only when a new standard period holds.
            if deltaMs > 0, let snapped = CaptureAnalyzer.snapToStandard(deltaMs) {
                if nominalMs == nil {
                    nominalMs = snapped
                } else if let current = nominalMs, current != snapped,
                          abs(deltaMs - snapped) <= snapped * 0.1 {
                    nominalChanges.append(.init(t: t,
                                                fromHz: 1000 / current,
                                                toHz: 1000 / snapped))
                    nominalMs = snapped
                }
            }
            guard let nominal = nominalMs else { return }

            if deltaMs > 0 {
                intervalHistogram[Int(deltaMs.rounded()), default: 0] += 1
                intervalStats.add(deltaMs)
                sFixRate.add(t: t, value: 1000 / deltaMs)
            }

            let arrivalGapMs = (t - prevT) * 1000
            switch CaptureAnalyzer.classify(deltaMs: deltaMs, nominalMs: nominal) {
            case .onCadence:
                onCadence += 1
                receivedIntervals += 1
            case .late:
                late += 1
                receivedIntervals += 1
            case .missed(let n):
                receivedIntervals += 1
                missedFixes += n
                sMissed.add(t: t, value: Double(n))
                noteGap(t: t, deviceGapMs: deltaMs, arrivalGapMs: arrivalGapMs,
                        missed: n, interruption: false, packet: packet, nominal: nominal)
                endCleanRun(endedAt: previous.iTOW, resumingAt: t, itow: packet.iTOW)
            case .interrupted:
                interruptions += 1
                sMissed.add(t: t, value: Double(Int(deltaMs / nominal) - 1))
                noteGap(t: t, deviceGapMs: deltaMs, arrivalGapMs: arrivalGapMs,
                        missed: 0, interruption: true, packet: packet, nominal: nominal)
                endCleanRun(endedAt: previous.iTOW, resumingAt: t, itow: packet.iTOW)
            case .anomalous:
                anomalous += 1
                // A duplicate or out-of-order timestamp is a device fault too.
                // Letting it slide would report the stretches either side of it
                // as one unbroken clean run.
                endCleanRun(endedAt: previous.iTOW, resumingAt: t, itow: packet.iTOW)
            }
            longestGapMs = max(longestGapMs, deltaMs)
        }

        /// The two-clock verdict. A device-side gap moves both clocks together;
        /// a transport stall moves only the host's.
        private mutating func noteGap(t: Double, deviceGapMs: Double, arrivalGapMs: Double,
                                      missed: Int, interruption: Bool,
                                      packet: GnimuPacket, nominal: Double) {
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

            svAtGaps.add(Double(packet.numSV))
            pdopAtGaps.add(packet.pDOP)

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
        private mutating func endCleanRun(endedAt lastGoodITOW: UInt32,
                                          resumingAt t: Double, itow: UInt32) {
            if let startITOW = cleanRunStartITOW, let start = cleanRunStart {
                let duration = (Double(lastGoodITOW) - Double(startITOW)) / 1000
                if duration > longestCleanRun {
                    longestCleanRun = duration
                    longestCleanRunStart = start
                }
            }
            cleanRunStart = t
            cleanRunStartITOW = itow
        }

        // MARK: Consistency

        private mutating func ingestConsistency(t: Double, packet: GnimuPacket) {
            if let previous {
                let delta = Double(packet.iTOW) - Double(previous.iTOW)
                if delta < 0 {
                    itowBackwards += 1
                    if firstITOWViolation == nil {
                        firstITOWViolation = t
                        itowViolationExample =
                            "iTOW went backwards: \(previous.iTOW) → \(packet.iTOW) ms"
                    }
                } else if delta == 0 {
                    itowDuplicate += 1
                    if firstITOWViolation == nil {
                        firstITOWViolation = t
                        itowViolationExample = "iTOW repeated: \(packet.iTOW) ms"
                    }
                }
            }

            // The packet reports both a time-of-week and a broken-out clock;
            // they should describe the same instant.
            if packet.dateTimeFlags & 0x03 != 0 {
                clockFieldSamples += 1
                let secondsOfDay = (Double(packet.iTOW) / 1000)
                    .truncatingRemainder(dividingBy: 86_400)
                let expected = (secondsOfDay - CaptureAnalyzer.gpsUtcLeapSeconds + 86_400)
                    .truncatingRemainder(dividingBy: 86_400)
                let actual = Double(packet.hour) * 3600 + Double(packet.minute) * 60
                    + Double(packet.second)
                var diff = abs(expected - actual)
                if diff > 43_200 { diff = 86_400 - diff }   // wrap at midnight
                if diff > 2 {
                    clockFieldMismatches += 1
                    if firstClockMismatch == nil {
                        firstClockMismatch = t
                        clockMismatchExample = String(
                            format: "iTOW implies %02d:%02d:%02.0f UTC, packet says %02d:%02d:%02d",
                            Int(expected / 3600), Int(expected.truncatingRemainder(
                                dividingBy: 3600) / 60),
                            expected.truncatingRemainder(dividingBy: 60),
                            Int(packet.hour), Int(packet.minute), Int(packet.second))
                    }
                }
            }

            // Distance covered between fixes against the speed the device
            // reported — two independently derived quantities that must agree.
            if let previous, previous.hasValidFix, packet.hasValidFix {
                let dtSeconds = (Double(packet.iTOW) - Double(previous.iTOW)) / 1000
                if dtSeconds > 0, dtSeconds < 2 {
                    let metres = CaptureAnalyzer.distance(previous.latitude, previous.longitude,
                                                          packet.latitude, packet.longitude)
                    distanceMetres += metres
                    let impliedSpeed = metres / dtSeconds
                    let reported = packet.groundSpeed
                    // Generous: GNSS position noise dominates at low speed, so
                    // only gross disagreement counts.
                    let allowance = max(packet.speedAccuracy * 5, 3.0) + reported * 0.5
                    speedSamples += 1
                    if abs(impliedSpeed - reported) > allowance {
                        speedMismatches += 1
                        if firstSpeedMismatch == nil {
                            firstSpeedMismatch = t
                            speedMismatchExample = String(
                                format: "position implies %.1f m/s, packet reports %.1f m/s",
                                impliedSpeed, reported)
                        }
                    }
                }
            }

            // At rest the accelerometer should read one gravity and the gyros
            // should read nothing — the cleanest IMU sanity test available.
            if packet.groundSpeed < CaptureAnalyzer.stationarySpeedMs {
                let magnitude = (packet.accelX * packet.accelX
                                 + packet.accelY * packet.accelY
                                 + packet.accelZ * packet.accelZ).squareRoot()
                restAccelStats.add(magnitude)
                let rotation = (packet.gyroX * packet.gyroX
                                + packet.gyroY * packet.gyroY
                                + packet.gyroZ * packet.gyroZ).squareRoot()
                restGyroStats.add(rotation)
            }

            var rangeProblem: String?
            if packet.latitude < -90 || packet.latitude > 90 {
                rangeProblem = String(format: "latitude %.6f out of range", packet.latitude)
            } else if packet.longitude < -180 || packet.longitude > 180 {
                rangeProblem = String(format: "longitude %.6f out of range", packet.longitude)
            } else if packet.headingOfMotion < -360 || packet.headingOfMotion > 360 {
                rangeProblem = String(format: "heading %.2f° out of range", packet.headingOfMotion)
            } else if packet.pDOP < 0 || packet.pDOP > 100 {
                rangeProblem = String(format: "pDOP %.2f out of range", packet.pDOP)
            } else if packet.batteryPercent > 100 {
                rangeProblem = "battery \(packet.batteryPercent)% out of range"
            } else if packet.numSV > 64 {
                rangeProblem = "\(packet.numSV) satellites is implausible"
            }
            if let rangeProblem {
                rangeViolations += 1
                if firstRangeViolation == nil {
                    firstRangeViolation = t
                    rangeViolationExample = rangeProblem
                }
            }
        }

        // MARK: Track

        private mutating func ingestTrack(t: Double, packet: GnimuPacket) {
            guard packet.hasValidFix else { return }
            trackCounter += 1
            guard trackCounter % trackStride == 0 else { return }
            track.append(TrackPoint(t: t, latitude: packet.latitude,
                                    longitude: packet.longitude,
                                    speedKmh: packet.movingSpeedKmh))
            // Halve the resolution rather than grow without bound, the same way
            // the series accumulators do.
            if track.count >= CaptureAnalyzer.maxTrackPoints {
                track = track.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
                trackStride *= 2
            }
        }

        // MARK: Finish

        mutating func finish(url: URL, analysisDuration: TimeInterval) -> CaptureAnalysis {
            // A session that never dropped a fix has its clean run still open.
            if let startITOW = cleanRunStartITOW, let lastITOW, let start = cleanRunStart {
                let duration = (Double(lastITOW) - Double(startITOW)) / 1000
                if duration > longestCleanRun {
                    longestCleanRun = duration
                    longestCleanRunStart = start
                }
            }
            if burstSize > 0 { burstSizes.append(burstSize) }

            sFixRate.finalize(); sMissed.finalize(); sNumSV.finalize(); sPDOP.finalize()
            sHAcc.finalize(); sArrival.finalize(); sSpeed.finalize(); sDrift.finalize()

            let hostDuration = (lastT ?? 0) - (firstT ?? 0)
            let deviceDuration = firstITOW.flatMap { first in
                lastITOW.map { (Double($0) - Double(first)) / 1000 }
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

            let itowFailures = itowBackwards + itowDuplicate
            checks.append(ConsistencyCheck(
                id: "itow-monotonic",
                title: "iTOW sequence",
                detail: "Time-of-week must increase on every fix; duplicates and backward steps indicate the device restated or reordered a fix.",
                status: itowFailures == 0 ? .pass : .fail,
                failures: itowFailures, samples: max(packets - 1, 0),
                firstFailureAt: firstITOWViolation, example: itowViolationExample))

            checks.append(ConsistencyCheck(
                id: "frame-integrity",
                title: "Frame integrity",
                detail: "Every line must hold a complete 88-byte frame with a valid RaceBox checksum.",
                status: undecodableLines == 0 ? .pass : (undecodableLines > packets / 100 ? .fail : .warn),
                failures: undecodableLines, samples: packets + undecodableLines,
                firstFailureAt: nil, example: nil))

            checks.append(ConsistencyCheck(
                id: "clock-fields",
                title: "Clock field agreement",
                detail: "The packet's broken-out UTC clock must match the instant its own iTOW describes, allowing for the 18-second GPS-UTC offset.",
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
