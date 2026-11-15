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

#if DEBUG
import CoreBluetooth
import Foundation

/// A capture file read for replay: the frames exactly as they were recorded,
/// each with when it arrived. Replay feeds them through the same decoder and
/// state path a live device uses, so the screens can be exercised, and a change
/// to that path checked, without hardware. Compiled into debug builds only.
///
/// Start one with launch arguments (Edit Scheme > Run > Arguments):
///   -replay /path/to/capture.jsonl   play it back as if a device were connected
///   -replaySpeed 4                   faster (or slower, 0.5) than real time
///   -replayLoop                      start again when it ends
/// Disconnect ends the replay.
nonisolated struct ReplayCapture {
    struct Frame {
        /// Seconds since the capture began, as recorded.
        let t: Double
        /// The stream it was recorded on, which names the characteristic it is
        /// replayed to.
        let stream: String
        let data: Data
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case noFrames
        case unsupported(Error)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read the capture: \(why)"
            case .noFrames: return "The capture holds no frames to replay."
            case .unsupported(let error): return error.localizedDescription
            }
        }
    }

    let deviceProtocol: DeviceProtocol
    let deviceName: String?
    let frames: [Frame]
    /// The characteristic each stream was recorded from, by stream name.
    let characteristics: [String: CBUUID]
    /// What the device reported about itself, restored so the Device panel and
    /// the channel names work as they did live.
    let identity: DeviceIdentity
    let schemaJSON: Data?
    let infoJSON: Data?

    /// Reads the whole file. Lines that aren't JSON, or aren't frames, are
    /// skipped: a replay shows what decodes, and the analyzer is the place
    /// that counts what doesn't.
    static func load(url: URL) throws -> ReplayCapture {
        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }

        var header: CaptureHeader?
        var frames: [Frame] = []

        for line in contents.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dict = object as? [String: Any] else { continue }

            switch dict["type"] as? String {
            case "header":
                let parsed = CaptureReader.parseHeader(dict)
                do { try CaptureReader.validate(parsed) } catch { throw LoadError.unsupported(error) }
                header = parsed
            case nil:
                if let t = dict["t"] as? Double,
                   let stream = dict["c"] as? String,
                   let encoded = dict["d"] as? String,
                   let bytes = Data(base64Encoded: encoded) {
                    frames.append(Frame(t: t, stream: stream, data: bytes))
                }
            default:
                continue   // a summary line, or a typed line from a newer schema
            }
        }

        guard let header, let name = header.protocolName,
              let deviceProtocol = DeviceProtocol(rawValue: name) else {
            throw LoadError.unsupported(CaptureReadError.missingHeader)
        }
        // Each stream goes back to the characteristic it was recorded from;
        // one the header doesn't give falls back to the protocol's own.
        var characteristics: [String: CBUUID] = [:]
        for stream in deviceProtocol.captureStreams { characteristics[stream.name] = stream.characteristic }
        for stream in header.streams {
            if let uuid = stream.characteristic { characteristics[stream.name] = CBUUID(string: uuid) }
        }
        frames = frames.filter { characteristics[$0.stream] != nil }
        guard !frames.isEmpty else { throw LoadError.noFrames }
        return ReplayCapture(deviceProtocol: deviceProtocol, deviceName: header.deviceName,
                             frames: frames, characteristics: characteristics,
                             identity: header.identity, schemaJSON: header.deviceSchemaJSON,
                             infoJSON: header.deviceInfoJSON)
    }
}
#endif
