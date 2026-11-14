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
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

/// A panel the connected screen can show. The tab strip in the wide and
/// stacked layouts offers `stripTabs`; the swipeable deck pages through
/// `deckPages`, which adds the map and the g-force meter. Which of them a device
/// gets depends on what it provides (see `DeviceProfile`).
enum MonitorPanel: String, Identifiable {
    case map, data, fixRate, streamHealth, gForce, level, capture, device, vehicle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .map:          return "Map"
        case .data:         return "Data"
        case .fixRate:      return "Fix Rate"
        case .streamHealth: return "Stream"
        case .gForce:       return "G-Force"
        case .level:        return "Level"
        case .capture:      return "Capture"
        case .device:       return "Device"
        case .vehicle:      return "Vehicle"
        }
    }

    /// Panels the tab strip offers. The map, or for a device with no position
    /// the vehicle panel, fills the main area instead of being a tab. The
    /// Device panel exists only for devices that offer configuration and
    /// commands.
    static func stripTabs(profile: DeviceProfile, hasDevice: Bool) -> [MonitorPanel] {
        var tabs: [MonitorPanel] = []
        // With a position, the map is the main area and the vehicle is a tab;
        // without one, the vehicle panel is the main area.
        if profile.hasVehicle && profile.mapIsPrimary { tabs.append(.vehicle) }
        if profile.hasGnss || profile.hasImu { tabs.append(.data) }
        if profile.hasReceiverClock { tabs.append(.fixRate) }
        if profile.hasStreamHeader { tabs.append(.streamHealth) }
        if profile.hasImu { tabs.append(.level) }
        tabs.append(.capture)
        if hasDevice { tabs.append(.device) }
        return tabs
    }

    /// Pages of the swipeable deck, in order.
    static func deckPages(profile: DeviceProfile, hasDevice: Bool) -> [MonitorPanel] {
        var pages: [MonitorPanel] = []
        if profile.hasGnss { pages.append(.map) }
        if profile.hasVehicle { pages.append(.vehicle) }
        if profile.hasGnss || profile.hasImu { pages.append(.data) }
        if profile.hasReceiverClock { pages.append(.fixRate) }
        if profile.hasStreamHeader { pages.append(.streamHealth) }
        if profile.hasImu { pages.append(.gForce) }
        if profile.hasImu { pages.append(.level) }
        pages.append(.capture)
        if hasDevice { pages.append(.device) }
        return pages
    }
}

/// How the connected screen is arranged for the space it has. Chosen from the
/// actual size (not the device or size class) so a resizable iPad window, a
/// rotated iPad and an iPhone all land on a sensible layout.
enum MonitorLayout {
    /// Map on the left, glance box and panel on the right.
    case wide
    /// Map on top, glance box and panel below.
    case stacked
    /// Pinned glance box over a swipeable deck of pages.
    case deck

    // What each arrangement needs, in points. The wide layout's right column
    // takes at least `rightColumnMin`, and the map keeps at least `mapMinWidth`.
    static let rightColumnMin: CGFloat = 460
    static let mapMinWidth: CGFloat = 360
    static let wideMinWidth = rightColumnMin + mapMinWidth
    static let stackedMinHeight: CGFloat = 700
    static let deckAbove: CGFloat = 560

    static func choose(for size: CGSize) -> MonitorLayout {
        #if os(macOS)
        return .wide   // the window has a minimum size that always fits it
        #else
        if size.width < deckAbove || size.height < 480 { return .deck }
        if size.width >= wideMinWidth && size.width >= size.height { return .wide }
        if size.height >= stackedMinHeight { return .stacked }
        return .deck
        #endif
    }
}

struct MonitorView: View {
    @ObservedObject var ble: BLEManager
    /// The panel the user is on. One value shared by every layout, so resizing
    /// across a layout boundary keeps their place. Reset to Map on every
    /// launch (per-session state, not @AppStorage): the deck opens on its
    /// first page, and the strip layouts, which show the map permanently,
    /// read it as Data (see `stripSelection`).
    @State private var selected: MonitorPanel = MonitorView.initialPanel

