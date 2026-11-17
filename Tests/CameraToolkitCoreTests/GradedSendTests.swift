@testable import CameraToolkitCore
import Foundation
import XCTest

/// Send to Immich with graded copies: the planner reaching clips that are
/// only on the NAS, the NAS copy's verification record, the graded-copy
/// bookkeeping, and the album swap (graded copy in, app-added original out).
final class GradedSendPlannerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_100)
    private let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))

    private func assignment(_ name: String, root: URL) -> PhotoEventAssignment {
        PhotoEventAssignment(sourceRootPath: root.appendingPathComponent("Card").path, relativePath: name, fileSize: 10, modifiedAt: date, eventID: event.id, deviceID: "sony-a7v")
    }

    private func key(_ name: String) -> String { FaceIndexStore.fileKey(fileName: name, byteCount: 10, modifiedAt: date) }

    func testNASOnlyLogClipsAreReadAndWrittenOnTheNAS() throws {
        try withTemporaryDirectory { root in
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            // C0001 on the drive, C0002 and C0003 only on the NAS, C0004 nowhere,
            // C0005 on the NAS but marked Not Log, C0006_709 a graded copy.
            let names = ["C0001.MP4", "C0002.MP4", "C0003.MP4", "C0004.MP4", "C0005.MP4", "C0006_709.mov"]
            let assignments = names.map { assignment($0, root: root) }
            var onDrive: Set<String> = []
            var onNAS: Set<String> = []
            for item in assignments {
                let drive = try XCTUnwrap(locations.driveURL(for: item, event: event, policy: .buffer))
                let nas = try XCTUnwrap(locations.archiveURL(for: item, event: event))
                switch item.relativePath {
                case "C0001.MP4": onDrive.insert(drive.path); onNAS.insert(nas.path)
                case "C0004.MP4": break
                default: onNAS.insert(nas.path)
                }
            }
            let inputs = GradedSyncPlanner.Inputs(
                events: [event], assignments: assignments, locations: locations, policy: { _ in .buffer },
                grades: [key("C0005.MP4"): ClipGrade(profileMark: .notLog)],
                resolver: GradeResolver(defaults: GradeDefaults(), lutRoles: [:])
            )
            let exists: (URL) -> Bool = { onDrive.contains($0.path) || onNAS.contains($0.path) }
            let placed = GradedSyncPlanner.placedRequests(inputs, readsNAS: true, fileExists: exists, detect: { _ in .sLog3SGamut3Cine }, range: { _ in .full })
            XCTAssertEqual(placed.map(\.request.source.lastPathComponent), ["C0001.MP4", "C0002.MP4", "C0003.MP4"])
            XCTAssertEqual(placed.map(\.placement), [.drive, .nas, .nas], "a clip on the drive keeps the drive plan")

            let drive = placed[0].request
            XCTAssertTrue(drive.outputFolder.path.hasPrefix(locations.bufferRoot.path + "/"))
            XCTAssertNotNil(drive.mirrorFolder)
            let nas = placed[1].request
            XCTAssertEqual(nas.source, locations.archiveURL(for: assignments[1], event: event), "read from the NAS copy")
            XCTAssertEqual(nas.outputFolder, GradedRenderNaming.outputFolder(editedRoot: locations.nasEditedRoot(for: event)))
            XCTAssertNil(nas.mirrorFolder, "written at its final name on the NAS")
            XCTAssertNil(nas.stabilization, "no second render step unless one is asked for")
            XCTAssertEqual(placed[1].originalRelativePath, locations.archiveRelativePath(for: assignments[1], event: event))
            XCTAssertEqual(placed[1].eventAssetID, CatalogStore.eventAssetID(assignments[1]))

            let copy = nas.outputFolder.appendingPathComponent("C0002_709.mov")
            XCTAssertEqual(placed[1].gradedRelativePath(forCopyAt: copy, locations: locations), locations.nasRelativePath(copy.path))
            let driveCopy = drive.outputFolder.appendingPathComponent("C0001_709.mov")
            XCTAssertEqual(placed[0].gradedRelativePath(forCopyAt: driveCopy, locations: locations), locations.mirrorRelativePath(forDrivePath: driveCopy.path), "a drive copy is known by the path Sync gives it")

            // Without NAS reading (Sync's plan), only the drive clip.
            XCTAssertEqual(GradedSyncPlanner.requests(inputs, fileExists: exists, detect: { _ in .sLog3SGamut3Cine }, range: { _ in .full }).map(\.source.lastPathComponent), ["C0001.MP4"])
            // Not log by the sidecar: nothing.
            XCTAssertTrue(GradedSyncPlanner.placedRequests(inputs, readsNAS: true, fileExists: exists, detect: { _ in nil }, range: { _ in .full }).isEmpty)
        }
    }

    func testANASCopyIsReadWholeAndRecordedAsVerified() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalog)
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            let folder = GradedRenderNaming.outputFolder(editedRoot: locations.nasEditedRoot(for: event))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("C0002_709.mov")
            try Data(repeating: 7, count: 4_096).write(to: copy)
            let store = try NASSyncStore(catalogURL: catalog)

            let record = try GradedNASRecorder.record(copyAt: copy, eventID: event.id, locations: locations, store: store)
            XCTAssertEqual(record.state, .verified)
            XCTAssertEqual(record.byteCount, 4_096)
            XCTAssertEqual(record.relativePath, locations.nasRelativePath(copy.path))
            XCTAssertEqual(record.sha256, try NASFileIO.sha256(copy.path, uncached: false))
            let stored = NASSyncStore.records(catalogURL: catalog, nasRoot: locations.nasRoot.path, pathKeys: [record.pathKey])
            XCTAssertEqual(stored[record.pathKey]?.state, .verified, "Sync sees it as already on the NAS")

            // A short read fails it, and nothing is recorded for it.
            let other = folder.appendingPathComponent("C0003_709.mov")
            try Data(repeating: 1, count: 10).write(to: other)
            XCTAssertThrowsError(try GradedNASRecorder.record(copyAt: other, eventID: event.id, locations: locations, store: store, hasher: { path, size in
                throw ToolkitError.commandFailed("Short read of \(path): 1 of \(size) bytes.")
            }))
            XCTAssertTrue(NASSyncStore.records(catalogURL: catalog, nasRoot: locations.nasRoot.path, pathKeys: [NASSyncStore.pathKey(locations.nasRelativePath(other.path)!)]).isEmpty)
            // A path outside the NAS root is refused.
            XCTAssertThrowsError(try GradedNASRecorder.record(copyAt: root.appendingPathComponent("x.mov"), eventID: event.id, locations: locations, store: store))
        }
    }

    func testTheRenderWritesAPartialBesideTheCopyAndOnlyRenamesIntoPlace() throws {
        try withTemporaryDirectory { root in
            let output = root.appendingPathComponent("NAS/2026/Beach Day/Edited/Rec709", isDirectory: true)
            let temporary = output.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let partial = temporary.appendingPathComponent(GradedRenderNaming.partialName())
            try Data(repeating: 0, count: 64).write(to: partial)
            // A stopped render's partial is removed; a finished copy is not.
            try Data(repeating: 1, count: 64).write(to: output.appendingPathComponent("C0001_709.mov"))
            XCTAssertEqual(GradedRenderNaming.removeStalePartials(in: output), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path), "the empty temporary folder goes too")
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("C0001_709.mov").path))
            XCTAssertTrue(GradedRenderNaming.isPartialName(partial.lastPathComponent))
            // The rename never replaces a file.
            let next = temporary.appendingPathComponent(GradedRenderNaming.partialName())
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try Data(repeating: 2, count: 64).write(to: next)
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: next.path, to: output.appendingPathComponent("C0001_709.mov").path))
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("C0001_709.mov")), Data(repeating: 1, count: 64))
        }
    }
}

