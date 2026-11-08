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
import Combine
import MapKit

/// The map's view state, kept above the panel so it survives layout changes:
/// resizing a window can swap the map between layouts, and a view that is
/// torn down and rebuilt would otherwise forget its zoom, follow mode and style.
final class MapState: ObservableObject {
    @Published var position: MapCameraPosition = .automatic
    @Published var follow = true
    @Published var satellite = false
    // Camera height when following. Backed off from max zoom so a little
    // surrounding road/context stays visible. Adjusted by the +/- controls.
    var zoomDistance: CLLocationDistance = 800
    var currentCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var lastCameraUpdate: Date = .distantPast
}

struct MapPanel: View {
    let telemetry: TelemetryState?
    @ObservedObject var state: MapState

    private var gnss: GnssBlock? { telemetry?.gnss }
    /// Where the device is, only while it reports a usable fix.
    private var fixCoordinate: CLLocationCoordinate2D? {
        guard let gnss, gnss.hasFix else { return nil }
        return gnss.coordinate
    }

    private let minDistance: CLLocationDistance = 80
    private let maxDistance: CLLocationDistance = 20000

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $state.position) {
                if let coordinate = fixCoordinate {
                    Annotation("", coordinate: coordinate, anchor: .center) {
                        PositionMarker(heading: gnss?.headingDeg ?? 0)
                    }
                }
            }
            .onChange(of: telemetry?.revision) { _, _ in
                guard state.follow, let coordinate = fixCoordinate else { return }
                let now = Date()
                guard now.timeIntervalSince(state.lastCameraUpdate) >= 0.2 else { return }
                state.lastCameraUpdate = now
                state.position = .camera(cameraFor(coordinate))
            }
            .onMapCameraChange { context in
                state.currentCenter = context.camera.centerCoordinate
            }
            .mapStyle(state.satellite ? .hybrid : .standard)

            VStack(spacing: 8) {
                mapControl(systemName: state.satellite ? "map" : "globe.americas.fill") {
                    state.satellite.toggle()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .help(state.satellite ? "Show standard map" : "Show satellite imagery")

                mapControl(systemName: state.follow ? "location.fill" : "location") {
                    state.follow.toggle()
                    if state.follow, let coordinate = fixCoordinate {
                        state.position = .camera(cameraFor(coordinate))
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .help(state.follow ? "Following — click to unlock map" : "Click to follow device")

                VStack(spacing: 0) {
                    mapControl(systemName: "plus") { zoom(by: 0.5) }
                    Divider().frame(width: 28)
                    mapControl(systemName: "minus") { zoom(by: 2.0) }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)
        }
        .onTapGesture { state.follow = false }
    }

    private func cameraFor(_ center: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(centerCoordinate: center, distance: state.zoomDistance, heading: 0, pitch: 0)
    }

    private func zoom(by factor: Double) {
        state.zoomDistance = min(max(state.zoomDistance * factor, minDistance), maxDistance)
        let center = (state.follow ? gnss?.coordinate : nil) ?? state.currentCenter
        state.position = .camera(cameraFor(center))
    }

    @ViewBuilder
    private func mapControl(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PositionMarker: View {
    let heading: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.25))
                .frame(width: 24, height: 24)
            Circle()
                .fill(.blue)
                .frame(width: 10, height: 10)
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 7))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(heading))
        }
    }
}