    /// The panel shown first. Debug builds can ask for another with `-startPanel`.
    private static var initialPanel: MonitorPanel {
        #if DEBUG
        return DemoLaunch.startPanel ?? .map
        #else
        return .map
        #endif
    }
    /// The map's zoom, follow mode and style, held here so they survive a
    /// layout change that rebuilds the map view.
    @StateObject private var mapState = MapState()

    var body: some View {
        VStack(spacing: 0) {
            MonitorBar(ble: ble)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            GeometryReader { geo in
                switch MonitorLayout.choose(for: geo.size) {
                case .wide:    wideLayout(width: geo.size.width)
                case .stacked: stackedLayout(height: geo.size.height)
                case .deck:    deckLayout
                }
            }
            #if os(macOS)
            .frame(minWidth: MonitorLayout.wideMinWidth, minHeight: 520)
            #endif
        }
        // Keep the screen awake while the live monitor is on-screen. This view
        // only exists while connected, and iOS only honors it in the foreground.
        .onAppear { setKeepAwake(true) }
        .onDisappear { setKeepAwake(false) }
    }

    private func setKeepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    // MARK: - Shared pieces

    /// What the connected device provides, which decides the panels offered.
    private var profile: DeviceProfile {
        DeviceProfile(telemetry: ble.telemetry, deviceProtocol: ble.deviceProtocol)
    }

    private var stripTabs: [MonitorPanel] {
        MonitorPanel.stripTabs(profile: profile, hasDevice: ble.supportsDeviceControl)
    }

    /// The panel the tab strip shows. The map and g-force pages exist only in
    /// the deck, so a selection of either reads as the first tab (Data, for a
    /// device with a position) when the strip is on screen, without losing the
    /// deck's selection.
    private var stripSelection: MonitorPanel {
        stripTabs.contains(selected) ? selected : (stripTabs.first ?? .capture)
    }

    @ViewBuilder
    private var glanceBox: some View {
        Group {
            if profile.hasGnss || !profile.hasVehicle {
                GlanceBox(telemetry: ble.telemetry, fixRate: ble.fixRate)
            } else {
                VehicleGlanceBox(telemetry: ble.telemetry, streamHealth: ble.streamHealth,
                                 schema: ble.gnimuSchema)
            }
        }
        .padding(12)
    }

