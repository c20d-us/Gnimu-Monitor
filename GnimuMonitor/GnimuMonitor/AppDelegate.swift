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

/// What the app delegate needs from the rest of the app to quit safely: the
/// recorder, so a capture in progress is filed before the process goes.
enum AppQuitGate {
    /// The recorder of the live session. Weak, since the manager owns it.
    nonisolated(unsafe) static weak var recorder: SessionRecorder?
    /// How long to wait for a capture to be filed before quitting regardless.
    /// Filing moves the file into iCloud, which can stall.
    static let timeout: TimeInterval = 10
}

#if os(macOS)
import AppKit

/// Quits the app when its last window closes — it is a single-window utility,
/// and a Mac app left running with no window has nothing to offer. Quitting
/// (this way or with Cmd-Q) finishes a capture in progress first, so the
/// recording is saved and filed, not cut off.
///
/// The report viewers are windows too, so the app quits only when all of them
/// are closed, which is what the delegate method means.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = AppQuitGate.recorder,
              recorder.isRecording || recorder.isFinishing else { return .terminateNow }

        let reply = OnceReply { sender.reply(toApplicationShouldTerminate: true) }
        recorder.whenIdle { reply.send() }
        // A stuck save mustn't keep the app from quitting. The capture is still
        // on disk in the app's scratch folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + AppQuitGate.timeout) { reply.send() }
        return .terminateLater
    }
}

/// Sends the terminate reply once, whichever of the save finishing and the
/// timeout comes first.
private final class OnceReply {
    private var sent = false
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func send() {
        guard !sent else { return }
        sent = true
        action()
    }
}
#endif
