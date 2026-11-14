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

/// A snapshot of how a Gnimu-protocol stream is doing, recomputed once a second.
/// Judged from the frame header: the device's own clock and sequence number, not
/// when frames happened to arrive, so Bluetooth delivery jitter doesn't hide a
/// device problem and a real gap shows as one.
struct StreamHealthReading: Equatable {
    /// Frames per second by the device's clock. Zero when the stream has gone quiet.
    var hz: Double = 0
    /// The rate the device should be holding: its schema's, or failing that,
    /// what the stream itself shows.
    var nominalHz: Double?
    /// Frames the sequence number says were lost since the previous reading.
    var framesLost = 0
    /// Frames delivered again, since the previous reading.
    var duplicates = 0
    /// Times the device's clock went back (it restarted) since the previous reading.
    var restarts = 0
    /// How far the arrival spacing strays from the device's own spacing, on
    /// average, in ms. Delivery jitter and burst delivery, not a device fault.
    var arrivalJitterMs: Double?
    var status: FixRateStatus = .noData

    /// Totals since the connection opened.
    var sessionFrames = 0
    var sessionLost = 0
    var sessionDuplicates = 0
    var sessionRestarts = 0

    static let empty = StreamHealthReading()
}

/// Derives stream health from each frame's device time and sequence number.
struct StreamHealthTracker {

    // MARK: Tuning

    /// Rate is averaged over this much history, but never fewer than
    /// `minimumWindowFrames` frames, so a slow stream still has something to measure.
    private let windowDuration: TimeInterval = 2.0
    private let minimumWindowFrames = 8
    private let maximumWindowFrames = 128
    /// Frames needed before any rate is reported.
    private let minimumFrames = 4
    /// A forward gap in the sequence up to this many frames is loss. A bigger
    /// jump means the frame is out of order, not that 130 were lost.
    private let maximumLossRun = 128

    // MARK: State

    private var window: [(arrival: Date, deviceMs: Int64)] = []
    private var lastDeviceTime: Int32?
    private var lastSequence: UInt8?
    /// Device time accumulated across clock wraps, so the window is monotonic.
    private var unwrapped: Int64 = 0

    private var pendingFrames = 0
    private var pendingLost = 0
    private var pendingDuplicates = 0
    private var pendingRestarts = 0
    private var sessionFrames = 0
    private var sessionLost = 0
    private var sessionDuplicates = 0
    private var sessionRestarts = 0

    mutating func reset() {
        self = StreamHealthTracker()
    }

    // MARK: Ingest

    /// Records one frame: its device time and sequence byte, and when it arrived.
    mutating func record(deviceTimeMs: Int32, sequence: UInt8, at now: Date = Date()) {
        var restarted = false
        if let last = lastDeviceTime {
            // Wrapping subtraction, so the 2^31 ms clock wrap reads as a small
            // step forward. A big negative step is the device starting over.
            let delta = Int32(bitPattern: UInt32(bitPattern: deviceTimeMs) &- UInt32(bitPattern: last))
            if delta < 0 {
                restarted = true
                window.removeAll()
                unwrapped = 0
                pendingRestarts += 1
                sessionRestarts += 1
            } else {
                unwrapped += Int64(delta)
            }
        }
        lastDeviceTime = deviceTimeMs

        if restarted {
            lastSequence = sequence          // no loss to count across a restart
        } else if let previous = lastSequence {
            switch sequence &- previous {
            case 1:
                lastSequence = sequence
            case 0:
                pendingDuplicates += 1
                sessionDuplicates += 1
            case let step where Int(step) <= maximumLossRun:
                let lost = Int(step) - 1
                pendingLost += lost
                sessionLost += lost
                lastSequence = sequence
            default:
                break                        // out of order: leave the expectation alone
            }
        } else {
            lastSequence = sequence
        }

        window.append((now, unwrapped))
        pendingFrames += 1
        sessionFrames += 1
        trim(now: now)
    }

    private mutating func trim(now: Date) {
        while window.count > minimumWindowFrames,
              let first = window.first,
              now.timeIntervalSince(first.arrival) > windowDuration {
            window.removeFirst()
        }
        if window.count > maximumWindowFrames {
            window.removeFirst(window.count - maximumWindowFrames)
        }
    }

    // MARK: Evaluation

