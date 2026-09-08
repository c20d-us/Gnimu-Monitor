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

/// Renders an analysis as one self-contained HTML file.
///
/// Everything is inline — no CDN, no vendored library, nothing to fetch. The
/// charts are SVG drawn by a small amount of hand-written JavaScript, which
/// keeps the file dependency-free and vector-clean for the eventual print/PDF
/// path.
nonisolated struct HTMLReportRenderer: ReportRenderer {
    let fileExtension = "html"

    func render(_ a: CaptureAnalysis) throws -> Data {
        let payload = try Self.payload(for: a)
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(a.source.deletingPathExtension().lastPathComponent)) — Capture Analysis</title>
        <style>
        \(Self.css)
        </style>
        </head>
        <body>
        \(Self.body(a))
        <script>
        const REPORT = \(payload);
        \(Self.js)
        </script>
        </body>
        </html>
        """
        guard let data = html.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    // MARK: - Escaping

    private func esc(_ s: String) -> String { Self.esc(s) }

    fileprivate static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Data payload

    /// Series and gap data for the charts, as JSON embedded in the page.
    private static func payload(for a: CaptureAnalysis) throws -> String {
        func series(_ s: TimeSeries) -> [String: Any] {
            [
                "name": s.name,
                "unit": s.unit,
                "points": s.buckets.map { [
                    round($0.t, 3), round($0.min, 4), round($0.max, 4), round($0.mean, 4)
                ] }
            ]
        }

        let histogram = a.cadence.intervalHistogramMs
            .sorted { $0.key < $1.key }
            .map { [$0.key, $0.value] }

        let object: [String: Any] = [
            "duration": round(max(a.summary.hostDuration, 1), 3),
            "nominalHz": a.summary.nominalHz as Any,
            "series": [
                "fixRate": series(a.series.fixRateHz),
                "missed": series(a.series.missedFixes),
                "numSV": series(a.series.numSV),
                "pDOP": series(a.series.pDOP),
                "hAcc": series(a.series.hAcc),
                "arrival": series(a.series.arrivalDeltaMs),
                "speed": series(a.series.speedKmh),
                "drift": series(a.series.clockDriftMs)
            ],
            "histogram": histogram,
            "gaps": a.cadence.gaps.prefix(200).map {
                [
                    "t": round($0.t, 2),
                    "device": round($0.deviceGapMs, 1),
                    "arrival": round($0.arrivalGapMs, 1),
                    "missed": $0.missedFixes,
                    "interruption": $0.isInterruption,
                    "attribution": $0.attribution.label
                ]
            },
            "track": a.track.map { [round($0.latitude, 6), round($0.longitude, 6),
                                    round($0.speedKmh, 1)] }
        ]

        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Trims float noise so the embedded JSON doesn't carry 17 digits per value.
    private static func round(_ v: Double, _ places: Int) -> Double {
        guard v.isFinite else { return 0 }
        let f = pow(10.0, Double(places))
        return (v * f).rounded() / f
    }
}

// MARK: - Stylesheet

extension HTMLReportRenderer {

    /// Light and dark are both defined up front; the print block strips the
    /// interactive chrome and forces a paper palette, so the eventual PDF
    /// conversion is a print of this same page rather than a rewrite.
    static let css = """
    :root {
      --bg: #f6f7f9; --panel: #ffffff; --ink: #14161a; --muted: #5b626e;
      --faint: #8b93a1; --line: #dfe3e9; --accent: #0a68d0;
      --pass: #1a7f4b; --warn: #a8690a; --fail: #c0392b; --grid: #eceff3;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #14161a; --panel: #1c1f25; --ink: #eef1f5; --muted: #a2abba;
        --faint: #737d8c; --line: #2b3038; --accent: #63a9f5;
        --pass: #48c98a; --warn: #e0a94a; --fail: #ef7365; --grid: #262b33;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--ink);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-text-size-adjust: 100%;
    }
    .wrap { max-width: 1180px; margin: 0 auto; padding: 24px 20px 64px; }

    header.top h1 { font-size: 24px; margin: 0 0 4px; letter-spacing: -0.01em; }
    header.top .sub { color: var(--muted); font-size: 14px; }

    .verdict {
      display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;
      padding: 14px 16px; border-radius: 10px; margin: 18px 0 24px;
      border: 1px solid var(--line); border-left-width: 4px; background: var(--panel);
    }
    .verdict.pass { border-left-color: var(--pass); }
    .verdict.warn { border-left-color: var(--warn); }
    .verdict.fail { border-left-color: var(--fail); }
    .verdict .title { font-weight: 650; font-size: 16px; }
    .verdict.pass .title { color: var(--pass); }
    .verdict.warn .title { color: var(--warn); }
    .verdict.fail .title { color: var(--fail); }
    .verdict .detail { color: var(--muted); font-size: 14px; }

    section { margin: 28px 0; }
    section > h2 {
      font-size: 13px; text-transform: uppercase; letter-spacing: 0.07em;
      color: var(--faint); margin: 0 0 12px; font-weight: 650;
    }

    /* Six across on a wide page so the summary reads as one band, stepping
       down rather than reflowing into a ragged 4 + 2. */
    .cards { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 12px; }
    @media (max-width: 1080px) { .cards { grid-template-columns: repeat(3, minmax(0, 1fr)); } }
    @media (max-width: 620px)  { .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
    .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
    .card .v { font-size: 23px; font-weight: 620; letter-spacing: -0.02em;
               font-variant-numeric: tabular-nums; white-space: nowrap; }
    .card .k { color: var(--muted); font-size: 12px; margin-top: 3px; }
    .card .n { color: var(--faint); font-size: 11px; margin-top: 2px; }

    table { width: 100%; border-collapse: collapse; background: var(--panel);
            border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
    th, td { text-align: left; padding: 9px 14px; border-bottom: 1px solid var(--line);
             font-size: 14px; vertical-align: top; }
    th { color: var(--muted); font-weight: 600; font-size: 12px;
         text-transform: uppercase; letter-spacing: 0.05em; }
    tr:last-child td { border-bottom: none; }
    td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
    td.k { color: var(--muted); width: 42%; }

    .status { font-weight: 650; font-size: 12px; letter-spacing: 0.04em; white-space: nowrap; }
    .status.pass { color: var(--pass); }
    .status.warn { color: var(--warn); }
    .status.fail { color: var(--fail); }
    .status.na { color: var(--faint); }

    .chart { background: var(--panel); border: 1px solid var(--line);
             border-radius: 10px; padding: 12px 14px 6px; margin-bottom: 12px; }
    .chart h3 { margin: 0 0 2px; font-size: 14px; font-weight: 620; }
    .chart .cap { color: var(--faint); font-size: 12px; margin-bottom: 6px; }
    .chart svg { display: block; width: 100%; height: auto; touch-action: pan-y; }
    .axis { stroke: var(--line); }
    .gridline { stroke: var(--grid); }
    .tick { fill: var(--faint); font-size: 10px; }

    .toolbar { position: sticky; top: 0; z-index: 5; display: flex; gap: 10px;
               align-items: center; padding: 10px 0; background: var(--bg);
               border-bottom: 1px solid var(--line); margin-bottom: 16px; flex-wrap: wrap; }
    .toolbar .hint { color: var(--faint); font-size: 12px; }
    button { font: inherit; font-size: 13px; padding: 5px 12px; border-radius: 7px;
             border: 1px solid var(--line); background: var(--panel); color: var(--ink); cursor: pointer; }
    button:hover { border-color: var(--accent); color: var(--accent); }

    .note { color: var(--muted); font-size: 13px; margin-top: 8px; }
    .scroll { overflow-x: auto; }
    footer { color: var(--faint); font-size: 12px; margin-top: 40px;
             border-top: 1px solid var(--line); padding-top: 14px; }

    /* Print: paper palette, no interactive chrome, sections kept whole. The PDF
       path is a print of this page, so this block is the PDF layout. */
    @media print {
      :root {
        --bg: #fff; --panel: #fff; --ink: #000; --muted: #333; --faint: #555;
        --line: #bbb; --grid: #e4e4e4;
        --pass: #14663c; --warn: #7a4c06; --fail: #96271b; --accent: #14448c;
      }
      /* Landscape: the report is a wide document — six summary cards in a row
         and full-width charts — and portrait forces both to reflow. The app
         also sets this natively (NSPrintInfo/UIPrintInfo); declaring it here
         too is what makes printing from a browser match. */
      @page { size: landscape; margin: 12mm; }
      body { font-size: 11px; }
      /* Do not remove this asymmetric padding, and do not "balance" it.
         macOS trims a fixed sliver off the right edge when rasterising a print
         job, even though the page geometry is correct — measured ink stops well
         inside the margin — and iOS prints the same document intact. Pulling
         the content left gives the trim empty space to eat, which was confirmed
         to fix it. It works because the trim is a fixed size rather than
         proportional: scale-related padding would be cropped along with
         everything else. Only needed for macOS; harmless elsewhere. */
      .wrap { max-width: none; padding: 0 5mm 0 0; }
      .cards { grid-template-columns: repeat(6, minmax(0, 1fr)); }
      .toolbar { display: none !important; }
      section { break-inside: avoid; margin: 14px 0; }
      #sec-transport, #sec-gnss { break-before: page; }
      .chart { break-inside: avoid; }
      header.top h1 { font-size: 18px; }
      .card .v { font-size: 17px; }
    }
    """
}

// MARK: - Document body

extension HTMLReportRenderer {

    static func body(_ a: CaptureAnalysis) -> String {
        let s = a.summary
        var out = "<div class=\"wrap\">"

        // Header
        out += "<header class=\"top\"><h1>\(esc(a.source.deletingPathExtension().lastPathComponent))</h1>"
        var subParts: [String] = []
        if let started = a.header.startedAt {
            let df = DateFormatter()
            df.dateStyle = .medium; df.timeStyle = .medium
            subParts.append(df.string(from: started))
        }
        if let device = a.header.deviceName { subParts.append(esc(device)) }
        subParts.append(byteText(a.fileSize))
        out += "<div class=\"sub\">\(subParts.joined(separator: " · "))</div></header>"

        out += verdict(a)
        out += toolbar()
        out += summaryCards(a)
        out += cadenceSection(a)
        out += transportSection(a)
        out += gnssSection(a)
        out += checksSection(a)
        out += gapsSection(a)
        out += trackSection(a)
        out += sessionSection(a)

        out += "<footer>Generated by Gnimu Monitor from "
        out += "\(esc(a.source.lastPathComponent)) · analysis took "
        out += String(format: "%.2f s", a.analysisDuration)
        out += "</footer></div>"
        return out
    }

    // MARK: Verdict

    /// One sentence at the top saying whether the device behaved, because a
    /// reader who reads nothing else should still learn the answer.
    private static func verdict(_ a: CaptureAnalysis) -> String {
        let s = a.summary
        let failed = a.checks.filter { $0.status == .fail }
        let warned = a.checks.filter { $0.status == .warn }

        let level: String
        let title: String
        var detail: [String] = []

        if !failed.isEmpty || s.errorRate > 1 {
            level = "fail"
            title = "Problems found"
        } else if !warned.isEmpty || s.missedFixes > 0 || s.interruptions > 0 {
            level = "warn"
            title = "Mostly healthy"
        } else {
            level = "pass"
            title = "Clean capture"
        }

        detail.append(s.missedFixes == 0
            ? "No fixes missed across \(s.expectedPackets.formatted()) expected."
            : "\(s.missedFixes.formatted()) of \(s.expectedPackets.formatted()) fixes missed "
              + String(format: "(%.2f%%).", s.errorRate))
        if s.interruptions > 0 {
            detail.append("\(s.interruptions) stream interruption\(s.interruptions == 1 ? "" : "s").")
        }
        if !failed.isEmpty {
            detail.append("Failed: " + failed.map { $0.title.lowercased() }.joined(separator: ", ") + ".")
        }
        if s.wasInterrupted {
            detail.append("The capture itself was interrupted rather than stopped.")
        }

        return """
        <div class="verdict \(level)">
          <span class="title">\(title)</span>
          <span class="detail">\(esc(detail.joined(separator: " ")))</span>
        </div>
        """
    }

    private static func toolbar() -> String {
        """
        <div class="toolbar">
          <button onclick="resetZoom()">Reset zoom</button>
          <button onclick="printReport()">Print / Save PDF</button>
          <span class="hint">Drag across any chart to zoom the shared time axis · double-click to reset</span>
        </div>
        """
    }

    // MARK: Summary

    private static func summaryCards(_ a: CaptureAnalysis) -> String {
        let s = a.summary
        func card(_ value: String, _ key: String, _ note: String? = nil) -> String {
            var h = "<div class=\"card\"><div class=\"v\">\(esc(value))</div>"
            h += "<div class=\"k\">\(esc(key))</div>"
            if let note { h += "<div class=\"n\">\(esc(note))</div>" }
            return h + "</div>"
        }

        var cards = ""
        cards += card(s.packetsReceived.formatted(), "Packets received",
                      "of \(s.expectedPackets.formatted()) expected")
        cards += card(String(format: "%.2f%%", s.errorRate), "Error rate",
                      "\(s.missedFixes.formatted()) missed")
        cards += card(duration(s.longestCleanRun), "Longest clean run", "no missed or late fixes")
        cards += card(s.nominalHz.map { String(format: "%g Hz", $0) } ?? "—", "Nominal rate",
                      String(format: "%.2f Hz mean", s.meanHz))
        cards += card(duration(s.deviceDuration), "Duration", "device clock")
        cards += card(s.interruptions.formatted(), "Interruptions",
                      s.longestGapMs > 0 ? String(format: "longest gap %.0f ms", s.longestGapMs) : nil)

        return "<section><h2>Summary</h2><div class=\"cards\">\(cards)</div></section>"
    }

    // MARK: Cadence

    private static func cadenceSection(_ a: CaptureAnalysis) -> String {
        var out = "<section><h2>Fix cadence</h2>"
        out += chart(id: "fixRate", title: "Fix rate",
                     caption: "Shaded band is the min–max within each bucket; the line is the mean.")
        out += chart(id: "missed", title: "Missed fixes",
                     caption: "Where fixes went missing. Clustering matters more than the total — an even scatter and a single burst mean very different things.")
        out += chart(id: "histogram", title: "Interval distribution",
                     caption: "iTOW deltas. A healthy device is one spike at nominal; spikes at whole multiples are discrete drops, and a smear means the device is bogging.")
        out += "</section>"
        return out
    }

    // MARK: Transport

    private static func transportSection(_ a: CaptureAnalysis) -> String {
        let t = a.transport
        var out = "<section id=\"sec-transport\"><h2>Transport vs. device</h2>"
        out += "<p class=\"note\">Every packet carries two clocks — the device's own iTOW and the host's arrival time. "
        out += "Comparing them separates fixes the device never produced from fixes it produced but couldn't deliver.</p>"

        if !t.attribution.isEmpty {
            out += "<div class=\"scroll\"><table><tr><th>Gap attribution</th><th>Count</th></tr>"
            for (kind, count) in t.attribution.sorted(by: { $0.value > $1.value }) {
                out += "<tr><td>\(esc(kind.label))</td><td class=\"num\">\(count.formatted())</td></tr>"
            }
            out += "</table></div>"
        }

        out += chart(id: "arrival", title: "Arrival interval",
                     caption: "Host-side delivery spacing. Bunching is normal — BLE delivers several packets per connection interval.")
        out += chart(id: "drift", title: "Host clock minus device clock",
                     caption: "Divergence between the two clocks. A steady slope is a clock-rate error; steps are buffering.")

        out += "<div class=\"scroll\"><table>"
        out += row("Arrival interval median", String(format: "%.1f ms", t.arrivalDeltaMs.median))
        out += row("Arrival interval p95", String(format: "%.1f ms", t.arrivalDeltaMs.quantile(0.95)))
        out += row("Arrival interval max", String(format: "%.1f ms", t.arrivalDeltaMs.max))
        out += row("Host/device clock ratio", t.clockRatio.map { String(format: "%.6f", $0) } ?? "—")
        out += row("Clock drift", t.clockDriftPPM.map { String(format: "%.0f ppm", $0) } ?? "—")
        out += row("Max divergence", String(format: "%.0f ms", t.maxDriftMs))
        out += row("Mean burst size", String(format: "%.1f packets", t.meanBurstSize))
        out += row("Largest burst", "\(t.maxBurstSize) packets")
        out += row("Burst spacing median", t.burstSpacingMs.isEmpty ? "—"
                   : String(format: "%.1f ms", t.burstSpacingMs.median))
        out += "</table></div></section>"
        return out
    }

    // MARK: GNSS

    private static func gnssSection(_ a: CaptureAnalysis) -> String {
        let g = a.gnss
        var out = "<section id=\"sec-gnss\"><h2>GNSS quality</h2>"

        // The correlation is the point of this section: it turns "it dropped
        // fixes" into a cause.
        if let svAtGaps = g.meanSVAtGaps, !g.numSV.isEmpty {
            let delta = svAtGaps - g.numSV.mean
            let worse = delta < -0.5
            out += "<div class=\"verdict \(worse ? "warn" : "pass")\">"
            out += "<span class=\"title\">\(worse ? "Drops line up with poor sky" : "Drops don't track sky quality")</span>"
            out += "<span class=\"detail\">"
            out += String(format: "%.1f satellites at gaps vs %.1f overall", svAtGaps, g.numSV.mean)
            if let pdop = g.meanPDOPAtGaps {
                out += String(format: "; pDOP %.2f vs %.2f", pdop, g.pDOP.mean)
            }
            out += worse ? ". Reception, not the device." : ". The device lost fixes with a clear view."
            out += "</span></div>"
        }

        out += chart(id: "numSV", title: "Satellites", caption: nil)
        out += chart(id: "pDOP", title: "pDOP", caption: nil)
        out += chart(id: "hAcc", title: "Horizontal accuracy", caption: nil)

        out += "<div class=\"scroll\"><table>"
        out += row("Satellites", String(format: "%.1f mean (%.0f–%.0f)",
                                        g.numSV.mean, g.numSV.min, g.numSV.max))
        out += row("pDOP", String(format: "%.2f mean, %.2f p95", g.pDOP.mean, g.pDOP.quantile(0.95)))
        out += row("Horizontal accuracy", String(format: "%.2f m mean, %.2f m p95",
                                                 g.hAcc.mean, g.hAcc.quantile(0.95)))
        out += row("Vertical accuracy", String(format: "%.2f m mean, %.2f m p95",
                                               g.vAcc.mean, g.vAcc.quantile(0.95)))
        let fixes = g.fixTypeCounts.sorted { $0.value > $1.value }
            .map { "\(fixTypeName($0.key)) \($0.value.formatted())" }
            .joined(separator: ", ")
        out += row("Fix types", fixes.isEmpty ? "—" : fixes)
        out += row("Distance", String(format: "%.2f km", g.distanceMetres / 1000))
        out += row("Max speed", String(format: "%.1f km/h", g.maxSpeedKmh))
        if let b0 = g.batteryStart, let b1 = g.batteryEnd {
            out += row("Battery", "\(b0)% → \(b1)%")
        }
        out += row("Charging transitions", g.chargingTransitions.formatted())
        out += "</table></div>"
        out += chart(id: "speed", title: "Ground speed", caption: nil)
        out += "</section>"
        return out
    }

    private static func fixTypeName(_ t: UInt8) -> String {
        switch t {
        case 0: return "No fix"
        case 1: return "Dead reckoning"
        case 2: return "2D"
        case 3: return "3D"
        case 4: return "GNSS+DR"
        case 5: return "Time only"
        default: return "Type \(t)"
        }
    }

    // MARK: Checks

    private static func checksSection(_ a: CaptureAnalysis) -> String {
        var out = "<section><h2>Consistency checks</h2><div class=\"scroll\"><table>"
        out += "<tr><th>Check</th><th>Result</th><th>Detail</th></tr>"
        for check in a.checks {
            let cls: String, mark: String
            switch check.status {
            case .pass:          cls = "pass"; mark = "PASS"
            case .warn:          cls = "warn"; mark = "WARN"
            case .fail:          cls = "fail"; mark = "FAIL"
            case .notApplicable: cls = "na";   mark = "N/A"
            }
            var detail = check.detail
            if check.failures > 0 {
                detail = "\(check.failures.formatted()) of \(check.samples.formatted()). " + detail
            }
            if let example = check.example { detail += " <em>\(esc(example))</em>" }
            out += "<tr><td>\(esc(check.title))</td>"
            out += "<td><span class=\"status \(cls)\">\(mark)</span></td>"
            out += "<td>\(detail)</td></tr>"
        }
        out += "</table></div></section>"
        return out
    }

    // MARK: Gaps

    private static func gapsSection(_ a: CaptureAnalysis) -> String {
        guard !a.cadence.gaps.isEmpty else { return "" }
        var out = "<section><h2>Gaps</h2><div class=\"scroll\"><table>"
        out += "<tr><th>At</th><th>Device gap</th><th>Arrival gap</th><th>Missed</th><th>Attribution</th></tr>"
        for gap in a.cadence.gaps.prefix(100) {
            out += "<tr><td class=\"num\">\(duration(gap.t))</td>"
            out += "<td class=\"num\">\(String(format: "%.0f ms", gap.deviceGapMs))</td>"
            out += "<td class=\"num\">\(String(format: "%.0f ms", gap.arrivalGapMs))</td>"
            out += "<td class=\"num\">\(gap.isInterruption ? "—" : gap.missedFixes.formatted())</td>"
            out += "<td>\(esc(gap.attribution.label))\(gap.isInterruption ? " (interruption)" : "")</td></tr>"
        }
        out += "</table></div>"
        if a.cadence.gaps.count > 100 {
            out += "<p class=\"note\">Showing the first 100 of \(a.cadence.gaps.count.formatted()).</p>"
        }
        out += "</section>"
        return out
    }

    // MARK: Track

    private static func trackSection(_ a: CaptureAnalysis) -> String {
        guard a.track.count > 1 else { return "" }
        return """
        <section><h2>Track</h2>
        \(chart(id: "track", title: "Recorded path",
                caption: "Coloured by speed. Not a map — just the shape of where the capture went."))
        </section>
        """
    }

    // MARK: Session

    private static func sessionSection(_ a: CaptureAnalysis) -> String {
        let h = a.header
        var out = "<section><h2>Session</h2><div class=\"scroll\"><table>"
        out += row("Device", h.deviceName ?? "—")
        out += row("Session id", h.sessionId ?? "—")
        out += row("App", dash([h.appVersion, h.appBuild].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " build ")))
        out += row("Host", dash([h.hostModel, h.hostPlatform, h.hostSystemVersion]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
        out += row("Low power mode", h.lowPowerMode.map { $0 ? "on" : "off" } ?? "—")
        out += row("Thermal state", h.thermalState ?? "—")
        out += row("Time zone", h.timeZone ?? "—")
        out += row("Capture schema", "v\(h.schema)")
        out += row("Capture size", byteText(a.fileSize))
        if a.summary.undecodableLines > 0 {
            out += row("Unreadable lines", a.summary.undecodableLines.formatted())
        }
        out += "</table></div>"
        if h.lowPowerMode == true || (h.thermalState != nil && h.thermalState != "nominal") {
            out += "<p class=\"note\">Low power mode and thermal pressure both throttle timers and radio "
            out += "scheduling, and can show up as jitter that has nothing to do with the device.</p>"
        }
        out += "</section>"
        return out
    }

    // MARK: Helpers

    private static func chart(id: String, title: String, caption: String?) -> String {
        var out = "<div class=\"chart\"><h3>\(esc(title))</h3>"
        if let caption { out += "<div class=\"cap\">\(esc(caption))</div>" }
        out += "<div id=\"chart-\(id)\"></div></div>"
        return out
    }

    private static func row(_ key: String, _ value: String) -> String {
        "<tr><td class=\"k\">\(esc(key))</td><td class=\"num\">\(esc(value))</td></tr>"
    }

    private static func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func duration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "—" }
        let total = Int(t)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Charts

extension HTMLReportRenderer {

    /// Hand-written SVG charting: no library to vendor, and vector output that
    /// survives the print/PDF path. All time-axis charts share one x range, so
    /// zooming any of them zooms the rest — which is what makes comparing the
    /// device clock against the host clock actually possible.
    static let js = #"""
    // window.print() is a no-op inside WKWebView, so when the app is hosting
    // this page it exposes a bridge and does the printing natively. In a plain
    // browser the bridge is absent and window.print() works as normal.
    function printReport() {
      const bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.gnimuReport;
      if (bridge) bridge.postMessage("print");
      else window.print();
    }

    const SVGNS = "http://www.w3.org/2000/svg";
    // r is deliberately small: the plot should run flush to the edge of its
    // card's content box, with the card's own padding providing the breathing
    // room. Anything larger reads as the chart being cut off, because the left
    // side hides the same gap behind the y-axis labels. Kept above zero so a
    // 2px stroke on the last point isn't halved by the viewBox edge.
    const W = 900, H = 170, PAD = { l: 52, r: 4, t: 10, b: 22 };
    let xRange = [0, REPORT.duration];

    const el = (name, attrs = {}) => {
      const n = document.createElementNS(SVGNS, name);
      for (const k in attrs) n.setAttribute(k, attrs[k]);
      return n;
    };

    // Rounds before decomposing: rounding the seconds afterwards turns 119.5 s
    // into "1:60". Sub-second precision only when zoomed in far enough to need it.
    const fmtTime = (s, span) => {
      s = Math.max(0, s);
      const decimals = (span != null && span < 10) ? 1 : 0;
      const factor = Math.pow(10, decimals);
      const r = Math.round(s * factor) / factor;
      const h = Math.floor(r / 3600);
      const m = Math.floor((r % 3600) / 60);
      const sec = r - h * 3600 - m * 60;
      const secText = sec.toFixed(decimals).padStart(decimals ? 4 : 2, "0");
      return h ? `${h}:${String(m).padStart(2, "0")}:${secText}` : `${m}:${secText}`;
    };

    const niceNum = (v) => {
      if (!isFinite(v)) return "0";
      const a = Math.abs(v);
      if (a >= 100) return v.toFixed(0);
      if (a >= 10) return v.toFixed(1);
      if (a >= 1) return v.toFixed(2);
      return v.toFixed(3);
    };

    /// Draws one time-series chart: min/max envelope plus the mean line.
    function timeSeries(host, spec) {
      const pts = spec.points.filter(p => p[0] >= xRange[0] && p[0] <= xRange[1]);
      host.innerHTML = "";
      const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });

      if (!pts.length) {
        svg.appendChild(text(W / 2, H / 2, "no data in this range", "middle"));
        host.appendChild(svg);
        return;
      }

      let lo = Infinity, hi = -Infinity;
      for (const p of pts) { if (p[1] < lo) lo = p[1]; if (p[2] > hi) hi = p[2]; }
      if (spec.nominal != null) { lo = Math.min(lo, spec.nominal); hi = Math.max(hi, spec.nominal); }
      if (lo === hi) { lo -= 1; hi += 1; }
      const padY = (hi - lo) * 0.08;
      lo -= padY; hi += padY;
      if (spec.zeroFloor && lo > 0) lo = 0;

      const X = (t) => PAD.l + (t - xRange[0]) / Math.max(xRange[1] - xRange[0], 1e-9) * (W - PAD.l - PAD.r);
      const Y = (v) => PAD.t + (1 - (v - lo) / (hi - lo)) * (H - PAD.t - PAD.b);

      // Horizontal grid and y labels
      for (let i = 0; i <= 3; i++) {
        const v = lo + (hi - lo) * i / 3, y = Y(v);
        svg.appendChild(el("line", { x1: PAD.l, y1: y, x2: W - PAD.r, y2: y, class: "gridline" }));
        svg.appendChild(text(PAD.l - 6, y + 3, niceNum(v), "end"));
      }
      // Time axis labels
      for (let i = 0; i <= 4; i++) {
        const t = xRange[0] + (xRange[1] - xRange[0]) * i / 4;
        svg.appendChild(text(X(t), H - 6, fmtTime(t, xRange[1] - xRange[0]), i === 0 ? "start" : (i === 4 ? "end" : "middle")));
      }

      if (spec.nominal != null) {
        svg.appendChild(el("line", {
          x1: PAD.l, y1: Y(spec.nominal), x2: W - PAD.r, y2: Y(spec.nominal),
          stroke: "currentColor", "stroke-dasharray": "4 4", "stroke-opacity": "0.45"
        }));
      }

      // Envelope, then mean on top of it.
      let up = "", down = "";
      for (let i = 0; i < pts.length; i++) up += `${i ? "L" : "M"}${X(pts[i][0]).toFixed(1)},${Y(pts[i][2]).toFixed(1)}`;
      for (let i = pts.length - 1; i >= 0; i--) down += `L${X(pts[i][0]).toFixed(1)},${Y(pts[i][1]).toFixed(1)}`;
      svg.appendChild(el("path", { d: up + down + "Z", fill: spec.color, "fill-opacity": "0.18", stroke: "none" }));

      let line = "";
      for (let i = 0; i < pts.length; i++) line += `${i ? "L" : "M"}${X(pts[i][0]).toFixed(1)},${Y(pts[i][3]).toFixed(1)}`;
      svg.appendChild(el("path", { d: line, fill: "none", stroke: spec.color, "stroke-width": "1.5" }));

      svg.appendChild(el("line", { x1: PAD.l, y1: H - PAD.b, x2: W - PAD.r, y2: H - PAD.b, class: "axis" }));
      attachZoom(svg, X);
      host.appendChild(svg);
    }

    /// Missed fixes are events, not a continuous signal — drawn as stems.
    function stems(host, spec) {
      const pts = spec.points.filter(p => p[0] >= xRange[0] && p[0] <= xRange[1]);
      host.innerHTML = "";
      const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
      const hi = Math.max(1, ...pts.map(p => p[2]));
      const X = (t) => PAD.l + (t - xRange[0]) / Math.max(xRange[1] - xRange[0], 1e-9) * (W - PAD.l - PAD.r);
      const Y = (v) => PAD.t + (1 - v / hi) * (H - PAD.t - PAD.b);

      for (let i = 0; i <= 2; i++) {
        const v = hi * i / 2, y = Y(v);
        svg.appendChild(el("line", { x1: PAD.l, y1: y, x2: W - PAD.r, y2: y, class: "gridline" }));
        svg.appendChild(text(PAD.l - 6, y + 3, v.toFixed(0), "end"));
      }
      for (let i = 0; i <= 4; i++) {
        const t = xRange[0] + (xRange[1] - xRange[0]) * i / 4;
        svg.appendChild(text(X(t), H - 6, fmtTime(t, xRange[1] - xRange[0]), i === 0 ? "start" : (i === 4 ? "end" : "middle")));
      }
      for (const p of pts) {
        const x = X(p[0]);
        svg.appendChild(el("line", {
          x1: x, y1: H - PAD.b, x2: x, y2: Y(p[2]), stroke: spec.color, "stroke-width": "2"
        }));
      }
      if (!pts.length) svg.appendChild(text(W / 2, H / 2, "none in this range", "middle"));
      svg.appendChild(el("line", { x1: PAD.l, y1: H - PAD.b, x2: W - PAD.r, y2: H - PAD.b, class: "axis" }));
      attachZoom(svg, X);
      host.appendChild(svg);
    }

    /// Interval histogram — a log count axis, because the nominal bucket holds
    /// tens of thousands while the interesting ones hold single digits.
    function histogram(host) {
      const bins = REPORT.histogram;
      host.innerHTML = "";
      const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
      if (!bins.length) { host.appendChild(svg); return; }
      const maxCount = Math.max(...bins.map(b => b[1]));
      const dataMax = Math.max(...bins.map(b => b[0]));
      const nominalMs = REPORT.nominalHz ? 1000 / REPORT.nominalHz : null;
      // Floor the axis at twice nominal so a clean capture — whose only bin is
      // nominal itself — puts its spike in the middle rather than pinned to the
      // right edge with an empty chart beside it. Longer intervals push it left.
      const maxMs = nominalMs ? Math.max(dataMax, nominalMs * 2) : dataMax;
      const X = (ms) => PAD.l + (ms / maxMs) * (W - PAD.l - PAD.r);
      const Y = (c) => PAD.t + (1 - Math.log10(c + 1) / Math.log10(maxCount + 1)) * (H - PAD.t - PAD.b);

      for (const p of [1, 10, 100, 1000, 10000, 100000]) {
        if (p > maxCount) break;
        const y = Y(p);
        svg.appendChild(el("line", { x1: PAD.l, y1: y, x2: W - PAD.r, y2: y, class: "gridline" }));
        svg.appendChild(text(PAD.l - 6, y + 3, p.toLocaleString(), "end"));
      }
      // Marker first, so the bars sit on top of it.
      if (nominalMs) {
        const nx = X(nominalMs);
        svg.appendChild(el("line", {
          x1: nx, y1: PAD.t, x2: nx, y2: H - PAD.b, stroke: "currentColor",
          "stroke-dasharray": "3 3", "stroke-opacity": "0.35"
        }));
        svg.appendChild(text(nx, PAD.t + 9, "nominal", "middle"));
      }
      for (const b of bins) {
        const x = X(b[0]);
        svg.appendChild(el("line", {
          x1: x, y1: H - PAD.b, x2: x, y2: Y(b[1]), stroke: "var(--accent)", "stroke-width": "2"
        }));
      }
      for (let i = 0; i <= 4; i++) {
        const ms = maxMs * i / 4;
        svg.appendChild(text(X(ms), H - 6, ms.toFixed(0) + " ms",
                             i === 0 ? "start" : (i === 4 ? "end" : "middle")));
      }
      svg.appendChild(el("line", { x1: PAD.l, y1: H - PAD.b, x2: W - PAD.r, y2: H - PAD.b, class: "axis" }));
      host.appendChild(svg);
    }

    /// The recorded path, equirectangular and coloured by speed.
    function track(host) {
      const pts = REPORT.track;
      host.innerHTML = "";
      if (pts.length < 2) return;
      let latMin = 90, latMax = -90, lonMin = 180, lonMax = -180, vMax = 0;
      for (const p of pts) {
        latMin = Math.min(latMin, p[0]); latMax = Math.max(latMax, p[0]);
        lonMin = Math.min(lonMin, p[1]); lonMax = Math.max(lonMax, p[1]);
        vMax = Math.max(vMax, p[2]);
      }
      // Longitude degrees shrink with latitude; without this the shape is wrong.
      const latSpan = Math.max(latMax - latMin, 1e-6);
      const lonSpan = Math.max((lonMax - lonMin) * Math.cos((latMin + latMax) / 2 * Math.PI / 180), 1e-6);
      const TH = 320;
      const scale = Math.min((W - 40) / lonSpan, (TH - 40) / latSpan);
      const ox = (W - lonSpan * scale) / 2, oy = (TH - latSpan * scale) / 2;
      const X = (lon) => ox + (lon - lonMin) * Math.cos((latMin + latMax) / 2 * Math.PI / 180) * scale;
      const Y = (lat) => TH - oy - (lat - latMin) * scale;

      const svg = el("svg", { viewBox: `0 0 ${W} ${TH}`, preserveAspectRatio: "xMidYMid meet" });
      for (let i = 1; i < pts.length; i++) {
        const v = vMax > 0 ? pts[i][2] / vMax : 0;
        svg.appendChild(el("line", {
          x1: X(pts[i - 1][1]), y1: Y(pts[i - 1][0]), x2: X(pts[i][1]), y2: Y(pts[i][0]),
          stroke: `hsl(${(1 - v) * 210}, 75%, 52%)`, "stroke-width": "2", "stroke-linecap": "round"
        }));
      }
      host.appendChild(svg);
    }

    function text(x, y, s, anchor) {
      const t = el("text", { x, y, class: "tick", "text-anchor": anchor || "middle" });
      t.textContent = s;
      return t;
    }

    /// Drag horizontally to zoom, double-click to reset. Applied to every
    /// time-axis chart so they stay locked together.
    function attachZoom(svg, X) {
      let startX = null, band = null;
      const toData = (clientX) => {
        const r = svg.getBoundingClientRect();
        const frac = (clientX - r.left) / r.width;
        const px = frac * W;
        const inner = (px - PAD.l) / (W - PAD.l - PAD.r);
        return xRange[0] + inner * (xRange[1] - xRange[0]);
      };
      svg.addEventListener("pointerdown", (e) => {
        startX = e.clientX;
        band = el("rect", { y: PAD.t, height: H - PAD.t - PAD.b,
                            fill: "currentColor", "fill-opacity": "0.12" });
        svg.appendChild(band);
        svg.setPointerCapture(e.pointerId);
      });
      svg.addEventListener("pointermove", (e) => {
        if (startX === null) return;
        const r = svg.getBoundingClientRect();
        const a = (startX - r.left) / r.width * W, b = (e.clientX - r.left) / r.width * W;
        band.setAttribute("x", Math.min(a, b));
        band.setAttribute("width", Math.abs(b - a));
      });
      svg.addEventListener("pointerup", (e) => {
        if (startX === null) return;
        const a = toData(startX), b = toData(e.clientX);
        startX = null;
        if (Math.abs(b - a) > (xRange[1] - xRange[0]) * 0.01) {
          xRange = [Math.min(a, b), Math.max(a, b)];
          drawAll();
        } else {
          band.remove();
        }
      });
      svg.addEventListener("dblclick", resetZoom);
    }

    function resetZoom() {
      xRange = [0, REPORT.duration];
      drawAll();
    }

    const SPECS = [
      ["fixRate", "fixRate", "var(--accent)", true],
      ["numSV", "numSV", "#2f9e6a", true],
      ["pDOP", "pDOP", "#b8860b", true],
      ["hAcc", "hAcc", "#8e6fd0", true],
      ["arrival", "arrival", "#d06a2f", true],
      ["drift", "drift", "#c0392b", false],
      ["speed", "speed", "#1c8fa8", true]
    ];

    function drawAll() {
      for (const [id, key, color, zeroFloor] of SPECS) {
        const host = document.getElementById("chart-" + id);
        if (!host) continue;
        const spec = Object.assign({}, REPORT.series[key], { color, zeroFloor });
        if (id === "fixRate" && REPORT.nominalHz != null) spec.nominal = REPORT.nominalHz;
        timeSeries(host, spec);
      }
      const missedHost = document.getElementById("chart-missed");
      if (missedHost) {
        stems(missedHost, Object.assign({}, REPORT.series.missed, { color: "#c0392b" }));
      }
    }

    drawAll();
    const histHost = document.getElementById("chart-histogram");
    if (histHost) histogram(histHost);
    const trackHost = document.getElementById("chart-track");
    if (trackHost) track(trackHost);
    // Charts are sized from measured width, so a resize needs a redraw.
    addEventListener("beforeprint", resetZoom);
    """#
}
