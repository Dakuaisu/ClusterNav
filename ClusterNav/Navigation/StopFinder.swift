import CoreLocation
import MapKit
import RideCore

/// Finds places along a route and how long a detour through one takes. Replaceable
/// in tests; the real one asks Apple Maps.
@MainActor
protocol StopFinderClient: AnyObject {
    /// Places of this kind around each point. Nil when no search could be completed.
    func places(_ kind: StopKind, near points: [Coordinate], radius: Double,
                completion: @escaping @MainActor ([StopCandidate]?) -> Void)
    /// Travel time from `origin` through `stop` to `destination`. Nil when unknown.
    func travelSeconds(from origin: Coordinate, via stop: Coordinate, to destination: Coordinate,
                       preferences: RoutePreferences, completion: @escaping @MainActor (Double?) -> Void)
    /// Abandons everything in flight; none of it answers afterwards.
    func cancel()
}

@MainActor
final class MapKitStopFinder: StopFinderClient {
    private var generation = 0
    private var searches: [MKLocalSearch] = []
    private var estimates: [MKDirections] = []

    func places(_ kind: StopKind, near points: [Coordinate], radius: Double,
                completion: @escaping @MainActor ([StopCandidate]?) -> Void) {
        let mine = generation
        guard !points.isEmpty else { return completion([]) }
        let tally = Tally(outstanding: points.count)
        for point in points {
            let request = MKLocalPointsOfInterestRequest(center: Self.location(point), radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.categories(kind))
            let search = MKLocalSearch(request: request)
            searches.append(search)
            search.start { response, _ in
                let found = response.map { $0.mapItems.compactMap(Self.candidate) }
                MainActor.assumeIsolated {
                    guard mine == self.generation else { return }
                    if let found {
                        tally.succeeded = true
                        tally.candidates += found
                    }
                    tally.outstanding -= 1
                    if tally.outstanding == 0 { completion(tally.succeeded ? tally.candidates : nil) }
                }
            }
        }
    }

    func travelSeconds(from origin: Coordinate, via stop: Coordinate, to destination: Coordinate,
                       preferences: RoutePreferences, completion: @escaping @MainActor (Double?) -> Void) {
        let mine = generation
        let tally = Tally(outstanding: 2)
        tally.succeeded = true
        for (start, end) in [(origin, stop), (stop, destination)] {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(start)))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(end)))
            request.transportType = .automobile
            request.tollPreference = preferences.avoidTolls ? .avoid : .any
            request.highwayPreference = preferences.avoidHighways ? .avoid : .any
            let directions = MKDirections(request: request)
            estimates.append(directions)
            directions.calculateETA { response, _ in
                let seconds = response?.expectedTravelTime
                MainActor.assumeIsolated {
                    guard mine == self.generation else { return }
                    if let seconds { tally.seconds += seconds } else { tally.succeeded = false }
                    tally.outstanding -= 1
                    if tally.outstanding == 0 { completion(tally.succeeded ? tally.seconds : nil) }
                }
            }
        }
    }

    func cancel() {
        generation += 1
        searches.forEach { $0.cancel() }
        estimates.forEach { $0.cancel() }
        searches = []
        estimates = []
    }

    @MainActor
    private final class Tally {
        var outstanding: Int
        var succeeded = false
        var candidates: [StopCandidate] = []
        var seconds = 0.0

        init(outstanding: Int) {
            self.outstanding = outstanding
        }
    }

    private static func categories(_ kind: StopKind) -> [MKPointOfInterestCategory] {
        switch kind {
        case .fuel: [.gasStation]
        case .rest: [.cafe, .restaurant, .restroom]
        }
    }

    private static func location(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    nonisolated private static func candidate(_ item: MKMapItem) -> StopCandidate? {
        let point: CLLocationCoordinate2D
        if #available(iOS 26, *) { point = item.location.coordinate } else { point = item.placemark.coordinate }
        guard let name = item.name, !name.isEmpty,
              let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude) else { return nil }
        return StopCandidate(name: name, coordinate: coordinate)
    }
}