final class GradedCopyStoreTests: XCTestCase {
    func testRecordsRoundTripAndKnowWhetherTheCopyIsOnTheNAS() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let trip = UUID()
            let other = UUID()
            let store = try GradedCopyStore(catalogURL: catalog)
            try store.save([
                GradedCopyRecord(eventID: trip, originalRelativePath: "2026/Trip/Originals/A7V/C0001.MP4", gradedRelativePath: "2026/Trip/Edited/Rec709/C0001_709.mov", sourceKey: "k1"),
                GradedCopyRecord(eventID: trip, originalRelativePath: "2026/Trip/Originals/A7V/C0002.MP4", gradedRelativePath: "2026/Trip/Edited/Rec709/C0002_709.mov", sourceKey: "k2"),
                GradedCopyRecord(eventID: other, originalRelativePath: "2026/Other/Originals/A7V/C0001.MP4", gradedRelativePath: "2026/Other/Edited/Rec709/C0001_709.mov", sourceKey: "k3"),
            ])
            try NASSyncStore(catalogURL: catalog).upsert([NASSyncRecord(
                nasRoot: root.path, relativePath: "2026/Trip/Edited/Rec709/C0001_709.mov", byteCount: 10, sha256: "ab", state: .verified, checkedAt: Date(), verifiedAt: Date()
            )])
            let trips = try store.records(eventIDs: [trip]).sorted { $0.sourceKey < $1.sourceKey }
            XCTAssertEqual(trips.map(\.sourceKey), ["k1", "k2"])
            XCTAssertEqual(trips.map(\.isOnNAS), [true, false], "a copy still on the drive is not waited for")
            XCTAssertEqual(try store.records().count, 3)
            XCTAssertTrue(GradedCopyStore.existingRecords(catalogURL: root.appendingPathComponent("missing.sqlite"), eventIDs: nil).isEmpty)
        }
    }
}

