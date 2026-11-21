import AVFoundation
import Observation
import RideCore

/// Speaks text; reports when an utterance with a given tag finished or was cancelled.
@MainActor
protocol SpeechClient: AnyObject {
    var onFinish: ((Int) -> Void)? { get set }
    func speak(_ text: String, tag: Int)
    func stop()
}

enum AudioRouteChange: Equatable {
    /// The output in use went away (headset unplugged or disconnected).
    case outputLost
    /// A new output appeared.
    case outputAdded
    case other
}

/// The system audio session, behind a seam so interruption and route handling is testable.
@MainActor
protocol AudioSessionClient: AnyObject {
    var onInterruption: ((Bool) -> Void)? { get set }
    var onRouteChange: ((AudioRouteChange) -> Void)? { get set }
    var outputName: String { get }
    var isExternalOutput: Bool { get }
    /// Configures for spoken prompts and activates; false when the system refused.
    func activate() -> Bool
    func deactivate()
}

/// Spoken directions through whatever output the system chose (helmet, earphones,
/// or the phone speaker when allowed). Holds at most the prompt being spoken and one
/// pending prompt; anything for another route or after a hold is dropped, never
/// replayed. Interruptions and a lost headset each hold speech independently.
/// Phone calls do not: directions keep speaking while a call rings or is connected,
/// and the audio interruption a call causes is not treated as a hold.
///
/// A turn prompt starts only while it is still true: same route and maneuver, and
/// guidance eligible (a current GPS position). Once started it is allowed to finish
/// while the fix it was planned from ages and newer fixes keep coming. It is cut only
/// when it becomes wrong or is overtaken: GPS lost (eligibility gone), the route
/// replaced, a hold, the ride ending, or a prompt for the next maneuver being ready.
@MainActor
@Observable
final class VoiceGuide {
    enum Hold: Hashable {
        case interruption, speakerFallback
    }

    private(set) var holds: Set<Hold> = []
    private(set) var outputName: String
    private(set) var activationFailed = false
    var style: VoiceStyle {
        didSet { planner.style = style }
    }

    @ObservationIgnored private let speech: SpeechClient
    @ObservationIgnored private let audio: AudioSessionClient
    @ObservationIgnored private var planner: VoicePromptPlanner
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var current: (tag: Int, prompt: VoicePrompt)?
    @ObservationIgnored private var pending: VoicePrompt?
    /// A turn that was due but never finished being heard: audio couldn't start, or a
    /// hold cut it. Its maneuver is spoken again, with the current distance, as soon as
    /// audio is back and it is still the next maneuver.
    @ObservationIgnored private var lost: VoicePrompt?
    @ObservationIgnored private var latest: NavigationSnapshot?
    @ObservationIgnored private var nextTag = 0
    @ObservationIgnored private var eligible = false
    @ObservationIgnored private var callActive = false

    init(speech: SpeechClient, audio: AudioSessionClient, style: VoiceStyle = .detailed) {
        self.speech = speech
        self.audio = audio
        self.style = style
        planner = VoicePromptPlanner(style: style)
        outputName = audio.outputName
        speech.onFinish = { [weak self] in self?.finished($0) }
        audio.onInterruption = { [weak self] began in self?.interruption(began) }
        audio.onRouteChange = { [weak self] in self?.routeChanged($0) }
    }

