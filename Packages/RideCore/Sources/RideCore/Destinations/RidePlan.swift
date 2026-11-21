import Foundation

/// A ride worth repeating: where to, the optional stop, and the route choices that go
/// with it. No route is stored; one is calculated from the rider's position each time.
public struct RidePlan: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var destination: Favourite
    public var stop: Favourite?
    public var preferences: RoutePreferences

    public init(id: UUID = UUID(), name: String, destination: Favourite, stop: Favourite? = nil,
                preferences: RoutePreferences = RoutePreferences()) {
        self.id = id
        self.name = name
        self.destination = destination
        self.stop = stop
        self.preferences = preferences
    }

    /// "To Office · via Fuel · no tolls", for a list row.
    public var summary: String {
        var parts = ["To \(destination.label)"]
        if let stop { parts.append("via \(stop.label)") }
        if preferences.avoidTolls { parts.append("no tolls") }
        if preferences.avoidHighways { parts.append("no highways") }
        return parts.joined(separator: " · ")
    }
}

public struct RidePlanList: Sendable, Equatable, Codable {
    public private(set) var items: [RidePlan] = []
    public static let maxPlans = 20

    public init(items: [RidePlan] = []) {
        self.items = Array(items.prefix(Self.maxPlans))
    }

    /// Newest first. A plan with the same name (ignoring case) is replaced. False when full.
    @discardableResult
    public mutating func save(_ plan: RidePlan) -> Bool {
        var plan = plan
        let name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.name = String((name.isEmpty ? plan.destination.label : name).prefix(FavouritesList.maxLabelLength))
        let replaced = items.contains { $0.name.caseInsensitiveCompare(plan.name) == .orderedSame }
        guard replaced || items.count < Self.maxPlans else { return false }
        items.removeAll { $0.name.caseInsensitiveCompare(plan.name) == .orderedSame }
        items.insert(plan, at: 0)
        return true
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
