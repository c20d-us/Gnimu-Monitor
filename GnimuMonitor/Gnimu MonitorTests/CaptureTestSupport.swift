//
//  CaptureTestSupport.swift
//  Gnimu MonitorTests
//
//  Pieces of the capture file format (schema 2) the synthetic captures share,
//  so each writes it the same way the recorder does.
//

import CoreBluetooth
import Foundation
@testable import Gnimu_Monitor

enum CaptureLines {
    /// One frame line, on the protocol's single stream.
    static func frame(t: Double, data: Data, stream: String = "frame") -> String {
        "{\"t\":\(String(format: "%.4f", t)),\"c\":\"\(stream)\",\"d\":\"\(data.base64EncodedString())\"}"
    }

    /// The header's `capture` block for a protocol.
    static func captureBlock(for deviceProtocol: DeviceProtocol, nominalHz: Double? = nil) -> [String: Any] {
        var block: [String: Any] = [
            "protocol": deviceProtocol.rawValue,
            "unit": "frame",
            "streams": deviceProtocol.captureStreams.map {
                ["name": $0.name, "characteristic": $0.characteristic.uuidString,
                 "frameBytes": $0.frameBytes] as [String: Any]
            },
            "encoding": "base64",
            "timeBase": "seconds since startedAt, monotonic",
        ]
        if let nominalHz { block["nominalHz"] = nominalHz }
        return block
    }

    /// A header line as JSON text, for the tests that write one by hand.
    static func headerText(for deviceProtocol: DeviceProtocol, nominalHz: Double? = nil,
                           startedAt: String = "2026-11-15T10:00:00.000Z",
                           deviceName: String? = nil) -> String {
        var header: [String: Any] = [
            "type": "header", "schema": captureSchemaVersion, "format": "gnimu-capture-jsonl",
            "startedAt": startedAt,
            "capture": captureBlock(for: deviceProtocol, nominalHz: nominalHz),
        ]
        if let deviceName { header["device"] = ["name": deviceName] }
        let data = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
