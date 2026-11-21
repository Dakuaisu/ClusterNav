import RideCore
import SwiftUI

struct RideView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                StatusChips()

                if model.mode == .live, !model.termsAccepted, let provider = model.provider {
                    Section("Before your first ride") {
                        Text(provider.termsNotice).font(.footnote)
                        Button("I understand") { model.acceptTerms() }
                            .accessibilityIdentifier("acceptTermsButton")
                    }
                }

                switch model.stage {
                case .choosing, .confirming:
                    if model.recoveryOffer != nil { RecoveryPrompt() }
                    DestinationPicker()
                case .requesting(let pending):
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Finding routes to \(Self.title(pending))…")
                        }
                        .padding(.vertical, 8)
                        Button("Cancel", role: .cancel) { model.cancelRouteOperation() }
                            .accessibilityIdentifier("cancelRequestButton")
                    }
                case .preview(let pending):
                    RouteChoice(pending: pending)
                case .navigating(let pending):
                    Navigating(pending: pending)
                case .atStop(let pending):
                    AtStop(pending: pending)
                case .failed(_, let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("routeError")
                        Button("Try again") { model.retry() }
                        Button("Choose another destination") { model.cancelDestination() }
                    } header: {
                        Text("Couldn't get a route")
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(routeUsageText)
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ride settings")
                    .accessibilityIdentifier("rideSettingsButton")
                }
            }
            .sheet(isPresented: $showSettings) { RideSettingsView() }
        }
    }

    private var navigationTitle: String {
        switch model.stage {
        case .navigating: "Navigating"
        case .preview: "Choose a route"
        case .atStop: "At your stop"
        default: "Where to?"
        }
    }

    static func title(_ pending: AppModel.PendingDestination) -> String {
        pending.label.isEmpty
            ? String(format: "%.5f, %.5f", pending.coordinate.latitude, pending.coordinate.longitude)
            : pending.label
    }

    private var routeUsageText: String {
        let usage = model.routeGate.usage
        switch model.routeGate.policy {
        case .disabled(let reason):
            return "Live navigation off: \(reason)."
        case .metered(let limits):
            return "Destinations today \(usage.dayCount)/\(limits.perDay), this month \(usage.monthCount)/\(limits.perMonth). Local limit only: it resets on reinstall and does not guarantee zero Google charges."
        case .unmetered:
            return "Routes from Apple Maps for cars - Apple has no motorcycle profile. No Google requests."
        }
    }
}

