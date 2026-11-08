//
//  RaceBoxFrameDecoderTests.swift
//  Gnimu MonitorTests
//
//  Pins how RaceBoxFrameDecoder turns an arbitrarily chopped notification
//  stream into frames: reassembly across notifications, several frames in
//  one, resynchronising after garbage, and discarding corrupt candidates.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

/// A valid frame whose iTOW identifies it: 1000 + 40 ms per index (25 Hz).
private func frame(_ index: Int) -> Data {
    var b = RaceBoxPacketBuilder()
    b.iTOW = UInt32(1000 + 40 * index)
    return b.build()
}

private func iTOWs(_ frames: [DecodedFrame]) -> [UInt32] {
    frames.map { $0.gnssEpochMs ?? 0 }
}

struct RaceBoxFrameDecoderTests {

    @Test func decodesOneFrameInOneNotification() {
        var decoder = RaceBoxFrameDecoder()
        let out = decoder.feed(frame(0))
        #expect(iTOWs(out) == [1000])
    }

    @Test func keepsTheBytesExactlyAsTheyArrived() {
        var decoder = RaceBoxFrameDecoder()
        let input = frame(3)
        let out = decoder.feed(input)
        #expect(out.count == 1)
        #expect(out.first?.raw == input)
    }

    @Test func waitsForTheRestOfAFrame() {
        var decoder = RaceBoxFrameDecoder()
        let f = frame(0)
        #expect(decoder.feed(f.prefix(87)).isEmpty)
        #expect(iTOWs(decoder.feed(f.suffix(1))) == [1000])
    }

    @Test(arguments: [1, 2, 6, 44, 86, 87])
    func reassemblesAFrameSplitAtAnyPoint(split: Int) {
        var decoder = RaceBoxFrameDecoder()
        let f = frame(5)
        var out = decoder.feed(f.prefix(split))
        out += decoder.feed(f.suffix(from: split))
        #expect(iTOWs(out) == [1200])
    }

    @Test func reassemblesFromSingleByteNotifications() {
        var decoder = RaceBoxFrameDecoder()
        var out: [DecodedFrame] = []
        for byte in frame(0) + frame(1) {
            out += decoder.feed(Data([byte]))
        }
        #expect(iTOWs(out) == [1000, 1040])
    }

    @Test func returnsEveryFrameInOneNotificationOldestFirst() {
        var decoder = RaceBoxFrameDecoder()
        let out = decoder.feed(frame(0) + frame(1) + frame(2))
        #expect(iTOWs(out) == [1000, 1040, 1080])
    }

    @Test func carriesTheTailOfAMergedNotificationIntoTheNext() {
        var decoder = RaceBoxFrameDecoder()
        let stream = frame(0) + frame(1) + frame(2)
        // Two whole frames and half of the third, then the rest.
        let cut = 88 * 2 + 44
        var out = decoder.feed(stream.prefix(cut))
        #expect(iTOWs(out) == [1000, 1040])
        out = decoder.feed(stream.suffix(from: cut))
        #expect(iTOWs(out) == [1080])
    }

    @Test func skipsLeadingGarbage() {
        var decoder = RaceBoxFrameDecoder()
        let garbage = Data([0x00, 0x11, 0xB5, 0x22, 0x62, 0x33])   // a lone B5 and a lone 62
        let out = decoder.feed(garbage + frame(0))
        #expect(iTOWs(out) == [1000])
    }

    @Test func aStraySyncPatternDoesNotSwallowTheRealFrameBehindIt() {
        var decoder = RaceBoxFrameDecoder()
        let stray = Data([0xB5, 0x62, 0x00, 0x00])
        let out = decoder.feed(stray + frame(0))
        #expect(iTOWs(out) == [1000])
    }

    @Test func dropsACorruptFrameAndKeepsTheNextOne() {
        var decoder = RaceBoxFrameDecoder()
        let corrupt = frame(0).replacing(byteAt: 30, with: 0xAA)
        let out = decoder.feed(corrupt + frame(1) + frame(2))
        #expect(iTOWs(out) == [1040, 1080])
    }

    @Test func recoversAfterALongRunOfNoise() {
        var decoder = RaceBoxFrameDecoder()
        #expect(decoder.feed(Data(repeating: 0x00, count: 200)).isEmpty)
        #expect(iTOWs(decoder.feed(frame(0))) == [1000])
    }

    @Test func resetDropsAPartialFrame() {
        var decoder = RaceBoxFrameDecoder()
        let f = frame(0)
        _ = decoder.feed(f.prefix(60))
        decoder.reset()
        // The second half alone must not complete anything...
        #expect(decoder.feed(f.suffix(from: 60)).isEmpty)
        // ...and the decoder still works afterwards.
        #expect(iTOWs(decoder.feed(frame(1))) == [1040])
    }

    @Test func decodedPacketMatchesWhatWasBuilt() throws {
        var b = RaceBoxPacketBuilder()
        b.iTOW = 555
        b.latitude = 48.8566
        b.longitude = 2.3522
        var decoder = RaceBoxFrameDecoder()
        let out = decoder.feed(b.build())
        let frame = try #require(out.first)
        #expect(frame.gnssEpochMs == 555)
        let gnss = try #require(frame.update.gnss)
        #expect(abs(try #require(gnss.latitude) - 48.8566) < 1e-7)
        #expect(abs(try #require(gnss.longitude) - 2.3522) < 1e-7)
        #expect(gnss.timeOfWeekMs == 555)
    }

    @Test func theUpdateIsExactlyWhatThePacketConvertsTo() throws {
        var b = RaceBoxPacketBuilder()
        b.iTOW = 777
        b.groundSpeedMps = 12.5
        b.battery = 0x80 | 64
        let bytes = b.build()
        var decoder = RaceBoxFrameDecoder()
        let frame = try #require(decoder.feed(bytes).first)
        let packet = try #require(RaceBoxPacket.parse(from: bytes))
        #expect(frame.update == packet.telemetryUpdate)
    }
}
