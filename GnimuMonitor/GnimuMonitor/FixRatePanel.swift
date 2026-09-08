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
import Charts

/// Real-time GNSS fix-rate monitor. Big iTOW rate readout on top, then two
/// stacked charts — iTOW rate over the last minute above, SV count below.
struct FixRatePanel: View {
    @ObservedObject var ble: BLEManager

    private let hzColor: Color = .orange
    private let svColor: Color = .blue

    private var samples: [(index: Int, sample: FixRateSample)] {
        Array(ble.rateHistory.enumerated()).map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(String(format: "%.1f", ble.fixRate.hz))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Hz iTOW")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(ble.fixRate.status.tint)
                if let sessionLine {
                    Text(sessionLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            chartSection(label: "Fix Rate",
                         color: hzColor,
                         domain: 0...30,
                         nominal: ble.fixRate.nominalHz,
                         markMissed: true) { entry in
                entry.sample.hz
            }
            .padding(.top, 24)

            chartSection(label: "Satellites", color: svColor, domain: 0...25) { entry in
                Double(entry.sample.sv)
            }
            .padding(.top, 48)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// How the cadence compares with what the device should be holding, and
    /// what went missing in the last second.
    private var statusLine: String {
        let rate = ble.fixRate
        guard let nominalHz = rate.nominalHz, rate.status != .noData else {
            return "waiting for fixes"
        }
        let nominal = String(format: "%g Hz nominal", nominalHz)
        switch rate.status {
        case .onRate:
            return "\(nominal) · on rate"
        case .degraded, .offRate:
            var parts: [String] = []
            if rate.interruptions > 0 { parts.append("stream interrupted") }
            if rate.missedFixes > 0 { parts.append("\(rate.missedFixes) missed") }
            if rate.lateIntervals > 0 { parts.append("\(rate.lateIntervals) late") }
            // Cadence can sag without any single interval standing out.
            if parts.isEmpty { parts.append("below rate") }
            return "\(nominal) · \(parts.joined(separator: ", "))"
        case .noData:
            return "waiting for fixes"
        }
    }

    /// Running totals since connecting — the view that says whether a device is
    /// healthy over a session rather than in this one second.
    private var sessionLine: String? {
        let rate = ble.fixRate
        guard rate.sessionIntervals > 0 else { return nil }
        // `sessionIntervals` counts only the fixes that arrived, so the missed
        // ones have to be added back to state what the device should have sent.
        let expected = rate.sessionIntervals + rate.sessionMissed
        let errorRate = expected > 0
            ? Double(rate.sessionMissed) / Double(expected) * 100
            : 0
        var line = "\(rate.sessionMissed.formatted()) missed of "
            + "\(expected.formatted()) fixes expected this session"
            + String(format: " · %.2f%% error rate", errorRate)
        if rate.sessionInterruptions > 0 {
            let count = rate.sessionInterruptions
            line += " · \(count.formatted()) interruption\(count == 1 ? "" : "s")"
        }
        return line
    }

    /// A labeled single-series line chart with a fixed Y domain, optionally
    /// showing the nominal rate and flagging samples that lost fixes.
    @ViewBuilder
    private func chartSection(
        label: String,
        color: Color,
        domain: ClosedRange<Double>,
        nominal: Double? = nil,
        markMissed: Bool = false,
        value: @escaping ((index: Int, sample: FixRateSample)) -> Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                if let nominal {
                    RuleMark(y: .value("Nominal", nominal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }

                ForEach(samples, id: \.index) { entry in
                    LineMark(
                        x: .value("t", entry.index),
                        y: .value(label, value(entry))
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                }

                if markMissed {
                    ForEach(samples.filter { $0.sample.missed > 0 }, id: \.index) { entry in
                        PointMark(
                            x: .value("t", entry.index),
                            y: .value(label, value(entry))
                        )
                        .symbolSize(28)
                        .foregroundStyle(.red)
                    }
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .frame(height: 110)
        }
    }
}
