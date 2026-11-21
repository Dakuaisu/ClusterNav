import Foundation

/// The maneuvers of a planned route in order, for stepping through it before leaving.
/// Each step's distance is the stretch ridden before that maneuver, and its spoken cue
/// is worded the way the voice guide words a cue at that distance.
public enum RouteRehearsal {
    public static func steps(for route: PlannedRoute,
                             configuration: GuidanceEngineConfiguration = GuidanceEngineConfiguration()) -> [GuidanceStep] {
        guard let engine = GuidanceEngine(route: route, session: SessionID(), generation: RouteGeneration(0),
                                          configuration: configuration) else { return [] }
        var previous = 0.0
        return engine.maneuvers.enumerated().map { index, maneuver in
            defer { previous = maneuver.along }
            return GuidanceStep(maneuver: maneuver.maneuver, roundaboutExit: maneuver.exitNumber,
                                roundaboutDirection: maneuver.roundaboutDirection,
                                distanceMetres: Int(max(maneuver.countdownAlong - previous, 0).rounded()),
                                roadText: maneuver.road, sequence: index)
        }
    }

    public static func steps(for route: FixtureRoute) -> [GuidanceStep] {
        route.steps.enumerated().map { index, step in
            GuidanceStep(maneuver: step.maneuver, roundaboutExit: step.roundaboutExit,
                         roundaboutDirection: step.roundaboutDirection, distanceMetres: step.lengthMetres,
                         roadText: step.roadText, sequence: index)
        }
    }

    /// What the rider would hear for this step, or nil for a turn the app never announces.
    public static func cue(for step: GuidanceStep, style: VoiceStyle) -> String? {
        let snapshot = NavigationSnapshot(session: SessionID(), generation: RouteGeneration(0),
                                          observedAt: MonotonicInstant(offset: .zero), state: .active, step: step,
                                          remainingMetres: step.distanceMetres, remainingSeconds: 0)
        return VoicePromptPlanner(style: style).repeatPrompt(for: snapshot)
    }
}
