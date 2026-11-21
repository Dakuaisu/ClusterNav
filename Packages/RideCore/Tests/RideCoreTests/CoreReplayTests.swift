import Foundation
import Testing
@testable import RideCore

@Suite("Deterministic core replay")
struct CoreReplayTests {
    /// A rider stops getting fixes: presentation refreshes keep coming, but the
    /// dashboard clears exactly five seconds after the last genuine measurement.
    static let genuineFixExpiry = """
    {"schemaVersion": 1, "events": [
      {"offset": 0, "ordinal": 0, "kind": "linkReady"},
      {"offset": 0, "ordinal": 1, "kind": "ack"},
      {"offset": 100, "ordinal": 0, "kind": "location", "x": 0, "y": 200},
      {"offset": 100, "ordinal": 1, "kind": "ack"},
      {"offset": 1100, "ordinal": 0, "kind": "refresh"},
      {"offset": 3100, "ordinal": 0, "kind": "refresh"},
      {"offset": 5099, "ordinal": 0, "kind": "tick"},
      {"offset": 5100, "ordinal": 0, "kind": "refresh"},
      {"offset": 5100, "ordinal": 1, "kind": "tick"},
      {"offset": 6000, "ordinal": 0, "kind": "location", "x": 0, "y": 230, "age": 5000},
      {"offset": 6500, "ordinal": 0, "kind": "location", "x": 0, "y": 240}
    ]}
    """

    /// The first clear fails, is sent again, and only that clear's answer counts.
    static let failedClear = """
    {"schemaVersion": 1, "events": [
      {"offset": 0, "ordinal": 0, "kind": "linkReady"},
      {"offset": 10, "ordinal": 0, "kind": "nack"},
      {"offset": 20, "ordinal": 0, "kind": "ack"},
      {"offset": 3020, "ordinal": 0, "kind": "tick"}
    ]}
    """

