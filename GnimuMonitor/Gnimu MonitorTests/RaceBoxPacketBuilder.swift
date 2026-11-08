//
//  RaceBoxPacketBuilder.swift
//  Gnimu MonitorTests
//
//  Test helper: builds valid 88-byte RaceBox data packets (UBX framing,
//  class 0xFF id 0x01, 80-byte payload, Fletcher checksum). Fields are in
//  natural units; the builder scales them to the wire format. Written against
//  the layout RaceBoxPacket.parse reads, so a parse regression shows up as a
//  mismatch between what was built and what was decoded.
//

import Foundation

struct RaceBoxPacketBuilder {
    var iTOW: UInt32 = 0
    var year: UInt16 = 2026
    var month: UInt8 = 11
    var day: UInt8 = 8
    var hour: UInt8 = 12
    var minute: UInt8 = 30
    var second: UInt8 = 15
    var validityFlags: UInt8 = 0x07
    var timeAccuracyNs: UInt32 = 25
    var nanoseconds: Int32 = 0
    var fixType: UInt8 = 3
    var fixStatusFlags: UInt8 = 0x01
    var dateTimeFlags: UInt8 = 0xE0
    var numSV: UInt8 = 12

    var longitude: Double = 0          // degrees
    var latitude: Double = 0           // degrees
    var heightEllipsoidM: Double = 0
    var heightMSLM: Double = 0
    var hAccM: Double = 1.0
    var vAccM: Double = 1.5
    var groundSpeedMps: Double = 0
    var headingDeg: Double = 0
    var speedAccMps: Double = 0.1
    var headingAccDeg: Double = 1.0
    var pDOP: Double = 1.2
    var latLonFlags: UInt8 = 0
    /// The raw battery byte: bit 7 is charging, the low 7 bits the level.
    var battery: UInt8 = 80

    var accelXG: Double = 0
    var accelYG: Double = 0
    var accelZG: Double = 1
    var gyroXDps: Double = 0
    var gyroYDps: Double = 0
    var gyroZDps: Double = 0

    static let frameBytes = 88

    /// Fletcher checksum over class, id, length and payload (bytes 2..<86).
    static func checksum(of bytes: [UInt8]) -> (UInt8, UInt8) {
        var a: UInt8 = 0
        var b: UInt8 = 0
        for i in 2..<86 {
            a = a &+ bytes[i]
            b = b &+ a
        }
        return (a, b)
    }

    func build() -> Data {
        var b = [UInt8](repeating: 0, count: Self.frameBytes)
        b[0] = 0xB5; b[1] = 0x62      // sync
        b[2] = 0xFF; b[3] = 0x01      // class, id
        b[4] = 0x50; b[5] = 0x00      // payload length 80, little-endian

        let p = 6                     // payload base
        func put(_ value: UInt64, at offset: Int, bytes: Int) {
            for i in 0..<bytes { b[p + offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        func putU32(_ v: UInt32, _ o: Int) { put(UInt64(v), at: o, bytes: 4) }
        func putI32(_ v: Int32, _ o: Int) { put(UInt64(UInt32(bitPattern: v)), at: o, bytes: 4) }
        func putU16(_ v: UInt16, _ o: Int) { put(UInt64(v), at: o, bytes: 2) }
        func putI16(_ v: Int16, _ o: Int) { put(UInt64(UInt16(bitPattern: v)), at: o, bytes: 2) }
        func scaledI32(_ v: Double, _ scale: Double) -> Int32 { Int32((v * scale).rounded()) }
        func scaledU32(_ v: Double, _ scale: Double) -> UInt32 { UInt32((v * scale).rounded()) }
        func scaledI16(_ v: Double, _ scale: Double) -> Int16 { Int16((v * scale).rounded()) }

        putU32(iTOW, 0)
        putU16(year, 4)
        b[p + 6] = month
        b[p + 7] = day
        b[p + 8] = hour
        b[p + 9] = minute
        b[p + 10] = second
        b[p + 11] = validityFlags
        putU32(timeAccuracyNs, 12)
        putI32(nanoseconds, 16)
        b[p + 20] = fixType
        b[p + 21] = fixStatusFlags
        b[p + 22] = dateTimeFlags
        b[p + 23] = numSV
        putI32(scaledI32(longitude, 1e7), 24)
        putI32(scaledI32(latitude, 1e7), 28)
        putI32(scaledI32(heightEllipsoidM, 1000), 32)
        putI32(scaledI32(heightMSLM, 1000), 36)
        putU32(scaledU32(hAccM, 1000), 40)
        putU32(scaledU32(vAccM, 1000), 44)
        putI32(scaledI32(groundSpeedMps, 1000), 48)
        putI32(scaledI32(headingDeg, 1e5), 52)
        putU32(scaledU32(speedAccMps, 1000), 56)
        putU32(scaledU32(headingAccDeg, 1e5), 60)
        putU16(UInt16((pDOP * 100).rounded()), 64)
        b[p + 66] = latLonFlags
        b[p + 67] = battery
        putI16(scaledI16(accelXG, 1000), 68)
        putI16(scaledI16(accelYG, 1000), 70)
        putI16(scaledI16(accelZG, 1000), 72)
        putI16(scaledI16(gyroXDps, 100), 74)
        putI16(scaledI16(gyroYDps, 100), 76)
        putI16(scaledI16(gyroZDps, 100), 78)

        let (ckA, ckB) = Self.checksum(of: b)
        b[86] = ckA
        b[87] = ckB
        return Data(b)
    }
}

extension Data {
    /// A copy with one byte replaced, leaving the checksum alone, so the
    /// result is a deliberately corrupt packet.
    func replacing(byteAt index: Int, with value: UInt8) -> Data {
        var copy = [UInt8](self)
        copy[index] = value
        return Data(copy)
    }
}
