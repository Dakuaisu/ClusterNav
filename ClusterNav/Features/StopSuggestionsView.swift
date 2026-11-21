import MapKit
import RideCore
import SwiftUI

/// Fuel or rest stops along the previewed route, least added time first. Results come
/// from Apple Maps and are shown on an Apple map.
struct StopSuggestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind = StopKind.fuel

    var body: some View {
        List {
            Section {
                Picker("Kind of stop", selection: $kind) {
                    Text("Fuel").tag(StopKind.fuel)
                    Text("Rest").tag(StopKind.rest)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("stopKindPicker")
            } footer: {
                Text("Asks Apple Maps for places near this route and for the travel time through each. Rest covers cafes, restaurants and restrooms.")
            }

            switch model.stopSearch {
            case .idle, .searching:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking along the route…")
                    }
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityIdentifier("stopSearchError")
                    Button("Try again") { model.findStops(kind) }
                }
            case .results(_, let stops) where stops.isEmpty:
                Section {
                    Text("Nothing was found within \(Format.distance(StopPlanner.maxOffRouteMetres)) of this route.")
                        .foregroundStyle(.secondary)
                }
            case .results(_, let stops):
                Section {
                    Map(initialPosition: .automatic) {
                        ForEach(stops) { stop in
                            Marker(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.coordinate.latitude,
                                                                                 longitude: stop.coordinate.longitude))
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Map of the suggested stops")
                    ForEach(stops) { stop in
                        Button {
                            model.chooseStop(stop)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.name).foregroundStyle(Color.primary)
                                Text("\(Self.added(stop.addedSeconds)) · \(Format.distance(stop.offRouteMetres)) from the route")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .accessibilityIdentifier("stop-\(stop.name)")
                    }
                } header: {
                    Text("Least added time first")
                } footer: {
                    Text("Times are Apple Maps estimates for cars. Choosing a stop plans the ride again, to the stop first.")
                }
            }
        }
        .navigationTitle("Stops on the way")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.findStops(kind) }
        .onChange(of: kind) { _, new in model.findStops(new) }
        .onDisappear { model.cancelStopSearch() }
    }

    static func added(_ seconds: Double) -> String {
        seconds < 30 ? "No extra time" : "Adds \(Format.duration(seconds))"
    }
}
