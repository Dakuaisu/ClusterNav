import Foundation
import RideCore
import Testing
@testable import ClusterNav

@MainActor
final class FakeStopFinder: StopFinderClient {
    var found: [StopCandidate]? = []
    var seconds: [String: Double] = [:]
    var placeSearches = 0
    var timings = 0
    var cancels = 0
    var holdPlaces = false
    var heldPlaces: (@MainActor ([StopCandidate]?) -> Void)?
    var lastPreferences: RoutePreferences?

    func places(_ kind: StopKind, near points: [Coordinate], radius: Double,
                completion: @escaping @MainActor ([StopCandidate]?) -> Void) {
        placeSearches += 1
        if holdPlaces { heldPlaces = completion } else { completion(found) }
    }

    func travelSeconds(from origin: Coordinate, via stop: Coordinate, to destination: Coordinate,
                       preferences: RoutePreferences, completion: @escaping @MainActor (Double?) -> Void) {
        timings += 1
        lastPreferences = preferences
        completion(seconds.first { $0.key == "\(stop.latitude),\(stop.longitude)" }?.value)
    }

    func cancel() { cancels += 1 }
}

@MainActor
struct StopSuggestionTests {
    let h = RideHarness()
    let finder = FakeStopFinder()
    let near = Coordinate(latitude: 12.9601, longitude: 77.5946)!
    let far = Coordinate(latitude: 12.9650, longitude: 77.5990)!

    init() {
        h.model.stopFinder = finder
        h.spy.line = [Coordinate(latitude: 12.95, longitude: 77.5946)!, h.office]
        finder.found = [StopCandidate(name: "Near pump", coordinate: near), StopCandidate(name: "Far pump", coordinate: far)]
        finder.seconds = ["\(near.latitude),\(near.longitude)": 900, "\(far.latitude),\(far.longitude)": 250]
    }

    private func preview(stop: Favourite? = nil) {
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false, stop: stop)
        h.spy.pendingRoute?(.success(h.spy.options))
    }

    @Test func suggestionsAreRankedByAddedTimeAndChoosingOnePlansThroughIt() throws {
        #expect(!h.model.canSuggestStops)
        h.model.routePreferences.avoidHighways = true
        preview()
        #expect(h.model.canSuggestStops)
        let base = try #require(h.model.routeOptions.first?.expectedSeconds)
        finder.seconds["\(far.latitude),\(far.longitude)"] = base + 120
        finder.seconds["\(near.latitude),\(near.longitude)"] = base + 600
        h.model.findStops(.fuel)
        guard case .results(.fuel, let stops) = h.model.stopSearch else {
            Issue.record("expected results, got \(h.model.stopSearch)")
            return
        }
        #expect(stops.map(\.name) == ["Far pump", "Near pump"], "the smaller detour wins, not the nearer place")
        #expect(stops.map(\.addedSeconds) == [120, 600])
        #expect(finder.lastPreferences?.avoidHighways == true, "detours are timed with the ride's route choices")
        #expect(h.spy.routeRequests == 1 && h.spy.started == 0, "suggesting stops requests no route and starts nothing")

        h.wait()
        h.model.chooseStop(stops[0])
        let request = try #require(h.spy.requests.last)
        #expect(h.spy.routeRequests == 2 && request.target == far, "the ride is planned again, to the stop first")
        #expect(h.model.stopSearch == .idle)
        h.spy.pendingRoute?(.success(h.spy.options))
        guard case .preview(let pending) = h.model.stage else {
            Issue.record("expected a preview, got \(h.model.stage)")
            return
        }
        #expect(pending.label == "Office" && pending.stop?.label == "Far pump")
        #expect(!h.model.canSuggestStops, "one stop per ride")
        #expect(h.spy.started == 0 && h.spy.committed.isEmpty)
    }

    @Test func failuresAndEmptySearchesAreReportedAsSuch() {
        preview()
        finder.found = nil
        h.model.findStops(.rest)
        guard case .failed = h.model.stopSearch else {
            Issue.record("a failed search is not an empty result: \(h.model.stopSearch)")
            return
        }
        finder.found = []
        h.model.findStops(.rest)
        #expect(h.model.stopSearch == .results(.rest, []))
        finder.found = [StopCandidate(name: "Untimed", coordinate: near)]
        finder.seconds = [:]
        h.model.findStops(.rest)
        guard case .failed = h.model.stopSearch else {
            Issue.record("places that couldn't be timed are not offered: \(h.model.stopSearch)")
            return
        }
        #expect(h.spy.routeRequests == 1)
    }

    @Test func aLateAnswerForAClosedPreviewIsIgnored() {
        preview()
        finder.holdPlaces = true
        h.model.findStops(.fuel)
        #expect(h.model.stopSearch == .searching(.fuel))
        h.model.cancelPreview()
        finder.heldPlaces?(finder.found)
        #expect(h.model.stopSearch != .results(.fuel, []) && finder.timings == 0)
        if case .results = h.model.stopSearch { Issue.record("results appeared for a preview that is gone") }
    }

    @Test func aRideThatAlreadyHasAStopIsNotOfferedAnother() {
        preview(stop: h.fuel)
        #expect(!h.model.canSuggestStops)
        h.model.findStops(.fuel)
        guard case .failed = h.model.stopSearch else {
            Issue.record("expected a refusal, got \(h.model.stopSearch)")
            return
        }
        #expect(finder.placeSearches == 0)
    }
}
