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
    /// The protocol the frames are in (`DeviceProtocol.rawValue`).
    var protocolName: String?
    /// What a line holds; "frame" is the only unit so far.
    var unit: String?
    /// The streams the file holds, each line naming one.
    var streams: [Stream] = []

    struct Stream: Sendable, Equatable {
        let name: String
        /// The characteristic the stream came from, as UUID text.
        let characteristic: String?
        let frameBytes: Int?
    }

    /// What the device reported about itself when recording began. Each is
    /// absent if the device hadn't reported it yet.
    var identity = DeviceIdentity()
    /// The Gnimu Schema and Device info characteristics' JSON.
    var deviceSchemaJSON: Data?
    var deviceInfoJSON: Data?
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
    case unsupportedProtocol(String)
    case unsupportedSchema(Int)
    case unsupportedUnit(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Couldn't read the capture: \(why)"
        case .missingHeader:       return "This file has no capture header — it may not be a Gnimu capture."
        case .noPackets:           return "This capture contains no readable packets."
        case .unsupportedProtocol(let name):
            return "This capture holds \(name) frames, which this version of the Monitor can't analyze."
        case .unsupportedSchema(let version):
            return version == 0 || version == 1
                ? "This capture was recorded by an older version of the Monitor (format \(version)) and can't be read. Record it again, or delete it."
                : "This capture is in a newer format (\(version)) than this version of the Monitor reads."
        case .unsupportedUnit(let unit):
            return "This capture records \(unit) lines, which this version of the Monitor can't read."
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
    /// `onFrame` receives the host arrival time (seconds since session start),
    /// the name of the stream the frame belongs to and its bytes, for the
    /// caller to decode in the header's protocol. Lines that aren't a readable frame line are reported through
    /// `onUndecodable` rather than aborting the read — a corrupt line is a
    /// finding, not a fatal error.
    nonisolated static func read(
        url: URL,
        onHeader: (CaptureHeader) -> Void,
        onFrame: (Double, String, Data) -> Void,
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
        var streamNames: Set<String> = []
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
                    try validate(h)
                    streamNames = Set(h.streams.map(\.name))
                    sawHeader = true
                    onHeader(h)
                case .frame(let t, let stream, let bytes):
                    // A frame naming a stream the header doesn't list isn't one
                    // this capture says it holds.
                    guard streamNames.contains(stream) else { onUndecodable(); continue }
                    sawPacket = true
                    onFrame(t, stream, bytes)
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
        if !remainder.isEmpty, case .frame(let t, let stream, let bytes) = classify(remainder[...]),
           streamNames.contains(stream) {
            sawPacket = true
            onFrame(t, stream, bytes)
        }

        guard sawHeader else { throw CaptureReadError.missingHeader }
        guard sawPacket else { throw CaptureReadError.noPackets }
    }

    // MARK: - Line parsing

    private enum Line {
        case header(CaptureHeader)
        case frame(Double, String, Data)
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
                  let stream = dict["c"] as? String,
                  let encoded = dict["d"] as? String,
                  let bytes = Data(base64Encoded: encoded) else {
                return .undecodable
            }
            return .frame(t, stream, bytes)
        }
    }

    /// Refuses a header this build can't read: another format version, a line
    /// unit it doesn't know, or a protocol it doesn't speak.
    static func validate(_ h: CaptureHeader) throws {
        guard h.schema == captureSchemaVersion else { throw CaptureReadError.unsupportedSchema(h.schema) }
        guard h.unit == captureUnit else { throw CaptureReadError.unsupportedUnit(h.unit ?? "unknown") }
        guard let name = h.protocolName, DeviceProtocol(rawValue: name) != nil else {
            throw CaptureReadError.unsupportedProtocol(h.protocolName ?? "unknown")
        }
    }

    static func parseHeader(_ d: [String: Any]) -> CaptureHeader {
        var h = CaptureHeader()
        h.schema = d["schema"] as? Int ?? 0
        h.format = d["format"] as? String
        h.sessionId = d["sessionId"] as? String
        h.timeZone = d["timeZone"] as? String
        if let s = d["startedAt"] as? String { h.startedAt = isoDate(s) }

        if let device = d["device"] as? [String: Any] {
            h.deviceName = device["name"] as? String
            h.peripheralId = device["peripheralId"] as? String
            if let id = device["identity"] as? [String: Any] {
                h.identity = DeviceIdentity(manufacturer: id["manufacturer"] as? String,
                                            model: id["model"] as? String,
                                            serial: id["serial"] as? String,
                                            firmware: id["firmware"] as? String,
                                            hardware: id["hardware"] as? String)
            }
            if let schema = device["schema"], JSONSerialization.isValidJSONObject(schema) {
                h.deviceSchemaJSON = try? JSONSerialization.data(withJSONObject: schema)
            }
            if let info = device["info"], JSONSerialization.isValidJSONObject(info) {
                h.deviceInfoJSON = try? JSONSerialization.data(withJSONObject: info)
            }
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
            h.protocolName = capture["protocol"] as? String
            h.unit = capture["unit"] as? String
            for entry in capture["streams"] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String else { continue }
                h.streams.append(.init(name: name, characteristic: entry["characteristic"] as? String,
                                       frameBytes: entry["frameBytes"] as? Int))
            }
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
