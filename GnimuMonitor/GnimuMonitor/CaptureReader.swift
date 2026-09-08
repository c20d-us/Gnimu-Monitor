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

/// The first line of a capture: everything about the session that the
/// per-packet lines don't carry. Mirrors what `SessionRecorder` writes.
nonisolated struct CaptureHeader: Sendable {
    var schema: Int = 0
    var format: String?
    var sessionId: String?
    var startedAt: Date?
    var timeZone: String?

    var deviceName: String?
    var peripheralId: String?

    var appVersion: String?
    var appBuild: String?

    var hostPlatform: String?
    var hostModel: String?
    var hostSystemVersion: String?
    /// Both throttle timers and radio scheduling, so both can look like device
    /// jitter in the analysis. Reported so a bad session can be attributed.
    var lowPowerMode: Bool?
    var thermalState: String?

    var nominalHz: Double?
    var frameBytes: Int = 88
}

/// The last line, written only on a clean stop. Its absence means the capture
/// was interrupted — which is itself a finding.
nonisolated struct CaptureTrailer: Sendable {
    var endedAt: Date?
    var durationSeconds: Double?
    var packets: Int?
    var rawBytes: Int?
    var meanHz: Double?
}

nonisolated enum CaptureReadError: LocalizedError {
    case unreadable(String)
    case missingHeader
    case noPackets
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Couldn't read the capture: \(why)"
        case .missingHeader:       return "This file has no capture header — it may not be a Gnimu capture."
        case .noPackets:           return "This capture contains no readable packets."
        case .cancelled:           return "Analysis was cancelled."
        }
    }
}

/// Streams a newline-delimited capture off disk.
///
/// Reads in fixed chunks rather than loading the file: a long session runs to
/// tens of megabytes, and nothing here needs more than one line at a time.
nonisolated enum CaptureReader {

    /// Bytes pulled from disk per read. Large enough that syscalls don't
    /// dominate, small enough that peak memory stays flat.
    private static let chunkSize = 1 << 20   // 1 MiB

    /// Reads `url` start to finish, delivering each element as it's parsed.
    ///
    /// `onFrame` receives the host arrival time (seconds since session start)
    /// and the decoded packet. Frames that fail to decode are counted and
    /// reported through `onUndecodable` rather than aborting the read — a
    /// corrupt line is a finding, not a fatal error.
    nonisolated static func read(
        url: URL,
        onHeader: (CaptureHeader) -> Void,
        onFrame: (Double, GnimuPacket) -> Void,
        onUndecodable: () -> Void,
        onTrailer: (CaptureTrailer) -> Void,
        onProgress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CaptureReadError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        // Progress is reported against file size: the only measure available
        // before the file has been read.
        let totalBytes = Double((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
        var bytesRead = 0.0

        var sawHeader = false
        var sawPacket = false
        var remainder = Data()
        var linesSinceCancelCheck = 0

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw CaptureReadError.unreadable(error.localizedDescription)
            }
            if chunk.isEmpty { break }

            bytesRead += Double(chunk.count)
            if totalBytes > 0 { onProgress(Swift.min(bytesRead / totalBytes, 1)) }

            remainder.append(chunk)

            // Hand off every complete line, keeping any partial tail for the
            // next chunk.
            while let newline = remainder.firstIndex(of: 0x0A) {
                let line = remainder[remainder.startIndex..<newline]
                remainder = remainder[remainder.index(after: newline)...]

                // Checking every line would cost more than it saves.
                linesSinceCancelCheck += 1
                if linesSinceCancelCheck >= 4096 {
                    linesSinceCancelCheck = 0
                    if isCancelled() { throw CaptureReadError.cancelled }
                }

                switch classify(line) {
                case .header(let h):
                    sawHeader = true
                    onHeader(h)
                case .frame(let t, let packet):
                    sawPacket = true
                    onFrame(t, packet)
                case .undecodable:
                    onUndecodable()
                case .trailer(let t):
                    onTrailer(t)
                case .blank:
                    break
                }
            }
            // Chunk boundaries slice into `remainder`; re-root it so the
            // sliced storage doesn't keep growing behind the indices.
            remainder = Data(remainder)
        }

        // A capture killed mid-write can end without a newline.
        if !remainder.isEmpty, case .frame(let t, let packet) = classify(remainder[...]) {
            sawPacket = true
            onFrame(t, packet)
        }

        guard sawHeader else { throw CaptureReadError.missingHeader }
        guard sawPacket else { throw CaptureReadError.noPackets }
    }

    // MARK: - Line parsing

    private enum Line {
        case header(CaptureHeader)
        case frame(Double, GnimuPacket)
        case trailer(CaptureTrailer)
        case undecodable
        case blank
    }

    private static func classify(_ line: Data.SubSequence) -> Line {
        guard line.count > 2 else { return .blank }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let dict = object as? [String: Any] else {
            return .undecodable
        }

        switch dict["type"] as? String {
        case "header":
            return .header(parseHeader(dict))
        case "summary":
            return .trailer(parseTrailer(dict))
        case .some:
            // An unrecognised typed line from a newer schema: skipped, not
            // counted against the device.
            return .blank
        case nil:
            // No "type" key means a packet line.
            guard let t = dict["t"] as? Double,
                  let encoded = dict["d"] as? String,
                  let bytes = Data(base64Encoded: encoded),
                  let packet = GnimuPacket.parse(from: bytes) else {
                return .undecodable
            }
            return .frame(t, packet)
        }
    }

    private static func parseHeader(_ d: [String: Any]) -> CaptureHeader {
        var h = CaptureHeader()
        h.schema = d["schema"] as? Int ?? 0
        h.format = d["format"] as? String
        h.sessionId = d["sessionId"] as? String
        h.timeZone = d["timeZone"] as? String
        if let s = d["startedAt"] as? String { h.startedAt = isoDate(s) }

        if let device = d["device"] as? [String: Any] {
            h.deviceName = device["name"] as? String
            h.peripheralId = device["peripheralId"] as? String
        }
        if let app = d["app"] as? [String: Any] {
            h.appVersion = app["version"] as? String
            h.appBuild = app["build"] as? String
        }
        if let host = d["host"] as? [String: Any] {
            h.hostPlatform = host["platform"] as? String
            h.hostModel = host["model"] as? String
            h.hostSystemVersion = host["systemVersion"] as? String
            h.lowPowerMode = host["lowPowerMode"] as? Bool
            h.thermalState = host["thermalState"] as? String
        }
        if let capture = d["capture"] as? [String: Any] {
            h.nominalHz = capture["nominalHz"] as? Double
            h.frameBytes = capture["frameBytes"] as? Int ?? 88
        }
        return h
    }

    private static func parseTrailer(_ d: [String: Any]) -> CaptureTrailer {
        var t = CaptureTrailer()
        if let s = d["endedAt"] as? String { t.endedAt = isoDate(s) }
        t.durationSeconds = d["durationSeconds"] as? Double
        t.packets = d["packets"] as? Int
        t.rawBytes = d["rawBytes"] as? Int
        t.meanHz = d["meanHz"] as? Double
        return t
    }

    /// The recorder writes fractional seconds; older or hand-edited files
    /// might not, so both are accepted.
    private static func isoDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
