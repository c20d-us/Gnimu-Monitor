# Proposal: the capture analyzer can't see single missed fixes at 20 Hz or 10 Hz

Status: proposed, not implemented. Scope: `CaptureAnalyzer.swift` only.

## Summary

The report for `Gnimu-2026-09-20-122352.jsonl` (70 min, RaceBox Mini
1000000002, 20 Hz) says **12 missed fixes**. The real number is **73**. Every
single-fix drop, meaning an iTOW delta of exactly 2× nominal, is silently counted
as on-cadence. This hides the most common failure a GNSS receiver has: skipping
one epoch.

The live `FixRateTracker` isn't affected. So the report currently *does*
contradict the live panel, even though the analyzer's header comment promises
the opposite.

## Root cause

`State.ingestCadence(t:packet:)` updates the nominal period **before**
classifying the interval, and it lets any single interval that lands on a
standard period change the nominal:

```swift
if deltaMs > 0, let snapped = CaptureAnalyzer.snapToStandard(deltaMs) {
    if nominalMs == nil {
        nominalMs = snapped
    } else if let current = nominalMs, current != snapped,
              abs(deltaMs - snapped) <= snapped * 0.1 {
        nominalChanges.append(...)
        nominalMs = snapped          // <- one interval is enough
    }
}
guard let nominal = nominalMs else { return }
...
switch CaptureAnalyzer.classify(deltaMs: deltaMs, nominalMs: nominal) {   // <- classified against the new nominal
```

At 20 Hz a dropped fix gives a 100 ms delta. That is exactly the 10 Hz
standard period, so the sequence is:

1. The 100 ms delta snaps to 100 and passes the 10% check. The nominal becomes 100 ms.
2. It's then classified against 100 ms, so it counts as `.onCadence`. The miss is lost.
3. The next 50 ms delta snaps back. The nominal returns to 50 ms.

The same thing happens at 10 Hz, where one drop gives 200 ms, the 5 Hz period.
It doesn't happen at 25 Hz: 80 ms snaps to 100 but fails the 10% check. It
doesn't happen at 5 Hz or 1 Hz either, because 400 ms and 2000 ms aren't
standard periods.

Double or larger drops (150 ms, 250 ms) aren't standard periods, so they are
still counted. That's why the report shows 12 rather than zero.

### Knock-on effects in the same report

Every field downstream of the classification is wrong in the same direction:

| Report field | Reported | Correct |
|---|---|---|
| Missed fixes | 12 | 73 |
| Expected packets | 84,384 | 84,445 |
| Longest clean run | 45:08 | 16:08 |
| Gaps table rows | 5 | 66 |
| `nominalChanges` recorded | 122 (spurious, two per drop) | 0 |
| SV / pDOP "at gaps" | based on 5 gaps | based on 66 gaps |

The Missed-fixes chart, the gap attribution counts and the clean-run marker are
also affected. `nominalChanges` isn't rendered anywhere at the moment, which is
why 122 spurious rate changes never showed up.

The "correct" column comes from a Python port of the analyzer's cadence logic,
run on the capture. The port reproduces the current report exactly (12 missed,
45:08 clean run), which confirms it is a faithful port. The "correct" figures
also agree with an independent count, (last iTOW − first iTOW) / 50 + 1 −
received = 73.

## Proposed change

A new nominal should only be adopted after it **holds for a run of consecutive
intervals**. Until the run completes, its intervals are held back rather than
classified. Then:

- **The run completes:** the rate really changed. Adopt the new nominal and
  classify the held intervals against it, so they come out on-cadence and none
  are counted as misses.
- **The run breaks:** it was a drop, not a rate change. Classify the held
  intervals against the current nominal, so a lone 100 ms counts as `.missed(1)`.

Captures that start unseeded work the same way. Everything is held until the
first run completes, and then the whole prefix is classified against that
nominal. This also fixes a smaller hidden version of the bug: today a capture
whose very first interval is a drop starts at the wrong nominal.

### Constant

```swift
/// Consecutive intervals a new standard period must hold before it replaces
/// the nominal. A single dropped fix at 20 Hz or 10 Hz lands exactly on the
/// next standard period (100 / 200 ms), so one interval proves nothing.
private static let nominalConfirmIntervals = 20
```

20 intervals is one second at 20 Hz. In the 2026-09-20 capture the longest run
of consecutive 100 ms deltas is 1, so the margin is very large. A real rate
change is a clean switch on the device, so it confirms within a second.

### State additions

```swift
/// Intervals whose classification waits on the nominal being settled.
struct PendingInterval {
    let t: Double
    let deltaMs: Double
    let arrivalGapMs: Double
    let previousITOW: UInt32
    let packet: GnimuPacket
}
var pending: [PendingInterval] = []
var candidateMs: Double?
var candidateRun = 0
var candidateStartT = 0.0
```

### `ingestCadence` restructured

The parts of `ingestCadence` that don't depend on the nominal stay where they
are: the histogram, `intervalStats`, `sFixRate` and `longestGapMs`. The nominal
block and the classification switch are replaced as follows:

