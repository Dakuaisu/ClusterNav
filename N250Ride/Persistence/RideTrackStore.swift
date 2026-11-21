import Foundation
import Observation
import RideCore

struct RideTrackPoint: Codable, Equatable, Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let horizontalAccuracy: Double
}

struct RideTrack: Codable, Identifiable, Equatable, Sendable {
    let id: RideID
    let startedAt: Date
    let consentEpoch: String
    var endedAt: Date?
    /// False for an interrupted recording, a storage failure or a capacity limit.
    var complete: Bool
    var segments: [[RideTrackPoint]]
    var pointCount: Int { segments.reduce(0) { $0 + $1.count } }
}

struct RideTrackMetadata: Codable, Identifiable, Equatable {
    let id: RideID
    let startedAt: Date
    var endedAt: Date?
    var complete: Bool
    var pointCount: Int
    var segmentCount: Int

    init(_ track: RideTrack) {
        id = track.id
        startedAt = track.startedAt
        endedAt = track.endedAt
        complete = track.complete
        pointCount = track.pointCount
        segmentCount = track.segments.filter { !$0.isEmpty }.count
    }
}

/// Separate, opt-in raw GPS history: one file per track, so a ride only ever rewrites
/// its own recording, plus a small index that can always be rebuilt from those files.
/// A draft is deliberately incomplete on disk: a crash or lost buffered fixes can never
/// be mistaken for a complete recording. The newest `maxTracks` are kept.
@MainActor
@Observable
final class RideTrackStore {
    private(set) var enabled: Bool
    private(set) var problem: String?
    /// Newest first.
    private(set) var tracks: [RideTrackMetadata] = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let singleFileURLs: [URL]
    @ObservationIgnored private let io: RecordIO
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let indexFile: RecordFile<[RideTrackMetadata]>
    /// Oldest first.
    @ObservationIgnored private var index: [RideTrackMetadata] = []
    @ObservationIgnored private var active: RideTrack?
    @ObservationIgnored private var activeFile: RecordFile<RideTrack>?
    @ObservationIgnored private var cached: RideTrack?
    @ObservationIgnored private var legStartedAt: Date?
    @ObservationIgnored private var hasGap = false
    @ObservationIgnored private var lastFlush: Date?
    private static let enabledKey = "rideTracksEnabled"
    private static let epochKey = "rideTracksConsentEpoch"
    static let maxPoints = 20_000
    static let maxTracks = 100
    /// A full track is under 3 MiB of JSON.
    private static let maxTrackBytes = 4 * 1_024 * 1_024
    private static let unreadable = "Some saved tracks couldn't be read. Delete all GPS tracks to discard them."
    private static let saveFailed = "Tracks couldn't be saved; the recording may be incomplete."
    private static let incomplete = "This track is incomplete."

