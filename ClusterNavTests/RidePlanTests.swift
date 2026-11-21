import Foundation
import RideCore
import Testing
@testable import ClusterNav

@MainActor
struct RidePlanTests {
    @Test func aPlanKeepsDestinationStopAndRouteChoicesAndIsRecalculatedOnUse() throws {
        let h = RideHarness()
        #expect(h.model.savePlan(named: "Commute") != nil, "only a previewed ride can be saved")
        h.model.routePreferences.avoidTolls = true
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false, stop: h.fuel)
        h.spy.pendingRoute?(.success(h.spy.options))
        #expect(h.model.savePlan(named: "  Commute ") == nil)
        #expect(h.model.plans.items.map(\.name) == ["Commute"])
        #expect(h.model.plans.items.first?.summary == "To Office · via Fuel · no tolls")
        #expect(h.spy.started == 0, "saving a plan starts nothing")

        let later = RideHarness(storage: h.storage, defaults: h.defaults)
        later.model.routePreferences.avoidTolls = false
        let plan = try #require(later.model.plans.items.first, "plans survive a restart")
        later.model.usePlan(plan)
        let request = try #require(later.spy.requests.last)
        #expect(later.spy.routeRequests == 1, "a fresh route is requested; nothing stored is reused")
        #expect(request.preferences == RoutePreferences(avoidTolls: true, avoidHighways: false),
                "the plan's own choices apply")
        #expect(later.model.routePreferences.avoidTolls, "and become the current route settings, so reroutes match")
        #expect(request.target == h.fuel.coordinate, "the first leg goes to the plan's stop")
        later.spy.pendingRoute?(.success(later.spy.options))
        guard case .preview(let pending) = later.model.stage else {
            Issue.record("expected a preview, got \(later.model.stage)")
            return
        }
        #expect(pending.label == "Office" && pending.stop?.label == "Fuel")
        #expect(later.spy.started == 0 && later.spy.committed.isEmpty, "Start stays a separate tap")

        later.model.deletePlan(plan.id)
        #expect(RideHarness(storage: h.storage, defaults: h.defaults).model.plans.items.isEmpty)
    }

    @Test func aPlanCannotReplaceARideInProgress() throws {
        let h = RideHarness()
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.spy.pendingRoute?(.success(h.spy.options))
        #expect(h.model.savePlan(named: "") == nil)
        let plan = try #require(h.model.plans.items.first)
        #expect(plan.name == "Office", "an empty name falls back to the destination")
        h.model.startNavigation()
        let riding = h.model.stage
        h.model.usePlan(plan)
        #expect(h.model.stage == riding && h.spy.routeRequests == 1)
    }

    @Test func plansAreReplacedByNameAndCapped() {
        var list = RidePlanList()
        let place = Favourite(label: "Office", coordinate: Coordinate(latitude: 12.97, longitude: 77.59)!)
        var results = [list.save(RidePlan(name: "Commute", destination: place))]
        results.append(list.save(RidePlan(name: "commute", destination: place,
                                          preferences: RoutePreferences(avoidTolls: true))))
        #expect(results == [true, true] && list.items.count == 1 && list.items[0].preferences.avoidTolls)
        for index in 1..<RidePlanList.maxPlans { list.save(RidePlan(name: "Plan \(index)", destination: place)) }
        let overflow = list.save(RidePlan(name: "One too many", destination: place))
        let replaced = list.save(RidePlan(name: "Plan 3", destination: place))
        #expect(!overflow && replaced, "replacing an existing plan still works when full")
        #expect(list.items.count == RidePlanList.maxPlans && list.items.first?.name == "Plan 3")
    }
}
