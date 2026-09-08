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

/// Where captures and their reports live, and how they're named.
nonisolated enum CaptureStorage {
    /// The app's iCloud Drive container, surfaced as a "Gnimu Monitor" folder.
    static let ubiquityContainerID = "iCloud.us.c20d.GnimuMonitor"
    static let captureExtension = "jsonl"
    /// A report sits beside its capture as `<capture name>-analysis.<ext>`,
    /// so the pair stays together wherever the files are moved.
    static let analysisSuffix = "-analysis"

    /// Why a capture couldn't go to iCloud, so the fallback can say which
    /// problem it hit instead of silently landing somewhere else.
    enum ICloudStatus: Sendable, Equatable {
        case available(URL)
        /// No iCloud account on the device, or iCloud Drive is switched off.
        case notSignedIn
        /// Signed in, but the app's own container didn't resolve — the
        /// entitlement isn't active on this build, or the container hasn't
        /// been provisioned yet.
        case containerUnavailable

        var reason: String? {
            switch self {
            case .available:           return nil
            case .notSignedIn:         return "iCloud Drive isn't signed in on this device."
            case .containerUnavailable: return "The app's iCloud container isn't available."
            }
        }
    }

    /// Blocks while it talks to the iCloud daemon — never call on the main
    /// thread.
    nonisolated static func iCloudStatus() -> ICloudStatus {
        let fm = FileManager.default
        // Distinguishes "no iCloud account" from "container not provisioned":
        // the token is present whenever the user is signed in, regardless of
        // whether this app's container resolves.
        guard fm.ubiquityIdentityToken != nil else { return .notSignedIn }
        guard let container = fm.url(forUbiquityContainerIdentifier: ubiquityContainerID) else {
            return .containerUnavailable
        }
        return .available(container.appendingPathComponent("Documents", isDirectory: true))
    }

    nonisolated static func iCloudDocuments() -> URL? {
        if case .available(let url) = iCloudStatus() { return url }
        return nil
    }

    nonisolated static func localDocuments() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }
}

/// One capture on disk, with whatever is known about its report.
nonisolated struct CaptureFile: Identifiable, Sendable {
    /// Path identity: two captures can share a name across storage locations.
    var id: String { url.path }

    let url: URL
    let name: String
    let recordedAt: Date?
    let byteSize: Int
    /// True when the file lives in iCloud rather than on the device.
    let isUbiquitous: Bool
    /// False when iCloud has evicted the contents to reclaim space; the file
    /// still exists but must be downloaded before it can be read.
    let isDownloaded: Bool
    /// The report beside it, if one has been produced.
    let analysisURL: URL?

    var hasAnalysis: Bool { analysisURL != nil }

    /// Display name without the extension — the timestamp is the useful part.
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Finds captures across both storage locations and keeps the list current.
///
/// Scanning touches the iCloud container, which blocks, so every filesystem
/// pass runs on a background queue and only the finished list crosses back to
/// the main actor.
final class CaptureStore: ObservableObject {
    @Published private(set) var captures: [CaptureFile] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    /// Nil until the first scan finishes — lets the panel tell "still looking"
    /// apart from "nothing here".
    @Published private(set) var hasScanned = false

    private let queue = DispatchQueue(label: "us.c20d.GnimuMonitor.captureStore", qos: .userInitiated)

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        queue.async { [weak self] in
            let found = Self.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.captures = found
                self.isRefreshing = false
                self.hasScanned = true
            }
        }
    }

    /// Deletes a capture and its report together — a report without its capture
    /// can't be re-derived or checked.
    func delete(_ capture: CaptureFile) {
        queue.async { [weak self] in
            let fm = FileManager.default
            try? fm.removeItem(at: capture.url)
            if let analysis = capture.analysisURL { try? fm.removeItem(at: analysis) }
            let found = Self.scan()
            DispatchQueue.main.async {
                self?.captures = found
            }
        }
    }

    func deleteAnalysis(for capture: CaptureFile) {
        guard let analysis = capture.analysisURL else { return }
        queue.async { [weak self] in
            try? FileManager.default.removeItem(at: analysis)
            let found = Self.scan()
            DispatchQueue.main.async { self?.captures = found }
        }
    }

    // MARK: - Scanning

    private nonisolated static func scan() -> [CaptureFile] {
        var byPath: [String: CaptureFile] = [:]
        for directory in [CaptureStorage.iCloudDocuments(), CaptureStorage.localDocuments()] {
            guard let directory else { continue }
            let isCloud = directory.path.contains("Mobile Documents")
            for file in captures(in: directory, isUbiquitous: isCloud) {
                byPath[file.id] = file
            }
        }
        // Newest first: the capture you just took is the one you want.
        return byPath.values.sorted {
            ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast)
        }
    }

    private nonisolated static func captures(in directory: URL, isUbiquitous: Bool) -> [CaptureFile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [])
        else { return [] }

        // Report names, so they aren't listed as captures in their own right.
        let analysisNames = Set(entries.map(\.lastPathComponent)
            .filter { $0.contains(CaptureStorage.analysisSuffix) })

        var results: [CaptureFile] = []
        for entry in entries {
            // An evicted iCloud file is replaced by a ".<name>.icloud"
            // placeholder. The capture still exists — it just isn't local.
            let placeholder = evictedCaptureName(entry.lastPathComponent)
            let isDownloaded = placeholder == nil
            let realName = placeholder ?? entry.lastPathComponent
            guard realName.hasSuffix(".\(CaptureStorage.captureExtension)"),
                  !realName.contains(CaptureStorage.analysisSuffix) else { continue }

            let realURL = directory.appendingPathComponent(realName)
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey,
                                                             .contentModificationDateKey])
            let base = (realName as NSString).deletingPathExtension
            let analysis = analysisNames
                .first { $0.hasPrefix(base + CaptureStorage.analysisSuffix) }
                .map { directory.appendingPathComponent($0) }

            results.append(CaptureFile(
                url: realURL,
                name: realName,
                recordedAt: recordedAt(from: base) ?? values?.contentModificationDate,
                byteSize: values?.fileSize ?? 0,
                isUbiquitous: isUbiquitous,
                isDownloaded: isDownloaded,
                analysisURL: analysis))
        }
        return results
    }

    /// Returns the underlying capture name if this entry is an iCloud eviction
    /// placeholder, otherwise nil.
    private nonisolated static func evictedCaptureName(_ entry: String) -> String? {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud") else { return nil }
        return String(entry.dropFirst().dropLast(".icloud".count))
    }

    /// The recorder names files `Gnimu-yyyy-MM-dd-HHmmss`, which is a more
    /// reliable record date than a modification time that a sync or a copy can
    /// rewrite.
    private nonisolated static func recordedAt(from base: String) -> Date? {
        guard base.hasPrefix("Gnimu-") else { return nil }
        let stamp = String(base.dropFirst("Gnimu-".count)).prefix(17)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df.date(from: String(stamp))
    }
}
