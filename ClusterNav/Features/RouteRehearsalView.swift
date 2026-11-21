import RideCore
import SwiftUI

/// Parked walk-through of the previewed route: every maneuver in order, each with the
/// cue the rider will hear, played on the audio output selected now.
struct RouteRehearsalView: View {
    @Environment(AppModel.self) private var model
    @State private var current = 0

    var body: some View {
        let steps = model.rehearsalSteps
        List {
            if steps.isEmpty {
                Text("This route is no longer open. Go back and choose a route again.")
                    .foregroundStyle(.secondary)
            } else {
                let step = steps[min(current, steps.count - 1)]
                Section {
                    TurnCard(snapshot: nil, rehearsal: step)
                    Text(RouteRehearsal.cue(for: step, style: model.voiceStyle) ?? "The app does not announce this turn.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("rehearsalCue")
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { move(-1, in: steps) }
                            .disabled(current == 0)
                            .accessibilityIdentifier("rehearsalPrevious")
                        Spacer()
                        Button {
                            model.hearRehearsalCue(step)
                        } label: {
                            Label("Hear it", systemImage: "speaker.wave.2.fill").foregroundStyle(.white)
                        }
                        .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("rehearsalHear")
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { move(1, in: steps) }
                            .labelStyle(.titleAndIcon)
                            .disabled(current >= steps.count - 1)
                            .accessibilityIdentifier("rehearsalNext")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Step \(min(current, steps.count - 1) + 1) of \(steps.count)")
                } footer: {
                    Text(audioNote)
                }

                Section("Whole route") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Button {
                            current = index
                            model.hearRehearsalCue(step)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: TurnCard.symbol(for: step.maneuver))
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(index == current ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.title(step)).foregroundStyle(Color.primary)
                                    Text("After \(Format.distance(Double(step.distanceMetres)))")
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("rehearsalStep-\(index)")
                    }
                }
            }
        }
        .navigationTitle("Rehearse the route")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func move(_ by: Int, in steps: [GuidanceStep]) {
        current = min(max(current + by, 0), steps.count - 1)
        model.hearRehearsalCue(steps[current])
    }

    private var audioNote: String {
        let output = "Plays through \(model.voice.outputName)."
        if let reason = model.voice.holdReason { return "\(output) \(reason)" }
        return model.voiceEnabled ? "\(output) Only while parked."
            : "\(output) Spoken directions are off, so these cues will not play during the ride."
    }

    static func title(_ step: GuidanceStep) -> String {
        let phrase = VoicePromptPlanner.phrase(step, roads: false)
        let name = phrase.prefix(1).uppercased() + phrase.dropFirst()
        return step.roadText.map { "\(name) - \($0)" } ?? name
    }
}