final class ImmichGradedAlbumSwapTests: XCTestCase {
    private let trip = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let serverRoot = "/external/library"
    private let album = ImmichAlbumTarget.existing(id: "album-9", name: "Beach Day")

    private var library: ImmichLibrary { ImmichLibrary(id: "lib", name: "Archive", importPaths: [serverRoot + "/"]) }
    private func asset(_ id: String, _ relative: String, offline: Bool = false) -> ImmichLibraryAsset {
        ImmichLibraryAsset(id: id, originalPath: "\(serverRoot)/\(relative)", isOffline: offline, isTrashed: offline)
    }
    private func record(_ n: Int, onNAS: Bool = true, at: Date = Date(timeIntervalSince1970: 1)) -> GradedCopyRecord {
        GradedCopyRecord(
            eventID: trip,
            originalRelativePath: "2026/T/Originals/A7V/C000\(n).MP4",
            gradedRelativePath: "2026/T/Edited/Rec709/C000\(n)_709.mov",
            sourceKey: "k\(n)", recordedAt: at, isOnNAS: onNAS
        )
    }

    func testAListedCopyTakesItsOriginalsPlaceAndAnUnlistedOneWaits() {
        let files = (1...4).map { ImmichCatalogFile(eventAssetID: "e\($0)", relativePath: "2026/T/Originals/A7V/C000\($0).MP4", isOnNAS: true, album: album, eventID: trip) }
        let assets = [
            asset("o1", "2026/T/Originals/A7V/C0001.MP4"), asset("g1", "2026/T/Edited/Rec709/C0001_709.mov"),
            asset("o2", "2026/T/Originals/A7V/C0002.MP4"),
            asset("o3", "2026/T/Originals/A7V/C0003.MP4"),
            asset("o4", "2026/T/Originals/A7V/C0004.MP4"),
        ]
        var report = ImmichReconciler.reconcile(files: files, assets: assets, library: library, mediaExtensions: [".mp4", ".mov"])
        XCTAssertEqual(Set(report.albumAssets[album] ?? []), ["o1", "o2", "o3", "o4"])

        let swap = ImmichGradedAlbumSwap.prepare(&report, files: files, assets: assets, library: library, records: [
            record(1),
            record(2),                 // on the NAS, not listed yet
            record(3, onNAS: false),   // still on the drive
        ])
        XCTAssertEqual(Set(report.albumAssets[album] ?? []), ["g1", "o2", "o3", "o4"], "the graded copy instead of its original")
        XCTAssertEqual(Set(report.eventAlbumAssets[trip] ?? []), ["g1", "o2", "o3", "o4"])
        XCTAssertEqual(swap.swaps, [ImmichGradedSwap(eventID: trip, album: album, originalAssetID: "o1", gradedAssetID: "g1")])
        XCTAssertEqual(swap.waitingForScan, ["2026/T/Edited/Rec709/C0002_709.mov"])
        XCTAssertEqual(swap.waitingByEvent[trip], 1)
        XCTAssertEqual(swap.notOnNASByEvent[trip], 1)

        var outcome = ImmichLibrarySyncOutcome(report: report)
        outcome.graded = swap
        XCTAssertTrue(outcome.waitsForScan, "the next check looks again for the copy on the NAS")
    }

