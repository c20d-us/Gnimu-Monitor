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
                Text(String(format: "%.1f", ble.itowRateHz))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Hz iTOW")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            chartSection(label: "Fix Rate", color: hzColor, domain: 0...30) { entry in
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

    /// A labeled single-series line chart with a fixed Y domain.
    @ViewBuilder
    private func chartSection(
        label: String,
        color: Color,
        domain: ClosedRange<Double>,
        value: @escaping ((index: Int, sample: FixRateSample)) -> Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(samples, id: \.index) { entry in
                LineMark(
                    x: .value("t", entry.index),
                    y: .value(label, value(entry))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .frame(height: 110)
        }
    }
}
