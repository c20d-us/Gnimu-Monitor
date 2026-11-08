//
//  Gnimu_MonitorTests.swift
//  Gnimu MonitorTests
//
//  Created by Chris Halstead on 11/8/26.
//

import Testing
@testable import Gnimu_Monitor

struct Gnimu_MonitorTests {

    /// Smoke test: proves the test bundle loads inside the app and can see its types.
    @Test func raceBoxFrameIsEightyEightBytes() {
        #expect(RaceBoxFrameDecoder.frameBytes == 88)
        #expect(DeviceProtocol.raceBox.frameBytes == 88)
    }

}