/// Bike link and mode at a glance.
private struct StatusChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    model.selectedTab = .bike
                } label: {
                    Chip(text: model.bike.state.isReady ? "Bike connected" : "Bike not connected",
                         systemImage: model.bike.state.isReady ? "checkmark.circle.fill"
                             : "antenna.radiowaves.left.and.right.slash",
                         tint: model.bike.state.isReady ? .green : .orange)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Bike tab")
                .accessibilityIdentifier("linkStatus")
                if model.mode == .simulation {
                    Chip(text: "Simulation", systemImage: "testtube.2", tint: .purple)
                        .accessibilityIdentifier("simulationBadge")
                } else {
                    Chip(text: model.provider?.name ?? "Live", systemImage: "map.fill", tint: .blue)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Candidate routes from the one request already made; choosing sends nothing.
private struct RouteChoice: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingDestination
    @State private var namingPlan = false
    @State private var planName = ""
    @State private var planMessage: String?

    var body: some View {
        Section {
            ForEach(model.routeOptions) { option in
                Button {
                    model.selectRoute(option.id)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: option.id == model.selectedRouteID ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(option.id == model.selectedRouteID ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Format.duration(option.expectedSeconds))
                                .font(.title3.weight(.semibold))
                            Text("\(Format.distance(option.distanceMetres))\(option.name.isEmpty ? "" : " · via \(option.name)")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                if option.id == model.routeOptions.first?.id { Tag(text: "Fastest", tint: .green) }
                                if option.hasHighways { Tag(text: "Highway", tint: .blue) }
                                if option.hasTolls { Tag(text: "Tolls", tint: .orange) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routeOption-\(option.id)")
            }
            if model.mode == .live {
                Button {
                    model.selectedTab = .map
                } label: {
                    Label("See routes on the map", systemImage: "map")
                }
            }
        } header: {
            Text("To \(RideView.title(pending))")
        } footer: {
            Text(model.mode == .simulation ? "Synthetic demo route" : model.provider?.routingLabel ?? "")
        }

        if let stop = pending.stop {
            Section {
                Label("Stop on the way: \(stop.label.isEmpty ? "unnamed place" : stop.label)", systemImage: "mappin.and.ellipse")
            } footer: {
                Text("Times and distances are for the leg to the stop. The rest is calculated when you continue from it.")
            }
        }

        Section {
            switch model.startStatus {
            case .checking:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking your position…")
                }
            case .blocked(let reason):
                Label(reason, systemImage: "location.slash").foregroundStyle(.orange)
                    .accessibilityIdentifier("startBlocked")
                Button("Recalculate") { model.recalculatePreview() }
            case .idle:
                if model.previewExpired {
                    Label("This route is more than two minutes old.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("Recalculate") { model.recalculatePreview() }
                }
            }
        }

        Section {
            startButton
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }

        Section {
            Button("Cancel", role: .cancel) { model.cancelPreview() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("cancelPreviewButton")
        }

        if model.canSuggestStops {
            Section {
                NavigationLink {
                    StopSuggestionsView()
                } label: {
                    Label("Fuel or a rest stop on the way", systemImage: "fuelpump")
                }
                .accessibilityIdentifier("findStopsLink")
            } footer: {
                Text("Looks along this route and ranks places by the minutes they add, then plans the ride through the one you pick.")
            }
        }

        Section {
            NavigationLink {
                RouteRehearsalView()
            } label: {
                Label("Rehearse this route", systemImage: "list.bullet.indent")
            }
            .disabled(model.rehearsalSteps.isEmpty)
            .accessibilityIdentifier("rehearseRouteLink")
        } footer: {
            Text("Step through every turn of this route and hear its cue through your headset before you leave.")
        }

        Section {
            Button {
                planName = RideView.title(pending)
                namingPlan = true
            } label: {
                Label("Save as a ride plan", systemImage: "bookmark")
            }
            .accessibilityIdentifier("savePlanButton")
            if let planMessage {
                Text(planMessage).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("planMessage")
            }
        } footer: {
            Text("Keeps this destination, its stop and the toll and highway choices together for another day.")
        }
        .alert("Name this ride plan", isPresented: $namingPlan) {
            TextField("Name", text: $planName)
            Button("Save") {
                planMessage = model.savePlan(named: planName) ?? "Saved. Find it under Ride plans on the Ride tab."
            }
            Button("Cancel", role: .cancel) {}
        }

        PreRideReady()
    }

    private var startButton: some View {
        Button {
            model.startNavigation()
        } label: {
            Label("Start", systemImage: "location.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.startStatus == .checking || model.previewExpired)
        .accessibilityIdentifier("startNavigationButton")
    }
}

private struct PreRideReady: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ReadyStatusRow(title: "Route", detail: routeDetail, systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                           tint: model.previewExpired || selectedRoute == nil ? .orange : .accentColor)
                .accessibilityIdentifier("readyRouteStatus")
            ReadyStatusRow(title: "Position", detail: positionDetail, systemImage: "location",
                           tint: .secondary)
                .accessibilityIdentifier("readyPositionStatus")
            ReadyStatusRow(title: "Bike", detail: LinkStatusRow.text(model.bike.state), systemImage: "motorcycle",
                           tint: model.bike.state.isReady ? .green : .orange)
                .accessibilityIdentifier("readyBikeStatus")
            ReadyStatusRow(title: "Helmet audio", detail: audioDetail, systemImage: "headphones",
                           tint: model.voice.holdReason == nil ? .accentColor : .orange)
                .accessibilityIdentifier("readyAudioStatus")
        } header: {
            Label("Pre-Ride Ready", systemImage: "checklist")
        } footer: {
            Text("Review while parked. The bike connection and spoken directions do not prevent Start.")
        }
    }

    private var selectedRoute: RouteOption? {
        model.routeOptions.first { $0.id == model.selectedRouteID }
    }

    private var routeDetail: String {
        if model.previewExpired { return "Expired. Recalculate before starting." }
        guard let route = selectedRoute else { return "No route selected." }
        let name = route.name.isEmpty ? "Selected route" : route.name
        return "\(name) · \(Format.distance(route.distanceMetres)) · \(Format.duration(route.expectedSeconds))"
    }

    private var positionDetail: String {
        if model.mode == .simulation { return "Simulated position; Start does not check GPS." }
        if model.startStatus == .checking { return "Checking your current position against the route start…" }
        guard let measured = model.lastFixTime else {
            return "No cached fix. Start checks your current position and route origin."
        }
        let time = measured.formatted(date: .abbreviated, time: .standard)
        return "Last cached fix: \(time). Start checks your current position and route origin."
    }

    private var audioDetail: String {
        let state = model.voiceEnabled ? "Spoken directions on" : "Spoken directions off"
        let reason = model.voice.holdReason.map { " \($0)" } ?? ""
        return "\(state) · Output: \(model.voice.outputName).\(reason)"
    }
}

private struct ReadyStatusRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(minWidth: 32, minHeight: 32)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct Navigating: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingDestination

    var body: some View {
        Section {
            TurnCard(snapshot: model.guidance, eligible: model.health.directionEligible)
            RideHealthView(health: model.health)
        } header: {
            Text("To \(RideView.title(pending))")
        } footer: {
            DashboardIntentView(intent: model.intent, delivery: model.dashboardDelivery)
        }

        if !model.inbox.waiting.isEmpty {
            Section {
                NavigationLink {
                    QueuedDestinationsView()
                } label: {
                    Label("\(model.inbox.waiting.count) destination\(model.inbox.waiting.count == 1 ? "" : "s") waiting",
                          systemImage: "tray.full")
                }
                .accessibilityIdentifier("queuedDestinations")
            }
        }

        Section {
            RouteOperationRow()
            if model.voiceEnabled {
                Button {
                    model.repeatInstruction()
                } label: {
                    Label("Repeat instruction", systemImage: "speaker.wave.2")
                }
                .disabled(!model.health.directionEligible)
                .accessibilityIdentifier("repeatInstructionButton")
            }
            if model.ride?.phase == .toStop {
                Button {
                    model.skipStop()
                } label: {
                    Label("Skip the stop", systemImage: "forward.end")
                }
                .accessibilityIdentifier("skipStopButton")
            }
        } header: {
            Text("Controls")
        } footer: {
            Text("Use these only while parked, or ask a pillion to.")
        }

        Section {
            Button(role: .destructive) {
                model.stopNavigation()
            } label: {
                Label("End ride", systemImage: "stop.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("stopButton")
        }
    }
}

/// Large next-turn display: arrow, distance, road, arrival time. No arrow is
/// drawn unless ride health says guidance is current.
struct TurnCard: View {
    let snapshot: NavigationSnapshot?
    var eligible = true

    /// A step of a route that is not being ridden, shown the way a turn is.
    init(snapshot: NavigationSnapshot?, eligible: Bool = true, rehearsal: GuidanceStep? = nil) {
        self.snapshot = rehearsal.map {
            NavigationSnapshot(session: SessionID(), generation: RouteGeneration(0),
                               observedAt: MonotonicInstant(offset: .zero), state: .active, step: $0)
        } ?? snapshot
        self.eligible = eligible
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: eligible || snapshot?.state == .arrived
                  ? Self.symbol(for: snapshot?.state == .arrived ? .arrival : snapshot?.step?.maneuver)
                  : "exclamationmark.triangle")
                .font(.system(size: 56, weight: .bold))
                .frame(width: 72)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.largeTitle.weight(.bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if eligible, snapshot?.state == .active, let road = snapshot?.step?.roadText {
                    Text(road).font(.headline).lineLimit(2)
                }
                if eligible, snapshot?.state == .active, let remaining = snapshot?.remainingSeconds,
                   let metres = snapshot?.remainingMetres {
                    Text("Arrive \(Date().addingTimeInterval(TimeInterval(remaining)).formatted(date: .omitted, time: .shortened)) · \(Format.distance(Double(metres))) · \(Format.duration(Double(remaining)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("currentTurn")
    }

    private var headline: String {
        guard let snapshot else { return "Starting…" }
        if !eligible, snapshot.state == .active { return "Paused" }
        switch snapshot.state {
        case .arrived: return "Arrived"
        case .active:
            guard let step = snapshot.step else { return "Follow the route" }
            return Format.distance(Double(step.distanceMetres))
        case .rerouting: return "Rerouting…"
        case .noLocation: return "Waiting for GPS"
        default: return "Follow the route"
        }
    }

    static func symbol(for maneuver: Maneuver?) -> String {
        switch maneuver {
        case .turnLeft, .sharpLeft: "arrow.turn.up.left"
        case .turnRight, .sharpRight: "arrow.turn.up.right"
        case .slightLeft, .keepLeft, .forkLeft, .rampLeft: "arrow.up.left"
        case .slightRight, .keepRight, .forkRight, .rampRight: "arrow.up.right"
        case .uTurnLeft: "arrow.uturn.left"
        case .uTurnRight: "arrow.uturn.right"
        case .merge: "arrow.triangle.merge"
        case .roundaboutClockwise, .roundaboutCounterClockwise: "arrow.triangle.turn.up.right.circle"
        case .ferry, .ferryTrain: "ferry"
        case .arrival: "flag.checkered"
        case .straight: "arrow.up"
        case .unsupported, nil: "location.north.line"
        }
    }
}

/// What the app asked the dashboard to show and what the Bluetooth link reported,
/// in one line. Only the rider can confirm what the dashboard actually displays.
struct DashboardIntentView: View {
    let intent: DashboardIntent
    var delivery: DashboardDelivery = .linkDown

    var body: some View {
        Label(Self.text(intent, delivery), systemImage: {
            if case .guidance = intent { return "gauge.with.dots.needle.67percent" }
            return "gauge.with.dots.needle.0percent"
        }())
    }

    static func text(_ intent: DashboardIntent, _ delivery: DashboardDelivery) -> String {
        let status = switch delivery {
        case .linkDown: "bike not connected"
        case .clearPending: "waiting for the bike"
        case .clearTransportAcknowledged: "bike acknowledged"
        case .clearHandedOffWithoutResponse: "sent, not acknowledged"
        case .guidanceSubmitted: "sent"
        case .deliveryUncertain: "delivery uncertain"
        }
        switch intent {
        case .guidance(let fields, _):
            return "Dashboard: \(ClusterIcon.name(fields.icon)) (\(status))"
        case .clear(let reason):
            return "Dashboard clear requested - \(describe(reason)) (\(status))"
        }
    }

    static func describe(_ reason: ClearReason) -> String {
        switch reason {
        case .noSession: "not navigating"
        case .notGuiding(.rerouting): "finding a new route"
        case .notGuiding(.noLocation): "waiting for GPS"
        case .notGuiding(.failed): "navigation problem"
        case .notGuiding: "waiting for the first position"
        case .noStep: "no current step"
        case .unsupportedManeuver: "turn it can't show"
        case .missingProgress: "distance/ETA unavailable"
        case .stale: "guidance is stale"
        case .invalidValues: "values out of range"
        }
    }
}

struct LinkStatusRow: View {
    let state: BikeLinkState

    var body: some View {
        Label(Self.text(state), systemImage: state.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle")
            .foregroundStyle(state.isReady ? .green : .orange)
    }

    static func text(_ state: BikeLinkState) -> String {
        switch state {
        case .unavailable(.unauthorized): "Bluetooth permission denied - enable it in Settings"
        case .unavailable(.poweredOff): "Bluetooth is off"
        case .unavailable: "Bluetooth unavailable"
        case .idle: "Bike not connected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .discovering: "Checking cluster…"
        case .ready: "Bike connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
        case .failed(let failure): "Connection failed: \(failure)"
        }
    }
}

enum Format {
    static func distance(_ metres: Double) -> String {
        if metres < 1_000 { return "\(Int((metres / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", metres / 1_000)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