    /// The current reading, draining the per-second counters.
    /// - Parameter nominalHz: the rate the device declares, if it does.
    mutating func evaluate(nominalHz declared: Double?, now: Date = Date()) -> StreamHealthReading {
        trim(now: now)
        var reading = StreamHealthReading(
            framesLost: pendingLost, duplicates: pendingDuplicates, restarts: pendingRestarts,
            sessionFrames: sessionFrames, sessionLost: sessionLost,
            sessionDuplicates: sessionDuplicates, sessionRestarts: sessionRestarts)
        let framesSince = pendingFrames
        defer {
            pendingFrames = 0
            pendingLost = 0
            pendingDuplicates = 0
            pendingRestarts = 0
        }

        guard window.count >= minimumFrames,
              let first = window.first, let last = window.last,
              last.deviceMs > first.deviceMs else { return reading }

        let nominal = declared ?? inferredNominal()
        reading.nominalHz = nominal

        // Stop reporting a rate once frames stop arriving.
        let quietFor = now.timeIntervalSince(last.arrival)
        guard quietFor <= max(1.0, 3 / max(nominal ?? 1, 0.1)) else { return reading }

        let spanSeconds = Double(last.deviceMs - first.deviceMs) / 1000
        reading.hz = Double(window.count - 1) / spanSeconds
        reading.arrivalJitterMs = arrivalJitter()

        guard let nominal, nominal > 0 else {
            reading.status = .onRate
            return reading
        }
        let ratio = reading.hz / nominal
        let expected = framesSince + reading.framesLost
        let lossFraction = expected > 0 ? Double(reading.framesLost) / Double(expected) : 0
        if ratio < 0.90 || lossFraction > 0.10 {
            reading.status = .offRate
        } else if reading.framesLost > 0 || reading.restarts > 0 || ratio < 0.98 {
            reading.status = .degraded
        } else {
            reading.status = .onRate
        }
        return reading
    }

    /// The rate the stream itself shows, from its most common spacing.
    private func inferredNominal() -> Double? {
        guard window.count >= minimumWindowFrames else { return nil }
        var counts: [Int64: Int] = [:]
        for i in 1..<window.count { counts[window[i].deviceMs - window[i - 1].deviceMs, default: 0] += 1 }
        guard let (mode, count) = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              mode > 0, Double(count) / Double(window.count - 1) >= 0.6 else { return nil }
        return 1000 / Double(mode)
    }

    /// Mean difference between how far apart frames arrived and how far apart
    /// the device says it sent them.
    private func arrivalJitter() -> Double? {
        guard window.count >= 2 else { return nil }
        var total = 0.0
        for i in 1..<window.count {
            let arrival = window[i].arrival.timeIntervalSince(window[i - 1].arrival) * 1000
            let device = Double(window[i].deviceMs - window[i - 1].deviceMs)
            total += abs(arrival - device)
        }
        return total / Double(window.count - 1)
    }
}

/// How often each vehicle channel's value changes, per second, over the last few
/// seconds. A fixed-rate frame repeats the latest value of every channel, so the
/// frame rate says nothing about how often the car is really being asked; value
/// changes are the nearest honest measure. A channel that holds steady (coolant
/// temperature, say) shows zero: that's a steady value, not a dead channel.
struct ChannelChangeTracker {
    private let windowSeconds: TimeInterval = 5
    private var lastValue: [String: Double] = [:]
    private var changes: [String: [Date]] = [:]
    private var firstRecordedAt: Date?

    mutating func reset() { self = ChannelChangeTracker() }

    /// Records the valid channel values of one frame, by channel key. A channel
    /// not in `values` is not valid right now; it isn't a change, and when it
    /// comes back with the value it had before, that isn't either.
    mutating func record(_ values: [String: Double], at now: Date = Date()) {
        if firstRecordedAt == nil { firstRecordedAt = now }
        for (key, value) in values {
            if let last = lastValue[key] {
                if last != value { changes[key, default: []].append(now) }
            } else {
                changes[key, default: []].append(now)    // the channel appeared
            }
            lastValue[key] = value
        }
        let cutoff = now.addingTimeInterval(-windowSeconds)
        for (key, times) in changes {
            if let firstKept = times.firstIndex(where: { $0 >= cutoff }) {
                if firstKept > 0 { changes[key] = Array(times[firstKept...]) }
            } else {
                changes[key] = []
            }
        }
    }

    /// Changes per second for each channel seen, over the window (or, in the
    /// first few seconds, over the time since recording began).
    func rates(now: Date = Date()) -> [String: Double] {
        guard let first = firstRecordedAt else { return [:] }
        let span = min(windowSeconds, max(now.timeIntervalSince(first), 0.5))
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var out: [String: Double] = [:]
        for key in lastValue.keys {
            let count = (changes[key] ?? []).filter { $0 >= cutoff }.count
            out[key] = Double(count) / span
        }
        return out
    }
}
