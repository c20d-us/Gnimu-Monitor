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

/// Lists the captures on the device and in iCloud, and turns them into reports.
///
/// Reports are produced here and shared out — they aren't read on the phone,
/// so a finished analysis offers Share as its primary action.
struct AnalysisPanel: View {
    @StateObject private var store = CaptureStore()
    /// Shared with the rest of the app, so a run auto-started when a recording
    /// finished is the same one this panel reports on.
    @ObservedObject var runner: AnalysisRunner
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var pendingDelete: CaptureFile?
    @State private var viewing: ReportSelection?

    var body: some View {
        Group {
            if store.captures.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.captures) { capture in
                        row(capture)
                    }
                } 
                .listStyle(.plain)
                .refreshable { store.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.refresh() }
        .onChange(of: runner.state) { _, state in
            // A finished run writes a new file; the list has to catch up.
            if case .finished = state { store.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            // iOS suspends a backgrounded app, so rather than pretend to keep
            // going, stop cleanly and let the row offer it again. A Mac app
            // that merely loses focus keeps running, so it isn't cancelled.
            if phase == .background, runner.state.isBusy { runner.cancel() }
            #endif
        }
        // An alert rather than a confirmationDialog: a centred modal box reads
        // as a deliberate stop for a destructive action, and looks the same on
        // iPhone, iPad and Mac. confirmationDialog renders as an anchored
        // popover in some of those contexts and a bottom sheet in others.
        #if os(iOS)
        .fullScreenCover(item: $viewing) { ReportViewer(selection: $0) }
        #endif
        .alert(
            "Delete this capture?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })
        ) {
            // Only promise to delete a report when there is one.
            Button(pendingDelete?.hasAnalysis == true
                   ? "Delete Capture and Report"
                   : "Delete Capture",
                   role: .destructive) {
                if let pendingDelete {
                    store.delete(pendingDelete)
                    runner.acknowledge(captureID: pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\($0.displayName) can't be recovered." } ?? "")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ capture: CaptureFile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.recordedAt.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? capture.displayName)
                    .font(.subheadline.weight(.medium))

                // Badges lead, each in a fixed-width slot that's reserved even
                // when the badge is absent. That keeps every icon — and the
                // size text after them — at the same x on every row, instead
                // of shifting as file sizes gain a digit.
                HStack(spacing: 6) {
                    // Always rendered, hidden with opacity rather than removed:
                    // an absent view is an EmptyView, which isn't laid out at
                    // all, so a .frame on it reserves nothing and everything
                    // after it slides left. The fixed widths keep the size text
                    // aligned across rows whichever cloud glyph is in use.
                    Image(systemName: capture.isDownloaded
                          ? "icloud" : "icloud.and.arrow.down")
                        .frame(width: 18, alignment: .leading)
                        .opacity(capture.isUbiquitous ? 1 : 0)
                        .accessibilityHidden(!capture.isUbiquitous)

                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .frame(width: 14, alignment: .leading)
                        .opacity(capture.hasAnalysis ? 1 : 0)
                        // The badge carries no text, so name it for VoiceOver.
                        .accessibilityLabel("Report available")
                        .accessibilityHidden(!capture.hasAnalysis)

                    Text(ByteCountFormatter.string(fromByteCount: Int64(capture.byteSize),
                                                   countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                status(for: capture)
            }

            Spacer(minLength: 0)

            trailing(for: capture)

            #if os(macOS)
            // Two-finger trackpad swipe does reveal the swipe actions here, but
            // a plain mouse has no swipe gesture at all — so the Mac keeps an
            // explicit control rather than stranding mouse users.
            Menu {
                managementItems(for: capture)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .frame(width: 44)
            #endif
        }
        .padding(.vertical, 4)
        // Swipe is the primary affordance again: this panel no longer sits in
        // the paged TabView whose horizontal drag used to beat it.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = capture } label: {
                Label("Delete", systemImage: "trash")
            }
            if capture.hasAnalysis {
                Button { deleteReport(capture) } label: {
                    Label("Delete Report", systemImage: "doc.badge.ellipsis")
                }
                .tint(.orange)
            }
            Button { runner.analyze(capture) } label: {
                Label(capture.hasAnalysis ? "Re-analyze" : "Analyze",
                      systemImage: "arrow.clockwise")
            }
            .tint(.blue)
            .disabled(runner.state.isBusy)
        }
        // Long-press on iOS, right-click on the Mac.
        .contextMenu { managementItems(for: capture) }
    }

    private func deleteReport(_ capture: CaptureFile) {
        store.deleteAnalysis(for: capture)
        // The notice about a report must not outlive the report.
        runner.acknowledge(captureID: capture.id)
    }

    /// Re-analyse and the two deletes, for the menu and the context menu.
    @ViewBuilder
    private func managementItems(for capture: CaptureFile) -> some View {
        if let analysis = capture.analysisURL {
            ShareLink(item: analysis) {
                Label("Share Report", systemImage: "square.and.arrow.up")
            }

            Button { runner.analyze(capture) } label: {
                Label("Re-analyze", systemImage: "arrow.clockwise")
            }
            .disabled(runner.state.isBusy)

            Button(role: .destructive) { deleteReport(capture) } label: {
                Label("Delete Report", systemImage: "doc.badge.ellipsis")
            }
        } else {
            Button { runner.analyze(capture) } label: {
                Label("Analyze", systemImage: "chart.bar.doc.horizontal")
            }
            .disabled(runner.state.isBusy)
        }

        Divider()

        Button(role: .destructive) { pendingDelete = capture } label: {
            Label("Delete Capture", systemImage: "trash")
        }
    }

    /// The trailing control. Deliberately never changes meaning in place: a row
    /// with a report offers Share, and re-analysing or deleting lives in the
    /// swipe actions where a mistap can't reach.
    @ViewBuilder
    private func trailing(for capture: CaptureFile) -> some View {
        if runner.state.activeCaptureID == capture.id {
            Button("Stop") { runner.cancel() }
                .buttonStyle(.bordered)
                .tint(.red)
        } else if let analysis = capture.analysisURL {
            Button("View") {
                let selection = ReportSelection(id: capture.id, url: analysis,
                                                title: capture.displayName)
                #if os(macOS)
                openWindow(id: ReportWindow.id, value: selection)
                #else
                viewing = selection
                #endif
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Analyze") { runner.analyze(capture) }
                .buttonStyle(.borderedProminent)
                .disabled(runner.state.isBusy)
        }
    }

    @ViewBuilder
    private func status(for capture: CaptureFile) -> some View {
        switch runner.state {
        case .downloading(let id) where id == capture.id:
            Label("Downloading from iCloud…", systemImage: "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .running(let id, let progress) where id == capture.id:
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 180)
        case .failed(let id, let message) where id == capture.id:
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
        // No "report saved" line: the row's green Report badge already says so,
        // and it keeps saying it after this transient state has moved on.
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.hasScanned ? "tray" : "hourglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.hasScanned ? "No captures yet" : "Looking for captures…")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.hasScanned {
                Text("Record one on the Capture page.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
