import CoreLocation
import MapKit
import RideCore
import SwiftUI

/// What the recap map and summary draw from a track, computed once per render.
struct RideRecapGeometry {
    let segments: [[CLLocationCoordinate2D]]
    /// Summed within each segment, never across a gap; nil without two points in a segment.
    let distance: CLLocationDistance?

    init(track: RideTrack) {
        let recorded = track.segments.filter { !$0.isEmpty }
        segments = recorded.map { segment in
            segment.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        }
        let pairs = recorded.flatMap { zip($0, $0.dropFirst()) }
        distance = pairs.isEmpty ? nil
            : pairs.reduce(0) { $0 + $1.0.coordinate.distance(to: $1.1.coordinate) }
    }

    var region: MKCoordinateRegion? {
        let coordinates = segments.flatMap { $0 }
        guard let first = coordinates.first else { return nil }
        var south = first.latitude, north = first.latitude, west = first.longitude, east = first.longitude
        for coordinate in coordinates {
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
            west = min(west, coordinate.longitude)
            east = max(east, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(180, max(0.01, (north - south) * 1.4)),
                                   longitudeDelta: min(360, max(0.01, (east - west) * 1.4))))
    }
}

struct RideRecapMap: View {
    let track: RideTrack
    let geometry: RideRecapGeometry
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(position: $position) {
                ForEach(Array(geometry.segments.enumerated()), id: \.offset) { _, segment in
                    if segment.count == 1, let point = segment.first {
                        Annotation("Recorded point", coordinate: point) {
                            Image(systemName: "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.accentColor, in: Circle())
                        }
                    } else {
                        MapPolyline(coordinates: segment)
                            .stroke(Color.accentColor, lineWidth: 4)
                    }
                }
            }
            .frame(height: 240)
            .accessibilityLabel("Map of recorded GPS segments")
            Button {
                if let region = geometry.region { position = .region(region) }
            } label: {
                Label("Fit route", systemImage: "viewfinder")
            }
            .accessibilityIdentifier("fitRecapRouteButton")
        }
        .onAppear {
            if let region = geometry.region { position = .region(region) }
        }
        .onChange(of: track) { _, _ in
            if !position.positionedByUser, let region = geometry.region { position = .region(region) }
        }
    }
}
