import RideCore
import SwiftUI
import UniformTypeIdentifiers

struct RideRecapDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: RideID

    @State private var confirmingExport = false
    @State private var confirmingDelete = false
    @State private var showingExporter = false
    @State private var exportDocument: RideRecapGPXDocument?
    @State private var actionError: String?

    var body: some View {
        List {
            if model.tracks.tracks.contains(where: { $0.id == id }), let track = model.tracks.route(id) {
                let geometry = RideRecapGeometry(track: track)
                Section {
                    if geometry.segments.isEmpty {
                        Text("No recorded GPS points are available to show on the map.")
                            .foregroundStyle(.secondary)
                    } else {
                        RideRecapMap(track: track, geometry: geometry)
                    }
                } header: {
                    Text("Recorded route")
                } footer: {
                    if geometry.segments.count > 1 {
                        Text("Separate lines and points show the recorded segments; gaps are not connected.")
                    }
                }

                Section {
                    LabeledContent("Started", value: track.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let endedAt = track.endedAt {
                        LabeledContent("Ended", value: endedAt.formatted(date: .abbreviated, time: .shortened))
                        if endedAt >= track.startedAt {
                            LabeledContent("Elapsed time", value: Self.elapsed(endedAt.timeIntervalSince(track.startedAt)))
                        }
                    } else {
                        LabeledContent("Ended", value: "Not recorded")
                    }
                    LabeledContent("GPS distance", value: geometry.distance.map { "About \(Format.distance($0))" } ?? "Not enough points")
                    LabeledContent("GPS points", value: "\(track.pointCount)")
                    LabeledContent("Segments", value: "\(geometry.segments.count)")
                    LabeledContent("Status", value: Self.status(track))
                } header: {
                    Text("Summary")
                } footer: {
                    Text("Distance is estimated from GPS within each segment, not the bike's odometer. Elapsed time includes any stops. An unfinished or incomplete track may be missing part of the ride.")
                }

                Section {
                    Button {
                        confirmingExport = true
                    } label: {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                    .disabled(track.pointCount == 0)
                    .accessibilityIdentifier("exportTrackButton")
                    Button("Delete recap", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("deleteTrackButton")
                } footer: {
                    Text("Exported copies can be shared and remain wherever you save them, even after this recap is deleted.")
                }
            } else {
                Text("This recap is no longer available.").foregroundStyle(.secondary)
            }
            if let problem = model.tracks.problem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle("Ride recap")
        .navigationBarTitleDisplayMode(.inline)
        // The file picker opens only once this sheet has gone: two can't be presented at once.
        .sheet(isPresented: $confirmingExport, onDismiss: { showingExporter = exportDocument != nil }) {
            if let track = model.tracks.route(id) {
                RideRecapExportSheet(track: track) { hideEnds in
                    confirmingExport = false
                    prepareExport(hidingEnds: hideEnds)
                }
            }
        }
        .confirmationDialog("Delete this recap?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete recap", role: .destructive) {
                if model.tracks.delete(id) {
                    dismiss()
                } else {
                    actionError = model.tracks.problem ?? "The recap could not be deleted. Please try again."
                }
            }
        } message: {
            Text("This stops recording this track if it is still in progress. Ride-history summaries and exported copies are not deleted.")
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentTypes: [RideRecapGPXDocument.contentType], defaultFilename: "ClusterNav-ride.gpx") { result in
            exportDocument = nil
            if case .failure(let error) = result {
                let failure = error as NSError
                if !(error is CancellationError),
                   !(failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError) {
                    actionError = "The GPX file could not be exported. Please try again."
                }
            }
        } onCancellation: {
            exportDocument = nil
        }
        .alert("Couldn't complete the action", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "Please try again.")
            }
    }

    private func prepareExport(hidingEnds: Bool) {
        guard let gpx = model.tracks.exportGPX(id, hidingEnds: hidingEnds) else {
            actionError = "This recap is no longer available to export."
            return
        }
        exportDocument = RideRecapGPXDocument(gpx: gpx)
    }

    private static func status(_ track: RideTrack) -> String {
        if track.endedAt == nil { return "Unfinished" }
        return track.complete ? "Complete" : "Incomplete"
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        return Format.duration(seconds)
    }
}

/// What exactly will leave the phone, shown before anything is saved.
private struct RideRecapExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: RideTrack
    let export: (Bool) -> Void
    @State private var hideEnds = true

    var body: some View {
        let shared = hideEnds ? track.hidingEnds() : track
        let geometry = RideRecapGeometry(track: shared)
        NavigationStack {
            List {
                Section {
                    Toggle("Hide the start and end", isOn: $hideEnds)
                        .accessibilityIdentifier("hideEndsToggle")
                } footer: {
                    Text("Leaves out every recorded point within \(Int(RideTrack.privacyRadiusMetres)) m of where this recording started and ended, such as your home or workplace.")
                }

                Section {
                    if geometry.segments.isEmpty {
                        Text("Nothing is left to share: the whole ride was within \(Int(RideTrack.privacyRadiusMetres)) m of its start or end.")
                            .foregroundStyle(.secondary)
                    } else {
                        RideRecapMap(track: shared, geometry: geometry)
                    }
                    LabeledContent("Points in the file", value: "\(shared.pointCount) of \(track.pointCount)")
                        .accessibilityIdentifier("exportPointCount")
                } header: {
                    Text("What will be shared")
                } footer: {
                    Text("The file contains these precise coordinates, their timestamps and GPS accuracy. Anyone you share it with can see where and when you travelled. Times are not altered.")
                }

                Section {
                    Button {
                        export(hideEnds)
                    } label: {
                        Text("Choose where to save").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shared.pointCount == 0)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("confirmExportButton")
                }
            }
            .navigationTitle("Export GPX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct RideRecapGPXDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml
    static var readableContentTypes: [UTType] { [contentType] }
    let data: Data

    init(gpx: String) {
        data = Data(gpx.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
