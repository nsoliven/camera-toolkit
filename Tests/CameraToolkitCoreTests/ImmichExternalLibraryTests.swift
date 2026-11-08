import XCTest
@testable import CameraToolkitCore

private let libraryID = "11111111-1111-4111-8111-111111111111"
private let root = "/external/library"

private func library(exclusions: [String] = []) -> ImmichLibrary {
    ImmichLibrary(id: libraryID, name: "Archive", importPaths: [root + "/"], exclusionPatterns: exclusions)
}

private func asset(_ id: String, _ relative: String, offline: Bool = false, trashed: Bool = false) -> ImmichLibraryAsset {
    ImmichLibraryAsset(id: id, originalPath: "\(root)/\(relative)", isOffline: offline, isTrashed: trashed || offline)
}

private func file(_ id: String, _ relative: String, onNAS: Bool = true, album: String? = nil) -> ImmichCatalogFile {
    ImmichCatalogFile(eventAssetID: id, relativePath: relative, isOnNAS: onNAS, albumName: album)
}

final class ImmichReconcilerTests: XCTestCase {
    private let media: Set<String> = [".arw", ".jpg", ".mp4"]

    private func statuses(_ report: ImmichReconcileReport) -> [String: String] {
        Dictionary(uniqueKeysWithValues: report.statuses.map { ($0.eventAssetID, $0.status) })
    }

    func testClassifiesEachFileByItsPathUnderTheLibrary() {
        let report = ImmichReconciler.reconcile(
            files: [
                file("in", "2026/Trip/Originals/A/DSC00001.ARW"),
                file("gone", "2026/Trip/Originals/A/DSC00002.ARW"),
                file("waiting", "2026/Trip/Originals/A/DSC00003.ARW"),
                file("sidecar", "2026/Trip/Originals/A/DSC00004.XML"),
                file("private", "2026/Secret/Originals/A/DSC00005.ARW"),
                file("local", "2026/Trip/Originals/A/DSC00006.ARW", onNAS: false)
            ],
            assets: [
                asset("a1", "2026/Trip/Originals/A/DSC00001.ARW"),
                asset("a2", "2026/Trip/Originals/A/DSC00002.ARW", offline: true)
            ],
            library: library(exclusions: ["**/Secret/**"]),
            mediaExtensions: media
        )
        XCTAssertEqual(statuses(report), [
            "in": "present", "gone": "offline", "waiting": "pendingScan",
            "sidecar": "excluded", "private": "excluded", "local": "notOnNAS"
        ])
        XCTAssertTrue(report.pathsLineUp)
    }