    init(directory parent: URL, defaults: UserDefaults, io: RecordIO = .real) {
        self.defaults = defaults
        self.io = io
        enabled = defaults.bool(forKey: Self.enabledKey)
        directory = parent.appendingPathComponent("PrivateRideTracks", isDirectory: true)
        singleFileURLs = [parent, directory].map { $0.appendingPathComponent("ride-tracks.json") }
        indexFile = RecordFile(directory: directory, name: "index.json", schemaVersion: 1,
                               maxBytes: 1_024 * 1_024, io: io)
        var unreadable = !splitSingleFiles()
        do {
            index = try indexFile.load() ?? []
        } catch {
            // The index is derived data: a damaged one is rebuilt from the track files.
            if case .unavailable = error {} else { try? indexFile.delete() }
        }
        let stored = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }.map { RideID($0) })
        let known = index.count
        index.removeAll { !stored.contains($0.id) }
        var changed = index.count != known
        for id in stored where !index.contains(where: { $0.id == id }) {
            if let track = (try? trackFile(id).load()) ?? nil {
                index.append(RideTrackMetadata(track))
                changed = true
            } else {
                unreadable = true
            }
        }
        index.sort { $0.startedAt < $1.startedAt }
        if changed { saveIndex() }
        if unreadable { problem = Self.unreadable }
        publish()
    }

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        defaults.set(UUID().uuidString, forKey: Self.epochKey)
        if !on {
            let now = Date()
            if let active {
                hasGap = true
                finish(active.id, now: now)
            }
            // Consent changed: no earlier draft may be continued.
            closeAbandonedDrafts()
        }
    }

    /// Called only for a new journey, never for a recovery or a later leg.
    func begin(_ id: RideID, startedAt: Date) {
        guard enabled, !index.contains(where: { $0.id == id }) else { return }
        if let active { finish(active.id, now: startedAt) }
        closeAbandonedDrafts()
        while index.count >= Self.maxTracks, let oldest = index.first {
            guard delete(oldest.id) else {
                problem = "Track storage is full and the oldest recap couldn't be removed. Delete a recap first."
                return
            }
        }
        let epoch = defaults.string(forKey: Self.epochKey) ?? UUID().uuidString
        defaults.set(epoch, forKey: Self.epochKey)
        let track = RideTrack(id: id, startedAt: startedAt, consentEpoch: epoch,
                              endedAt: nil, complete: false, segments: [[]])
        active = track
        activeFile = trackFile(id)
        hasGap = false
        legStartedAt = startedAt
        lastFlush = startedAt
        index.append(RideTrackMetadata(track))
        flush()
    }

    /// Only resumes a draft that existed before interruption under uninterrupted consent.
    func resume(_ id: RideID, at now: Date) {
        guard enabled, let epoch = defaults.string(forKey: Self.epochKey) else { return }
        if active?.id != id {
            let file = trackFile(id)
            guard index.contains(where: { $0.id == id && $0.endedAt == nil }),
                  let track = (try? file.load()) ?? nil, track.endedAt == nil, track.consentEpoch == epoch
            else { return }
            if let active { finish(active.id, now: now) }
            active = track
            activeFile = file
            hasGap = true
        }
        legStartedAt = now
        active?.segments.append([])
        lastFlush = now
        flush()
    }

    func add(_ sample: LocationSample, now: Date) {
        guard enabled, let recorded = active?.pointCount, let legStartedAt, sample.timestamp >= legStartedAt,
              sample.timestamp.timeIntervalSinceReferenceDate.isFinite,
              sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0 else { return }
        let lastPoint = active?.segments.reversed().lazy.compactMap(\.last).first
        if let lastPoint, sample.timestamp <= lastPoint.timestamp { return }
        guard recorded < Self.maxPoints else {
            hasGap = true
            problem = "Track point limit reached; this recording is incomplete."
            return
        }
        // Mutated in place: a copy here would duplicate the whole recording on every fix.
        if active?.segments.isEmpty == true { active?.segments.append([]) }
        if let last = active?.segments.last?.last, sample.timestamp.timeIntervalSince(last.timestamp) > 5 {
            active?.segments.append([])
            hasGap = true
            problem = Self.incomplete
        }
        if let segment = active?.segments.indices.last {
            active?.segments[segment].append(
                RideTrackPoint(coordinate: sample.coordinate, timestamp: sample.timestamp,
                               horizontalAccuracy: sample.horizontalAccuracy))
        }
        if let active { record(active) }
        publish()
        if now.timeIntervalSince(lastFlush ?? now) >= 20 { lastFlush = now; flush() }
    }

    /// Pause at a stop; no fixes are accepted until a new leg starts.
    func pause() {
        legStartedAt = nil
        flush()
    }

    func finish(_ id: RideID, now: Date) {
        guard var track = active, track.id == id, let file = activeFile else { return }
        track.endedAt = now
        track.complete = !hasGap
        let saved = write(track, to: file)
        // An unsaved ending leaves the draft on disk, which a relaunch shows as unfinished.
        if !saved { track.complete = false }
        active = nil
        activeFile = nil
        legStartedAt = nil
        cached = track
        record(track)
        saveIndex()
        problem = saved ? nil : Self.saveFailed
        publish()
    }

    func flush() {
        guard let active, let activeFile else { return }
        if write(active, to: activeFile) {
            problem = hasGap ? Self.incomplete : nil
        } else {
            hasGap = true
            problem = Self.saveFailed
        }
        record(active)
        saveIndex()
        publish()
    }

    /// Ends drafts that can no longer be continued (a discarded recovery, changed consent,
    /// a newer ride) at their last recorded point, as incomplete.
    func closeAbandonedDrafts() {
        var changed = false
        for entry in index where entry.endedAt == nil && entry.id != active?.id {
            let file = trackFile(entry.id)
            guard var track = (try? file.load()) ?? nil else { continue }
            track.endedAt = track.segments.reversed().lazy.compactMap(\.last).first?.timestamp ?? track.startedAt
            track.complete = false
            guard write(track, to: file) else { continue }
            record(track)
            changed = true
        }
        if changed {
            saveIndex()
            publish()
        }
    }

    func route(_ id: RideID) -> RideTrack? {
        if let active, active.id == id { return active }
        if cached?.id != id { cached = (try? trackFile(id).load()) ?? nil }
        return cached
    }

    @discardableResult
    func delete(_ id: RideID) -> Bool {
        do {
            try trackFile(id).delete()
        } catch {
            problem = "Couldn't delete the recap."
            return false
        }
        if active?.id == id {
            active = nil
            activeFile = nil
            legStartedAt = nil
        }
        if cached?.id == id { cached = nil }
        index.removeAll { $0.id == id }
        saveIndex()
        publish()
        return true
    }

    /// Also discards anything unreadable, including recordings in an earlier layout.
    @discardableResult
    func deleteAll() -> Bool {
        do {
            for url in singleFileURLs + [directory] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            problem = "Couldn't delete the saved tracks."
            return false
        }
        try? indexFile.delete()
        index = []
        active = nil
        activeFile = nil
        cached = nil
        legStartedAt = nil
        problem = nil
        publish()
        return true
    }

    /// GPX 1.1 keeps segment boundaries and the original measurement time and accuracy.
    func exportGPX(_ id: RideID) -> String? {
        guard let track = route(id) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let segments = track.segments.filter { !$0.isEmpty }.map { segment in
            let points = segment.map { point in
                "<trkpt lat=\"\(point.coordinate.latitude)\" lon=\"\(point.coordinate.longitude)\"><time>\(formatter.string(from: point.timestamp))</time><extensions><pv:horizontalAccuracy>\(point.horizontalAccuracy)</pv:horizontalAccuracy></extensions></trkpt>"
            }.joined()
            return "<trkseg>\(points)</trkseg>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Pulsar Vector\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:pv=\"urn:pulsar-vector:gpx:1\"><trk>\(segments)</trk></gpx>"
    }

    private func trackFile(_ id: RideID) -> RecordFile<RideTrack> {
        RecordFile(directory: directory, name: "\(id).json", schemaVersion: 1, maxBytes: Self.maxTrackBytes, io: io)
    }

    /// Coordinates are written only into a directory already excluded from backups.
    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try io.excludeFromBackup(directory)
            return true
        } catch {
            return false
        }
    }

    private func write(_ track: RideTrack, to file: RecordFile<RideTrack>) -> Bool {
        guard prepareDirectory() else { return false }
        do {
            try file.save(track)
            return true
        } catch {
            return false
        }
    }

    /// Best effort: a missing or outdated index is rebuilt from the track files at launch.
    private func saveIndex() {
        guard prepareDirectory() else { return }
        try? indexFile.save(index)
    }

    private func record(_ track: RideTrack) {
        let entry = RideTrackMetadata(track)
        if let position = index.firstIndex(where: { $0.id == track.id }) {
            index[position] = entry
        } else {
            index.append(entry)
        }
    }

    private func publish() {
        tracks = index.reversed()
    }

    /// Earlier builds kept every track in one file. False when one of those can't be read;
    /// it is then left untouched until the rider deletes all tracks.
    private func splitSingleFiles() -> Bool {
        var readable = true
        for url in singleFileURLs where FileManager.default.fileExists(atPath: url.path) {
            let old = RecordFile<[RideTrack]>(directory: url.deletingLastPathComponent(), name: url.lastPathComponent,
                                              schemaVersion: 1, maxBytes: 8 * 1_024 * 1_024, io: io)
            guard let stored = (try? old.load()) ?? nil else {
                readable = false
                continue
            }
            let moved = stored.allSatisfy { track in
                let file = trackFile(track.id)
                return FileManager.default.fileExists(atPath: file.url.path) || write(track, to: file)
            }
            if moved { try? old.delete() } else { readable = false }
        }
        return readable
    }
}
