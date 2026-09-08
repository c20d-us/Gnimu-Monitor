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

/// Capture-file format version. Bump when the line schema changes so readers
/// can tell which shape they're looking at.
private let captureSchemaVersion = 1

/// One captured frame: the raw RaceBox bytes plus when they reached us.
private struct RecordedFrame: Sendable {
    /// Seconds since the session started, from the monotonic system clock.
    let t: Double
    let data: Data
}

/// Where a finished capture ended up.
enum CaptureDestination: Sendable {
    case iCloud
    case local

    var label: String {
        switch self {
        case .iCloud:
            return "iCloud Drive → Gnimu Monitor"
        case .local:
            #if os(iOS)
            return "Files → On My iPhone → Gnimu Monitor"
            #else
            return "the app's Documents folder"
            #endif
        }
    }
}

/// A finished capture, for the panel to report after recording stops.
struct CompletedCapture: Sendable {
    let url: URL
    let destination: CaptureDestination
    let packets: Int
    let bytes: Int
    let duration: TimeInterval
    /// Why it didn't go to iCloud, when it didn't.
    let fallbackReason: String?
}

/// Serializes every byte of disk work onto its own queue.
///
/// Nothing here touches the main actor, and nothing the recorder calls on it
/// waits for a result — the BLE delegate hands over an array and returns
/// immediately, so a slow write can never stall the incoming packet stream.
private final class LogWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "us.c20d.GnimuMonitor.capture", qos: .utility)
    private var handle: FileHandle?
    /// Set once a write fails; every later write is skipped rather than
    /// retried, so one full disk doesn't produce an error per packet.
    private var failure: String?

    init(url: URL, header: Data) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
    }

    /// Encode and append a batch. Returns immediately; the caller is told about
    /// a failure through `onError`, which is delivered on the main queue.
    func append(_ frames: [RecordedFrame], onError: @escaping @Sendable (String) -> Void) {
        guard !frames.isEmpty else { return }
        queue.async { [self] in
            guard failure == nil, let handle else { return }
            var blob = Data()
            for frame in frames {
                // Hand-built rather than JSONEncoder: this runs for every packet
                // of a multi-hour session, and the shape is two fixed keys.
                let line = "{\"t\":\(String(format: "%.4f", frame.t))," +
                           "\"d\":\"\(frame.data.base64EncodedString())\"}\n"
                blob.append(contentsOf: Array(line.utf8))
            }
            do {
                try handle.write(contentsOf: blob)
            } catch {
                failure = error.localizedDescription
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
    }

    /// Append the trailer, close the file, then move it to its final home.
    /// `completion` lands on the main queue.
    func finish(trailer: Data,
                completion: @escaping @Sendable (Result<(URL, CaptureDestination, String?), Error>) -> Void) {
        queue.async { [self] in
            if let handle {
                try? handle.write(contentsOf: trailer)
                try? handle.close()
            }
            handle = nil

            let result: Result<(URL, CaptureDestination, String?), Error>
            do {
                result = .success(try Self.relocate(url))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Move a finished capture into iCloud Drive, falling back to the local
    /// Documents directory when iCloud isn't available (not signed in, or
    /// disabled for the app) so a capture is never lost to a sync problem.
    ///
    /// Runs on the writer queue: `url(forUbiquityContainerIdentifier:)` blocks
    /// while it talks to the iCloud daemon and must not be called on the main
    /// thread.
    private static func relocate(_ source: URL) throws -> (URL, CaptureDestination, String?) {
        let fm = FileManager.default
        let status = CaptureStorage.iCloudStatus()

        if case .available(let folder) = status {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = uniqueURL(folder.appendingPathComponent(source.lastPathComponent))
            // setUbiquitous moves the file and hands ownership to the sync
            // daemon; a plain moveItem into the container is not equivalent.
            try fm.setUbiquitous(true, itemAt: source, destinationURL: target)
            return (target, .iCloud, nil)
        }

        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let target = uniqueURL(docs.appendingPathComponent(source.lastPathComponent))
        try fm.moveItem(at: source, to: target)
        return (target, .local, status.reason)
    }

    /// Suffix the name until it doesn't collide — two sessions started in the
    /// same second, or a leftover from a previous move.
    private static func uniqueURL(_ proposed: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else { return proposed }
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        let folder = proposed.deletingLastPathComponent()
        for n in 2... {
            let candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return proposed
    }
}

/// Records the raw RaceBox frame stream to a newline-delimited JSON capture
/// file, then files it in iCloud Drive.
///
/// One JSON object per line rather than a single JSON array: the format stays
/// extensible, but the file is append-only and valid at every instant, so a
/// crash or a force-quit costs the last line instead of making a multi-hour
/// capture unparseable.
///
/// Lives on `BLEManager` rather than in a view, so recording keeps running
/// while the user swipes between panels and the panel is torn down.
final class SessionRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var packetCount = 0
    /// Raw protocol bytes captured — the payload size, not the file size.
    @Published private(set) var capturedBytes = 0
    @Published private(set) var startedAt: Date?
    /// Set when a write fails; recording stops and the panel shows this.
    @Published private(set) var errorMessage: String?
    /// The most recent finished capture, for the panel to report.
    @Published private(set) var lastCapture: CompletedCapture?
    /// True between "stop" and the file landing in iCloud.
    @Published private(set) var isFinishing = false

    /// How often buffered frames are handed to the writer.
    private let flushInterval: TimeInterval = 1.0
    /// Flush early if a burst arrives, so memory can't grow without bound if
    /// the timer is starved.
    private let maxPendingFrames = 512

    private var writer: LogWriter?
    private var pending: [RecordedFrame] = []
    private var flushTimer: Timer?
    /// Monotonic reference for frame timestamps; unaffected by clock changes.
    private var startUptime: Double = 0
    private var sessionID = UUID()

    var elapsed: TimeInterval {
        guard isRecording else { return 0 }
        return ProcessInfo.processInfo.systemUptime - startUptime
    }

    // MARK: - Control

    /// Clears the finished-capture report at the start of a new device session.
    /// The panel should only ever offer a file this session actually produced —
    /// an earlier one may since have been moved, shared away, or deleted.
    func beginSession() {
        lastCapture = nil
        errorMessage = nil
    }

    /// Drops the finished-capture report if the file is no longer where it was
    /// left — deleted or moved from Files since this session recorded it.
    /// Cheap enough (one stat) to run each time the panel comes on screen.
    func forgetCaptureIfMissing() {
        guard let capture = lastCapture else { return }
        if !Self.stillExists(at: capture.url) { lastCapture = nil }
    }

    private static func stillExists(at url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        // A capture in iCloud that's been evicted to reclaim space is replaced
        // by a ".<name>.icloud" placeholder. The file still exists — it just
        // isn't downloaded — so that must not read as deleted.
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    func start(deviceName: String?, peripheralID: String?, nominalHz: Double?) {
        guard !isRecording else { return }

        sessionID = UUID()
        let now = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        packetCount = 0
        capturedBytes = 0
        errorMessage = nil
        lastCapture = nil

        let header = headerLine(startedAt: now, deviceName: deviceName,
                                peripheralID: peripheralID, nominalHz: nominalHz)
        do {
            // Written to a scratch directory first: appending 25 times a second
            // directly inside the iCloud container would have the sync daemon
            // chasing every flush.
            let scratch = try Self.scratchDirectory()
            let url = scratch.appendingPathComponent(Self.fileName(for: now))
            writer = try LogWriter(url: url, header: header)
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            return
        }

        startedAt = now
        isRecording = true
        // .common mode, not the default: a timer on the default mode stops
        // firing while the user is swiping between panels or panning the map,
        // which is exactly when a long capture shouldn't stall its flushes.
        let timer = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func stop() {
        guard isRecording, let writer else { return }
        isRecording = false
        flushTimer?.invalidate()
        flushTimer = nil
        flush()

        isFinishing = true
        let packets = packetCount
        let bytes = capturedBytes
        let duration = ProcessInfo.processInfo.systemUptime - startUptime
        let trailer = trailerLine(packets: packets, bytes: bytes, duration: duration)

        writer.finish(trailer: trailer) { [weak self] result in
            guard let self else { return }
            isFinishing = false
            switch result {
            case .success(let (url, destination, reason)):
                lastCapture = CompletedCapture(url: url, destination: destination,
                                               packets: packets, bytes: bytes,
                                               duration: duration,
                                               fallbackReason: reason)
            case .failure(let error):
                errorMessage = "Couldn't save capture: \(error.localizedDescription)"
            }
        }
        self.writer = nil
        startedAt = nil
    }

    // MARK: - Capture

    /// Called from the BLE delegate for every validated frame. Does the least
    /// work that will do — one array append — so the packet path stays clear;
    /// encoding and disk I/O happen on the writer queue at flush time.
    func record(frame: Data) {
        guard isRecording else { return }
        pending.append(RecordedFrame(t: ProcessInfo.processInfo.systemUptime - startUptime,
                                     data: frame))
        packetCount += 1
        capturedBytes += frame.count
        if pending.count >= maxPendingFrames { flush() }
    }

    private func flush() {
        guard !pending.isEmpty, let writer else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        writer.append(batch) { [weak self] message in
            guard let self else { return }
            errorMessage = "Recording stopped: \(message)"
            stop()
        }
    }

    // MARK: - File layout

    private static func scratchDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("Captures", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Sortable, filesystem-safe, and unambiguous across time zones.
    private static func fileName(for date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Gnimu-\(df.string(from: date)).jsonl"
    }

    // MARK: - Header and trailer

    /// The first line of every capture: everything about the session that the
    /// per-packet lines don't carry. Deliberately roomy — extra keys cost one
    /// line in the whole file, and a capture you can't attribute later is worth
    /// much less than one you can.
    private func headerLine(startedAt: Date, deviceName: String?,
                            peripheralID: String?, nominalHz: Double?) -> Data {
        var device: [String: Any] = [:]
        if let deviceName { device["name"] = deviceName }
        // Note: iOS peripheral identifiers are per-install, not device serials —
        // they identify a device within one install of the app, nothing more.
        if let peripheralID { device["peripheralId"] = peripheralID }

        var capture: [String: Any] = [
            "protocol": "racebox",
            "frameBytes": 88,
            "encoding": "base64",
            // Says how to read the "t" on every packet line.
            "timeBase": "seconds since startedAt, monotonic"
        ]
        if let nominalHz { capture["nominalHz"] = nominalHz }

        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo

        let header: [String: Any] = [
            "type": "header",
            "schema": captureSchemaVersion,
            "format": "gnimu-capture-jsonl",
            "sessionId": sessionID.uuidString,
            "startedAt": Self.iso8601.string(from: startedAt),
            "timeZone": TimeZone.current.identifier,
            "device": device,
            "app": [
                "name": info["CFBundleName"] as? String ?? "Gnimu Monitor",
                "version": info["CFBundleShortVersionString"] as? String ?? "",
                "build": info["CFBundleVersion"] as? String ?? ""
            ],
            "host": [
                "platform": Self.platformName,
                "systemVersion": process.operatingSystemVersionString,
                "model": Self.hardwareModel,
                // Both throttle timers and radio scheduling, so both can show up
                // as BLE jitter that has nothing to do with the device.
                "lowPowerMode": process.isLowPowerModeEnabled,
                "thermalState": Self.thermalStateName(process.thermalState)
            ],
            "capture": capture
        ]
        return Self.jsonLine(header)
    }

    /// The last line, written on a clean stop. Its absence is meaningful: a
    /// capture with no trailer was interrupted rather than stopped.
    private func trailerLine(packets: Int, bytes: Int, duration: TimeInterval) -> Data {
        Self.jsonLine([
            "type": "summary",
            "sessionId": sessionID.uuidString,
            "endedAt": Self.iso8601.string(from: Date()),
            "durationSeconds": (duration * 1000).rounded() / 1000,
            "packets": packets,
            "rawBytes": bytes,
            "meanHz": duration > 0 ? (Double(packets) / duration * 100).rounded() / 100 : 0
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> Data {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return Data("{}\n".utf8)
        }
        data.append(0x0A)
        return data
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var platformName: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    /// The marketing name isn't available, but the machine identifier
    /// ("iPhone17,1") pins down the hardware a capture came from.
    private static var hardwareModel: String {
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