    func testPathMatchIgnoresCaseAndUnicodeSpelling() {
        let report = ImmichReconciler.reconcile(
            files: [file("one", "2026/Caf\u{E9}/Originals/A/dsc00001.arw")],
            assets: [asset("a1", "2026/Cafe\u{301}/Originals/A/DSC00001.ARW")],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertEqual(statuses(report), ["one": "present"])
    }

    func testAnOnlineCopySpeaksForADuplicatedPathAndIsCounted() {
        let report = ImmichReconciler.reconcile(
            files: [file("one", "2026/T/a.jpg")],
            assets: [asset("old", "2026/T/a.jpg", offline: true), asset("new", "2026/T/A.JPG")],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertEqual(report.statuses.first?.immichAssetID, "new")
        XCTAssertEqual(report.duplicatedPaths, 1)
    }

    func testAlbumsTakeOnlyOnlineAssetsThatAreNotTrashed() {
        let report = ImmichReconciler.reconcile(
            files: [
                file("in", "2026/T/1.jpg", album: "Trip"),
                file("trashed", "2026/T/2.jpg", album: "Trip"),
                file("offline", "2026/T/3.jpg", album: "Trip"),
                file("noAlbum", "2026/T/4.jpg")
            ],
            assets: [
                asset("a1", "2026/T/1.jpg"),
                asset("a2", "2026/T/2.jpg", trashed: true),
                asset("a3", "2026/T/3.jpg", offline: true),
                asset("a4", "2026/T/4.jpg")
            ],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertEqual(report.albumAssets, ["Trip": ["a1"]])
    }

    func testPathsThatNeverMatchAreReported() {
        let report = ImmichReconciler.reconcile(
            files: [file("one", "2026/T/1.jpg")],
            assets: [asset("a1", "other/place/1.jpg")],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertFalse(report.pathsLineUp)
    }

    func testNewLibraryWithNoAssetsYetStillLinesUp() {
        let report = ImmichReconciler.reconcile(
            files: [file("one", "2026/T/1.jpg")],
            assets: [],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertTrue(report.pathsLineUp)
        XCTAssertEqual(report.count(.pendingScan), 1)
    }

    func testAssetsTheCatalogDoesNotClaimAreCounted() {
        let report = ImmichReconciler.reconcile(
            files: [],
            assets: [asset("a1", "2025/Old/1.jpg"), asset("a2", "2025/Old/2.jpg", offline: true)],
            library: library(),
            mediaExtensions: media
        )
        XCTAssertEqual(report.assetsOutsideCatalog, 2)
        XCTAssertEqual(report.offlineOutsideCatalog, 1)
    }
}

final class ImmichExclusionMatcherTests: XCTestCase {
    func testGlobsMatchTheFullServerPath() {
        let matcher = ImmichExclusionMatcher(patterns: ["**/*.photo-edit", "**/_Trash/**", "/lib/Edited/**", "**/*.{tif,png}"])
        XCTAssertTrue(matcher.isExcluded("/lib/2026/T/a.photo-edit"))
        XCTAssertTrue(matcher.isExcluded("/lib/_Trash/a.jpg"))
        XCTAssertTrue(matcher.isExcluded("/lib/Edited/x/a.jpg"))
        XCTAssertTrue(matcher.isExcluded("/lib/2026/a.png"))
        XCTAssertFalse(matcher.isExcluded("/lib/2026/T/a.jpg"))
        XCTAssertFalse(matcher.isExcluded("/lib/2026/Edited/a.jpg"))
    }

    func testABrokenPatternMatchesNothing() {
        XCTAssertFalse(ImmichExclusionMatcher(patterns: ["{oops"]).isExcluded("/lib/oops"))
    }
}

final class ImmichEventAlbumRuleTests: XCTestCase {
    private func event(policy: ImmichAlbumPolicy, optIn: Bool? = nil, custom: String? = nil) -> SavedCameraEvent {
        SavedCameraEvent(name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000), immichUploadEnabled: optIn, immichAlbumPolicy: policy, immichAlbumName: custom)
    }

    func testNoAlbumByDefault() {
        XCTAssertNil(SavedCameraEvent(name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000)).immichAlbumTitle(isPrivate: false))
    }

    func testEventAndCustomAlbumNames() {
        XCTAssertEqual(event(policy: .event).immichAlbumTitle(isPrivate: false), "Trip 2026")
        XCTAssertEqual(event(policy: .custom, custom: " Best ").immichAlbumTitle(isPrivate: false), "Best")
        XCTAssertEqual(event(policy: .custom, custom: "  ").immichAlbumTitle(isPrivate: false), "Trip 2026")
    }

    func testPrivateEventNeedsItsOwnOptIn() {
        XCTAssertNil(event(policy: .event).immichAlbumTitle(isPrivate: true))
        XCTAssertNil(event(policy: .event, optIn: false).immichAlbumTitle(isPrivate: true))
        XCTAssertEqual(event(policy: .event, optIn: true).immichAlbumTitle(isPrivate: true), "Trip 2026")
    }

    func testSummaryCountsWhatTheStripShows() {
        let summary = ImmichEventSummary(statuses: [
            ImmichCatalogStatus(eventAssetID: "1", status: "present"),
            ImmichCatalogStatus(eventAssetID: "2", status: "present", isTrashed: true),
            ImmichCatalogStatus(eventAssetID: "3", status: "pendingScan"),
            ImmichCatalogStatus(eventAssetID: "4", status: "offline"),
            ImmichCatalogStatus(eventAssetID: "5", status: "excluded"),
            ImmichCatalogStatus(eventAssetID: "6", status: "notOnNAS")
        ])
        XCTAssertEqual(summary.inImmich, 1)
        XCTAssertEqual(summary.outstandingText, "1 waiting for scan · 1 offline · 1 in Immich trash")
        XCTAssertTrue(summary.needsAttention)
    }
}

final class ImmichAlbumCarryOverTests: XCTestCase {
    private func plan(_ moves: [ImmichPathMove], _ assets: [ImmichLibraryAsset]) -> ImmichAlbumCarryOver.Plan {
        ImmichAlbumCarryOver.plan(moves: moves, assets: assets, library: library())
    }

    func testRenamedFilePairsOldAndNewAsset() {
        let result = plan(
            [ImmichPathMove(from: "2026/A/1.jpg", to: "2026/B/1.jpg")],
            [asset("old", "2026/A/1.jpg", offline: true), asset("new", "2026/B/1.jpg")]
        )
        XCTAssertEqual(result.pairs.map(\.oldAssetID), ["old"])
        XCTAssertEqual(result.pairs.map(\.newAssetID), ["new"])
        XCTAssertEqual(result.settledMoveKeys.count, 1)
    }

    func testFolderRenamePairsEveryFileUnderIt() {
        let result = plan(
            [ImmichPathMove(from: "2026/A", to: "2026/B", isFolder: true)],
            [
                asset("o1", "2026/A/x/1.jpg", offline: true), asset("n1", "2026/B/x/1.jpg"),
                asset("o2", "2026/A/2.jpg", offline: true), asset("n2", "2026/B/2.jpg"),
                asset("other", "2026/AB/3.jpg", offline: true)
            ]
        )
        XCTAssertEqual(Set(result.pairs.map(\.newAssetID)), ["n1", "n2"])
        XCTAssertEqual(result.settledMoveKeys.count, 1)
    }

    func testChainOfRenamesEndsAtTheOnlineAsset() {
        let result = plan(
            [ImmichPathMove(from: "2026/A/1.jpg", to: "2026/B/1.jpg"), ImmichPathMove(from: "2026/B/1.jpg", to: "2026/C/1.jpg")],
            [asset("a", "2026/A/1.jpg", offline: true), asset("b", "2026/B/1.jpg", offline: true), asset("c", "2026/C/1.jpg")]
        )
        XCTAssertEqual(Set(result.pairs.map(\.oldAssetID)), ["a", "b"])
        XCTAssertEqual(Set(result.pairs.map(\.newAssetID)), ["c"])
    }

    func testAMoveWaitsUntilImmichHasScanned() {
        let move = ImmichPathMove(from: "2026/A/1.jpg", to: "2026/B/1.jpg")
        // Not scanned yet: the old asset still looks fine.
        var result = plan([move], [asset("old", "2026/A/1.jpg")])
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertTrue(result.settledMoveKeys.isEmpty)
        // Scan half done: old is offline, new is not listed yet.
        result = plan([move], [asset("old", "2026/A/1.jpg", offline: true)])
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertTrue(result.settledMoveKeys.isEmpty)
    }

    func testNothingAtTheOldPathMeansNothingToCarry() {
        let result = plan([ImmichPathMove(from: "2026/A/1.jpg", to: "2026/B/1.jpg")], [asset("new", "2026/B/1.jpg")])
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.settledMoveKeys.count, 1)
    }
}

final class ImmichClientLibraryTests: XCTestCase {
    func testScanIsAPostToTheLibraryWithTheKeyHeader() async throws {
        let transport = ScriptedTransport()
        transport.respond("POST", "/api/libraries/\(libraryID)/scan", status: 204, body: "")
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        try await client.requestLibraryScan(libraryID: libraryID)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret-key")
    }

    func testAssetsArePagedAndIncludeOfflineOnes() async throws {
        let transport = ScriptedTransport()
        transport.respond("POST", "/api/search/metadata", bodies: [
            searchPage([asset("a1", "1.jpg")], nextPage: "2"),
            searchPage([asset("a2", "2.jpg", offline: true)], nextPage: nil)
        ])
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let assets = try await client.libraryAssets(libraryID: libraryID)

        XCTAssertEqual(assets.map(\.id), ["a1", "a2"])
        XCTAssertTrue(assets[1].isOffline)
        let bodies = try transport.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        XCTAssertEqual(bodies.map { $0["page"] as? Int }, [1, 2])
        XCTAssertEqual(bodies.first?["libraryId"] as? String, libraryID)
        XCTAssertEqual(bodies.first?["withDeleted"] as? Bool, true)
    }

    func testAnUnsafeIDNeverReachesAURL() async throws {
        let transport = ScriptedTransport()
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)
        do {
            try await client.requestLibraryScan(libraryID: "../users")
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAFailureNeverCarriesTheKey() async throws {
        let transport = ScriptedTransport()
        transport.respond("POST", "/api/libraries/\(libraryID)/scan", status: 403, body: "")
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)
        do {
            try await client.requestLibraryScan(libraryID: libraryID)
            XCTFail("Expected a failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("secret-key"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
    }
}

final class ImmichLibrarySyncTests: XCTestCase {
    private let trip = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var catalogURL: URL!

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("immich-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        catalogURL = folder.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder) }
    }

    private func configuration(events: [SavedCameraEvent], assignments: [PhotoEventAssignment] = []) -> AppConfiguration {
        let folder = catalogURL.deletingLastPathComponent()
        return AppConfiguration(
            demoRootPath: folder.appendingPathComponent("Demo").path,
            importSourcePath: folder.appendingPathComponent("Card").path,
            archivePath: folder.appendingPathComponent("Library/Originals").path,
            bufferPath: folder.appendingPathComponent("Buffer").path,
            cameraLibraryRootPath: folder.appendingPathComponent("Library").path,
            catalogDatabasePath: catalogURL.path,
            activityLogPath: folder.appendingPathComponent("activity.jsonl").path,
            savedEvents: events,
            selectedEventID: events.first?.id,
            photoEventAssignments: assignments
        )
    }

    /// A catalog holding `count` assignments of the trip, and the catalog
    /// files for them at `2026/T/<n>.jpg` on the NAS.
    private func prepareCatalog(count: Int, album: String? = nil) throws -> [ImmichCatalogFile] {
        let assignments = (1...count).map {
            PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "\($0).jpg", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: trip)
        }
        let event = SavedCameraEvent(id: trip, name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        _ = try CatalogStore(url: catalogURL).bootstrap(configuration: configuration(events: [event], assignments: assignments), createBackup: false)
        return assignments.enumerated().map { index, assignment in
            file(CatalogStore.eventAssetID(assignment), "2026/T/\(index + 1).jpg", album: album)
        }
    }

    private func transport(assets: [ImmichLibraryAsset]) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/libraries/\(libraryID)", body: encode(library()))
        transport.respond("GET", "/api/server/media-types", body: #"{"image":[".jpg"],"video":[".mp4"],"sidecar":[".xmp"]}"#)
        transport.respond("POST", "/api/search/metadata", bodies: [searchPage(assets, nextPage: nil)])
        return transport
    }

    private func sync(_ transport: ScriptedTransport, carries: Bool = false) throws -> ImmichLibrarySync {
        ImmichLibrarySync(
            client: try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport),
            libraryID: libraryID,
            catalogURL: catalogURL,
            carriesAlbumsAcrossRenames: carries
        )
    }

    func testCheckStoresStatusesAndChangesNothingInImmichWithoutAlbums() async throws {
        let files = try prepareCatalog(count: 2)
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.report.count(.present), 1)
        XCTAssertEqual(outcome.report.count(.pendingScan), 1)
        let stored = try CatalogInspector(url: catalogURL).immichStatuses(eventID: trip)
        XCTAssertEqual(stored[files[0].eventAssetID]?.immichAssetID, "a1")
        XCTAssertEqual(stored[files[1].eventAssetID]?.status, "pendingScan")
        XCTAssertEqual(transport.writes.map(\.url?.path), ["/api/search/metadata"], "only the search is a POST")
    }

    func testAFileTheCatalogHasNotWrittenIsSkippedNotFatal() async throws {
        var files = try prepareCatalog(count: 1)
        files.append(file("not-yet-in-catalog", "2026/T/9.jpg"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.report.count(.present), 1)
        XCTAssertEqual(outcome.report.count(.pendingScan), 0)
    }

    func testALibraryThatDoesNotMatchRecordsNothing() async throws {
        let files = try prepareCatalog(count: 1)
        let transport = transport(assets: [ImmichLibraryAsset(id: "a1", originalPath: "\(root)/elsewhere/z.jpg")])

        do {
            _ = try await sync(transport).check(files: files)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not look like"))
        }
        XCTAssertTrue(try CatalogInspector(url: catalogURL).immichStatuses(eventID: trip).isEmpty)
    }

    func testEventAlbumIsCreatedOnceAndFilled() async throws {
        let files = try prepareCatalog(count: 1, album: "Trip 2026")
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("GET", "/api/albums", body: "[]")
        transport.respond("POST", "/api/albums", status: 201, body: #"{"id":"album-1","albumName":"Trip 2026"}"#)
        transport.respond("PUT", "/api/albums/album-1/assets", body: #"[{"id":"a1","success":true}]"#)

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.albumsCreated, 1)
        XCTAssertEqual(outcome.addedToAlbums, 1)
    }

    func testRenameCarriesAlbumsWhenAllowed() async throws {
        let files = try prepareCatalog(count: 1)
        try ImmichPathMoveStore(catalogURL: catalogURL).record([
            NASRename(from: "2026/T/old.jpg", to: "2026/T/1.jpg", byteCount: 10, state: .renamed)
        ])
        let transport = transport(assets: [asset("old", "2026/T/old.jpg", offline: true), asset("new", "2026/T/1.jpg")])
        transport.respond("GET", "/api/albums", body: #"[{"id":"album-1","albumName":"Favorites"}]"#)
        transport.respond("PUT", "/api/albums/album-1/assets", body: #"[{"id":"new","success":true}]"#)

        let outcome = try await sync(transport, carries: true).check(files: files)

        XCTAssertEqual(outcome.carriedOver, 1)
        let lookup = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/albums" })
        XCTAssertEqual(lookup.url?.query, "assetId=old")
        XCTAssertTrue(try ImmichPathMoveStore(catalogURL: catalogURL).moves().isEmpty)
    }

    func testRenameWaitsWhenCarryingIsOff() async throws {
        let files = try prepareCatalog(count: 1)
        try ImmichPathMoveStore(catalogURL: catalogURL).record([
            NASRename(from: "2026/T/old.jpg", to: "2026/T/1.jpg", byteCount: 10, state: .renamed)
        ])
        let transport = transport(assets: [asset("old", "2026/T/old.jpg", offline: true), asset("new", "2026/T/1.jpg")])

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.carriedOver, 0)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
        XCTAssertEqual(try ImmichPathMoveStore(catalogURL: catalogURL).moves().count, 1)
    }

    func testAFailedCarryKeepsTheMoveForNextTime() async throws {
        let files = try prepareCatalog(count: 1)
        try ImmichPathMoveStore(catalogURL: catalogURL).record([
            NASRename(from: "2026/T/old.jpg", to: "2026/T/1.jpg", byteCount: 10, state: .renamed)
        ])
        let transport = transport(assets: [asset("old", "2026/T/old.jpg", offline: true), asset("new", "2026/T/1.jpg")])
        transport.respond("GET", "/api/albums", status: 500, body: "")

        let outcome = try await sync(transport, carries: true).check(files: files)

        XCTAssertEqual(outcome.carriedOver, 0)
        XCTAssertEqual(outcome.problems.count, 1)
        XCTAssertEqual(try ImmichPathMoveStore(catalogURL: catalogURL).moves().count, 1)
    }

    func testMoveStoreKeepsOnlyRealRenamesAndAgesThemOut() throws {
        _ = try prepareCatalog(count: 1)
        let store = try ImmichPathMoveStore(catalogURL: catalogURL)
        let now = Date()
        try store.record([
            NASRename(from: "a", to: "b", byteCount: 1, state: .renamed),
            NASRename(from: "c", to: "d", byteCount: 1, state: .merged),
            NASRename(kind: .folder, from: "e", to: "f", byteCount: 0, state: .renamed),
            NASRename(from: "g", to: "h", byteCount: 1, state: .absent),
            NASRename(from: "i", to: "j", byteCount: 1, state: .differs)
        ], at: now)
        XCTAssertEqual(Set(try store.moves(now: now).map(\.from)), ["a", "c", "e"])
        XCTAssertTrue(try store.moves(now: now.addingTimeInterval(ImmichPathMoveStore.retention + 60)).isEmpty)
    }

    func testBuildSkipsNothingOnTheNASAndWithholdsPrivateAlbums() {
        let shared = SavedCameraEvent(id: trip, name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000), immichAlbumPolicy: .event)
        let secret = SavedCameraEvent(name: "Family Party", eventDate: Date(timeIntervalSince1970: 1_780_000_000), immichAlbumPolicy: .event, storagePolicy: .archiveOnly)
        let locations = EventStorageLocations(configuration: configuration(events: [shared, secret]))
        let assignments = [shared, secret].map {
            PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "DSC00001.ARW", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: $0.id)
        }

        let files = ImmichCatalogFile.build(assignments: assignments, events: [shared, secret], locations: locations, verifiedPathKeys: [])

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].albumName, "Trip 2026")
        XCTAssertNil(files[1].albumName)
        XCTAssertTrue(files.allSatisfy { !$0.relativePath.hasPrefix("/") })
    }
}

private func encode<T: Encodable>(_ value: T) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func searchPage(_ assets: [ImmichLibraryAsset], nextPage: String?) -> String {
    let next = nextPage.map { "\"\($0)\"" } ?? "null"
    return #"{"albums":{"items":[]},"assets":{"items":\#(encode(assets)),"nextPage":\#(next),"total":\#(assets.count),"count":\#(assets.count)}}"#
}

/// Answers by method and path; anything unscripted is a test failure rather
/// than a request to a real server.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private struct Key: Hashable {
        var method: String
        var path: String
    }

    private let lock = NSLock()
    private var scripted: [Key: (status: Int, bodies: [String])] = [:]
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }
    var writes: [URLRequest] { requests.filter { $0.httpMethod != "GET" } }

    func respond(_ method: String, _ path: String, status: Int = 200, body: String = "") {
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
        guard let answer else {
            throw ToolkitError.commandFailed("Unexpected request \(key.method) \(key.path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: nil)!
        return (Data(answer.1.utf8), response)
    }
}
