import Foundation
import Testing
@testable import N250Ride

@MainActor
struct SavedPlaceShortcutTests {
    @Test func queuedRequestWaitsForForegroundAndRunsOnce() {
        let h = RideHarness()
        let handoff = SavedPlaceShortcutHandoff()
        h.model.setShortcut(.home, label: "Home", coordinate: h.office)
        h.model.selectedTab = .bike
        handoff.enqueue(.home)

        #expect(handoff.consumeIfActive(false, model: h.model).isEmpty)
        #expect(handoff.pending == [.home] && h.spy.routeRequests == 0)
        #expect(handoff.consumeIfActive(true, model: h.model).isEmpty)
        #expect(handoff.pending.isEmpty && h.model.selectedTab == .ride)
        #expect(h.spy.routeRequests == 1 && h.spy.started == 0 && h.spy.committed.isEmpty)
        h.spy.pendingRoute?(.success(h.spy.options))
        guard case .preview(let destination) = h.model.stage else {
            Issue.record("Expected a route preview")
            return
        }
        #expect(destination.label == "Home" && !h.model.isRiding)
        #expect(handoff.consumeIfActive(true, model: h.model).isEmpty)
        #expect(h.spy.routeRequests == 1 && h.spy.started == 0)
    }

    @Test func missingPlacesGiveGuidanceWithoutRequests() {
        let h = RideHarness()
        let handoff = SavedPlaceShortcutHandoff()
        handoff.enqueue(.home)
        handoff.enqueue(.work)
        let messages = handoff.consumeIfActive(true, model: h.model)
        #expect(messages.count == 2)
        #expect(messages[0].contains("Set Home") && messages[1].contains("Set Work"))
        #expect(handoff.pending.isEmpty && h.spy.routeRequests == 0)
        #expect(h.model.stage == .choosing)
    }

    @Test func workOpensPreviewWithoutStarting() {
        let h = RideHarness()
        h.model.setShortcut(.work, label: "Office", coordinate: h.office)
        #expect(h.model.previewSavedPlace(.work) == nil)
        h.spy.pendingRoute?(.success(h.spy.options))
        guard case .preview(let destination) = h.model.stage else {
            Issue.record("Expected a route preview")
            return
        }
        #expect(destination.label == "Office" && h.spy.started == 0 && h.spy.committed.isEmpty)
    }

    @Test func busyStagesDoNotReplaceTheCurrentRoute() {
        let h = RideHarness()
        h.model.setShortcut(.home, label: "Home", coordinate: h.office)
        h.model.propose(h.office, label: "Other")
        let confirming = h.model.stage
        #expect(h.model.previewSavedPlace(.home)?.contains("current route") == true)
        #expect(h.model.stage == confirming && h.spy.routeRequests == 0)
        h.model.confirmDestination(label: "Other", saveAsFavourite: false)
        let requesting = h.model.stage
        #expect(h.model.previewSavedPlace(.home) != nil && h.model.stage == requesting)
        h.spy.pendingRoute?(.success(h.spy.options))
        let preview = h.model.stage
        #expect(h.model.previewSavedPlace(.home) != nil && h.model.stage == preview)
        h.model.startNavigation()
        let riding = h.model.stage
        #expect(h.model.previewSavedPlace(.home) != nil && h.model.stage == riding)
        #expect(h.spy.routeRequests == 1 && h.spy.started == 1)
    }

    @Test func failedRouteMayBeReplaced() {
        let h = RideHarness()
        h.model.setShortcut(.work, label: "Work", coordinate: h.office)
        h.model.propose(h.office, label: "Other")
        h.model.confirmDestination(label: "Other", saveAsFavourite: false)
        h.spy.pendingRoute?(.failure(.network))
        guard case .failed = h.model.stage else {
            Issue.record("Expected route failure")
            return
        }
        h.wait()
        #expect(h.model.previewSavedPlace(.work) == nil)
        #expect(h.spy.routeRequests == 2 && h.spy.started == 0)
    }

    @Test func unfinishedRecoveryIsNotOverwritten() {
        let first = RideHarness()
        first.model.recovery.setEnabled(true)
        first.model.setShortcut(.home, label: "Home", coordinate: first.office)
        first.startRide()
        let restarted = RideHarness(storage: first.storage, defaults: first.defaults)
        #expect(restarted.model.recoveryOffer != nil)
        #expect(restarted.model.previewSavedPlace(.home)?.contains("unfinished ride") == true)
        #expect(restarted.model.recoveryOffer != nil && restarted.model.stage == .choosing)
        #expect(restarted.spy.routeRequests == 0 && restarted.spy.started == 0)
    }
}
