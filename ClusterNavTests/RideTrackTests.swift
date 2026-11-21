import Foundation
import MapKit
import RideCore
import Testing
@testable import ClusterNav

@MainActor
struct RideTrackTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "RideTrackTests-\(UUID())")!
    let point = Coordinate(latitude: 12.97, longitude: 77.59)!
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func segmentedRoutePersistsAndExportsOriginalMeasurements() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 4.5, timestamp: start), now: start)
        store.pause()
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 8, timestamp: start), now: start)
        store.resume(id, at: start.addingTimeInterval(10))
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 7, timestamp: start.addingTimeInterval(11)),
                  now: start.addingTimeInterval(11))
        store.finish(id, now: start.addingTimeInterval(12))
        let reloaded = RideTrackStore(directory: directory, defaults: defaults)
        let route = try #require(reloaded.route(id))
        #expect(route.complete)
        #expect(route.segments.map(\.count) == [1, 1])
        #expect(route.segments[0][0].timestamp == start)
        #expect(route.segments[0][0].horizontalAccuracy == 4.5)
        let gpx = try #require(reloaded.exportGPX(id))
        #expect(gpx.components(separatedBy: "<trkseg>").count == 3)
        #expect(gpx.contains("<pv:horizontalAccuracy>4.5</pv:horizontalAccuracy>"))
        #expect(reloaded.delete(id))
        #expect(reloaded.route(id) == nil)
    }

    @Test func optOutPreservesButCannotResumeOldJourney() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 1, timestamp: start), now: start)
        store.setEnabled(false)
        store.setEnabled(true)
        store.resume(id, at: start)
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 2, timestamp: start), now: start)
        let route = try #require(store.route(id))
        #expect(!route.complete)
        #expect(route.pointCount == 1)
    }

    @Test func interruptedRecoveryStaysIncomplete() throws {
        let id = RideID()
        let first = RideTrackStore(directory: directory, defaults: defaults)
        first.setEnabled(true)
        first.begin(id, startedAt: start)
        first.add(LocationSample(coordinate: point, horizontalAccuracy: 3, timestamp: start), now: start)
        first.flush()
        let second = RideTrackStore(directory: directory, defaults: defaults)
        second.resume(id, at: start.addingTimeInterval(5))
        second.finish(id, now: start.addingTimeInterval(6))
        #expect(try #require(second.route(id)).complete == false)
    }

    @Test func sourceTimesRejectOldFixesAndSplitOnlyUnexpectedGaps() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        func add(_ seconds: TimeInterval, accuracy: Double = 1) {
            store.add(LocationSample(coordinate: point, horizontalAccuracy: accuracy,
                                     timestamp: start.addingTimeInterval(seconds)), now: start)
        }
        add(-1)
        add(0)
        add(0, accuracy: 2)
        add(5)
        add(4)
        add(11)
        store.pause()
        store.resume(id, at: start.addingTimeInterval(30))
        add(11, accuracy: 2)
        add(29)
        add(30)
        store.finish(id, now: start.addingTimeInterval(31))
        let route = try #require(RideTrackStore(directory: directory, defaults: defaults).route(id))
        #expect(route.segments.map(\.count) == [2, 1, 1])
        #expect(!route.complete)
    }

    @Test func backupExclusionFailurePreventsWritingCoordinates() throws {
        let writes = TrackWriteCounter()
        let io = RecordIO(write: { _, _ in writes.increment() }, excludeFromBackup: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let store = RideTrackStore(directory: directory, defaults: defaults, io: io)
        store.setEnabled(true)
        store.begin(RideID(), startedAt: start)
        #expect(store.problem != nil)
        #expect(writes.count == 0)
        #expect(storedFiles().isEmpty)
    }

    @Test func singleFileLayoutIsSplitPerTrackAndDeletionIsDurable() throws {
        let id = RideID()
        let original = RideTrack(id: id, startedAt: start, consentEpoch: "legacy", endedAt: start,
                                 complete: true, segments: [[RideTrackPoint(coordinate: point, timestamp: start,
                                                                             horizontalAccuracy: 1)]])
        let legacy = RecordFile<[RideTrack]>(directory: directory, name: "ride-tracks.json", schemaVersion: 1,
                                              maxBytes: 8 * 1_024 * 1_024)
        try legacy.save([original])
        let store = RideTrackStore(directory: directory, defaults: defaults)
        #expect(store.route(id) == original)
        #expect(!FileManager.default.fileExists(atPath: legacy.url.path))
        #expect(storedFiles().contains("\(id).json"))
        #expect(store.delete(id))
        #expect(RideTrackStore(directory: directory, defaults: defaults).route(id) == nil)
    }

    @Test func deletionIsDurableEvenWhenNothingCanBeWritten() throws {
        let id = RideID()
        let store = RideTrackStore(directory: directory, defaults: defaults)
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.finish(id, now: start)
        let io = RecordIO(write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                          excludeFromBackup: RecordIO.real.excludeFromBackup)
        let failing = RideTrackStore(directory: directory, defaults: defaults, io: io)
        #expect(failing.delete(id))
        #expect(failing.tracks.isEmpty)
        let reloaded = RideTrackStore(directory: directory, defaults: defaults)
        #expect(reloaded.route(id) == nil && reloaded.tracks.isEmpty, "a stale index entry is dropped at launch")
    }

    @Test func exclusionFailureDuringSaveDoesNotReplacePriorFile() throws {
        let state = TrackIOState()
        let io = RecordIO(write: { data, url in
            state.recordWrite()
            try RecordIO.real.write(data, url)
        }, excludeFromBackup: { url in
            if state.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try RecordIO.real.excludeFromBackup(url)
        })
        let id = RideID()
        let store = RideTrackStore(directory: directory, defaults: defaults, io: io)
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        let writesBeforeFailure = state.writes
        #expect(writesBeforeFailure > 0)
        state.failExclusion()
        store.add(LocationSample(coordinate: point, horizontalAccuracy: 1, timestamp: start), now: start)
        store.flush()
        #expect(state.writes == writesBeforeFailure)
        #expect(store.problem != nil)
        let reloaded = RideTrackStore(directory: directory, defaults: defaults)
        #expect(try #require(reloaded.route(id)).pointCount == 0)
    }

    private func storedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("PrivateRideTracks").path)) ?? []
    }

    private func sample(_ seconds: TimeInterval) -> LocationSample {
        LocationSample(coordinate: point, horizontalAccuracy: 5, timestamp: start.addingTimeInterval(seconds))
    }

    @Test func aFullLengthTrackSavesAndTheNextPointMarksItIncomplete() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        for second in 0..<RideTrackStore.maxPoints { store.add(sample(Double(second)), now: start) }
        store.flush()
        #expect(store.problem == nil, "the documented point cap fits in the track's file")
        store.add(sample(Double(RideTrackStore.maxPoints)), now: start)
        store.finish(id, now: start.addingTimeInterval(Double(RideTrackStore.maxPoints)))
        let saved = try #require(RideTrackStore(directory: directory, defaults: defaults).route(id))
        #expect(saved.pointCount == RideTrackStore.maxPoints && !saved.complete)
    }

    @Test func theOldestRecapMakesRoomForANewRide() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        store.setEnabled(true)
        var ids: [RideID] = []
        for ride in 0...RideTrackStore.maxTracks {
            let id = RideID()
            ids.append(id)
            let began = start.addingTimeInterval(Double(ride) * 60)
            store.begin(id, startedAt: began)
            store.add(LocationSample(coordinate: point, horizontalAccuracy: 5, timestamp: began), now: began)
            store.finish(id, now: began.addingTimeInterval(30))
        }
        #expect(store.problem == nil)
        let reloaded = RideTrackStore(directory: directory, defaults: defaults)
        #expect(reloaded.tracks.count == RideTrackStore.maxTracks)
        #expect(reloaded.route(ids[0]) == nil, "the oldest recap was removed")
        #expect(reloaded.route(ids[1])?.pointCount == 1 && reloaded.tracks.first?.id == ids.last)
    }

    @Test func aGapIsReportedOnlyWhileItsRideIsRecording() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.add(sample(0), now: start)
        store.add(sample(60), now: start)
        #expect(store.problem != nil)
        store.finish(id, now: start.addingTimeInterval(61))
        #expect(store.problem == nil, "a finished ride leaves no banner behind")
        #expect(store.tracks.first?.complete == false && store.tracks.first?.segmentCount == 2)
    }

    @Test func aDraftThatCanNoLongerContinueIsClosedAtItsLastPoint() throws {
        let id = RideID()
        let first = RideTrackStore(directory: directory, defaults: defaults)
        first.setEnabled(true)
        first.begin(id, startedAt: start)
        first.add(sample(3), now: start)
        first.flush()
        let relaunched = RideTrackStore(directory: directory, defaults: defaults)
        #expect(relaunched.tracks.first?.endedAt == nil)
        relaunched.closeAbandonedDrafts()
        let closed = try #require(RideTrackStore(directory: directory, defaults: defaults).route(id))
        #expect(closed.endedAt == start.addingTimeInterval(3) && !closed.complete)
        relaunched.resume(id, at: start.addingTimeInterval(10))
        relaunched.add(sample(11), now: start)
        #expect(relaunched.route(id)?.pointCount == 1, "a closed draft is never continued")
    }

    @Test func aDamagedIndexIsRebuiltFromTheTrackFiles() throws {
        let id = RideID()
        let store = RideTrackStore(directory: directory, defaults: defaults)
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.add(sample(0), now: start)
        store.finish(id, now: start.addingTimeInterval(1))
        let index = directory.appendingPathComponent("PrivateRideTracks/index.json")
        try Data("not json".utf8).write(to: index)
        let damaged = RideTrackStore(directory: directory, defaults: defaults)
        #expect(damaged.tracks.map(\.id) == [id] && damaged.tracks.first?.pointCount == 1 && damaged.problem == nil)
        try FileManager.default.removeItem(at: index)
        #expect(RideTrackStore(directory: directory, defaults: defaults).tracks.map(\.id) == [id])
    }

    @Test func anUnreadableTrackIsReportedKeptAndDiscardedOnlyByDeleteAll() throws {
        let folder = directory.appendingPathComponent("PrivateRideTracks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(RideID()).json")
        try Data(#"{"schemaVersion":99,"payload":{}}"#.utf8).write(to: file)
        let store = RideTrackStore(directory: directory, defaults: defaults)
        #expect(store.tracks.isEmpty && store.problem != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.deleteAll())
        #expect(store.problem == nil && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func exportedGPXIsWellFormedAndKeepsSegments() throws {
        let store = RideTrackStore(directory: directory, defaults: defaults)
        let id = RideID()
        store.setEnabled(true)
        store.begin(id, startedAt: start)
        store.add(sample(0), now: start)
        store.add(sample(1), now: start)
        store.add(sample(60), now: start)
        store.finish(id, now: start.addingTimeInterval(61))
        let gpx = try #require(store.exportGPX(id))
        let counter = GPXElementCounter()
        let parser = XMLParser(data: Data(gpx.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = counter
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
        #expect(counter.counts["trkseg"] == 2 && counter.counts["trkpt"] == 3 && counter.counts["time"] == 3)
        #expect(counter.counts["horizontalAccuracy"] == 3)
    }

    @Test func recapGeometryMeasuresWithinSegmentsAndFitsEveryPoint() throws {
        let north = try #require(Coordinate(latitude: 12.98, longitude: 77.59))
        let east = try #require(Coordinate(latitude: 12.98, longitude: 77.61))
        func points(_ coordinates: [Coordinate]) -> [RideTrackPoint] {
            coordinates.map { RideTrackPoint(coordinate: $0, timestamp: start, horizontalAccuracy: 5) }
        }
        let track = RideTrack(id: RideID(), startedAt: start, consentEpoch: "e", endedAt: start, complete: false,
                              segments: [points([point, north]), [], points([east])])
        let geometry = RideRecapGeometry(track: track)
        #expect(geometry.segments.map(\.count) == [2, 1])
        let distance = try #require(geometry.distance)
        #expect(abs(distance - point.distance(to: north)) < 0.001, "the gap to the last segment is not counted")
        let region = try #require(geometry.region)
        #expect(abs(region.center.latitude - 12.975) < 1e-9 && abs(region.center.longitude - 77.60) < 1e-9)
        #expect(region.span.latitudeDelta >= 0.01 && region.span.longitudeDelta >= 0.02)
        let single = RideRecapGeometry(track: RideTrack(id: RideID(), startedAt: start, consentEpoch: "e", endedAt: nil,
                                                        complete: false, segments: [points([point])]))
        #expect(single.distance == nil && single.region?.span.latitudeDelta == 0.01)
        #expect(RideRecapGeometry(track: RideTrack(id: RideID(), startedAt: start, consentEpoch: "e", endedAt: nil,
                                                   complete: false, segments: [[]])).region == nil)
    }

    @Test func modelOnlyRecordsAfterLiveStart() throws {
        let spy = SpyProvider()
        let timers = ManualRideTimers(clock: ManualClock())
        let model = AppModel(configuration: AppConfiguration(navigationProvider: .apple, googleAPIKey: nil,
                                                            liveNavigationAuthorized: false, provenStatusProfile: nil),
                             defaults: defaults, provider: spy, dependencies: .virtual(timers))
        model.locationAuthorization = { .authorizedWhenInUse }
        model.tracks.setEnabled(true)
        model.propose(point)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        let sample = LocationSample(coordinate: point, horizontalAccuracy: 5, timestamp: timers.clock.wallNow)
        let fix = AdmittedFix(sample: sample, measuredAt: timers.clock.now, expiresAt: timers.clock.now + .seconds(5))
        spy.onFix?(fix)
        #expect(model.tracks.tracks.isEmpty)
        model.startNavigation()
        spy.onFix?(fix)
        #expect(model.tracks.tracks.first?.pointCount == 1)
        model.stopNavigation()
        spy.onFix?(fix)
        #expect(model.tracks.tracks.first?.pointCount == 1)
    }
}

private final class GPXElementCounter: NSObject, XMLParserDelegate {
    var counts: [String: Int] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        counts[elementName, default: 0] += 1
    }
}

private final class TrackWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

private final class TrackIOState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    private var count = 0
    var shouldFail: Bool { lock.lock(); defer { lock.unlock() }; return failure }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func recordWrite() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func failExclusion() { lock.lock(); defer { lock.unlock() }; failure = true }
}
