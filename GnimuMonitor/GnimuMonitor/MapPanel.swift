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
import MapKit

struct MapPanel: View {
    let packet: GnimuPacket?

    @State private var position: MapCameraPosition = .automatic
    @State private var follow = true
    @State private var lastCameraUpdate: Date = .distantPast

    // Camera height when following. Backed off from max zoom so a little
    // surrounding road/context stays visible. Adjusted by the +/- controls.
    @State private var zoomDistance: CLLocationDistance = 800
    @State private var currentCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var satellite = false

    private let minDistance: CLLocationDistance = 80
    private let maxDistance: CLLocationDistance = 20000

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $position) {
                if let packet, packet.hasValidFix {
                    Annotation("", coordinate: packet.coordinate, anchor: .center) {
                        PositionMarker(heading: packet.headingOfMotion)
                    }
                }
            }
            .onChange(of: packet?.iTOW) { _, _ in
                guard follow, let packet, packet.hasValidFix else { return }
                let now = Date()
                guard now.timeIntervalSince(lastCameraUpdate) >= 0.2 else { return }
                lastCameraUpdate = now
                position = .camera(cameraFor(packet.coordinate))
            }
            .onMapCameraChange { context in
                currentCenter = context.camera.centerCoordinate
            }
            .mapStyle(satellite ? .hybrid : .standard)

            VStack(spacing: 8) {
                mapControl(systemName: satellite ? "map" : "globe.americas.fill") {
                    satellite.toggle()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .help(satellite ? "Show standard map" : "Show satellite imagery")

                mapControl(systemName: follow ? "location.fill" : "location") {
                    follow.toggle()
                    if follow, let packet, packet.hasValidFix {
                        position = .camera(cameraFor(packet.coordinate))
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .help(follow ? "Following — click to unlock map" : "Click to follow device")

                VStack(spacing: 0) {
                    mapControl(systemName: "plus") { zoom(by: 0.5) }
                    Divider().frame(width: 28)
                    mapControl(systemName: "minus") { zoom(by: 2.0) }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)
        }
        .onTapGesture { follow = false }
    }

    private func cameraFor(_ center: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(centerCoordinate: center, distance: zoomDistance, heading: 0, pitch: 0)
    }

    private func zoom(by factor: Double) {
        zoomDistance = min(max(zoomDistance * factor, minDistance), maxDistance)
        let center = (follow ? packet?.coordinate : nil) ?? currentCenter
        position = .camera(cameraFor(center))
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
