//
//  GnimuFrameBuilder.swift
//  Gnimu MonitorTests
//
//  Test helper: builds Gnimu frames (v1) from field values, using the copied
//  layout. The app only decodes; this exists so tests can make frames the
//  vectors don't cover. Follows the spec's encoding: a value is multiplied by
//  its field's scale, rounded half away from zero, and saturated to its type
//  (aux fields, with no fixed scale, take raw integers).
//

import Foundation
@testable import Gnimu_Monitor

struct GnimuFrameBuilder {
    typealias V1 = GnimuFrameV1

    var deviceTimeMs: Int32 = 0
    var sequence: UInt8 = 0
    var capabilities: UInt8 = 0
    var state: UInt8 = 2
    private(set) var values: [V1.Field: Double] = [:]

    mutating func set(_ field: V1.Field, _ value: Double) { values[field] = value }

    func build() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: V1.frameBytes)
        put(&b, UInt64(UInt32(bitPattern: deviceTimeMs)), at: V1.deviceTimeMsOffset, bytes: 4)
        b[V1.sequenceOffset] = sequence
        b[V1.specVersionOffset] = V1.specVersion
        b[V1.capabilitiesOffset] = capabilities
        b[V1.stateOffset] = state

        for (field, value) in values {
            let info = V1.fields[field.rawValue]
            switch info.type {
            case .f64:
                put(&b, value.bitPattern, at: info.offset, bytes: 8)
            default:
                let scaled = info.scale == 0 ? value : value * Double(info.scale)
                let rounded = scaled >= 0 ? (scaled + 0.5).rounded(.down) : -((-scaled + 0.5).rounded(.down))
                let (lo, hi) = range(of: info.type)
                let raw = Int64(min(max(rounded, lo), hi))
                put(&b, UInt64(bitPattern: raw), at: info.offset, bytes: info.type.width)
            }
            let maskOffset = V1.blocks[info.block.rawValue].maskOffset
            b[maskOffset + info.bit / 8] |= UInt8(1 << (info.bit % 8))
        }
        return b
    }

    private func put(_ b: inout [UInt8], _ value: UInt64, at offset: Int, bytes: Int) {
        for i in 0..<bytes { b[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
    }

    private func range(of type: V1.WireType) -> (Double, Double) {
        switch type {
        case .u8: return (0, 255)
        case .u16: return (0, 65_535)
        case .i16: return (-32_768, 32_767)
        case .i32: return (-2_147_483_648, 2_147_483_647)
        case .f64: return (0, 0)
        }
    }
}
