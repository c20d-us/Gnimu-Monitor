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

import Combine
import CoreBluetooth
import SwiftUI

/// Capture control: one big start/stop target, live counters while running,
/// and where the finished file landed. No inputs to fill in — the session
/// metadata is collected automatically.
struct RecordPanel: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var recorder: SessionRecorder
    /// Analysis starts automatically once a capture is filed; this reports it
    /// without making the user go looking on the Analysis page.
    @ObservedObject var analysis: AnalysisRunner

    /// Drives the elapsed readout. The recorder tracks time itself; this only
    /// exists to re-render once a second while recording.
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            recordButton

            VStack(spacing: 6) {
                if recorder.isRecording {
                    Text(elapsedText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(recorder.packetCount.formatted()) packets · \(sizeText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(idleHeadline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 72)

            status

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(ticker) { tick = $0 }
        // The capture may have been deleted from Files since it was recorded;
        // don't keep offering to share something that's gone.
        .onAppear { recorder.forgetCaptureIfMissing() }
    }

    // MARK: - Pieces

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start(deviceName: ble.selectedPeripheral?.name,
                               peripheralID: ble.selectedPeripheral?.identifier.uuidString,
                               nominalHz: ble.fixRate.nominalHz)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(recorder.isRecording ? 0.18 : 0.12))
                Circle()
                    .strokeBorder(Color.red.opacity(0.55), lineWidth: 3)

                // Disc when idle, rounded square when running — the standard
                // record/stop shape change, so the control reads at a glance.
                RoundedRectangle(cornerRadius: recorder.isRecording ? 14 : 60, style: .continuous)
                    .fill(Color.red)
                    .frame(width: recorder.isRecording ? 62 : 120,
                           height: recorder.isRecording ? 62 : 120)
            }
            .frame(width: 190, height: 190)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!ble.isConnected || recorder.isFinishing)
        .opacity(ble.isConnected && !recorder.isFinishing ? 1 : 0.4)
        .animation(.snappy(duration: 0.22), value: recorder.isRecording)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var status: some View {
        if let error = recorder.errorMessage {
            label(error, icon: "exclamationmark.triangle.fill", tint: .orange)
        } else if recorder.isFinishing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        } else if let capture = recorder.lastCapture {
            VStack(spacing: 10) {
                label("Saved to \(capture.destination.label)",
                      icon: capture.destination == .iCloud ? "icloud.fill" : "folder.fill",
                      tint: .green)
                Text(capture.url.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(capture.packets.formatted()) packets · \(byteText(capture.bytes))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                // Say which problem sent it here, rather than leaving iCloud
                // looking like it silently chose not to work.
                if let reason = capture.fallbackReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                // The way a capture reaches iCloud Drive, a Mac, or anywhere
                // else while the app files them locally.
                analysisStatus

                ShareLink(item: capture.url) {
                    Label("Share Capture", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        } else if recorder.isRecording {
            label("Capture is analyzed and filed when you stop",
                  icon: "square.and.arrow.down", tint: .secondary)
        }
    }

    /// Progress of the analysis that starts on its own when a capture lands.
    @ViewBuilder
    private var analysisStatus: some View {
        switch analysis.state {
        case .running(_, let progress):
            VStack(spacing: 4) {
                Text("Analyzing…").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress).frame(maxWidth: 180)
            }
        case .finished:
            label("Report saved", icon: "chart.bar.doc.horizontal", tint: .green)
        case .failed(_, let message):
            label(message, icon: "exclamationmark.triangle.fill", tint: .orange)
        default:
            EmptyView()
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
    }

    // MARK: - Formatting

    private var idleHeadline: String {
        ble.isConnected ? "Tap to start capturing" : "Connect a device to record"
    }

    private var elapsedText: String {
        // `tick` is read so the timer actually invalidates this view.
        _ = tick
        let total = Int(recorder.elapsed)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var sizeText: String {
        _ = tick
        return byteText(recorder.capturedBytes)
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