    func testTheNewestCopyOfAnOriginalSpeaksForIt() {
        let files = [ImmichCatalogFile(eventAssetID: "e1", relativePath: "2026/T/Originals/A7V/C0001.MP4", isOnNAS: true, album: album, eventID: trip)]
        let assets = [asset("o1", "2026/T/Originals/A7V/C0001.MP4"), asset("g1", "2026/T/Edited/Rec709/C0001_709.mov"), asset("g2", "2026/T/Edited/Rec709/C0001_709 (2).mov")]
        var report = ImmichReconciler.reconcile(files: files, assets: assets, library: library, mediaExtensions: [".mp4", ".mov"])
        var newer = record(1, at: Date(timeIntervalSince1970: 2))
        newer.gradedRelativePath = "2026/T/Edited/Rec709/C0001_709 (2).mov"
        let swap = ImmichGradedAlbumSwap.prepare(&report, files: files, assets: assets, library: library, records: [record(1), newer])
        XCTAssertEqual(report.albumAssets[album], ["g2"])
        XCTAssertEqual(swap.swaps.map(\.gradedAssetID), ["g2"])
    }

    func testOnlyOriginalsTheAppAddedLeaveTheAlbumAndOnlyOnce() {
        let swaps = [
            ImmichGradedSwap(eventID: trip, album: album, originalAssetID: "o1", gradedAssetID: "g1"),
            ImmichGradedSwap(eventID: trip, album: album, originalAssetID: "o2", gradedAssetID: "g2"), // added by hand
            ImmichGradedSwap(eventID: trip, album: album, originalAssetID: "o3", gradedAssetID: "g3"), // taken out before
            ImmichGradedSwap(eventID: trip, album: album, originalAssetID: "o4", gradedAssetID: "g4"), // copy not in the album
        ]
        let plan = ImmichGradedAlbumSwap.originalsToRemove(
            swaps: swaps,
            albumIDs: [trip: "album-9"],
            members: ["album-9": ["o1", "g1", "o2", "g2", "o3", "g3", "o4"]],
            appAdded: ["album-9": ["o1", "o3", "o4"]],
            alreadyRemoved: ["album-9": ["o3"]]
        )
        XCTAssertEqual(plan["album-9"]?.map(\.original), ["o1"])
        XCTAssertEqual(plan["album-9"]?.map(\.graded), ["g1"])
    }

    // MARK: Through a check

    private var catalogURL: URL!
    private var logs: URL { catalogURL.deletingLastPathComponent().appendingPathComponent("Immich Logs", isDirectory: true) }

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("immich-graded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        catalogURL = folder.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder) }
    }

    /// One clip of the event in the catalog, its graded copy written down,
    /// and the files the check is given.
    private func prepare() throws -> [ImmichCatalogFile] {
        let folder = catalogURL.deletingLastPathComponent()
        let assignment = PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "C0001.MP4", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: trip)
        let event = SavedCameraEvent(id: trip, name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        var configuration = AppConfiguration.testConfiguration(root: folder, catalog: catalogURL)
        configuration.savedEvents = [event]
        configuration.photoEventAssignments = [assignment]
        _ = try CatalogStore(url: catalogURL).bootstrap(configuration: configuration, createBackup: false)
        try GradedCopyStore(catalogURL: catalogURL).save([record(1)])
        return [ImmichCatalogFile(eventAssetID: CatalogStore.eventAssetID(assignment), relativePath: "2026/T/Originals/A7V/C0001.MP4", isOnNAS: true, album: album, eventID: trip)]
    }

