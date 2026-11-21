import Foundation
import Testing
@testable import RideCore

/// Cases from the boundaries between features, replayed through the real engine,
/// admission, coordinator and write pump.
@Suite("Boundary replays")
struct BoundaryReplayTests {
    private func trace(_ fixes: [(x: Double, y: Double)], everyMilliseconds: Int = 1_000) throws -> ReplayTrace {
        var events = [#"{"offset":0,"ordinal":0,"kind":"linkReady"}"#, #"{"offset":0,"ordinal":1,"kind":"ack"}"#]
        for (i, fix) in fixes.enumerated() {
            let time = 100 + i * everyMilliseconds
            events.append("{\"offset\":\(time),\"ordinal\":0,\"kind\":\"location\",\"x\":\(fix.x),\"y\":\(fix.y),\"accuracy\":5}")
            events.append("{\"offset\":\(time),\"ordinal\":1,\"kind\":\"ack\"}")
        }
        return try ReplayTrace.load("{\"schemaVersion\":1,\"events\":[\(events.joined(separator: ","))]}")
    }

    private let straightThenRight = PlannedRoute(steps: [
        PlannedStep(points: [at(0, 0)], instructions: ""),
        PlannedStep(points: [at(0, 0), at(0, 1_500)], instructions: "Turn right onto Cross Road"),
        PlannedStep(points: [at(0, 1_500), at(400, 1_500)], instructions: "Arrive at the destination"),
    ], expectedTravelSeconds: 200)

    @Test func aParallelRoadInsideToleranceKeepsSteadyGuidance() throws {
        // A service road 30 m beside the route: within the 40 m + accuracy tolerance.
        let runner = CoreReplayRunner(route: straightThenRight)
        _ = runner.run(try trace((0..<40).map { (x: 30.0, y: Double($0) * 15) }))
        #expect(runner.snapshots.allSatisfy { $0.state == .active }, "no reroute flapping beside the route")
        let distances = runner.snapshots.compactMap { $0.step?.distanceMetres }
        #expect(distances == distances.sorted(by: >), "the countdown to the turn never jumps back")
        #expect(runner.snapshots.allSatisfy { $0.step?.maneuver == .turnRight })
    }

    @Test func aParallelRoadBeyondToleranceReroutesOnceAndStaysCleared() throws {
        // A different road 80 m away, ridden for a minute: one decision, no return to guidance.
        let runner = CoreReplayRunner(route: straightThenRight)
        _ = runner.run(try trace((0..<60).map { (x: 80.0, y: Double($0) * 15) }))
        let states = runner.snapshots.map(\.state)
        let firstReroute = try #require(states.firstIndex(of: .rerouting))
        #expect(firstReroute <= 3, "decided within the first few fixes")
        #expect(states[firstReroute...].allSatisfy { $0 == .rerouting }, "it does not flip back while still off the route")
        guard case .clear = try #require(runner.intents.last) else {
            Issue.record("the dashboard must not show a turn for a road the rider is not on")
            return
        }
    }

