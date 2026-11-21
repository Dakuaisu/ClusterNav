import Foundation
import MapKit
import RideCore
import Testing
import UIKit
@testable import ClusterNav

/// The real Apple provider, on virtual time, with scripted locations and directions.
@MainActor
struct AppleProviderAdapterTests {
    let timers = ManualRideTimers(clock: ManualClock())
    let location = FakeLocation()
    let directions = FakeDirections()
    let provider: AppleNavigationProvider
    let origin = Coordinate(latitude: 12.97, longitude: 77.59)!
    let target = Coordinate(latitude: 12.9745, longitude: 77.5863)!

    init() {
        provider = AppleNavigationProvider(clock: timers.clock, timers: timers,
                                           defaults: UserDefaults(suiteName: "adapter-\(UUID())")!,
                                           location: location, directions: directions)
    }

    func request(_ reason: RouteReason = .initial, session: SessionID = SessionID(),
                 generation: RouteGeneration = RouteGeneration(0), fix: FixRequirement = .initial) -> NavigationRouteRequest {
        NavigationRouteRequest(operationID: UUID(), session: session, generation: generation, target: target,
                               title: "Office", preferences: RoutePreferences(), reason: reason,
                               alternatives: reason == .initial, fix: fix)
    }

    @Test func untrustworthyFixesNeverStartARequest() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { results.append($0) }
        #expect(location.isRunning)
        location.deliver(origin, age: 6, clock: timers.clock)
        location.deliver(origin, age: -3, clock: timers.clock)
        location.deliver(origin, accuracy: 80, age: 1, clock: timers.clock)
        #expect(directions.queries.isEmpty, "cached, future and imprecise fixes are not an origin")
        location.deliver(origin, age: 0.5, clock: timers.clock)
        location.deliver(origin, age: 1, clock: timers.clock)
        #expect(directions.queries.count == 1)
        #expect(directions.queries[0].origin == origin)
    }

    @Test func fixWaitTimesOutAndReleasesLocation() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { results.append($0) }
        timers.advance(by: .milliseconds(14_999))
        #expect(results.isEmpty)
        timers.advance(by: .milliseconds(1))
        #expect(results.count == 1 && (try? results[0].get()) == nil)
        #expect(!location.isRunning, "a failed initial request does not leave GPS running")
    }

    @Test func oldTimeoutCannotDrainANewerWait() {
        var first: [Result<PreparedRoute, RouteRequestFailure>] = []
        var second: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { first.append($0) }
        timers.advance(by: .seconds(10))
        provider.prepareRoute(request(fix: .current)) { second.append($0) }
        timers.advance(by: .seconds(6))
        #expect(first.isEmpty, "the replaced request answers nothing")
        #expect(second.isEmpty, "the first wait's timeout did not end the second")
        location.deliver(origin, clock: timers.clock)
        #expect(directions.queries.count == 1)
    }

    @Test func preparationNeverDisturbsTheActiveRoute() throws {
        var snapshots: [NavigationSnapshot] = []
        provider.onSnapshot = { snapshots.append($0) }
        let sessionA = SessionID()
        var prepared: PreparedRoute?
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(request(session: sessionA)) { prepared = try? $0.get() }
        directions.answer(.success([FakeDirections.route(from: origin)]))
        let a = try #require(prepared)
        #expect(snapshots.isEmpty, "preparing emits nothing")
        #expect(provider.commitPreparedRoute(a.handle, option: 0))
        #expect(snapshots.isEmpty, "committing emits nothing")
        provider.startGuidance()
        #expect(snapshots.last?.session == sessionA, "the last fresh fix is guided on the committed route")

        var failed: Result<PreparedRoute, RouteRequestFailure>?
        provider.prepareRoute(request(.manual, session: sessionA, generation: RouteGeneration(1), fix: .current)) { failed = $0 }
        timers.advance(by: .seconds(1))
        location.deliver(FakeDirections.point(origin, x: 0, y: 100), clock: timers.clock)
        directions.answer(.failure(.network))
        #expect(failed.map { if case .failure(.network) = $0 { true } else { false } } == true)
        timers.advance(by: .seconds(1))
        location.deliver(FakeDirections.point(origin, x: 0, y: 150), clock: timers.clock)
        let latest = try #require(snapshots.last)
        #expect(latest.session == sessionA && latest.generation == RouteGeneration(0) && latest.state == .active,
                "route A keeps guiding after B failed")
        #expect(latest.measurementAt == timers.clock.now)
    }

    @Test func cancelledAnswerIsIgnored() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        let r = request()
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(r) { results.append($0) }
        provider.cancelPreparation(r.operationID)
        directions.answer(.success([FakeDirections.route(from: origin)]))
        #expect(results.isEmpty && directions.cancels == 1)
    }

    @Test func startCheckNeedsACurrentPositionNearTheStart() throws {
        var prepared: PreparedRoute?
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(request()) { prepared = try? $0.get() }
        directions.answer(.success([FakeDirections.route(from: origin)]))
        let handle = try #require(prepared).handle
        var checks: [StartCheck] = []
        timers.advance(by: .seconds(20))
        provider.checkStart(handle) { checks.append($0) }
        #expect(checks.isEmpty, "the 20 s old fix is not current")
        location.deliver(FakeDirections.point(origin, x: 0, y: 300), clock: timers.clock)
        guard case .movedFromOrigin(let metres) = checks.first else {
            Issue.record("expected a displacement, got \(checks)")
            return
        }
        #expect(abs(metres - 300) < 5)
        timers.advance(by: .seconds(6))
        provider.checkStart(handle) { checks.append($0) }
        location.deliver(FakeDirections.point(origin, x: 0, y: 40), clock: timers.clock)
        #expect(checks.last == .ready)
    }

    private func candidate(id: Int, line: [Coordinate], seconds: Double = 180) -> PlannedCandidate {
        var candidate = FakeDirections.route(from: origin)
        candidate.line = line
        candidate.option = RouteOption(id: id, name: "Route \(id)", distanceMetres: 1_500 + Double(id),
                                       expectedSeconds: seconds, hasTolls: false, hasHighways: false)
        return candidate
    }

    private func prepare(_ candidates: [PlannedCandidate]) throws -> PreparedRoute {
        var prepared: PreparedRoute?
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(request()) { prepared = try? $0.get() }
        directions.answer(.success(candidates))
        return try #require(prepared)
    }

    private func configuredMap() throws -> MKMapView {
        let map = try #require(provider.mapHostView as? MKMapView)
        map.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: origin.latitude + 0.0025,
                                                                       longitude: origin.longitude),
                                         span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)),
                      animated: false)
        map.layoutIfNeeded()
        return map
    }

    @Test func tappingRouteUsesOverlayIdentityAfterSelectionReordersDrawing() throws {
        let shared = FakeDirections.point(origin, x: 0, y: 100)
        let north = FakeDirections.point(origin, x: 0, y: 500)
        let east = FakeDirections.point(origin, x: 250, y: 500)
        let routeA = candidate(id: 7, line: [origin, shared, north])
        let routeB = candidate(id: 42, line: [origin, shared, east])
        let route = try prepare([routeA, routeB])
        let map = try configuredMap()
        var selections: [(PreparedRouteHandle, RouteOption.ID)] = []
        provider.onPreviewRouteSelection = { [weak provider] handle, option in
            selections.append((handle, option))
            _ = provider?.previewPrepared(handle, option: option)
        }

        let bPoint = FakeDirections.point(origin, x: 125, y: 300)
        provider.selectPreviewRoute(at: map.convert(CLLocationCoordinate2D(latitude: bPoint.latitude,
                                                                            longitude: bPoint.longitude), toPointTo: map))
        #expect(selections.last?.0 == route.handle && selections.last?.1 == 42)
        #expect(map.overlays.last?.title == AppleNavigationProvider.selectedTitle)
        let aPoint = FakeDirections.point(origin, x: 0, y: 350)
        provider.selectPreviewRoute(at: map.convert(CLLocationCoordinate2D(latitude: aPoint.latitude,
                                                                            longitude: aPoint.longitude), toPointTo: map))
        #expect(selections.last?.1 == 7)
        #expect(selections.count == 2 && directions.queries.count == 1)
        provider.selectPreviewRoute(at: CGPoint(x: -500, y: -500))
        #expect(selections.count == 2)
    }

    @Test func sharedSectionsHaveSeparateAccessiblePointedCallouts() throws {
        let end = FakeDirections.point(origin, x: 0, y: 700)
        let line = [origin, end]
        let route = try prepare([candidate(id: 1, line: line), candidate(id: 2, line: line, seconds: 240)])
        let map = try configuredMap()
        let labels = map.annotations.compactMap { $0 as? RoutePreviewAnnotation }
        #expect(labels.count == 2)
        let labelPoints = labels.map { map.convert($0.coordinate, toPointTo: map) }
        for (label, point) in zip(labels, labelPoints) {
            #expect((RoutePreviewGeometry.distance(from: point, to: label.overlay, on: map) ?? 100) < 1)
        }
        let rects = zip(labels, labelPoints).map { label, point in
            let size = RoutePreviewAnnotationView.size(for: label.option)
            return CGRect(x: point.x - size.width / 2, y: point.y - size.height, width: size.width, height: size.height)
        }
        #expect(!rects[0].intersects(rects[1]), "identical lines still get separate selectable labels")

        var selected: RouteOption.ID?
        provider.onPreviewRouteSelection = { handle, option in
            #expect(handle == route.handle)
            selected = option
        }
        let sharedPoint = FakeDirections.point(origin, x: 0, y: 350)
        provider.selectPreviewRoute(at: map.convert(CLLocationCoordinate2D(latitude: sharedPoint.latitude,
                                                                            longitude: sharedPoint.longitude), toPointTo: map))
        #expect(selected == 1, "a tap on a perfectly shared section keeps the selected route")
        selected = nil
        let alternative = try #require(labels.first { $0.option.id == 2 })
        let view = try #require(provider.mapView(map, viewFor: alternative) as? RoutePreviewAnnotationView)
        view.layoutIfNeeded()
        let button = try #require(view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(button.currentTitle == "4 min · 1.5 km")
        #expect(button.accessibilityLabel?.contains("Route 2") == true)
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityValue == "Not selected")
        #expect(view.layer.sublayers?.contains(where: { ($0 as? CAShapeLayer)?.path != nil }) == true)
        #expect(view.centerOffset.y == -view.bounds.height / 2)
        #expect(button.bounds.height >= 44)
        button.sendActions(for: .touchUpInside)
        #expect(selected == 2, "the callout is selectable even where the lines coincide")
    }

    @Test func previewCleanupDoesNotRemoveOtherMapContentOrAffectActiveGuidance() throws {
        let line = [origin, FakeDirections.point(origin, x: 0, y: 500)]
        let route = try prepare([candidate(id: 3, line: line), candidate(id: 4, line: line)])
        let map = try configuredMap()
        let other = MKPointAnnotation()
        other.coordinate = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        map.addAnnotation(other)
        let stale = try #require(map.annotations.compactMap { $0 as? RoutePreviewAnnotation }.first)
        let staleView = try #require(provider.mapView(map, viewFor: stale) as? RoutePreviewAnnotationView)
        let staleButton = try #require(staleView.subviews.compactMap { $0 as? UIButton }.first)
        var selections = 0
        provider.onPreviewRouteSelection = { _, _ in selections += 1 }

        #expect(provider.commitPreparedRoute(route.handle, option: 4))
        #expect(map.annotations.compactMap { $0 as? RoutePreviewAnnotation }.isEmpty)
        #expect(map.annotations.contains { $0 === other })
        staleButton.sendActions(for: .touchUpInside)
        #expect(selections == 0)
        provider.startGuidance()
        #expect(map.overlays.count == 1)
        #expect(map.overlays.first?.title == AppleNavigationProvider.selectedTitle)
        provider.selectPreviewRoute(at: map.convert(other.coordinate, toPointTo: map))
        #expect(selections == 0)
        provider.stop()
        #expect(map.overlays.isEmpty && map.annotations.contains { $0 === other })
    }

    @Test func rehearsalReadsThePreparedRouteWithoutAnotherRequest() throws {
        let route = try prepare([candidate(id: 5, line: [origin, FakeDirections.point(origin, x: 0, y: 500)])])
        let steps = provider.rehearsalSteps(route.handle, option: 5)
        #expect(!steps.isEmpty && steps.last?.maneuver == .arrival)
        #expect(steps.allSatisfy { RouteRehearsal.cue(for: $0, style: .detailed) != nil })
        #expect(provider.rehearsalSteps(route.handle, option: 99).isEmpty)
        #expect(directions.queries.count == 1, "rehearsing asks Apple for nothing")
        provider.discardPrepared(route.handle)
        #expect(provider.rehearsalSteps(route.handle, option: 5).isEmpty)
    }

    @Test func discardRemovesOnlyItsPreviewAndKeepsMapGestures() throws {
        let line = [origin, FakeDirections.point(origin, x: 0, y: 500)]
        let route = try prepare([candidate(id: 8, line: line)])
        let map = try configuredMap()
        let observer = try #require(map.subviews.compactMap { $0 as? RoutePreviewLayoutObserver }.first)
        #expect(!observer.isUserInteractionEnabled && !observer.isOpaque && observer.accessibilityElementsHidden)
        let tap = try #require(map.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .first { ($0.delegate as AnyObject?) === provider })
        let longPress = try #require(map.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        #expect(!tap.cancelsTouchesInView)
        #expect(provider.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: longPress))
        provider.recenter()
        #expect(map.overlays.count == 1)
        provider.discardPrepared(route.handle)
        #expect(map.overlays.isEmpty)
        #expect(map.annotations.compactMap { $0 as? RoutePreviewAnnotation }.isEmpty)
        #expect(!provider.previewPrepared(route.handle, option: 8))
    }
}
