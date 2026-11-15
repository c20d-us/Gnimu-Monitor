//
//  QuitSafetyTests.swift
//  Gnimu MonitorTests
//
//  Quitting while a capture is recording: the recorder reports when it is idle,
//  which is what the macOS app delegate waits for before letting the app quit.
//

import Foundation
import Testing
@testable import Gnimu_Monitor

@MainActor
struct QuitSafetyTests {
    @Test func anIdleRecorderRunsTheBlockAtOnce() {
        let recorder = SessionRecorder()
        var ran = false
        recorder.whenIdle { ran = true }
        #expect(ran)
    }

    @Test func theQuitGateHoldsTheLiveRecorder() {
        let ble = BLEManager()
        #expect(AppQuitGate.recorder === ble.recorder)
    }
}
