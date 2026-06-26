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
