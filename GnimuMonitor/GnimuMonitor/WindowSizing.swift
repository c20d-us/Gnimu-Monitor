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

/// Default macOS window sizes for each screen.
enum WindowSize {
    static let picker = CGSize(width: 400, height: 600)
    // 4:3, matching iPad landscape so the Mac window feels like the same app.
    static let monitor = CGSize(width: 1200, height: 900)
}

extension Scene {
    /// Applies the macOS window defaults (size, centering, no frame restoration).
    /// A no-op on iOS/iPadOS, where the app is full-screen and several of these
    /// modifiers are unavailable.
    func gnimuWindowDefaults() -> some Scene {
        #if os(macOS)
        self
            // .contentMinSize lets .defaultSize set the launch size while the greedy
            // device list still can't stretch the window to fill the screen.
            .windowResizability(.contentMinSize)
            .defaultSize(width: WindowSize.picker.width, height: WindowSize.picker.height)
            .defaultPosition(.center)
            // Don't restore the previous window frame; relaunch always opens
            // centered at the default size.
            .restorationBehavior(.disabled)
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

extension View {
    /// On macOS, resize the hosting window to the picker/monitor size and
    /// re-center it whenever the connection state changes.
    func sizesWindow(connected: Bool) -> some View {
        modifier(WindowSizingModifier(connected: connected))
    }
}

private struct WindowSizingModifier: ViewModifier {
    let connected: Bool
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window = $0 })
            .onChange(of: connected) { _, isConnected in
                guard let window else { return }
                window.setContentSize(isConnected ? WindowSize.monitor : WindowSize.picker)
                window.center()
            }
    }
}

/// Bridges up to the AppKit `NSWindow` hosting this SwiftUI view.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#else

extension View {
    /// No-op on non-macOS platforms, which don't have free-floating windows.
    func sizesWindow(connected: Bool) -> some View { self }
}

#endif