    private func transport(members: [[ImmichLibraryAsset]]) -> SwapTransport {
        let assets = [asset("o1", "2026/T/Originals/A7V/C0001.MP4"), asset("g1", "2026/T/Edited/Rec709/C0001_709.mov")]
        let transport = SwapTransport()
        transport.respond("GET", "/api/libraries/lib", body: Self.encode(library))
        transport.respond("GET", "/api/server/media-types", body: #"{"image":[".jpg"],"video":[".mp4",".mov"],"sidecar":[".xmp"]}"#)
        transport.respond("GET", "/api/users/me", body: #"{"id":"me","email":"user@example.com","name":"Example User","isAdmin":false}"#)
        transport.respond("GET", "/api/albums", body: #"[{"id":"album-9","albumName":"Beach Day"}]"#)
        transport.respond("POST", "/api/search/metadata", bodies: [Self.page(assets)] + members.map(Self.page))
        transport.respond("PUT", "/api/albums/album-9/assets", body: #"[{"id":"g1","success":true}]"#)
        transport.respond("DELETE", "/api/albums/album-9/assets", body: #"[{"id":"o1","success":true}]"#)
        return transport
    }

    private func sync(_ transport: SwapTransport) throws -> ImmichLibrarySync {
        ImmichLibrarySync(
            client: try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport),
            libraryID: "lib", catalogURL: catalogURL, logFolder: logs
        )
    }

    func testACheckAddsTheGradedCopyAndTakesTheAppsOriginalOutOnce() async throws {
        let files = try prepare()
        // The app had put the flat original in the album on an earlier send.
        ImmichChangeLog.append(ImmichAlbumAdditionEntry(albumID: "album-9", albumName: "Beach Day", assetIDs: ["o1"]), to: logs.appendingPathComponent(ImmichGradedAlbumSwap.additionsLogName))
        let original = asset("o1", "2026/T/Originals/A7V/C0001.MP4")
        let graded = asset("g1", "2026/T/Edited/Rec709/C0001_709.mov")
        let first = transport(members: [[original], [original, graded]])

        let outcome = try await sync(first).check(files: files)

        let put = try XCTUnwrap(first.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(try Self.ids(put), ["g1"], "the graded copy goes in; the original is not sent again")
        let delete = try XCTUnwrap(first.requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(delete.url?.path, "/api/albums/album-9/assets", "album membership only")
        XCTAssertEqual(try Self.ids(delete), ["o1"])
        XCTAssertFalse(first.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path.hasPrefix("/api/assets") == true }, "no asset is ever deleted")
        XCTAssertEqual(outcome.graded.removedOriginals, 1)
        XCTAssertEqual(outcome.albumStates[trip]?.inAlbum, 1)
        let removals = try String(contentsOf: logs.appendingPathComponent(ImmichGradedAlbumSwap.removalsLogName), encoding: .utf8)
        XCTAssertTrue(removals.contains(#""assetIDs":["o1"]"#))
        XCTAssertTrue(removals.contains(#""replacedBy":["g1"]"#))

        // Next check: the copy is in, the original stays out, nothing is
        // added back or taken out again.
        let second = transport(members: [[graded], [graded]])
        let again = try await sync(second).check(files: files)
        XCTAssertFalse(second.requests.contains { $0.httpMethod == "PUT" })
        XCTAssertFalse(second.requests.contains { $0.httpMethod == "DELETE" })
        XCTAssertEqual(again.graded.removedOriginals, 0)
    }

    func testAnOriginalAddedByHandStaysInTheAlbum() async throws {
        let files = try prepare()
        let original = asset("o1", "2026/T/Originals/A7V/C0001.MP4")
        let graded = asset("g1", "2026/T/Edited/Rec709/C0001_709.mov")
        let transport = transport(members: [[original], [original, graded]])

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(try Self.ids(try XCTUnwrap(transport.requests.first { $0.httpMethod == "PUT" })), ["g1"])
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "DELETE" }, "the app did not add it, so it stays")
        XCTAssertEqual(outcome.graded.removedOriginals, 0)
    }

    private static func ids(_ request: URLRequest) throws -> [String] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap((try JSONSerialization.jsonObject(with: body) as? [String: [String]])?["ids"])
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func page(_ assets: [ImmichLibraryAsset]) -> String {
        #"{"albums":{"items":[]},"assets":{"items":\#(encode(assets)),"nextPage":null,"total":\#(assets.count),"count":\#(assets.count)}}"#
    }
}

/// Answers by method and path, each scripted body once (the last repeats).
private final class SwapTransport: HTTPTransport, @unchecked Sendable {
    private struct Key: Hashable { var method: String; var path: String }
    private let lock = NSLock()
    private var scripted: [Key: (status: Int, bodies: [String])] = [:]
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func respond(_ method: String, _ path: String, status: Int = 200, body: String) {
        respond(method, path, status: status, bodies: [body])
    }

    func respond(_ method: String, _ path: String, status: Int = 200, bodies: [String]) {
        lock.withLock { scripted[Key(method: method, path: path)] = (status, bodies) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let key = Key(method: request.httpMethod ?? "GET", path: request.url?.path ?? "")
        let answer: (Int, String)? = lock.withLock {
            recorded.append(request)
            guard var entry = scripted[key], !entry.bodies.isEmpty else { return nil }
            let body = entry.bodies.count > 1 ? entry.bodies.removeFirst() : entry.bodies[0]
            scripted[key] = entry
            return (entry.status, body)
        }
        guard let answer else { throw ToolkitError.commandFailed("Unexpected request \(key.method) \(key.path)") }
        return (Data(answer.1.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: nil)!)
    }
}
