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
        let data: Data
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case noFrames

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read the capture: \(why)"
            case .noFrames: return "The capture holds no frames to replay."
            }
        }
    }

    let deviceProtocol: DeviceProtocol
    let deviceName: String?
    let frames: [Frame]

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

        var deviceProtocol = DeviceProtocol.raceBox
        var deviceName: String?
        var frames: [Frame] = []

        for line in contents.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dict = object as? [String: Any] else { continue }

            switch dict["type"] as? String {
            case "header":
                if let capture = dict["capture"] as? [String: Any],
                   let raw = capture["protocol"] as? String,
                   let known = DeviceProtocol(rawValue: raw) {
                    deviceProtocol = known
                }
                if let device = dict["device"] as? [String: Any] {
                    deviceName = device["name"] as? String
                }
            case nil:
                if let t = dict["t"] as? Double,
                   let encoded = dict["d"] as? String,
                   let bytes = Data(base64Encoded: encoded) {
                    frames.append(Frame(t: t, data: bytes))
                }
            default:
                continue   // a summary line, or a typed line from a newer schema
            }
        }

        guard !frames.isEmpty else { throw LoadError.noFrames }
        return ReplayCapture(deviceProtocol: deviceProtocol, deviceName: deviceName, frames: frames)
    }
}
#endif