```swift
private mutating func ingestCadence(t: Double, packet: GnimuPacket) {
    guard let previous, let prevT = previousT else { return }
    let deltaMs = Double(packet.iTOW) - Double(previous.iTOW)

    if deltaMs > 0 {
        intervalHistogram[Int(deltaMs.rounded()), default: 0] += 1
        intervalStats.add(deltaMs)
        sFixRate.add(t: t, value: 1000 / deltaMs)
    }
    longestGapMs = max(longestGapMs, deltaMs)

    settleNominal(PendingInterval(t: t, deltaMs: deltaMs,
                                  arrivalGapMs: (t - prevT) * 1000,
                                  previousITOW: previous.iTOW, packet: packet))
}

/// Holds intervals back while a different standard period is proving itself,
/// so a single dropped fix can't redefine the nominal it should be judged by.
private mutating func settleNominal(_ interval: PendingInterval) {
    let onStandard = interval.deltaMs > 0
        ? CaptureAnalyzer.snapToStandard(interval.deltaMs)
            .flatMap { abs(interval.deltaMs - $0) <= $0 * 0.1 ? $0 : nil }
        : nil

    guard let period = onStandard, period != nominalMs else {
        // Not a new period, so any held run was just a drop. Once a nominal
        // exists, everything held belongs to it.
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

private mutating func flushPending() {
    guard let nominal = nominalMs else { return }
    for interval in pending { classify(interval, nominal: nominal) }
    pending.removeAll(keepingCapacity: true)
}

/// The existing classification switch, moved here unchanged apart from
/// reading its inputs from the held interval.
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
                missed: n, interruption: false, packet: iv.packet, nominal: nominal)
        endCleanRun(endedAt: iv.previousITOW, resumingAt: iv.t, itow: iv.packet.iTOW)
    case .interrupted:
        interruptions += 1
        sMissed.add(t: iv.t, value: Double(Int(iv.deltaMs / nominal) - 1))
        noteGap(t: iv.t, deviceGapMs: iv.deltaMs, arrivalGapMs: iv.arrivalGapMs,
                missed: 0, interruption: true, packet: iv.packet, nominal: nominal)
        endCleanRun(endedAt: iv.previousITOW, resumingAt: iv.t, itow: iv.packet.iTOW)
    case .anomalous:
        anomalous += 1
        endCleanRun(endedAt: iv.previousITOW, resumingAt: iv.t, itow: iv.packet.iTOW)
    }
}
```

### `finish()`

Call `flushPending()` before the summary is built. Otherwise a capture that ends
partway through a candidate run loses up to 19 intervals from its counts.

Ordering is safe. Held intervals add their `sMissed` points up to 19 intervals
late, but with their own `t`, and `TimeSeries.add` places each value in a bucket
by `t`, so arrival order doesn't matter. The gap list and the clean-run
tracking are also fed strictly in iTOW order, because the flush always runs
oldest first and nothing else classifies in between.

## What doesn't change

- **`FixRateTracker`**: it already adopts a new nominal only when it holds a
  60% majority in two consecutive evaluations, so the live panel never had
  this bug.
- **`classify(deltaMs:nominalMs:)`, the tolerances, `snapToStandard`**: all as
  they are. The bug is in *when* the nominal moves, not in how an interval is
  judged.
- **Memory**: `pending` holds at most `nominalConfirmIntervals` intervals once
  seeded. Unseeded, it holds only until the first run of 20, which is the start
  of any capture.

## Tests to add

A captured-frame fixture isn't needed for these. A synthetic iTOW stream is
enough:

| Stream | Missed now | Missed after |
|---|---|---|
| 20 Hz, 400 intervals, 3 single drops (100 ms) | 0 | 3 |
| 10 Hz, 400 intervals, 2 single drops (200 ms) | 0 | 2 |
| 25 Hz, 400 intervals, 2 single drops (80 ms) | 2 | 2 (regression guard) |
| 20 Hz for 300, then 10 Hz for 300, no drops | 0 | 0, and exactly one `nominalChanges` entry |
| First interval is a 100 ms drop, then 20 Hz | nominal starts at 100 | 1 missed, nominal 20 Hz from the start |
| Capture ends 5 intervals into a 10 Hz run | n/a | those 5 counted as 1 missed each (never confirmed) |

The "Missed now" column is from the Python port of the current logic. Also
re-run the analyzer on `Gnimu-2026-09-20-122352.jsonl` and expect the
corrected column of the knock-on effects table above.

## Alternatives considered

- **Fix the nominal once for the whole capture and drop `nominalChanges`.**
  This is simpler, but a real mid-capture rate change would then report every
  interval as a drop, for example 50% missed after a 20 → 10 Hz switch. That
  failure is loud but wrong. The held-run approach costs about 40 lines to get
  it right.
- **Seed the nominal from the header's `capture.nominalHz`.** This helps only
  with the start-of-capture case, which the held prefix already covers. It also
  trusts a value the live tracker inferred, rather than one measured from the
  file. Not needed.
- **Classify against the pre-update nominal, then update.** This fixes the
  single interval, but the next 50 ms delta would then be classified against
  100 ms as `.anomalous`, and the nominal would still flap 122 times.