    @Test func closelySpacedTurnsAreBothAnnouncedInOrder() throws {
        // Left, then right 40 m later: the second cue is due the moment the first is passed.
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0)], instructions: ""),
            PlannedStep(points: [at(0, 0), at(0, 300)], instructions: "Turn left onto First Lane"),
            PlannedStep(points: [at(0, 300), at(-40, 300)], instructions: "Turn right onto Second Lane"),
            PlannedStep(points: [at(-40, 300), at(-40, 700)], instructions: "Arrive at the destination"),
        ], expectedTravelSeconds: 90)
        var fixes: [(x: Double, y: Double)] = (0...30).map { (x: 0.0, y: Double($0) * 10) }
        fixes += (1...4).map { (x: Double($0) * -10, y: 300.0) }
        fixes += (1...10).map { (x: -40.0, y: 300 + Double($0) * 10) }
        let runner = CoreReplayRunner(route: route)
        _ = runner.run(try trace(fixes))

        #expect(runner.snapshots.allSatisfy { $0.state == .active })
        let maneuvers = runner.snapshots.compactMap { $0.step?.maneuver }
        let order = maneuvers.reduce(into: [Maneuver]()) { if $0.last != $1 { $0.append($1) } }
        #expect(order == [.turnLeft, .turnRight, .arrival], "neither turn is skipped or shown out of order")
        let firstRight = try #require(runner.snapshots.first { $0.step?.maneuver == .turnRight })
        #expect((firstRight.step?.distanceMetres ?? 999) <= 40)

        var planner = VoicePromptPlanner(style: .detailed)
        let spoken = runner.snapshots.compactMap { planner.next(for: $0)?.text }
        let left = try #require(spoken.firstIndex { $0.hasPrefix("Now, turn left") })
        let right = try #require(spoken.firstIndex { $0.hasPrefix("Now, turn right") })
        #expect(left < right, "the second turn gets its own final cue")
    }

    @Test(arguments: [
        "Im Kreisverkehr die zweite Ausfahrt nehmen",
        "गोल चक्कर पर दूसरा निकास लें",
        "ロータリーで2番目の出口を出る",
    ])
    func aRoundaboutDescribedInAnotherLanguageIsNeverShownAsAPlainTurn(instructions: String) throws {
        // Without English wording only the line is left. Every exit of a ring used to be
        // announced as "turn left", the turn off the ring, whichever way the exit led.
        for (sweep, direction) in [(90.0, RoundaboutDirection.left), (180, .straight), (270, .right)] {
            let route = roundaboutRoute(radius: 40, sweep: sweep, instructions: instructions)
            let engine = try #require(GuidanceEngine(route: route, session: SessionID(), generation: RouteGeneration(0)))
            let first = try #require(engine.maneuvers.first)
            #expect(first.maneuver == .roundaboutClockwise, "sweep \(sweep): got \(first.maneuver)")
            #expect(first.roundaboutDirection == direction, "sweep \(sweep)")
            #expect(first.countdownAlong != nil, "the countdown ends at the ring's entry")
        }
    }

    @Test func aRoundedCornerWithUnreadableWordingIsNotMistakenForARoundabout() throws {
        var corner = [at(0, 0), at(0, 280)]
        for degrees in stride(from: 0.0, through: 90, by: 10) {
            let t = degrees * .pi / 180
            corner.append(at(20 - 20 * cos(t), 280 + 20 * sin(t)))
        }
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0)], instructions: ""),
            PlannedStep(points: corner, instructions: "Rechts abbiegen"),
            PlannedStep(points: [at(20, 300), at(320, 300)], instructions: "Arrive at the destination"),
        ], expectedTravelSeconds: 60)
        let engine = try #require(GuidanceEngine(route: route, session: SessionID(), generation: RouteGeneration(0)))
        let first = try #require(engine.maneuvers.first)
        #expect(first.maneuver != .roundaboutClockwise && first.maneuver != .roundaboutCounterClockwise,
                "got \(first.maneuver)")
    }

    @Test func rehearsalListsEveryManeuverOfThePlannedRouteWithItsCue() throws {
        let steps = RouteRehearsal.steps(for: cityRoute)
        #expect(steps.map(\.maneuver) == [.turnRight, .turnLeft, .arrival])
        #expect(steps.map(\.distanceMetres) == [500, 400, 400], "each distance is the stretch before that turn")
        #expect(steps.map(\.roadText) == ["First Cross", "Second Main", nil])
        #expect(RouteRehearsal.cue(for: steps[0], style: .detailed) == "In 500 metres, turn right onto First Cross.")
        #expect(RouteRehearsal.cue(for: steps[0], style: .concise) == "In 500 metres, turn right.")
        #expect(RouteRehearsal.cue(for: GuidanceStep(maneuver: .unsupported, distanceMetres: 100), style: .detailed) == nil)

        let ring = RouteRehearsal.steps(for: roundaboutRoute(radius: 40, sweep: 270))
        #expect(ring.first?.maneuver == .roundaboutClockwise && ring.first?.roundaboutExit == 2)
        #expect((ring.first?.distanceMetres ?? 0) < 320, "a roundabout is counted down to its entry")
        #expect(RouteRehearsal.steps(for: FixtureRoute.demo).count == FixtureRoute.demo.steps.count)
        #expect(RouteRehearsal.steps(for: PlannedRoute(steps: [], expectedTravelSeconds: 0)).isEmpty)
    }

    @Test func stopsAreRankedByAddedMinutesNotByDistanceFromTheRoute() throws {
        let line = [at(0, 0), at(0, 6_000), at(4_000, 6_000)]
        let points = StopPlanner.searchPoints(along: line)
        #expect(points.count == 3, "a 10 km ride is searched at three points inside it")
        #expect(points.allSatisfy { StopPlanner.distance(from: $0, to: line) < 1 })
        #expect(points.allSatisfy { $0.distance(to: line[0]) > 1_000 && $0.distance(to: line[2]) > 1_000 },
                "never at the start or the destination")
        #expect(StopPlanner.searchPoints(along: [at(0, 0), at(0, 800)]).count == 1)
        #expect(StopPlanner.searchPoints(along: [at(0, 0)]).isEmpty)
        #expect((1_000...5_000).contains(StopPlanner.searchRadius(along: line)))

        func place(_ name: String, _ x: Double, _ y: Double) -> StopCandidate { StopCandidate(name: name, coordinate: at(x, y)) }
        let found = [place("Across the river", 200, 3_000), place("On the corner", 30, 5_950),
                     place("On the corner", 40, 5_960), place("Far away", 3_000, 2_000), place("Side road", 600, 1_000)]
        let shortlist = StopPlanner.shortlist(found, along: line)
        #expect(shortlist.map(\.candidate.name) == ["On the corner", "Across the river", "Side road"],
                "duplicates and places over 1.5 km from the line are dropped")
        #expect(abs(shortlist[1].offRouteMetres - 200) < 2)

        // The nearest place needs a long way round; the furthest is nearly on the way.
        let ranked = StopPlanner.ranked([(shortlist[0].candidate, shortlist[0].offRouteMetres, 900),
                                         (shortlist[1].candidate, shortlist[1].offRouteMetres, 1_500),
                                         (shortlist[2].candidate, shortlist[2].offRouteMetres, 880)], baseSeconds: 840)
        #expect(ranked.map(\.name) == ["Side road", "On the corner", "Across the river"])
        #expect(ranked.map(\.addedSeconds) == [40, 60, 660])
        #expect(StopPlanner.ranked([(shortlist[0].candidate, 0, 800)], baseSeconds: 840).first?.addedSeconds == 0,
                "a stop never claims to save time")
    }
}
