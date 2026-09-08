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
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Runs one analysis at a time: reads the capture, renders a report, and writes
/// it beside the capture.
///
/// A foreground activity by design. The parse is fast enough that background
/// execution isn't worth the complexity, so leaving the app cancels the run and
/// the panel offers it again rather than pretending to have finished.
final class AnalysisRunner: ObservableObject {

    enum State: Equatable {
        case idle
        case downloading(captureID: String)
        case running(captureID: String, progress: Double)
        case finished(captureID: String, url: URL)
        case failed(captureID: String, message: String)

        var activeCaptureID: String? {
            switch self {
            case .downloading(let id):     return id
            case .running(let id, _):      return id
            default:                       return nil
            }
        }

        var isBusy: Bool { activeCaptureID != nil }
    }

    @Published private(set) var state: State = .idle

    private let renderer: ReportRenderer
    private let queue = DispatchQueue(label: "us.c20d.GnimuMonitor.analysis", qos: .userInitiated)
    /// Read from the analysis thread, written from the main actor.
    private let cancelled = Cancellation()

    init(renderer: ReportRenderer = HTMLReportRenderer()) {
        self.renderer = renderer
    }

    // MARK: - Control

    func analyze(_ capture: CaptureFile) {
        analyze(url: capture.url, isDownloaded: capture.isDownloaded)
    }

    /// Analyses a capture by location — used when a recording has just finished
    /// and there's no listing entry for it yet.
    func analyze(url: URL, isDownloaded: Bool = true) {
        guard !state.isBusy else { return }
        cancelled.reset()
        // Ids are paths, so this matches what the listing will produce.
        let id = url.path
        state = isDownloaded ? .running(captureID: id, progress: 0)
                             : .downloading(captureID: id)
        setKeepAwake(true)

        let renderer = self.renderer
        let cancelled = self.cancelled
        let source = url

        queue.async { [weak self] in
            do {
                if !isDownloaded {
                    try Self.materialize(source, cancelled: cancelled)
                    DispatchQueue.main.async {
                        guard let self, !cancelled.isCancelled else { return }
                        self.state = .running(captureID: id, progress: 0)
                    }
                }

                let analysis = try CaptureAnalyzer.analyze(
                    url: source,
                    onProgress: { fraction in
                        DispatchQueue.main.async {
                            guard let self, case .running = self.state else { return }
                            self.state = .running(captureID: id, progress: fraction)
                        }
                    },
                    isCancelled: { cancelled.isCancelled })

                let data = try renderer.render(analysis)
                // The report sits beside its capture, named after it, so the
                // pair travels together however the files are moved.
                let name = source.deletingPathExtension().lastPathComponent
                    + CaptureStorage.analysisSuffix + "." + renderer.fileExtension
                let finalURL = source.deletingLastPathComponent().appendingPathComponent(name)
                try Self.writeAtomically(data, to: finalURL)
                Self.removeStaleReports(besides: finalURL, for: source)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setKeepAwake(false)
                    self.state = cancelled.isCancelled
                        ? .idle
                        : .finished(captureID: id, url: finalURL)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setKeepAwake(false)
                    if cancelled.isCancelled {
                        self.state = .idle
                    } else {
                        self.state = .failed(
                            captureID: id,
                            message: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Stops the run and leaves nothing behind — the report is only written
    /// once it's complete, so there's no partial file to clean up.
    func cancel() {
        guard state.isBusy else { return }
        cancelled.cancel()
        setKeepAwake(false)
        state = .idle
    }

    /// Clears a finished or failed result so the row goes back to its resting
    /// state once the panel has reported it.
    func acknowledge() {
        switch state {
        case .finished, .failed: state = .idle
        default: break
        }
    }

    /// Clears the result for one capture specifically.
    ///
    /// The "report saved" line is a transient notice — the row's own badge is
    /// the lasting record — so it must not outlive the report it refers to.
    func acknowledge(captureID: String) {
        switch state {
        case .finished(let id, _) where id == captureID: state = .idle
        case .failed(let id, _) where id == captureID:   state = .idle
        default: break
        }
    }

    // MARK: - Work

    /// Pulls an evicted iCloud capture back down, waiting for it to land.
    ///
    /// Bounded rather than open-ended: a capture that won't download is a
    /// failure the panel should report, not a spinner that never stops.
    private nonisolated static func materialize(_ url: URL, cancelled: Cancellation) throws {
        let fm = FileManager.default
        try fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(120)
        while !fm.fileExists(atPath: url.path) {
            if cancelled.isCancelled { throw CaptureReadError.cancelled }
            guard Date() < deadline else {
                throw CaptureReadError.unreadable("iCloud didn't finish downloading this capture.")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Writes to a sibling temporary file and moves it into place, so an
    /// interrupted write can never leave a half-formed report behind.
    private nonisolated static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        do {
            try fm.moveItem(at: temporary, to: url)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Deletes reports for this capture left by a different renderer.
    ///
    /// The store matches any `<capture>-analysis.*`, so a stale `.md` sitting
    /// beside a fresh `.html` would leave which one gets listed to chance.
    private nonisolated static func removeStaleReports(besides keep: URL, for capture: URL) {
        let fm = FileManager.default
        let folder = capture.deletingLastPathComponent()
        let prefix = capture.deletingPathExtension().lastPathComponent
            + CaptureStorage.analysisSuffix
        guard let entries = try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(prefix)
            && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    private func setKeepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// A cancellation flag both the main actor and the analysis queue can touch.
nonisolated final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}