    @Test func refreshNeverExtendsGenuineFreshness() throws {
        let log = CoreReplayRunner().run(try ReplayTrace.load(Self.genuineFixExpiry))
        let lines = log.filter { $0.hasPrefix("t=") }
        #expect(lines[2].contains("guidance icon=74"), "first genuine fix shows the turn")
        #expect(lines[6].contains("guidance"), "4.999 s after the measurement: still fresh")
        #expect(lines[7].contains("clear stale") && lines[8].contains("clear stale"),
                "refreshes do not count as measurements")
        #expect(log.contains("rejected tooOld"), "a cached 5 s old fix is not evidence")
        #expect(lines[10].contains("guidance"), "a genuine new fix restores guidance")
    }

    @Test func failedClearIsRetriedAndAcknowledgedOnce() throws {
        let log = CoreReplayRunner().run(try ReplayTrace.load(Self.failedClear))
        #expect(log.contains("event failed(RideCore.ClusterChannel.navigation)"))
        #expect(log.filter { $0 == "event clearAcknowledged" }.count == 1)
        #expect(log.last?.contains("delivery=clearTransportAcknowledged writes=2") == true)
    }

    @Test func replayIsDeterministicOverManyRuns() throws {
        let trace = try ReplayTrace.load(Self.genuineFixExpiry)
        let first = CoreReplayRunner().run(trace)
        for _ in 0..<100 { #expect(CoreReplayRunner().run(trace) == first) }
    }

    @Test func longStraightKeepsGuidanceAndAdvancesToTurn() throws {
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0)], instructions: ""),
            PlannedStep(points: [at(0, 0), at(0, 3_500)], instructions: "Continue straight"),
            PlannedStep(points: [at(0, 3_500), at(0, 5_000)], instructions: "Turn right"),
            PlannedStep(points: [at(0, 5_000), at(500, 5_000)], instructions: "Arrive at the destination"),
        ], expectedTravelSeconds: 400)
        var events = [#"{"offset":0,"ordinal":0,"kind":"linkReady"}"#,
                      #"{"offset":0,"ordinal":1,"kind":"ack"}"#]
        for i in 0...140 {
            let time = 100 + i * 2_000
            events.append("{\"offset\":\(time),\"ordinal\":0,\"kind\":\"location\",\"x\":0,\"y\":\(i * 30),\"accuracy\":5}")
            events.append("{\"offset\":\(time),\"ordinal\":1,\"kind\":\"ack\"}")
        }
        let trace = try ReplayTrace.load("{\"schemaVersion\":1,\"events\":[\(events.joined(separator: ","))]}")
        let runner = CoreReplayRunner(route: route)
        let log = runner.run(trace)
        #expect(log == CoreReplayRunner(route: route).run(trace))
        #expect(runner.snapshots.count == 141)
        for (i, snapshot) in runner.snapshots.enumerated() {
            let expected: Maneuver = i * 30 < 3_500 ? .straight : .turnRight
            #expect(snapshot.state == .active && snapshot.step?.maneuver == expected, "fix \(i)")
            guard case .guidance(let fields, let frame) = runner.intents[2 + i * 2] else {
                Issue.record("missing guidance at fix \(i)")
                continue
            }
            #expect(fields.icon == ManeuverMapper.icon(for: expected, stepMetres: snapshot.step!.distanceMetres))
            #expect(runner.navigationWrites.contains(frame), "guidance was not sent at fix \(i)")
        }
    }

    @Test func projectionClampsToSearchWindowOnLongSegment() throws {
        let line = try #require(RoutePolyline([at(0, 0), at(0, 5_000)]))
        let before = try #require(line.project(at(3, 90), within: 100, 200))
        #expect(abs(before.along - 100) < 0.01)
        #expect(abs(before.offset - (109.0).squareRoot()) < 0.01)
        let after = try #require(line.project(at(4, 210), within: 100, 200))
        #expect(abs(after.along - 200) < 0.01)
        #expect(abs(after.offset - (116.0).squareRoot()) < 0.01)
        #expect(line.project(at(0, 100), within: 5_100, 5_200) == nil)
        #expect(line.project(at(0, 100), within: 200, 100) == nil)
    }

    @Test func fixesJustBeyondInitialWindowStayOnLongSegment() throws {
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0), at(0, 3_500)], instructions: "Continue straight"),
            PlannedStep(points: [at(0, 3_500), at(0, 5_000)], instructions: "Arrive"),
        ], expectedTravelSeconds: 400)
        let trace = try ReplayTrace.load(#"""
        {"schemaVersion":1,"events":[
          {"offset":0,"ordinal":0,"kind":"linkReady"},
          {"offset":0,"ordinal":1,"kind":"ack"},
          {"offset":100,"ordinal":0,"kind":"location","y":410},
          {"offset":100,"ordinal":1,"kind":"ack"},
          {"offset":2100,"ordinal":0,"kind":"location","y":410},
          {"offset":2100,"ordinal":1,"kind":"ack"},
          {"offset":4100,"ordinal":0,"kind":"location","y":410}
        ]}
        """#)
        let runner = CoreReplayRunner(route: route)
        _ = runner.run(trace)
        #expect(runner.snapshots.allSatisfy { $0.state == .active && $0.step?.maneuver == .straight })
        guard case .guidance(let fields, _) = runner.intents.last else {
            Issue.record("in-window boundary is close enough for guidance, not rerouting")
            return
        }
        #expect(fields.icon == ClusterIcon.straight)

        let tooFar = try ReplayTrace.load(#"""
        {"schemaVersion":1,"events":[
          {"offset":100,"ordinal":0,"kind":"location","y":460},
          {"offset":2100,"ordinal":0,"kind":"location","y":460},
          {"offset":4100,"ordinal":0,"kind":"location","y":460}
        ]}
        """#)
        let outside = CoreReplayRunner(route: route)
        _ = outside.run(tooFar)
        #expect(outside.snapshots.last?.state == .rerouting, "the bounded point is beyond off-route tolerance")
    }

    @Test func genuinelyConflictingTurnIsClearedRatherThanShownStraight() throws {
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0), at(0, 3_500)], instructions: "Turn left"),
            PlannedStep(points: [at(0, 3_500), at(500, 3_500)], instructions: "Arrive"),
        ], expectedTravelSeconds: 400)
        let trace = try ReplayTrace.load(#"""
        {"schemaVersion":1,"events":[
          {"offset":0,"ordinal":0,"kind":"linkReady"},
          {"offset":0,"ordinal":1,"kind":"ack"},
          {"offset":100,"ordinal":0,"kind":"location","y":100}
        ]}
        """#)
        let runner = CoreReplayRunner(route: route)
        _ = runner.run(trace)
        #expect(runner.snapshots.last?.step?.maneuver == .unsupported)
        #expect(runner.intents.last == .clear(.unsupportedManeuver))
        #expect(runner.navigationWrites.last == TbtFrame.stop())
    }

    @Test func malformedTracesAreRejected() {
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 2, "events": []}"#)
        }
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 5, "ordinal": 0, "kind": "tick"}, {"offset": 4, "ordinal": 0, "kind": "tick"}]}"#)
        }
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 5, "ordinal": 1, "kind": "tick"}, {"offset": 5, "ordinal": 1, "kind": "tick"}]}"#)
        }
        #expect(throws: (any Error).self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 0, "ordinal": 0, "kind": "teleport"}]}"#)
        }
    }
}
