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

/// Turns a finished analysis into a shareable file.
///
/// The analysis model holds every number; a renderer only decides how to show
/// them. Swapping this out — Markdown now, HTML next, PDF later — can't change
/// what the report says.
nonisolated protocol ReportRenderer: Sendable {
    var fileExtension: String { get }
    func render(_ analysis: CaptureAnalysis) throws -> Data
}

/// Interim renderer: a plain-text summary so the pipeline works end to end.
/// The HTML renderer replaces this and will carry the charts.
nonisolated struct MarkdownReportRenderer: ReportRenderer {
    let fileExtension = "md"

    func render(_ a: CaptureAnalysis) throws -> Data {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }
        func row(_ label: String, _ value: String) { line("| \(label) | \(value) |") }

        let s = a.summary
        line("# Capture Analysis")
        line()
        line("**\(a.source.deletingPathExtension().lastPathComponent)**")
        line()
        if let started = a.header.startedAt {
            line("Recorded \(started.formatted(date: .abbreviated, time: .standard))")
            line()
        }

        line("## Summary")
        line()
        line("| | |")
        line("|---|---|")
        row("Packets received", s.packetsReceived.formatted())
        row("Expected", s.expectedPackets.formatted())
        row("Missed fixes", s.missedFixes.formatted())
        row("Error rate", String(format: "%.2f%%", s.errorRate))
        row("Nominal rate", s.nominalHz.map { String(format: "%g Hz", $0) } ?? "—")
        row("Mean rate", String(format: "%.2f Hz", s.meanHz))
        row("Duration (device clock)", format(duration: s.deviceDuration))
        row("Duration (host clock)", format(duration: s.hostDuration))
        row("Longest clean run", format(duration: s.longestCleanRun))
        row("Interruptions", s.interruptions.formatted())
        row("Late intervals", s.lateIntervals.formatted())
        row("Out-of-sequence intervals", s.anomalousIntervals.formatted())
        row("Longest gap", String(format: "%.0f ms", s.longestGapMs))
        if s.wasInterrupted { row("Capture", "**Interrupted — no summary line**") }
        line()

        line("## Transport vs. device")
        line()
        line("| | |")
        line("|---|---|")
        let t = a.transport
        row("Arrival interval (median)", String(format: "%.1f ms", t.arrivalDeltaMs.median))
        row("Arrival interval (p95)", String(format: "%.1f ms", t.arrivalDeltaMs.quantile(0.95)))
        row("Arrival interval (max)", String(format: "%.1f ms", t.arrivalDeltaMs.max))
        row("Host/device clock ratio", t.clockRatio.map { String(format: "%.6f", $0) } ?? "—")
        row("Clock drift", t.clockDriftPPM.map { String(format: "%.0f ppm", $0) } ?? "—")
        row("Max divergence", String(format: "%.0f ms", t.maxDriftMs))
        row("Mean burst size", String(format: "%.1f packets", t.meanBurstSize))
        row("Largest burst", "\(t.maxBurstSize) packets")
        line()
        if !t.attribution.isEmpty {
            line("Gap attribution:")
            line()
            for (kind, count) in t.attribution.sorted(by: { $0.value > $1.value }) {
                line("- \(kind.label): \(count)")
            }
            line()
        }

        line("## GNSS quality")
        line()
        line("| | |")
        line("|---|---|")
        let g = a.gnss
        row("Satellites", String(format: "%.1f mean (%.0f–%.0f)", g.numSV.mean, g.numSV.min, g.numSV.max))
        row("pDOP", String(format: "%.2f mean, %.2f p95", g.pDOP.mean, g.pDOP.quantile(0.95)))
        row("Horizontal accuracy", String(format: "%.2f m mean, %.2f m p95", g.hAcc.mean, g.hAcc.quantile(0.95)))
        if let sv = g.meanSVAtGaps {
            row("Satellites at gaps", String(format: "%.1f (vs %.1f overall)", sv, g.numSV.mean))
        }
        if let pdop = g.meanPDOPAtGaps {
            row("pDOP at gaps", String(format: "%.2f (vs %.2f overall)", pdop, g.pDOP.mean))
        }
        row("Distance", String(format: "%.2f km", g.distanceMetres / 1000))
        row("Max speed", String(format: "%.1f km/h", g.maxSpeedKmh))
        if let b0 = g.batteryStart, let b1 = g.batteryEnd { row("Battery", "\(b0)% → \(b1)%") }
        line()

        line("## Consistency checks")
        line()
        line("| Check | Result | Detail |")
        line("|---|---|---|")
        for check in a.checks {
            let mark: String
            switch check.status {
            case .pass: mark = "PASS"
            case .warn: mark = "WARN"
            case .fail: mark = "FAIL"
            case .notApplicable: mark = "n/a"
            }
            var detail = check.example ?? check.detail
            if check.failures > 0 {
                detail = "\(check.failures.formatted()) of \(check.samples.formatted()) — \(detail)"
            }
            row3(&out, check.title, mark, detail)
        }
        line()

        line("## Session")
        line()
        line("| | |")
        line("|---|---|")
        row("Device", a.header.deviceName ?? "—")
        row("App", dash([a.header.appVersion, a.header.appBuild]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " build ")))
        row("Host", dash([a.header.hostModel, a.header.hostSystemVersion]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
        row("Low power mode", a.header.lowPowerMode.map { $0 ? "**on**" : "off" } ?? "—")
        row("Thermal state", a.header.thermalState ?? "—")
        row("Capture size", ByteCountFormatter.string(fromByteCount: Int64(a.fileSize), countStyle: .file))
        row("Analysis took", String(format: "%.2f s", a.analysisDuration))
        line()

        guard let data = out.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    private func row3(_ out: inout String, _ a: String, _ b: String, _ c: String) {
        // Pipes inside a cell would break the table.
        let safe = c.replacingOccurrences(of: "|", with: "\\|")
        out += "| \(a) | \(b) | \(safe) |\n"
    }

    /// Empty is not the same as zero — say so rather than printing a blank.
    private func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

    private func format(duration: TimeInterval) -> String {
        guard duration > 0 else { return "—" }
        let total = Int(duration)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
