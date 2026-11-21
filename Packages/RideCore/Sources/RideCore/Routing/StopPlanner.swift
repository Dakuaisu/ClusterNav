import Foundation

public enum StopKind: String, Sendable, CaseIterable, Identifiable {
    case fuel, rest
    public var id: String { rawValue }
}

/// A place a search returned, before anything is known about the detour to it.
public struct StopCandidate: Sendable, Equatable {
    public var name: String
    public var coordinate: Coordinate

    public init(name: String, coordinate: Coordinate) {
        self.name = name
        self.coordinate = coordinate
    }
}

/// A stop worth offering: how much longer the ride takes with it, and how far it is
/// from the planned line.
public struct StopSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { "\(name)|\(coordinate.latitude)|\(coordinate.longitude)" }
    public var name: String
    public var coordinate: Coordinate
    public var addedSeconds: Double
    public var offRouteMetres: Double

    public init(name: String, coordinate: Coordinate, addedSeconds: Double, offRouteMetres: Double) {
        self.name = name
        self.coordinate = coordinate
        self.addedSeconds = addedSeconds
        self.offRouteMetres = offRouteMetres
    }
}

/// Chooses where to look for stops along a planned line and ranks what was found by
/// the time a stop adds to the ride, not by straight-line distance.
public enum StopPlanner {
    public static let maxSearchPoints = 4
    public static let maxOffRouteMetres = 1_500.0
    public static let shortlistSize = 5
    /// Two results this close with the same name are one place.
    static let samePlaceMetres = 75.0

    /// Evenly spaced points inside the line (never its ends): one for a short ride,
    /// up to `maxSearchPoints` for a long one.
    public static func searchPoints(along line: [Coordinate]) -> [Coordinate] {
        let lengths = zip(line, line.dropFirst()).map { $0.distance(to: $1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }
        let count = min(maxSearchPoints, max(1, Int(total / 3_000)))
        return (1...count).compactMap { index in
            var remaining = total * Double(index) / Double(count + 1)
            for (segment, length) in lengths.enumerated() {
                if remaining <= length, length > 0 {
                    let t = remaining / length
                    let a = line[segment], b = line[segment + 1]
                    return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
                }
                remaining -= length
            }
            return line.last
        }
    }

    /// Search radius around each point, wide enough for neighbouring searches to meet.
    public static func searchRadius(along line: [Coordinate]) -> Double {
        let total = zip(line, line.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let spacing = total / Double(searchPoints(along: line).count + 1)
        return min(max(spacing * 0.6, 1_000), 5_000)
    }

    /// The few candidates nearest the line, without duplicates, nearest first.
    public static func shortlist(_ found: [StopCandidate], along line: [Coordinate]) -> [(candidate: StopCandidate, offRouteMetres: Double)] {
        var kept: [(candidate: StopCandidate, offRouteMetres: Double)] = []
        let measured = found.map { (candidate: $0, offRouteMetres: distance(from: $0.coordinate, to: line)) }
            .filter { $0.offRouteMetres <= maxOffRouteMetres }
            .sorted { $0.offRouteMetres < $1.offRouteMetres }
        for item in measured where !kept.contains(where: {
            $0.candidate.name.caseInsensitiveCompare(item.candidate.name) == .orderedSame
                && $0.candidate.coordinate.distance(to: item.candidate.coordinate) < samePlaceMetres
        }) {
            kept.append(item)
            if kept.count == shortlistSize { break }
        }
        return kept
    }

    /// Smallest detour first. `viaSeconds` is the travel time through the stop to the
    /// destination; a stop on the way can't make the ride shorter than planned.
    public static func ranked(_ timed: [(candidate: StopCandidate, offRouteMetres: Double, viaSeconds: Double)],
                              baseSeconds: Double) -> [StopSuggestion] {
        timed.map {
            StopSuggestion(name: $0.candidate.name, coordinate: $0.candidate.coordinate,
                           addedSeconds: max($0.viaSeconds - baseSeconds, 0), offRouteMetres: $0.offRouteMetres)
        }
        .sorted { ($0.addedSeconds, $0.offRouteMetres) < ($1.addedSeconds, $1.offRouteMetres) }
    }

    /// Metres from a point to the nearest part of the line.
    static func distance(from point: Coordinate, to line: [Coordinate]) -> Double {
        guard let first = line.first else { return .infinity }
        let metresPerLongitude = cos(point.latitude * .pi / 180) * 111_320
        func local(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * metresPerLongitude, (c.latitude - point.latitude) * 110_574)
        }
        var nearest = point.distance(to: first)
        for (a, b) in zip(line, line.dropFirst()) {
            let p = local(a), q = local(b)
            let dx = q.x - p.x, dy = q.y - p.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / lengthSquared)) : 0
            let x = p.x + t * dx, y = p.y + t * dy
            nearest = min(nearest, (x * x + y * y).squareRoot())
        }
        return nearest
    }
}
