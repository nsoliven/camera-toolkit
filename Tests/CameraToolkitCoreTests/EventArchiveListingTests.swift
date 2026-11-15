import Foundation
import XCTest
@testable import CameraToolkitCore

/// The presence sweep answering the NAS place from one listing of the
/// event's folder: present, missing, and — when the listing fails — unknown.
final class EventArchiveListingTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var locations: EventStorageLocations
        var event: SavedCameraEvent
        var assignments: [PhotoEventAssignment]
        /// Mirror path of each file, relative to the NAS root.
        var mirror: [String: String]
        var folders: [String]
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventArchiveListingTests-\(UUID().uuidString)", isDirectory: true)
        let event = SavedCameraEvent(name: "Trip 2026", eventDate: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")))
        let configuration = AppConfiguration(
            demoRootPath: root.path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            savedEvents: [event]
        )
        let locations = EventStorageLocations(configuration: configuration)
        let assignments = [("A.ARW", 10), ("B.ARW", 20), ("C.ARW", 30)].map { name, size in
            PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Card").path,
                relativePath: name,
                fileSize: Int64(size),
                modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                eventID: event.id,
                deviceID: "sony-a7v"
            )
        }
        let layout = locations.layout(for: event, deviceID: "sony-a7v")
        var mirror: [String: String] = [:]
        for assignment in assignments {
            mirror[assignment.relativePath] = try layout.mirrorRelativePath(for: assignment.relativePath)
        }
        try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            locations: locations,
            event: event,
            assignments: assignments,
            mirror: mirror,
            folders: NASPresenceIndex.folders(for: [event], locations: locations)
        )
    }

    /// A.ARW on the NAS at its size, C.ARW there at another size, B.ARW absent.
    private func writeNASCopies(_ f: Fixture) throws {
        for (name, size) in [("A.ARW", 10), ("C.ARW", 31)] {
            let url = f.locations.nasRoot.appending(path: try XCTUnwrap(f.mirror[name]))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
    }

    /// Answers every place but the NAS; a NAS path reaching it is a stat the
    /// listing was meant to save.
    private final class StatCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var nas = 0
        let root: String
        init(root: String) { self.root = root }
        var nasStats: Int { lock.withLock { nas } }
        var probe: EventPresenceScanner.PresenceProbe {
            { [self] url, _, _ in
                if url?.path.hasPrefix(root) == true { lock.withLock { nas += 1 } }
                return .missing
            }
        }
    }

    private func scan(
        _ f: Fixture,
        listing: NASTreeListing? = nil,
        failed: Bool = false,
        facts: [String: NASSyncStore.VerifiedFact]? = nil,
        probe: EventPresenceScanner.PresenceProbe? = nil
    ) throws -> EventPresenceSummary {
        try XCTUnwrap(EventPresenceScanner.scan(
            event: f.event,
            assignments: f.assignments,
            locations: f.locations,
            mountedVolumes: VolumeInfo.mountedVolumePaths(),
            probe: probe,
            nasFacts: facts ?? [:],
            archiveListing: listing,
            archiveListingFailed: failed
        ))
    }

    private func asset(_ summary: EventPresenceSummary, _ name: String) throws -> EventAssetPresence {
        try XCTUnwrap(summary.assets.first { $0.assignment.relativePath == name })
    }

    private func listed(_ f: Fixture, timeout: TimeInterval = 10) throws -> NASTreeListing {
        switch EventArchiveListing.list(nasRoot: f.locations.nasRoot, folders: f.folders, timeout: timeout) {
        case .listed(let listing): return listing
        case .failed(let reason): throw XCTSkip("listing failed: \(reason)")
        case .cancelled: throw XCTSkip("listing cancelled")
        }
    }

    func testOneListingAnswersPresentAndMissingWithoutAStatPerFile() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try writeNASCopies(f)
        let counter = StatCounter(root: f.locations.nasRoot.path)
        let summary = try scan(f, listing: try listed(f), probe: counter.probe)

        XCTAssertEqual(try asset(summary, "A.ARW").archive, .present, "name and size match")
        XCTAssertEqual(try asset(summary, "B.ARW").archive, .missing, "nothing at that path")
        XCTAssertEqual(try asset(summary, "C.ARW").archive, .missing, "a different size is not this file")
        XCTAssertEqual(summary.onArchive, 1)
        XCTAssertEqual(summary.counts.archiveUnknown, 0)
        XCTAssertEqual(counter.nasStats, 0, "the listing replaced the per-file NAS stats")
    }

    func testAListedFileIsPresentButNotVerifiedWithoutASyncRecord() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try writeNASCopies(f)
        let unverified = try scan(f, listing: try listed(f))
        let a = try asset(unverified, "A.ARW")
        XCTAssertEqual(a.archive, .present)
        XCTAssertNil(a.archiveVerifiedAt, "a listing proves a name and a size, not the bytes")
        XCTAssertFalse(a.archiveIsTrusted, "Take Off Drive must not rely on it")
        XCTAssertEqual(unverified.verifiedOnArchive, 0)

        // Only a record of the same size says verified.
        let key = NASSyncStore.pathKey(try XCTUnwrap(f.mirror["A.ARW"]))
        let verifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let matching = NASSyncStore.VerifiedFact(verifiedAt: verifiedAt, byteCount: 10, sourceModifiedAt: nil)
        XCTAssertEqual(try asset(try scan(f, listing: try listed(f), facts: [key: matching]), "A.ARW").archiveVerifiedAt, verifiedAt)
        let otherSize = NASSyncStore.VerifiedFact(verifiedAt: verifiedAt, byteCount: 11, sourceModifiedAt: nil)
        XCTAssertNil(try asset(try scan(f, listing: try listed(f), facts: [key: otherSize]), "A.ARW").archiveVerifiedAt)
    }

    func testAFailedListingIsUnknownNeverMissingOrPresent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try writeNASCopies(f)
        let key = NASSyncStore.pathKey(try XCTUnwrap(f.mirror["A.ARW"]))
        let verified = NASSyncStore.VerifiedFact(verifiedAt: Date(), byteCount: 10, sourceModifiedAt: nil)
        let counter = StatCounter(root: f.locations.nasRoot.path)
        let summary = try scan(f, failed: true, facts: [key: verified], probe: counter.probe)

        XCTAssertEqual(Set(summary.assets.map(\.archive)), [.unknown])
        XCTAssertEqual(counter.nasStats, 0, "a share that failed its listing is not asked file by file")
        XCTAssertEqual(summary.counts.archiveUnknown, 3)
        XCTAssertEqual(summary.onArchive, 0)
        XCTAssertEqual(summary.verifiedOnArchive, 0, "a sync record does not make an unlisted file verified")
        XCTAssertFalse(summary.archiveOffline, "the NAS is connected; it just did not answer this time")
        XCTAssertTrue(summary.assets.allSatisfy { !$0.archiveIsTrusted })
    }

    func testAnUnmountedNASStaysOfflineRatherThanUnknown() throws {
        var f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // A volume name nothing mounts: never read, only compared.
        let nasVolume = "/Volumes/CTAbsentNAS-\(UUID().uuidString.prefix(8))/Library"
        let configuration = AppConfiguration(
            demoRootPath: f.root.path,
            importSourcePath: f.root.appendingPathComponent("Card").path,
            archivePath: nasVolume + "/Originals",
            bufferPath: f.root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: nasVolume,
            catalogDatabasePath: f.root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: f.root.appendingPathComponent("activity.jsonl").path,
            savedEvents: [f.event]
        )
        f.locations = EventStorageLocations(configuration: configuration)
        let summary = try scan(f, failed: true)
        XCTAssertTrue(summary.archiveOffline)
        XCTAssertEqual(summary.counts.archiveUnknown, 0)
    }

    func testAListingThatThrowsIsFailed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let answer = EventArchiveListing.list(nasRoot: f.locations.nasRoot, folders: f.folders, lister: { _, _, _ in
            throw ToolkitError.commandFailed("no")
        })
        guard case .failed = answer else { return XCTFail("\(answer)") }
    }

    func testANASRootThatIsGoneFailsTheListing() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.locations.nasRoot)
        guard case .failed = EventArchiveListing.list(nasRoot: f.locations.nasRoot, folders: f.folders) else {
            return XCTFail("a share that went away is not an empty folder")
        }
    }

    func testAMissingEventFolderOnAConnectedNASMeansEveryFileIsMissing() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let summary = try scan(f, listing: try listed(f))
        XCTAssertEqual(Set(summary.assets.map(\.archive)), [.missing])
    }

    func testAListingThatDoesNotAnswerInTimeIsFailedAndAskedToStop() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let started = Date()
        let answer = EventArchiveListing.list(nasRoot: f.locations.nasRoot, folders: f.folders, timeout: 0.1, lister: { _, _, isCancelled in
            release.wait()
            if isCancelled() { stopped.signal() }
            throw CancellationError()
        })
        guard case .failed(let reason) = answer else { return XCTFail("\(answer)") }
        XCTAssertTrue(reason.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success, "the abandoned listing is told to stop")
    }

    func testACancelledSweepStopsWaiting() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let release = DispatchSemaphore(value: 0)
        let answer = EventArchiveListing.list(nasRoot: f.locations.nasRoot, folders: f.folders, lister: { _, _, _ in
            release.wait()
            throw CancellationError()
        }, isCancelled: { true })
        release.signal()
        guard case .cancelled = answer else { return XCTFail("\(answer)") }
    }

    func testCoverageNeedsEveryFolder() throws {
        var listing = NASTreeListing(root: "/Volumes/nas_share", method: .smb)
        listing.cover("2026/One", at: Date())
        XCTAssertTrue(EventArchiveListing.covers(listing, folders: ["2026/One"]))
        XCTAssertFalse(EventArchiveListing.covers(listing, folders: ["2026/One", "2026/Two"]))
        XCTAssertFalse(EventArchiveListing.covers(nil, folders: ["2026/One"]))
        XCTAssertFalse(EventArchiveListing.covers(listing, folders: []))
    }
}