    /// Why speech is paused, for ride health; nil when it isn't.
    var holdReason: String? {
        if holds.contains(.speakerFallback) { return "Headset disconnected - voice paused. Allow the phone speaker?" }
        if holds.contains(.interruption) { return "Voice paused by another app." }
        if activationFailed { return "Audio unavailable - voice can't play." }
        return nil
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            lost = nil
            silence()
        }
    }

    /// A new ride or leg: forget every stage spoken so far.
    func reset() {
        planner = VoicePromptPlanner(style: style)
        latest = nil
        lost = nil
        silence()
    }

    /// Ride health's verdict, updated whenever it changes (including measurement expiry
    /// with no new snapshot). Losing eligibility drops every turn prompt at once.
    func setEligible(_ on: Bool) {
        eligible = on
        dropObsoleteTurns()
    }

    /// `eligible` is ride health's verdict: turns are spoken only on current guidance.
    func handle(_ snapshot: NavigationSnapshot, eligible: Bool) {
        if let latest, latest.session != snapshot.session || latest.generation != snapshot.generation {
            lost = nil
            silence()
        }
        latest = snapshot
        self.eligible = eligible
        dropObsoleteTurns()
        // Held or stale turns are not planned at all, so a stage that was never
        // spoken can still be spoken once it is current and allowed again.
        guard enabled, holds.isEmpty else { return }
        if eligible || snapshot.state != .active, let prompt = planner.next(for: snapshot) {
            if prompt.priority == .turn { lost = nil }
            enqueue(prompt)
        } else {
            speakLost()
        }
    }

    private func speakLost() {
        guard enabled, holds.isEmpty, current == nil, let prompt = lost,
              isCurrent(prompt, speaking: false), let latest,
              let text = planner.resumePrompt(for: latest) else { return }
        lost = nil
        say(VoicePrompt(text: text, priority: .turn, session: prompt.session, generation: prompt.generation,
                        step: prompt.step))
    }

    /// The current instruction again; refused while held or not current.
    func repeatCurrent(eligible: Bool) {
        guard enabled, holds.isEmpty, eligible, let latest, let text = planner.repeatPrompt(for: latest) else { return }
        self.eligible = eligible
        pending = nil
        if current != nil { speech.stop() }
        current = nil
        let prompt = VoicePrompt(text: text, priority: .turn, session: latest.session, generation: latest.generation,
                                 step: latest.step?.sequence)
        guard isCurrent(prompt, speaking: false) else { return }
        say(prompt)
    }

    /// A sample outside a ride (the parked rehearsal), on whatever output is selected.
    /// It replaces a sample still playing and is refused while audio is held.
    func speakSample(_ text: String) {
        guard holds.isEmpty else { return }
        pending = nil
        if current != nil {
            current = nil
            speech.stop()
        }
        say(VoicePrompt(text: text, priority: .status, session: SessionID(), generation: RouteGeneration(0)))
    }

    /// A call never silences directions. The interruption it causes (in either order) is ignored.
    func callChanged(_ active: Bool) {
        callActive = active
        if active { setHold(.interruption, false) }
    }

    /// Explicit permission to use the phone speaker after the headset went away.
    func allowSpeaker() {
        setHold(.speakerFallback, false)
    }

    // MARK: Scheduling

    private func enqueue(_ prompt: VoicePrompt) {
        guard let current else { return say(prompt) }
        // A turn for another maneuver replaces one still being spoken: the rider has moved on.
        let supersedes = prompt.priority == .turn && current.prompt.priority == .turn
            && prompt.step != current.prompt.step
        if prompt.priority > current.prompt.priority || supersedes {
            pending = nil
            speech.stop()
            self.current = nil
            say(prompt)
        } else if pending == nil || prompt.priority >= pending!.priority {
            pending = prompt
        }
    }

    private func say(_ prompt: VoicePrompt) {
        guard audio.activate() else {
            activationFailed = true
            if prompt.priority == .turn { lost = prompt }
            return
        }
        activationFailed = false
        nextTag += 1
        current = (nextTag, prompt)
        speech.speak(prompt.text, tag: nextTag)
    }

    private func finished(_ tag: Int) {
        guard current?.tag == tag else { return }
        current = nil
        let next = pending
        pending = nil
        if let next, holds.isEmpty, isCurrent(next, speaking: false) {
            say(next)
        } else {
            audio.deactivate()
        }
    }

    /// Whether a turn prompt may be (or keep being) spoken. Status prompts always may.
    /// Not yet started: eligible guidance on the same route and still the same maneuver.
    /// Already speaking: eligible guidance on the same route; the next maneuver's own
    /// prompt replaces it (see `enqueue`), passing the turn alone does not.
    private func isCurrent(_ prompt: VoicePrompt, speaking: Bool) -> Bool {
        guard prompt.priority == .turn else { return true }
        guard eligible, let latest, latest.session == prompt.session,
              latest.generation == prompt.generation else { return false }
        return speaking || (latest.state == .active && latest.step?.sequence == prompt.step)
    }

    private func dropObsoleteTurns() {
        if let pending, !isCurrent(pending, speaking: false) { self.pending = nil }
        if let lost, !isCurrent(lost, speaking: false) { self.lost = nil }
        if let current, !isCurrent(current.prompt, speaking: true) {
            self.current = nil
            speech.stop()
            audio.deactivate()
        }
    }

    private func silence() {
        pending = nil
        if current != nil {
            current = nil
            speech.stop()
        }
        audio.deactivate()
    }

    private func setHold(_ hold: Hold, _ on: Bool) {
        if on {
            holds.insert(hold)
            if let cut = pending ?? current?.prompt, cut.priority == .turn { lost = cut }
            silence()
        } else {
            holds.remove(hold)
            speakLost()
        }
    }

    private func interruption(_ began: Bool) {
        if began, callActive { return }
        setHold(.interruption, began)
    }

    private func routeChanged(_ change: AudioRouteChange) {
        let wasExternal = outputName != "iPhone"
        outputName = audio.outputName
        switch change {
        case .outputLost where wasExternal && !audio.isExternalOutput:
            setHold(.speakerFallback, true)
        case .outputAdded where audio.isExternalOutput:
            setHold(.speakerFallback, false)
        default:
            break
        }
    }
}

// MARK: Real clients

@MainActor
final class SystemSpeechClient: NSObject, SpeechClient, AVSpeechSynthesizerDelegate {
    var onFinish: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var tags: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, tag: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        tags[ObjectIdentifier(utterance)] = tag
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // Cancelled utterances may not all report back; their tags are retired here.
        tags.removeAll()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { done(id) }
    }

    private func done(_ id: ObjectIdentifier) {
        guard let tag = tags.removeValue(forKey: id) else { return }
        onFinish?(tag)
    }
}

@MainActor
final class SystemAudioSessionClient: AudioSessionClient {
    var onInterruption: ((Bool) -> Void)?
    var onRouteChange: ((AudioRouteChange) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var active = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.onInterruption?(began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let change: AudioRouteChange = switch reason {
            case .oldDeviceUnavailable: .outputLost
            case .newDeviceAvailable: .outputAdded
            default: .other
            }
            MainActor.assumeIsolated { self?.onRouteChange?(change) }
        })
    }

    var outputName: String {
        let output = session.currentRoute.outputs.first
        return output?.portType == .builtInSpeaker || output == nil ? "iPhone" : output?.portName ?? "iPhone"
    }

    var isExternalOutput: Bool {
        session.currentRoute.outputs.contains { ![.builtInSpeaker, .builtInReceiver].contains($0.portType) }
    }

    func activate() -> Bool {
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            active = true
            return true
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            active = false
            return false
        }
    }

    func deactivate() {
        guard active else { return }
        active = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
