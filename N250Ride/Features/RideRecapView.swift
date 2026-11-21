import SwiftUI

struct RideRecapView: View {
    @Environment(AppModel.self) private var model
    @State private var showingConsent = false
    @State private var confirmingDeleteAll = false
    @State private var deleteFailed = false

    var body: some View {
        List {
            Section {
                Toggle("Record GPS tracks", isOn: Binding(
                    get: { model.tracks.enabled },
                    set: { on in
                        if on {
                            showingConsent = true
                        } else {
                            model.tracks.setEnabled(false)
                        }
                    }))
                    .accessibilityIdentifier("trackRecordingToggle")
            } header: {
                Text("Recording")
            } footer: {
                Text("Off by default and separate from ride history. Recording starts with your next new ride. Turning it off stops the current recording but keeps saved tracks until you delete them. The latest \(RideTrackStore.maxTracks) recaps are kept; the oldest is removed when a new recording starts.")
            }

            Section("Saved recaps") {
                if model.tracks.tracks.isEmpty {
                    Text(model.tracks.problem != nil ? "No recaps are currently available."
                         : model.tracks.enabled ? "No recaps yet." : "No recaps yet. Turn on recording to save a future ride.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.tracks.tracks) { track in
                    NavigationLink {
                        RideRecapDetailView(id: track.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                            Text("\(track.pointCount) GPS points · \(track.segmentCount) segments")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !track.complete {
                                Text(track.endedAt == nil ? "Unfinished" : "Incomplete")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let problem = model.tracks.problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
            }

            if !model.tracks.tracks.isEmpty || model.tracks.problem != nil {
                Section {
                    Button("Delete all GPS tracks", role: .destructive) { confirmingDeleteAll = true }
                        .accessibilityIdentifier("deleteAllTracksButton")
                } footer: {
                    Text("Deleting tracks does not delete ride-history summaries or copies you've exported.")
                }
            }
        }
        .navigationTitle("GPS Recaps")
        .alert("Record GPS tracks?", isPresented: $showingConsent) {
            Button("Turn on recording") { model.tracks.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Future rides can save precise locations, timestamps and GPS accuracy on this phone. Recording starts with your next new ride. Turning it off stops recording but does not delete saved tracks.")
        }
        .confirmationDialog("Delete all GPS tracks?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all tracks", role: .destructive) {
                if !model.tracks.deleteAll() { deleteFailed = true }
            }
        } message: {
            Text("This also discards any unreadable saved tracks and stops the current track. Ride-history summaries and exported copies are not deleted.")
        }
        .alert("Couldn't delete tracks", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.tracks.problem ?? "The saved tracks could not be deleted. Please try again.")
        }
    }
}
