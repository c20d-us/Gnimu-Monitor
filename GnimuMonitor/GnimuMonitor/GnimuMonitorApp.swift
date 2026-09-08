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

import SwiftUI

/// Identifier for the report window scene, shared between the scene that
/// declares it and the panel that opens it.
enum ReportWindow {
    static let id = "gnimu-report"
}

@main
struct GnimuMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .gnimuWindowDefaults()

        #if os(macOS)
        // A real window rather than a sheet: macOS sheets can't be resized, and
        // a long report is exactly the thing you want to make taller. It also
        // lets a report stay open while you browse other captures, and lets
        // several be open at once.
        WindowGroup(id: ReportWindow.id, for: ReportSelection.self) { $selection in
            if let selection {
                ReportViewer(selection: selection)
                    .frame(minWidth: 900, minHeight: 420)
            }
        }
        .defaultSize(width: 1300, height: 900)
        .defaultPosition(.center)
        // contentMinSize, not contentSize: the window can be dragged to any
        // size at or above the content's minimum.
        .windowResizability(.contentMinSize)
        #endif
    }
}
