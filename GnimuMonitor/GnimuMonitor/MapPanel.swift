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
                position = .camera(MapCamera(
                    centerCoordinate: packet.coordinate,
                    distance: 300,
                    heading: 0,
                    pitch: 0
                ))
            }

            Button {
                follow.toggle()
                if follow, let packet, packet.hasValidFix {
                    position = .camera(MapCamera(
                        centerCoordinate: packet.coordinate,
                        distance: 300,
                        heading: 0,
                        pitch: 0
                    ))
                }
            } label: {
                Image(systemName: follow ? "location.fill" : "location")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(follow ? "Following — click to unlock map" : "Click to follow device")
        }
        .onTapGesture { follow = false }
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