    /// The main area beside or above the panels: the map for a device with a
    /// position, otherwise the vehicle panel.
    @ViewBuilder
    private var mapPanel: some View {
        if profile.mapIsPrimary {
            MapPanel(telemetry: ble.telemetry, state: mapState)
        } else {
            VehiclePanel(ble: ble)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch stripSelection {
        case .fixRate: FixRatePanel(ble: ble)
        case .streamHealth: StreamHealthPanel(ble: ble)
        case .level:   LevelPanel(telemetry: ble.telemetry)
        case .capture: RecordPanel(ble: ble, recorder: ble.recorder,
                                   analysis: ble.analysisRunner)
        case .device:  DevicePanel(ble: ble, recorder: ble.recorder)
        case .vehicle: VehiclePanel(ble: ble)
        case .map, .gForce, .data: DataPanel(telemetry: ble.telemetry)
        }
    }

    /// The row of panel buttons under the panel.
    private var tabStrip: some View {
        HStack(spacing: 10) {
            ForEach(stripTabs) { tabButton($0) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// One button in the tab strip: bordered-prominent when selected, plain
    /// bordered otherwise, all equal-width via `maxWidth: .infinity`.
    @ViewBuilder
    private func tabButton(_ tab: MonitorPanel) -> some View {
        let isSelected = stripSelection == tab
        if isSelected {
            Button { selected = tab } label: {
                Text(tab.label).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { selected = tab } label: {
                Text(tab.label).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            #if os(iOS)
            // The system fill is nearly the colour of the bar behind it on iPad;
            // a darker backing makes the unselected tabs read as buttons.
            .background(Color.primary.opacity(0.10), in: Capsule())
            #endif
        }
    }

    // MARK: - Layouts

    /// Map on the left, glance box + switchable panel + tab strip on the right.
    /// The right column takes about 45% of the width, between 460 and 600 pt:
    /// enough for five tab buttons and the Device panel's rows, while the map
    /// keeps the rest.
    private func wideLayout(width: CGFloat) -> some View {
        let rightWidth = min(600, max(MonitorLayout.rightColumnMin, width * 0.45))
        return HStack(spacing: 0) {
            mapPanel
                .frame(maxWidth: .infinity)

            Divider()

            VStack(spacing: 0) {
                glanceBox

                Divider()

                // Scrolling content stays above the tab strip.
                panelContent.clipped()

                Divider()

                tabStrip
            }
            .frame(width: rightWidth)
        }
        // The columns run down into the iPad's home-indicator inset, so the
        // strip (and the divider above it) sit at the screen bottom instead of
        // leaving a band under it.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Map across the top, then glance box, panel and tab strip: for a portrait
    /// iPad, or a window too narrow for two columns but tall enough to stack.
    private func stackedLayout(height: CGFloat) -> some View {
        // The map is a glance at where the device is, so it stays modest and
        // the panel below gets the rest of the height.
        let mapHeight = min(340, max(180, height * 0.30))
        return VStack(spacing: 0) {
            mapPanel
                .frame(maxWidth: .infinity)
                .frame(height: mapHeight)

            Divider()

            glanceBox

            Divider()

            panelContent
                .frame(maxHeight: .infinity)
                .clipped()

            Divider()

            tabStrip
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Pinned glance box over a swipeable deck, for phones and small windows.
    @ViewBuilder
    private var deckLayout: some View {
        #if os(iOS)
        CompactMonitor(ble: ble, mapState: mapState, selected: $selected)
        #else
        wideLayout(width: MonitorLayout.wideMinWidth)
        #endif
    }
}

#if os(iOS)
/// Deck layout: a pinned glance box above a paged
/// Map / Data / Fix Rate / G-Force / Level / Capture (/ Device) deck.
private struct CompactMonitor: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var mapState: MapState
    @Binding var selected: MonitorPanel

    private var profile: DeviceProfile {
        DeviceProfile(telemetry: ble.telemetry, deviceProtocol: ble.deviceProtocol)
    }

    private var pages: [MonitorPanel] {
        MonitorPanel.deckPages(profile: profile, hasDevice: ble.supportsDeviceControl)
    }

    /// The page shown. A selection the device has no page for (the map, on a
    /// device with no position) reads as the first page that it does have.
    private var deckSelection: Binding<MonitorPanel> {
        Binding(get: { pages.contains(selected) ? selected : (pages.first ?? .capture) },
                set: { selected = $0 })
    }

    @ViewBuilder
    private func page(_ panel: MonitorPanel) -> some View {
        switch panel {
        case .map:          MapPage(telemetry: ble.telemetry, mapState: mapState)
        case .data:         DataPanel(telemetry: ble.telemetry)
        case .vehicle:      TitledPage("Vehicle") { VehiclePanel(ble: ble) }
        case .fixRate:      TitledPage("Fix Rate") { FixRatePanel(ble: ble) }
        case .streamHealth: TitledPage("Stream Health") { StreamHealthPanel(ble: ble) }
        case .gForce:       TitledPage("G-Force") { GForcePanel(telemetry: ble.telemetry) }
        case .level:        TitledPage("Level") { LevelPanel(telemetry: ble.telemetry) }
        case .capture:
            TitledPage("Capture") {
                RecordPanel(ble: ble, recorder: ble.recorder, analysis: ble.analysisRunner)
            }
        case .device:       DevicePanel(ble: ble, recorder: ble.recorder)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if profile.hasGnss || !profile.hasVehicle {
                    GlanceBox(telemetry: ble.telemetry, fixRate: ble.fixRate)
                } else {
                    VehicleGlanceBox(telemetry: ble.telemetry, streamHealth: ble.streamHealth,
                                 schema: ble.gnimuSchema)
                }
            }
            .padding(12)

            TabView(selection: deckSelection) {
                ForEach(pages) { panel in
                    page(panel).tag(panel)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
    }
}

/// Names a page in the compact deck. The split layout labels these panels with
/// its bottom tab strip; the swipeable deck has no such strip, so each of the
/// non-obvious pages carries its own title instead.
private struct TitledPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            content
        }
    }
}

/// Full-page g-force meter — a deck-only panel (not shown in the wide or stacked layouts).
private struct GForcePanel: View {
    let telemetry: TelemetryState?

    private var gMagnitude: Double {
        let x = telemetry?.imu?.longitudinalG ?? 0, y = telemetry?.imu?.lateralG ?? 0
        return (x * x + y * y).squareRoot()
    }

    var body: some View {
        VStack(spacing: 20) {
            // Matches the data-panel axis mapping (x: longitudinal, y: lateral).
            GForceMeter(x: telemetry?.imu?.lateralG ?? 0, y: telemetry?.imu?.longitudinalG ?? 0)
                .frame(width: 260, height: 260)
            Text(String(format: "%.2f g", gMagnitude))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A lateral/longitudinal g-force plot: rings at 1 g, crosshairs, and a dot for
/// the current acceleration clamped to the dial edge.
private struct GForceMeter: View {
    let x: Double   // horizontal axis g
    let y: Double   // vertical axis g (positive = up/forward)

    private let maxG = 2.0

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let r = min(cx, cy) - 2

            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                       with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            let rr = r / maxG   // 1 g reference ring
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                       with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            var cross = Path()
            cross.move(to: CGPoint(x: cx - r, y: cy)); cross.addLine(to: CGPoint(x: cx + r, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - r)); cross.addLine(to: CGPoint(x: cx, y: cy + r))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            let rawDx = CGFloat(x / maxG) * r
            let rawDy = CGFloat(-y / maxG) * r   // invert so forward = up
            let dist = sqrt(rawDx * rawDx + rawDy * rawDy)
            let scale = dist > r ? r / dist : 1.0
            let dx = rawDx * scale, dy = rawDy * scale

            let dot = max(8, min(cx, cy) * 0.1)
            ctx.fill(Path(ellipseIn: CGRect(x: cx + dx - dot / 2, y: cy + dy - dot / 2,
                                            width: dot, height: dot)),
                     with: .color(.green))
        }
    }
}

/// The map page in the compact deck. The map doesn't fill the page — a strip
/// below it stays part of the TabView so a horizontal swipe there flips pages
/// instead of being eaten by the map's own pan gesture.
private struct MapPage: View {
    let telemetry: TelemetryState?
    @ObservedObject var mapState: MapState

    var body: some View {
        VStack(spacing: 0) {
            MapPanel(telemetry: telemetry, state: mapState)

            // Empty strip that stays part of the TabView, giving the page dots
            // room and a place to swipe without the map eating the gesture.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.bar)
        }
    }
}
#endif

/// Slim top bar shown while connected: device name and a Disconnect button.
private struct MonitorBar: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        ZStack {
            // Centred, clear of the window controls an iPad window draws at the
            // leading edge, and of the Disconnect button at the trailing edge.
            if let name = ble.selectedDeviceName ?? ble.selectedPeripheral?.name {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 120)
            }

            HStack {
                Spacer()

                Button("Disconnect") { ble.disconnect() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }
}
