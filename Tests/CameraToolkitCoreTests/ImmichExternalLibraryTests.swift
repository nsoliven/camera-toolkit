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

private func file(_ id: String, _ relative: String, onNAS: Bool = true, album: ImmichAlbumTarget? = nil, event: UUID? = nil) -> ImmichCatalogFile {
    ImmichCatalogFile(eventAssetID: id, relativePath: relative, isOnNAS: onNAS, album: album, eventID: event)
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
                file("in", "2026/T/1.jpg", album: .named("Trip")),
                file("trashed", "2026/T/2.jpg", album: .named("Trip")),
                file("offline", "2026/T/3.jpg", album: .named("Trip")),
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
        XCTAssertEqual(report.albumAssets, [.named("Trip"): ["a1"]])
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

    func testEveryEventSwitchFillsOnlyTheUntouchedDefault() {
        let untouched = SavedCameraEvent(name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(untouched.immichAlbumTitle(isPrivate: false, albumsForEveryEvent: true), "Trip 2026")
        XCTAssertNil(untouched.immichAlbumTitle(isPrivate: false, albumsForEveryEvent: false))
        XCTAssertNil(event(policy: .none).immichAlbumTitle(isPrivate: false, albumsForEveryEvent: true))
        XCTAssertEqual(event(policy: .custom, custom: "Best").immichAlbumTitle(isPrivate: false, albumsForEveryEvent: true), "Best")
        XCTAssertNil(untouched.immichAlbumTitle(isPrivate: true, albumsForEveryEvent: true))
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
    private func prepareCatalog(count: Int, album: ImmichAlbumTarget? = nil) throws -> [ImmichCatalogFile] {
        let assignments = (1...count).map {
            PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "\($0).jpg", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: trip)
        }
        let event = SavedCameraEvent(id: trip, name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        _ = try CatalogStore(url: catalogURL).bootstrap(configuration: configuration(events: [event], assignments: assignments), createBackup: false)
        return assignments.enumerated().map { index, assignment in
            file(CatalogStore.eventAssetID(assignment), "2026/T/\(index + 1).jpg", album: album, event: trip)
        }
    }

    private func transport(assets: [ImmichLibraryAsset]) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/libraries/\(libraryID)", body: encode(library()))
        transport.respond("GET", "/api/server/media-types", body: #"{"image":[".jpg"],"video":[".mp4"],"sidecar":[".xmp"]}"#)
        transport.respond("POST", "/api/search/metadata", bodies: [searchPage(assets, nextPage: nil)])
        transport.respond("GET", "/api/users/me", body: #"{"id":"me","email":"user@example.com","name":"Example User","isAdmin":false}"#)
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
        let files = try prepareCatalog(count: 1, album: .named("Trip 2026"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("POST", "/api/search/metadata", bodies: [searchPage([asset("a1", "2026/T/1.jpg")], nextPage: nil), searchPage([], nextPage: nil)])
        transport.respond("GET", "/api/albums", body: "[]")
        transport.respond("POST", "/api/albums", status: 201, body: #"{"id":"album-1","albumName":"Trip 2026"}"#)
        transport.respond("PUT", "/api/albums/album-1/assets", body: #"[{"id":"a1","success":true}]"#)

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.albumsCreated, 1)
        XCTAssertEqual(outcome.addedToAlbums, 1)
        XCTAssertEqual(outcome.resolvedAlbums[trip]?.id, "album-1", "the new album is paired by ID from now on")
        XCTAssertEqual(outcome.albumStates[trip]?.inAlbum, 1)
        XCTAssertEqual(try ImmichEventAlbumStore(catalogURL: catalogURL).all()[trip]?.albumName, "Trip 2026")
    }

    func testANamedAlbumNeverTakesOverAnotherEventsPairedAlbum() async throws {
        let files = try prepareCatalog(count: 1, album: .named("Trip 2026"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("POST", "/api/search/metadata", bodies: [searchPage([asset("a1", "2026/T/1.jpg")], nextPage: nil), searchPage([], nextPage: nil)])
        transport.respond("GET", "/api/albums", body: #"[{"id":"taken","albumName":"Trip 2026"}]"#)
        transport.respond("POST", "/api/albums", status: 201, body: #"{"id":"fresh","albumName":"Trip 2026"}"#)
        transport.respond("PUT", "/api/albums/fresh/assets", body: #"[{"id":"a1","success":true}]"#)
        var sync = try sync(transport)
        sync.reservedAlbumIDs = ["taken"]

        let outcome = try await sync.check(files: files)

        XCTAssertEqual(outcome.resolvedAlbums[trip]?.id, "fresh")
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/api/albums/taken/assets" })
    }

    func testWithoutTheKeysUserNoAlbumIsMadeOrFilledByName() async throws {
        let files = try prepareCatalog(count: 1, album: .named("Trip 2026"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("GET", "/api/albums", body: #"[{"id":"x","albumName":"Trip 2026","ownerId":"someone"}]"#)
        transport.respond("GET", "/api/users/me", status: 403, body: "")

        let outcome = try await sync(transport).check(files: files)

        XCTAssertTrue(outcome.problems.contains { $0.contains("user.read") })
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/albums" })
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
    }

    func testEveryAlbumAdditionIsLogged() async throws {
        let files = try prepareCatalog(count: 1, album: .existing(id: "album-9", name: "Trip"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("POST", "/api/search/metadata", bodies: [searchPage([asset("a1", "2026/T/1.jpg")], nextPage: nil), searchPage([], nextPage: nil)])
        transport.respond("GET", "/api/albums", body: #"[{"id":"album-9","albumName":"Trip"}]"#)
        transport.respond("PUT", "/api/albums/album-9/assets", body: #"[{"id":"a1","success":true}]"#)
        var sync = try sync(transport)
        let logs = catalogURL.deletingLastPathComponent().appendingPathComponent("Immich Logs", isDirectory: true)
        sync.logFolder = logs

        _ = try await sync.check(files: files)

        let line = try String(contentsOf: logs.appendingPathComponent("album-additions.jsonl"), encoding: .utf8)
        XCTAssertTrue(line.contains(#""albumID":"album-9""#))
        XCTAssertTrue(line.contains(#""assetIDs":["a1"]"#))
    }

    func testPairedAlbumGetsOnlyWhatIsMissingAndNothingIsRemoved() async throws {
        let files = try prepareCatalog(count: 3, album: .existing(id: "album-9", name: "Old Name"))
        let assets = [asset("a1", "2026/T/1.jpg"), asset("a2", "2026/T/2.jpg"), asset("a3", "2026/T/3.jpg")]
        let transport = transport(assets: assets)
        // Library, then the album's members: a1 is in it, plus a photo from elsewhere.
        transport.respond("POST", "/api/search/metadata", bodies: [
            searchPage(assets, nextPage: nil),
            searchPage([asset("a1", "2026/T/1.jpg"), ImmichLibraryAsset(id: "phone", originalPath: "/upload/x.jpg")], nextPage: nil)
        ])
        transport.respond("GET", "/api/albums", body: #"[{"id":"album-9","albumName":"Renamed In Immich","assetCount":2}]"#)
        transport.respond("PUT", "/api/albums/album-9/assets", body: #"[{"id":"a2","success":true},{"id":"a3","success":true}]"#)

        let outcome = try await sync(transport).check(files: files)

        let put = try XCTUnwrap(transport.requests.first { $0.httpMethod == "PUT" })
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.httpBody)) as? [String: [String]])["ids"]
        XCTAssertEqual(Set(sent ?? []), ["a2", "a3"])
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "DELETE" })
        XCTAssertEqual(outcome.addedToAlbums, 2)
        XCTAssertEqual(outcome.albumStates[trip]?.albumCount, 4)
        XCTAssertEqual(outcome.albumStates[trip]?.inAlbum, 3)
        XCTAssertEqual(outcome.resolvedAlbums[trip]?.name, "Renamed In Immich", "a rename in Immich is picked up")
    }

    func testAPairedAlbumThatIsGoneIsReportedNotRecreated() async throws {
        let files = try prepareCatalog(count: 1, album: .existing(id: "album-9", name: "Gone"))
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg")])
        transport.respond("GET", "/api/albums", body: "[]")

        let outcome = try await sync(transport).check(files: files)

        XCTAssertEqual(outcome.missingAlbumIDs, ["album-9"])
        XCTAssertEqual(outcome.albumsCreated, 0)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" || ($0.httpMethod == "POST" && $0.url?.path == "/api/albums") })
    }

    func testCheckingChosenEventsReadsOnlyTheirFolders() async throws {
        let files = try prepareCatalog(count: 2)
        let transport = transport(assets: [asset("a1", "2026/T/1.jpg"), asset("a2", "2026/T/2.jpg")])

        let outcome = try await sync(transport).check(files: files, events: [trip], fillsAlbums: false)

        XCTAssertEqual(outcome.report.count(.present), 2)
        let search = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/search/metadata" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(search.httpBody)) as? [String: Any])
        XCTAssertEqual(body["originalPath"] as? String, "\(root)/2026/T/")
        XCTAssertEqual(body["libraryId"] as? String, libraryID)
    }

    func testCheckingNoFilesOfTheChosenEventsReadsNothing() async throws {
        let files = try prepareCatalog(count: 1)
        let transport = transport(assets: [])

        let outcome = try await sync(transport).check(files: files, events: [UUID()], fillsAlbums: false)

        XCTAssertEqual(outcome.report.statuses.count + outcome.report.counts.values.reduce(0, +), 0)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/api/search/metadata" })
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

    func testAlbumNamesTellSameNameEventsApartAndLeaveCustomNamesAlone() {
        let first = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        let second = SavedCameraEvent(name: "beach day", eventDate: Date(timeIntervalSince1970: 1_790_000_000))
        let custom = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_795_000_000), immichAlbumPolicy: .custom, immichAlbumName: "Summer")
        let optedOut = SavedCameraEvent(name: "Family Party", eventDate: Date(timeIntervalSince1970: 1_780_000_000), immichAlbumPolicy: ImmichAlbumPolicy.none)
        let secret = SavedCameraEvent(name: "Secret", eventDate: Date(timeIntervalSince1970: 1_780_000_000), storagePolicy: .archiveOnly)
        let child = SavedCameraEvent(name: "Secret Part", eventDate: Date(timeIntervalSince1970: 1_780_000_000), parentEventID: secret.id)
        let events = [first, second, custom, optedOut, secret, child]
        let locations = EventStorageLocations(configuration: configuration(events: events))

        let titles = ImmichAlbumNaming.titles(events: events, locations: locations, albumsForEveryEvent: true)

        XCTAssertEqual(titles[first.id], "Beach Day · \(EventStorageLocations.eventDateString(first.eventDate))")
        XCTAssertEqual(titles[second.id], "beach day · \(EventStorageLocations.eventDateString(second.eventDate))")
        XCTAssertEqual(titles[custom.id], "Summer")
        XCTAssertNil(titles[optedOut.id])
        XCTAssertNil(titles[secret.id])
        XCTAssertNil(titles[child.id], "a subevent of a private event is private too")
        XCTAssertTrue(ImmichAlbumNaming.titles(events: events, locations: locations, albumsForEveryEvent: false).keys.elementsEqual([custom.id]))
    }

    func testBuildGivesUntouchedEventsAnAlbumWhenEveryEventIsOn() {
        let event = SavedCameraEvent(id: trip, name: "Trip 2026", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        let locations = EventStorageLocations(configuration: configuration(events: [event]))
        let assignment = PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "DSC00001.ARW", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: trip)
        let storageOnly = PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "DSC00002.ARW", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: trip, immichUploadOverride: false)

        let files = ImmichCatalogFile.build(assignments: [assignment, storageOnly], events: [event], locations: locations, verifiedPathKeys: [], albumsForEveryEvent: true)

        XCTAssertEqual(files.map(\.album), [.named("Trip 2026"), nil])
        XCTAssertEqual(files.map(\.eventID), [trip, trip])
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
        XCTAssertEqual(files[0].album, .named("Trip 2026"))
        XCTAssertNil(files[1].album)
        XCTAssertTrue(files.allSatisfy { !$0.relativePath.hasPrefix("/") })
    }
}

final class ImmichAlbumPairingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)
    private lazy var locations = EventStorageLocations(configuration: AppConfiguration(
        demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
        bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
        activityLogPath: "/tmp/a.jsonl"
    ))

    /// An album of camera-library `paths` plus `uploads` phone uploads
    /// (outside the library). With neither, one upload, so it is not empty.
    private func album(_ id: String, _ name: String, paths: [String] = [], uploads: Int? = nil, dates: [Date] = []) -> ImmichAlbumContents {
        let uploadCount = uploads ?? (paths.isEmpty ? max(1, dates.count) : 0)
        let all = paths.map { "\(root)/\($0)" } + (0..<uploadCount).map { "/upload/\(id)/IMG_\($0).HEIC" }
        return ImmichAlbumContents(album: ImmichAlbum(id: id, name: name, assetCount: all.count), originalPaths: all, captureDates: dates)
    }

    /// One file per date for `event`, at `<folder>/<n>.jpg`, with that date
    /// as its file time.
    private func datedFiles(_ event: SavedCameraEvent, folder: String, dates: [Date]) -> [ImmichCatalogFile] {
        dates.enumerated().map { index, date in
            ImmichCatalogFile(eventAssetID: "\(event.id)|\(index)", relativePath: "\(folder)/\(index).jpg", isOnNAS: true, eventID: event.id, modifiedAt: date)
        }
    }

    /// `count` dates from `start`, `hours` apart.
    private func days(from start: Date, count: Int, hours: Double = 6) -> [Date] {
        (0..<count).map { start.addingTimeInterval(Double($0) * hours * 3_600) }
    }

    private let dayLength: TimeInterval = 86_400

    /// `count` files of `event` at `<folder>/<n>.jpg`.
    private func files(_ event: SavedCameraEvent, folder: String, count: Int) -> [ImmichCatalogFile] {
        (1...count).map { file("\(event.id)|\($0)", "\(folder)/\($0).jpg", event: event.id) }
    }

    private func pair(_ albums: [ImmichAlbumContents], _ events: [SavedCameraEvent], _ files: [ImmichCatalogFile] = [], currentUserID: String? = nil) -> ImmichPairingResult {
        // Private policy resolves through the events' own list.
        var configuration = AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
        configuration.savedEvents = events
        return ImmichAlbumPairing.pair(albums: albums, events: events, files: files, library: library(), locations: EventStorageLocations(configuration: configuration), currentUserID: currentUserID)
    }

    func testPairsByNameIgnoringCaseAndUnicodeSpelling() {
        let event = SavedCameraEvent(name: "Caf\u{E9} Day", eventDate: date)
        let result = pair([album("x", "cafe\u{301} day")], [event])
        XCTAssertEqual(result.pairs.map(\.eventID), [event.id])
        XCTAssertEqual(result.pairs.first?.basis, .name)
    }

    func testPairsByDatedAlbumTitle() {
        let event = SavedCameraEvent(name: "Beach Day", eventDate: date)
        let result = pair([album("x", ImmichAlbumNaming.datedTitle(for: event))], [event])
        XCTAssertEqual(result.pairs.map(\.eventID), [event.id])
    }

    func testPairsByContentsWhenMostPhotosAreOneEvents() {
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        let other = SavedCameraEvent(name: "Family Party", eventDate: date)
        let paths = (1...8).map { "2026/T/\($0).jpg" } + ["2026/P/1.jpg"]
        let result = pair([album("x", "Favorites", paths: paths)], [trip, other], files(trip, folder: "2026/T", count: 8) + files(other, folder: "2026/P", count: 1))
        XCTAssertEqual(result.pairs.map(\.eventID), [trip.id])
        XCTAssertEqual(result.pairs.first?.basis, .contents)
        XCTAssertEqual(result.pairs.first?.matchedAssets, 8)
    }

    func testTooFewOrTooMixedPhotosDoNotPair() {
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        let other = SavedCameraEvent(name: "Family Party", eventDate: date)
        let allFiles = files(trip, folder: "2026/T", count: 10) + files(other, folder: "2026/P", count: 10)
        let few = album("few", "Few", paths: (1...4).map { "2026/T/\($0).jpg" })
        let mixed = album("mixed", "Mixed", paths: (1...6).map { "2026/T/\($0).jpg" } + (1...4).map { "2026/P/\($0).jpg" })
        let result = pair([few, mixed], [trip, other], allFiles)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.unpaired.first { $0.album.id == "few" }?.reason, .noMatch)
        // Not one event's album, but six of the trip's photos: linked to the
        // trip only (four of the party's are under the link minimum).
        XCTAssertNil(result.unpaired.first { $0.album.id == "mixed" })
        XCTAssertEqual(result.links.map(\.eventID), [trip.id])
        XCTAssertEqual(result.links.first?.basis, .severalEvents)
        XCTAssertEqual(result.links.first?.matchedAssets, 6)

        // Spread thin over many events with too few each, it stays mixed.
        let many = (0..<25).map { SavedCameraEvent(name: "Event \($0)", eventDate: date) }
        let manyFiles = many.enumerated().flatMap { index, event in files(event, folder: "2026/E\(index)", count: 40) }
        let thin = album("thin", "Thin", paths: many.indices.flatMap { index in (1...5).map { "2026/E\(index)/\($0).jpg" } }.prefix(24 * 5 + 4).map { $0 })
        let spread = pair([thin], many, manyFiles)
        XCTAssertTrue(spread.links.allSatisfy { $0.matchedAssets >= ImmichAlbumPairing.linkMinimumAssets })
    }

    func testTwoEventsWithTheAlbumsNameTieUnlessPhotosSettleIt() {
        let first = SavedCameraEvent(name: "Beach Day", eventDate: date)
        let second = SavedCameraEvent(name: "Beach Day", eventDate: date.addingTimeInterval(86_400 * 30))
        XCTAssertEqual(pair([album("x", "Beach Day")], [first, second]).unpaired.first?.reason, .tie)
        let settled = pair([album("x", "Beach Day", paths: (1...5).map { "2026/B/\($0).jpg" })], [first, second], files(second, folder: "2026/B", count: 5))
        XCTAssertEqual(settled.pairs.map(\.eventID), [second.id])
        XCTAssertEqual(settled.pairs.first?.basis, .nameAndContents)
    }

    func testNameAndContentsThatDisagreeDoNotPair() {
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        let other = SavedCameraEvent(name: "Family Party", eventDate: date)
        let result = pair([album("x", "Family Party", paths: (1...5).map { "2026/T/\($0).jpg" })], [trip, other], files(trip, folder: "2026/T", count: 5))
        XCTAssertEqual(result.unpaired.first?.reason, .nameAndContentsDisagree)
    }

    func testAnEventMatchingTwoAlbumsPairsWithNeitherButLinksBoth() {
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        let result = pair([album("a", "Trip 2026", paths: ["2026/T/1.jpg"]), album("b", "trip 2026", paths: ["2026/T/2.jpg"])], [trip])
        XCTAssertTrue(result.pairs.isEmpty, "neither is clearly its own album")
        XCTAssertEqual(Set(result.links.map(\.album.id)), ["a", "b"])
        XCTAssertTrue(result.links.allSatisfy { $0.eventID == trip.id })
        XCTAssertTrue(result.unpaired.isEmpty)
    }

    func testPrivateOptedOutAndAlreadyPairedEventsAreLeftAlone() {
        let secret = SavedCameraEvent(name: "Secret", eventDate: date, storagePolicy: .archiveOnly)
        let allowed = SavedCameraEvent(name: "Allowed", eventDate: date, immichUploadEnabled: true, storagePolicy: .archiveOnly)
        let optedOut = SavedCameraEvent(name: "Family Party", eventDate: date, immichAlbumPolicy: ImmichAlbumPolicy.none)
        var paired = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        paired.pairImmichAlbum(ImmichAlbum(id: "kept", name: "Kept"))
        let one = ["2026/X/1.jpg"]
        let result = pair(
            [album("s", "Secret", paths: one), album("al", "Allowed", paths: one), album("o", "Family Party", paths: one), album("t", "Trip 2026", paths: one), album("kept", "Kept", paths: one)],
            [secret, allowed, optedOut, paired]
        )
        XCTAssertEqual(result.pairs.map(\.eventID), [allowed.id])
        XCTAssertEqual(result.unpaired.first { $0.album.id == "s" }?.reason, .privateEvent)
        XCTAssertEqual(result.privatePairs.map(\.album.id), ["s"], "waits for Allow album and pair")
        XCTAssertEqual(result.privateEventIDs, [secret.id])
        XCTAssertEqual(result.unpaired.first { $0.album.id == "o" }?.reason, .eventOptedOut)
        // A second album for an event that has its own is an "also in" link.
        XCTAssertNil(result.unpaired.first { $0.album.id == "t" })
        XCTAssertEqual(result.links.map(\.album.id), ["t"])
        XCTAssertEqual(result.links.first?.eventID, paired.id)
        XCTAssertEqual(result.alreadyPaired, 1)
    }

    // MARK: F1

    func testSharedAlbumsAreNeverPaired() {
        let event = SavedCameraEvent(name: "Beach Day", eventDate: date)
        var shared = album("x", "Beach Day", paths: ["2026/B/1.jpg"])
        shared.album.ownerID = "friend"
        let result = pair([shared], [event], [], currentUserID: "me")
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.unpaired.first?.reason, .sharedWithYou)
    }

    func testTheAlbumsOwnCountDecidesTheShare() {
        // A big album listing only ten of this event's photos is mostly others.
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        var big = album("x", "Shared Trip", paths: (1...10).map { "2026/T/\($0).jpg" })
        big.album.assetCount = 500
        let result = pair([big], [trip], files(trip, folder: "2026/T", count: 10))
        XCTAssertTrue(result.pairs.isEmpty, "not the trip's own album")
        XCTAssertEqual(result.links.map(\.eventID), [trip.id], "but the trip is in it")
    }

    func testAPicksAlbumIsLinkedButNotFilled() {
        // 20 picks out of a 100-photo event: clearly this event's, but not the whole event.
        let trip = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        let picks = album("picks", "Best of the Trip", paths: (1...20).map { "2026/T/\($0).jpg" })
        let whole = SavedCameraEvent(name: "Beach Day", eventDate: date)
        let eventAlbum = album("whole", "Beach Day", paths: (1...9).map { "2026/B/\($0).jpg" })
        let result = pair([picks, eventAlbum], [trip, whole], files(trip, folder: "2026/T", count: 100) + files(whole, folder: "2026/B", count: 10))
        XCTAssertEqual(result.pairs.first { $0.album.id == "picks" }?.fills, false)
        XCTAssertEqual(result.pairs.first { $0.album.id == "whole" }?.fills, true)

        var linked = trip
        linked.pairImmichAlbum(ImmichAlbum(id: "picks", name: "Best of the Trip"), fills: false)
        XCTAssertNil(ImmichAlbumNaming.targets(events: [linked], locations: locations, albumsForEveryEvent: true)[linked.id], "a picks album is never filled")
        linked.immichAlbumFill = true
        XCTAssertEqual(ImmichAlbumNaming.targets(events: [linked], locations: locations, albumsForEveryEvent: false)[linked.id], .existing(id: "picks", name: "Best of the Trip"))
    }

    // MARK: F2, F6

    func testAPairedSameNameEventMakesTheNewOneDated() {
        var older = SavedCameraEvent(name: "Trip", eventDate: date)
        older.pairImmichAlbum(ImmichAlbum(id: "old-album", name: "Trip"))
        let newer = SavedCameraEvent(name: "Trip", eventDate: date.addingTimeInterval(365 * 86_400), immichAlbumPolicy: .event)
        let targets = ImmichAlbumNaming.targets(events: [older, newer], locations: locations, albumsForEveryEvent: false)
        XCTAssertEqual(targets[older.id], .existing(id: "old-album", name: "Trip"))
        XCTAssertEqual(targets[newer.id], .named(ImmichAlbumNaming.datedTitle(for: newer)))
    }

    func testAnAutomaticAlbumStopsFillingWhenTheSwitchIsOff() {
        var event = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "auto", name: "Trip 2026"), fills: true, automatic: true)
        XCTAssertNotNil(ImmichAlbumNaming.targets(events: [event], locations: locations, albumsForEveryEvent: true)[event.id])
        XCTAssertNil(ImmichAlbumNaming.targets(events: [event], locations: locations, albumsForEveryEvent: false)[event.id])
    }

    // MARK: R3, R4, R5

    func testASharedAlbumIsNeverFilled() {
        var event = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "theirs", name: "Their Trip", ownerID: "friend"), fills: true, shared: true)
        XCTAssertFalse(event.fillsImmichAlbum)
        event.immichAlbumFill = true
        XCTAssertFalse(event.fillsImmichAlbum, "shared wins over the switch")
        XCTAssertNil(ImmichAlbumNaming.targets(events: [event], locations: locations, albumsForEveryEvent: true)[event.id])
    }

    // MARK: Phone albums, several events, private, idempotence

    func testNameWordsIgnoreCaseAccentsDigitsEmojiAndStopWords() {
        XCTAssertEqual(ImmichAlbumPairing.nameWords("24' Island"), ["island"])
        XCTAssertEqual(ImmichAlbumPairing.nameWords("Blue Cliff w Sam and Seaside"), ["blue", "cliff", "sam", "seaside"])
        XCTAssertEqual(ImmichAlbumPairing.nameWords("SEASIDE \u{1F30A}"), ["seaside"])
        XCTAssertEqual(ImmichAlbumPairing.nameWords("Caf\u{E9} Trip 2021!"), ["cafe"])
        XCTAssertEqual(ImmichAlbumPairing.nameWords("Favorites"), [])
    }

    func testAPhoneAlbumPairsByItsDatesAndANameWord() {
        let start = date
        // The album starts the day after the event's photos end: within a day.
        let island = SavedCameraEvent(name: "Island", eventDate: start)
        let coast = SavedCameraEvent(name: "Blue Cliff w Sam and Seaside", eventDate: start.addingTimeInterval(40 * dayLength))
        let other = SavedCameraEvent(name: "Beach Day", eventDate: start.addingTimeInterval(41 * dayLength))
        let eventFiles = datedFiles(island, folder: "2026/I", dates: days(from: start, count: 5))
            + datedFiles(coast, folder: "2026/C", dates: days(from: coast.eventDate, count: 12))
            + datedFiles(other, folder: "2026/B", dates: days(from: other.eventDate, count: 4))
        let islandAlbum = album("ia", "Island 2026", dates: days(from: start.addingTimeInterval(1.25 * dayLength), count: 24))
        let coastAlbum = album("ca", "Seaside \u{1F30A}", dates: days(from: coast.eventDate.addingTimeInterval(dayLength), count: 6))
        let result = pair([islandAlbum, coastAlbum], [island, coast, other], eventFiles)
        XCTAssertTrue(result.pairs.isEmpty, "dates alone never take an event's own album")
        XCTAssertEqual(result.links.first { $0.album.id == "ia" }?.eventID, island.id)
        XCTAssertEqual(result.links.first { $0.album.id == "ia" }?.basis, .dates)
        XCTAssertEqual(result.links.first { $0.album.id == "ia" }?.fills, false, "never filled")
        XCTAssertEqual(result.links.first { $0.album.id == "ca" }?.eventID, coast.id, "the beach day overlaps too, but shares no word")
        XCTAssertNotNil(result.links.first?.dateSpan)
    }

    func testAPhoneAlbumForAnEventWithItsOwnAlbumIsAlsoIn() {
        var island = SavedCameraEvent(name: "Island", eventDate: date)
        island.pairImmichAlbum(ImmichAlbum(id: "own", name: "Island (2026)"))
        let result = pair([album("ph", "Island phone", dates: days(from: date, count: 8))], [island], datedFiles(island, folder: "2026/I", dates: days(from: date, count: 8)))
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.links.map(\.eventID), [island.id])
        XCTAssertEqual(result.links.first?.basis, .dates)
    }

    func testOutliersAreTrimmedFromTheSpan() throws {
        let span = ImmichAlbumPairing.robustSpan(days(from: date, count: 20) + [date.addingTimeInterval(-4 * 365 * dayLength)])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(span).lowerBound, date, "the one import-day photo years earlier drops out")
        XCTAssertNil(ImmichAlbumPairing.robustSpan([]))
        // Exports nine months later do not stretch a three-day shoot.
        let shoot = days(from: date, count: 20, hours: 3.5)
        let exports = (0..<4).map { date.addingTimeInterval(270 * dayLength + Double($0) * 3_600) }
        let robust = try XCTUnwrap(ImmichAlbumPairing.robustSpan(shoot + exports))
        XCTAssertLessThanOrEqual(robust.upperBound.timeIntervalSince(robust.lowerBound), 3 * dayLength)

        let trip = SavedCameraEvent(name: "Lakes", eventDate: date)
        let dates = days(from: date, count: 20) + [date.addingTimeInterval(-4 * 365 * dayLength)]
        let result = pair([album("l", "Lakes 2026", dates: dates)], [trip], datedFiles(trip, folder: "2026/L", dates: days(from: date, count: 10)))
        XCTAssertEqual(result.links.map(\.eventID), [trip.id])
    }

    func testLongSpanSystemAlbumsNeverPair() {
        let trip = SavedCameraEvent(name: "Lakes", eventDate: date)
        let tripFiles = datedFiles(trip, folder: "2026/L", dates: days(from: date, count: 10))
        let years = (0..<40).map { date.addingTimeInterval(Double($0) * 30 * dayLength) }
        let favorites = album("f", "Favorites", dates: years)
        let lakesForever = album("lf", "Lakes Forever", dates: years)
        let recents = album("r", "Recents", dates: days(from: date, count: 10))
        let result = pair([favorites, lakesForever, recents], [trip], tripFiles)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.unpaired.first { $0.album.id == "f" }?.reason, .longSpan(days: 930))
        if case .longSpan? = result.unpaired.first(where: { $0.album.id == "lf" })?.reason {} else { XCTFail("a name word is not enough over years") }
        XCTAssertEqual(result.unpaired.first { $0.album.id == "r" }?.reason, .noDateMatch, "a system word never matches a name")
    }

    func testAnAmbiguousNameIsSettledByDates() {
        let earlier = SavedCameraEvent(name: "Harbor City", eventDate: date)
        let later = SavedCameraEvent(name: "Harbor City", eventDate: date.addingTimeInterval(365 * dayLength))
        let files = datedFiles(earlier, folder: "2026/H1", dates: days(from: earlier.eventDate, count: 8))
            + datedFiles(later, folder: "2027/H2", dates: days(from: later.eventDate, count: 8))
        let result = pair([album("h", "Harbor City", dates: days(from: date.addingTimeInterval(dayLength), count: 5))], [earlier, later], files)
        XCTAssertEqual(result.pairs.map(\.eventID), [earlier.id])
        XCTAssertEqual(result.pairs.first?.basis, .nameAndDates)

        // Without dates it stays a tie, as before.
        XCTAssertEqual(pair([album("h", "Harbor City")], [earlier, later], files).unpaired.first?.reason, .tie)

        // Two events with the word on the same days: left alone.
        let twin = SavedCameraEvent(name: "Harbor Walk", eventDate: date)
        let twinFiles = files + datedFiles(twin, folder: "2026/HW", dates: days(from: date, count: 8))
        let tied = pair([album("p", "Harbor pics", dates: days(from: date.addingTimeInterval(dayLength), count: 5))], [earlier, twin], twinFiles)
        XCTAssertTrue(tied.pairs.isEmpty)
        XCTAssertEqual(tied.unpaired.first?.reason, .datesFitSeveralEvents)
    }

    func testSeveralEventsLinkThresholds() {
        let names = ["A", "B", "C", "D", "E", "F"]
        let events = names.map { SavedCameraEvent(name: "Event \($0)", eventDate: date) }
        let inAlbum = [60, 30, 6, 4, 5, 5]
        let eventSizes = [100, 100, 10, 10, 10, 100]
        var allFiles: [ImmichCatalogFile] = []
        var paths: [String] = []
        for (index, event) in events.enumerated() {
            allFiles += files(event, folder: "2026/\(names[index])", count: eventSizes[index])
            paths += (1...inAlbum[index]).map { "2026/\(names[index])/\($0).jpg" }
        }
        let result = pair([album("u", "Year in Review", paths: paths)], events, allFiles)
        XCTAssertTrue(result.pairs.isEmpty, "no event holds 80% of it")
        // A 55%, B 27%, C 5.5% of the album; D has 4 (< 5); E 4.5% of the album
        // but half its own event; F 4.5% of the album and 5% of its event.
        XCTAssertEqual(Set(result.links.map(\.eventID)), Set([events[0], events[1], events[2], events[4]].map(\.id)))
        XCTAssertTrue(result.links.allSatisfy { $0.basis == .severalEvents && !$0.fills })

        // One event dominates: today's pairing for it, a link for the parent trip.
        let parent = SavedCameraEvent(name: "Trip", eventDate: date)
        var child = SavedCameraEvent(name: "Day One", eventDate: date)
        child.parentEventID = parent.id
        let dominated = album("d", "Highlights", paths: (1...90).map { "2026/T/D/\($0).jpg" } + (1...10).map { "2026/T/\($0).jpg" })
        let both = pair([dominated], [parent, child], files(child, folder: "2026/T/D", count: 100) + files(parent, folder: "2026/T", count: 200))
        XCTAssertEqual(both.pairs.map(\.eventID), [child.id])
        XCTAssertEqual(both.pairs.first?.basis, .contents)
        XCTAssertEqual(both.pairs.first?.fills, true, "90 of the child's 100: kept filled, as before")
        XCTAssertEqual(both.links.map(\.eventID), [parent.id])
    }

    func testPrivateEventsWaitForAllowAlbum() {
        let secret = SavedCameraEvent(name: "Hidden Cove", eventDate: date, storagePolicy: .archiveOnly)
        let allowed = SavedCameraEvent(name: "Open Cove", eventDate: date.addingTimeInterval(60 * dayLength), immichUploadEnabled: true, storagePolicy: .archiveOnly)
        let files = datedFiles(secret, folder: "2026/S", dates: days(from: secret.eventDate, count: 5))
            + datedFiles(allowed, folder: "2026/O", dates: days(from: allowed.eventDate, count: 5))
        let result = pair(
            [album("s", "Cove pics", dates: days(from: secret.eventDate, count: 5)), album("o", "More cove pics", dates: days(from: allowed.eventDate, count: 5))],
            [secret, allowed], files
        )
        XCTAssertEqual(result.links.map(\.eventID), [allowed.id])
        XCTAssertEqual(result.privateLinks.map(\.eventID), [secret.id])
        XCTAssertEqual(result.privateAlbumIDs, ["s"])
        XCTAssertEqual(result.unpaired.map(\.reason), [.privateEvent])
    }

    func testPairingTwiceChangesNothingAndLeavesManualPairingsAlone() {
        let island = SavedCameraEvent(name: "Island", eventDate: date)
        var manual = SavedCameraEvent(name: "Concert", eventDate: date.addingTimeInterval(90 * dayLength))
        manual.pairImmichAlbum(ImmichAlbum(id: "m", name: "My Picks"), fills: false)
        let parent = SavedCameraEvent(name: "Trip", eventDate: date.addingTimeInterval(200 * dayLength))
        let child = SavedCameraEvent(name: "Day One", eventDate: parent.eventDate, parentEventID: parent.id)
        let files = datedFiles(island, folder: "2026/I", dates: days(from: date, count: 6))
            + self.files(parent, folder: "2026/T", count: 50) + self.files(child, folder: "2026/T/D", count: 50)
        let albums = [
            album("ia", "Island phone", dates: days(from: date, count: 6)),
            album("m", "My Picks", paths: (1...10).map { "2026/T/\($0).jpg" }),
            album("x", "Mixed", paths: (1...30).map { "2026/T/\($0).jpg" } + (1...20).map { "2026/T/D/\($0).jpg" })
        ]
        let first = pair(albums, [island, manual, parent, child], files)
        XCTAssertTrue(first.pairs.isEmpty)
        XCTAssertEqual(Set(first.links.map(\.eventID)), [island.id, parent.id, child.id])
        XCTAssertEqual(first.alreadyPaired, 1, "the manual pairing is left alone")

        var events = [island, manual, parent, child]
        for pair in first.pairs {
            if let index = events.firstIndex(where: { $0.id == pair.eventID }) { events[index].pairImmichAlbum(pair.album, fills: pair.fills) }
        }
        var configuration = AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
        configuration.savedEvents = events
        let second = ImmichAlbumPairing.pair(
            albums: albums, events: events, files: files, library: library(),
            locations: EventStorageLocations(configuration: configuration),
            linkedAlbumIDs: Set(first.links.map(\.album.id))
        )
        XCTAssertTrue(second.pairs.isEmpty)
        XCTAssertTrue(second.links.isEmpty)
        XCTAssertTrue(second.unpaired.isEmpty)
        XCTAssertEqual(second.alreadyPaired, 3)
        XCTAssertEqual(events.first { $0.id == manual.id }?.immichAlbumID, "m")
    }

    func testSomeoneElsesAlbumIsNeverPairedOrLinked() {
        let island = SavedCameraEvent(name: "Island", eventDate: date)
        let trip = SavedCameraEvent(name: "Trip", eventDate: date)
        let other = SavedCameraEvent(name: "Other", eventDate: date)
        let files = datedFiles(island, folder: "2026/I", dates: days(from: date, count: 6))
            + self.files(trip, folder: "2026/T", count: 20) + self.files(other, folder: "2026/O", count: 20)
        var phone = album("p", "Island phone", dates: days(from: date, count: 6))
        phone.album.ownerID = "friend"
        var several = album("s", "Shared mix", paths: (1...10).map { "2026/T/\($0).jpg" } + (1...10).map { "2026/O/\($0).jpg" })
        several.album.ownerID = "friend"
        let result = pair([phone, several], [island, trip, other], files, currentUserID: "me")
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.unpaired.map(\.reason), [.sharedWithYou, .sharedWithYou])
    }

    func testAnEmptyAlbumNeverPairs() {
        let event = SavedCameraEvent(name: "Beach Day", eventDate: date)
        let empty = ImmichAlbumContents(album: ImmichAlbum(id: "e", name: "Beach Day", assetCount: 0), originalPaths: [])
        let result = pair([empty], [event])
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.unpaired.first?.reason, .empty)
    }

    func testAlbumAssetsCarryTheirCaptureDates() {
        let local = ImmichLibraryAsset(id: "a", originalPath: "/x", localDateTime: "2026-05-04T10:00:00.000Z", fileCreatedAt: "2026-05-04T17:00:00.000Z")
        XCTAssertEqual(local.captureDate, ImmichLibraryAsset.parseDate("2026-05-04T10:00:00Z"))
        XCTAssertEqual(ImmichLibraryAsset(id: "b", originalPath: "/x", fileCreatedAt: "2026-05-04T17:00:00Z").captureDate, ImmichLibraryAsset.parseDate("2026-05-04T17:00:00.000Z"))
        XCTAssertNil(ImmichLibraryAsset(id: "c", originalPath: "/x").captureDate)
    }

    func testAPhoneAlbumIsNeverFilledEvenWithAllOfASmallEventsPhotos() {
        // Two camera photos of a two-photo event among forty phone photos.
        let pond = SavedCameraEvent(name: "Pond Walk", eventDate: date)
        let phone = album("p", "Pond Walk", paths: ["2026/P/1.jpg", "2026/P/2.jpg"], uploads: 40, dates: days(from: date, count: 42, hours: 1))
        let result = pair([phone], [pond], files(pond, folder: "2026/P", count: 2))
        XCTAssertEqual(result.pairs.map(\.eventID), [pond.id], "its name is the event's")
        XCTAssertEqual(result.pairs.first?.fills, false, "but a phone album is never filled")
    }

    func testAnAlbumTheUserMovedAnEventOffIsNotPairedAgain() {
        // The event was paired with "a", then set to a new album by name.
        var event = SavedCameraEvent(name: "Pond Walk", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "a", name: "Pond Walk"))
        event.useNewImmichAlbumNamedAfterEvent()
        let albums = [album("a", "Pond Walk", dates: days(from: date, count: 5))]
        XCTAssertEqual(pair(albums, [event]).pairs.map(\.album.id), ["a"], "without the record it would pair again")
        var configuration = AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
        configuration.savedEvents = [event]
        let again = ImmichAlbumPairing.pair(albums: albums, events: [event], files: [], library: library(), locations: EventStorageLocations(configuration: configuration), linkedAlbumIDs: ["a"])
        XCTAssertTrue(again.pairs.isEmpty)
        XCTAssertTrue(again.links.isEmpty)
        XCTAssertEqual(again.alreadyPaired, 1)
    }

    func testEventDatesComeFromImmichThenTheCaptureCacheThenFileTimes() {
        // File times run twelve days after the shoot (copied later).
        let shoot = date
        let event = SavedCameraEvent(name: "Pond Walk", eventDate: shoot)
        let late = datedFiles(event, folder: "2026/P", dates: days(from: shoot.addingTimeInterval(12 * dayLength), count: 6))
        let phone = album("ph", "Pond phone", dates: days(from: shoot, count: 6))
        XCTAssertEqual(pair([phone], [event], late).unpaired.first?.reason, .noDateMatch, "file times alone miss it")

        var configuration = AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
        configuration.savedEvents = [event]
        let locations = EventStorageLocations(configuration: configuration)
        let assets = late.enumerated().map { index, file in
            ImmichLibraryAsset(id: "a\(index)", originalPath: "\(root)/\(file.relativePath)", localDateTime: ISO8601DateFormatter().string(from: shoot.addingTimeInterval(Double(index) * 3_600)))
        }
        let assetDates = ImmichAlbumPairing.assetDates(assets: assets, library: library())
        XCTAssertEqual(assetDates.count, 6)
        let byImmich = ImmichAlbumPairing.pair(albums: [phone], events: [event], files: late, library: library(), locations: locations, assetDates: assetDates)
        XCTAssertEqual(byImmich.links.map(\.eventID), [event.id])

        let byCache = ImmichAlbumPairing.pair(
            albums: [phone], events: [event], files: late, library: library(), locations: locations,
            captureDates: Dictionary(uniqueKeysWithValues: late.map { ($0.eventAssetID, shoot) })
        )
        XCTAssertEqual(byCache.links.map(\.eventID), [event.id])
    }

    func testCaptureDatesAreReadFromTheCacheByAssignment() throws {
        let event = SavedCameraEvent(name: "Pond Walk", eventDate: date)
        let assignment = PhotoEventAssignment(sourceRootPath: "/tmp/card", relativePath: "DCIM/DSC00001.ARW", fileSize: 42, modifiedAt: date, eventID: event.id)
        let missing = PhotoEventAssignment(sourceRootPath: "/tmp/card", relativePath: "DCIM/DSC00002.ARW", fileSize: 42, modifiedAt: date, eventID: event.id)
        let cache = CaptureDateCache(url: nil)
        let stamp = CaptureTimestamp(original: "2026:05:04 10:00:00")
        cache.store(path: "/tmp/card/DCIM/DSC00001.ARW", size: 42, modifiedAt: date, timestamp: stamp)
        let dates = ImmichAlbumPairing.captureDates(assignments: [assignment, missing], cache: cache)
        XCTAssertEqual(dates, [CatalogStore.eventAssetID(assignment): try XCTUnwrap(stamp.date)])
    }

    func testTheWholeEventRuleForAPickedAlbum() {
        XCTAssertTrue(SavedCameraEvent.immichAlbumHoldsWholeEvent(matched: 80, eventMediaCount: 100))
        XCTAssertFalse(SavedCameraEvent.immichAlbumHoldsWholeEvent(matched: 79, eventMediaCount: 100))
        XCTAssertFalse(SavedCameraEvent.immichAlbumHoldsWholeEvent(matched: 0, eventMediaCount: 0))
    }

    func testWithoutTheKeysUserNoAlbumWithAnOwnerPairs() {
        let event = SavedCameraEvent(name: "Beach Day", eventDate: date)
        var owned = album("x", "Beach Day")
        owned.album.ownerID = "someone"
        let result = pair([owned], [event], [], currentUserID: nil)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.unpaired.first?.reason, .ownerUnknown)
    }

    func testTheFillSwitchShowsWhetherAnAutomaticAlbumIsFillingNow() {
        var event = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "auto", name: "Trip 2026"), fills: true, automatic: true)
        XCTAssertTrue(event.isFillingImmichAlbum(albumsForEveryEvent: true))
        XCTAssertFalse(event.isFillingImmichAlbum(albumsForEveryEvent: false))
    }

    func testPairingIsByIDAndSurvivesARename() {
        var event = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "album-1", name: "Trip 2026"))
        XCTAssertEqual(event.immichAlbumPolicy, .custom, "a build without pairing still finds the album by name")
        let targets = ImmichAlbumNaming.targets(events: [event], locations: locations, albumsForEveryEvent: false)
        XCTAssertEqual(targets[event.id], .existing(id: "album-1", name: "Trip 2026"))
        event.unpairImmichAlbum()
        XCTAssertNil(ImmichAlbumNaming.targets(events: [event], locations: locations, albumsForEveryEvent: true)[event.id], "unpaired means No album, even with every-event albums on")
    }

    private func sampleConfiguration() -> AppConfiguration {
        AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
    }

    func testEveryEventSwitchIsOffByDefaultAndAnOldStoredValueIsIgnored() throws {
        XCTAssertFalse(sampleConfiguration().immichAlbumsForEveryEvent)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleConfiguration())) as? [String: Any])
        json["immichAlbumsForEveryEvent"] = true
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.immichAlbumsForEveryEvent)
        var on = sampleConfiguration()
        on.immichAlbumsForEveryEvent = true
        XCTAssertTrue(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(on)).immichAlbumsForEveryEvent)
    }

    func testAlbumIDRoundTripsWithTheEvent() throws {
        var event = SavedCameraEvent(name: "Trip 2026", eventDate: date)
        event.pairImmichAlbum(ImmichAlbum(id: "album-1", name: "Trip"))
        let decoded = try JSONDecoder().decode(SavedCameraEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.immichAlbumID, "album-1")
    }

    func testWebLinkPointsAtTheAlbumPage() {
        XCTAssertEqual(ImmichClient.webURL(serverURL: "https://photos.example.com", albumID: "abc-1")?.absoluteString, "https://photos.example.com/albums/abc-1")
        XCTAssertEqual(ImmichClient.webURL(serverURL: "photos.example.com:2283/api/", albumID: "abc-1")?.absoluteString, "http://photos.example.com:2283/albums/abc-1")
        XCTAssertNil(ImmichClient.webURL(serverURL: "https://photos.example.com", albumID: "../x"))
    }

    func testEventFoldersCoverSubeventsInsideTheParent() {
        let folders = ImmichLibrarySync.eventFolders(of: [
            file("1", "2026/2026-01-01 Trip/Originals/A/1.jpg"),
            file("2", "2026/2026-01-01 Trip/Beach/Originals/A/2.jpg"),
            file("3", "2026/2026-02-01 Party/Originals/A/3.jpg")
        ])
        XCTAssertEqual(folders, ["2026/2026-01-01 Trip", "2026/2026-02-01 Party"])
    }
}

final class ImmichStackTests: XCTestCase {
    private let trip = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let party = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private var catalogURL: URL!

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("immich-stacks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        catalogURL = folder.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder) }
    }

    /// A burst of `count` RAW frames, half a second apart, in `folder`.
    private func burst(_ event: UUID, folder: String, first: Int, count: Int, at time: Date) -> [ImmichCatalogFile] {
        (0..<count).map { index in
            let name = String(format: "DSC%05d.ARW", first + index)
            return ImmichCatalogFile(eventAssetID: "\(event)|\(name)", relativePath: "\(folder)/\(name)", isOnNAS: true, eventID: event, byteCount: 1_000 + Int64(index), modifiedAt: time.addingTimeInterval(Double(index) * 0.5))
        }
    }

    private func assets(for files: [ImmichCatalogFile]) -> [ImmichLibraryAsset] {
        files.map { asset("id-" + (($0.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension + "-" + (($0.relativePath as NSString).pathExtension), $0.relativePath) }
    }

    private func id(_ name: String) -> String { "id-" + (name as NSString).deletingPathExtension + "-" + (name as NSString).pathExtension }

    func testBurstIsOneGroupWithItsCoverOnTop() {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 5, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .burst)
        // The board's cover is the middle frame.
        XCTAssertEqual((groups[0].relativePaths[0] as NSString).lastPathComponent, "DSC00003.ARW")
        XCTAssertEqual(Set(groups[0].relativePaths), Set(files.map(\.relativePath)))
    }

    func testNeverAcrossEvents() {
        // Same folder name pattern, back-to-back frames, two events.
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 2, at: start)
            + burst(party, folder: "2026/P/Originals/A", first: 3, count: 2, at: start.addingTimeInterval(1))
        let groups = ImmichStackGrouping.groups(files: files)
        XCTAssertEqual(groups.count, 2)
        for group in groups {
            XCTAssertTrue(group.relativePaths.allSatisfy { $0.hasPrefix(group.eventID == trip ? "2026/T/" : "2026/P/") })
        }
    }

    func testRawAndJpegOfOneShotAreAPair() {
        let files = ["DSC00010.ARW", "DSC00010.JPG"].map {
            ImmichCatalogFile(eventAssetID: $0, relativePath: "2026/T/Originals/A/\($0)", isOnNAS: true, eventID: trip, byteCount: 10, modifiedAt: start)
        }
        let groups = ImmichStackGrouping.groups(files: files)
        XCTAssertEqual(groups.map(\.kind), [.rawPair])
        XCTAssertEqual(groups.first?.relativePaths.count, 2)
    }

    func testAnEditGoesOnTopOfItsOriginal() {
        let original = ImmichCatalogFile(eventAssetID: "o", relativePath: "2026/T/Originals/A/C0001.MP4", isOnNAS: true, eventID: trip, byteCount: 10, modifiedAt: start)
        let groups = ImmichStackGrouping.groups(files: [original], editPaths: ["2026/T/Edited/C0001_709.mp4", "2026/T/Edited/C00012.mp4", "2026/P/Edited/C0001_709.mp4"])
        XCTAssertEqual(groups.map(\.kind), [.edit])
        XCTAssertEqual(groups.first?.relativePaths, ["2026/T/Edited/C0001_709.mp4", "2026/T/Originals/A/C0001.MP4"])
        XCTAssertTrue(ImmichStackGrouping.isEdit("dsc00001-edit", of: "dsc00001"))
        XCTAssertFalse(ImmichStackGrouping.isEdit("dsc000012", of: "dsc00001"))
    }

    func testPlanCreatesCoverFirstAndRerunIsUnchanged() throws {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        var plan = ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [], records: [:])
        XCTAssertEqual(plan.creates.first?.assetIDs.first, id("DSC00002.ARW"))
        let record = ImmichStackRecord(key: groups[0].key, stackID: "s-1", eventID: trip, kind: .burst, assetIDs: plan.creates[0].assetIDs)
        let account = ImmichAccountStack(id: "s-1", primaryAssetID: id("DSC00002.ARW"), assetIDs: plan.creates[0].assetIDs)
        plan = ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [account], records: [record.key: record])
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertEqual(plan.unchanged, 1)
    }

    func testAUserStackWhosePrimaryIsInTheBurstIsNeverTouched() {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let users = ImmichAccountStack(id: "theirs", primaryAssetID: id("DSC00001.ARW"), assetIDs: [id("DSC00001.ARW"), "elsewhere"])
        let plan = ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [users], records: [:])
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertEqual(plan.skipped.first?.reason, .inSomeoneElsesStack(stackID: "theirs"))
    }

    func testANonPrimaryMemberOfAUserStackIsNotStolen() {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let users = ImmichAccountStack(id: "theirs", primaryAssetID: "elsewhere", assetIDs: ["elsewhere", id("DSC00003.ARW")])
        let plan = ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [users], records: [:])
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertEqual(plan.skippedForeign, 1)
    }

    func testARenamedFrameIsAddedBackToTheAppsOwnStack() {
        let before = burst(trip, folder: "2026/Old/Originals/A", first: 1, count: 3, at: start)
        let key = ImmichStackGrouping.groups(files: before)[0].key
        let oldIDs = assets(for: before).map(\.id)
        let record = ImmichStackRecord(key: key, stackID: "ours", eventID: trip, kind: .burst, assetIDs: oldIDs)
        // The folder was renamed: same frames, new paths, new Immich assets.
        let after = burst(trip, folder: "2026/New/Originals/A", first: 1, count: 3, at: start)
        let newAssets = after.map { asset("new-" + ($0.relativePath as NSString).lastPathComponent, $0.relativePath) }
        let groups = ImmichStackGrouping.groups(files: after)
        XCTAssertEqual(groups[0].key, key, "the group keeps its identity across a rename")
        let account = ImmichAccountStack(id: "ours", primaryAssetID: oldIDs[0], assetIDs: oldIDs)
        let plan = ImmichStackPlanner.plan(groups: groups, assets: newAssets, library: library(), accountStacks: [account], records: [key: record])
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertEqual(plan.creates.first?.replacing, ["ours"])
        XCTAssertEqual(plan.creates.first?.assetIDs.first, "new-DSC00002.ARW")
    }

    func testFramesNotInImmichAreReportedNotStacked() {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let plan = ImmichStackPlanner.plan(groups: ImmichStackGrouping.groups(files: files), assets: Array(assets(for: files).prefix(1)), library: library(), accountStacks: [], records: [:])
        XCTAssertEqual(plan.skipped.first?.reason, .notInImmich(found: 1, of: 3))
    }

    func testRunnerCreatesCoverFirstStoresTheStackAndADryRunWritesNothing() async throws {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let store = try ImmichStackStore(catalogURL: catalogURL)
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", body: "[]")
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let dry = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: true)
        XCTAssertEqual(dry.plan.creates.count, 1)
        XCTAssertTrue(transport.writes.isEmpty, "a dry run only reads")

        let cover = id("DSC00002.ARW")
        transport.respond("POST", "/api/stacks", body: #"{"id":"s-9","primaryAssetId":"\#(cover)","assets":[{"id":"\#(cover)"},{"id":"\#(id("DSC00001.ARW"))"},{"id":"\#(id("DSC00003.ARW"))"}]}"#)
        let logged = LockedEntries()
        let real = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false) { logged.add($0) }
        XCTAssertEqual(real.created.map(\.stackID), ["s-9"])
        XCTAssertEqual(logged.all.map(\.stackID), ["s-9"])
        XCTAssertEqual(logged.all.map(\.action), [.created])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.writes.first?.httpBody)) as? [String: [String]])
        XCTAssertEqual(body["assetIds"]?.first, cover)
        XCTAssertEqual(try store.records()[groups[0].key]?.stackID, "s-9")
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "DELETE" })

        // Run again with Immich now holding that stack: nothing is created.
        transport.respond("GET", "/api/stacks", body: #"[{"id":"s-9","primaryAssetId":"\#(cover)","assets":[{"id":"\#(cover)"},{"id":"\#(id("DSC00001.ARW"))"},{"id":"\#(id("DSC00003.ARW"))"}]}]"#)
        let again = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false)
        XCTAssertTrue(again.created.isEmpty)
        XCTAssertEqual(again.plan.unchanged, 1)
        XCTAssertEqual(transport.requests.count { $0.httpMethod == "POST" && $0.url?.path == "/api/stacks" }, 1)
    }

    // MARK: F3, F4, P1

    private func stackJSON(_ id: String, primary: String, _ members: [String]) -> String {
        #"{"id":"\#(id)","primaryAssetId":"\#(primary)","assets":[\#(members.map { #"{"id":"\#($0)"}"# }.joined(separator: ","))]}"#
    }

    func testReplacingTheAppsStackRemovesItFirstSoADepartedMemberIsNotMergedBack() async throws {
        // The app stacked a, b, c; c has since left the burst (moved to another event).
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 2, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let a = id("DSC00001.ARW"), b = id("DSC00002.ARW"), c = "moved-away"
        let store = try ImmichStackStore(catalogURL: catalogURL)
        try store.save(ImmichStackRecord(key: groups[0].key, stackID: "ours", eventID: trip, kind: .burst, assetIDs: [a, b, c]))
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", body: "[\(stackJSON("ours", primary: a, [a, b, c]))]")
        transport.respond("DELETE", "/api/stacks/ours", status: 204, body: "")
        transport.respond("POST", "/api/stacks", body: stackJSON("new", primary: b, [b, a]))
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)
        let logged = LockedEntries()

        let report = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false) { logged.add($0) }

        XCTAssertEqual(transport.writes.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["DELETE /api/stacks/ours", "POST /api/stacks"])
        XCTAssertEqual(report.created.first?.assetIDs.sorted(), [a, b].sorted(), "the record holds what Immich answered")
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(try store.records()[groups[0].key]?.stackID, "new")
        XCTAssertEqual(logged.all.map(\.action), [.removedOwn, .created])
    }

    func testAStackTheUserUnstackedIsNeverMadeAgain() async throws {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let store = try ImmichStackStore(catalogURL: catalogURL)
        try store.save(ImmichStackRecord(key: groups[0].key, stackID: "ours", eventID: trip, kind: .burst, assetIDs: assets(for: files).map(\.id)))
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", body: "[]")
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let first = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false)
        XCTAssertEqual(first.plan.skippedRemoved, 1)
        XCTAssertEqual(try store.records()[groups[0].key]?.removedInImmich, true)
        let second = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false)
        XCTAssertEqual(second.plan.skippedRemoved, 1)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testACoverTheUserPickedIsKept() {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let ids = assets(for: files).map(\.id)
        let record = ImmichStackRecord(key: groups[0].key, stackID: "ours", eventID: trip, kind: .burst, assetIDs: ids)
        let account = ImmichAccountStack(id: "ours", primaryAssetID: id("DSC00003.ARW"), assetIDs: ids)
        let plan = ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [account], records: [record.key: record])
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertTrue(plan.creates.isEmpty)
    }

    func testAStackWhoseCreateAnswerWasLostIsAdoptedNotOrphaned() async throws {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 2, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let ids = assets(for: files).map(\.id)
        let store = try ImmichStackStore(catalogURL: catalogURL)
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", bodies: ["[]", "[\(stackJSON("made", primary: ids[1], ids))]"])
        transport.respond("POST", "/api/stacks", status: 502, body: "")
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)
        let logged = LockedEntries()

        let report = try await ImmichStackRunner.run(client: client, groups: groups, assets: assets(for: files), library: library(), store: store, dryRun: false) { logged.add($0) }

        XCTAssertEqual(report.created.map(\.stackID), ["made"])
        XCTAssertEqual(try store.records()[groups[0].key]?.stackID, "made")
        XCTAssertEqual(logged.all.map(\.action), [.adopted])
    }

    // MARK: R2, R5

    func testWhenTheFirstFrameLeavesNoStackEverCrossesEvents() async throws {
        // The app stacked a, b, c for the trip; a was then moved to the party,
        // whose burst is now a, d.
        let (a, b, c, d) = ("a", "b", "c", "d")
        let tripGroup = ImmichStackGroup(key: "trip-burst", eventID: trip, kind: .burst, relativePaths: ["2026/T/b.arw", "2026/T/c.arw"])
        let partyGroup = ImmichStackGroup(key: "party-burst", eventID: party, kind: .burst, relativePaths: ["2026/P/a.arw", "2026/P/d.arw"])
        let assets = [asset(a, "2026/P/a.arw"), asset(b, "2026/T/b.arw"), asset(c, "2026/T/c.arw"), asset(d, "2026/P/d.arw")]
        let store = try ImmichStackStore(catalogURL: catalogURL)
        try store.save(ImmichStackRecord(key: "trip-burst", stackID: "ours", eventID: trip, kind: .burst, assetIDs: [a, b, c]))
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", body: "[\(stackJSON("ours", primary: a, [a, b, c]))]")
        transport.respond("DELETE", "/api/stacks/ours", status: 204, body: "")
        transport.respond("POST", "/api/stacks", bodies: [stackJSON("party-new", primary: a, [a, d]), stackJSON("trip-new", primary: b, [b, c])])
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let report = try await ImmichStackRunner.run(client: client, groups: [partyGroup, tripGroup], assets: assets, library: library(), store: store, dryRun: false)

        let calls = transport.writes.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(calls.first, "DELETE /api/stacks/ours", "the trip's stack goes before a joins the party's")
        XCTAssertEqual(calls.filter { $0.hasPrefix("DELETE") }.count, 1)
        for post in transport.writes where post.httpMethod == "POST" {
            let ids = Set((try JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: [String]])?["assetIds"] ?? [])
            XCTAssertTrue(ids.isSubset(of: [a, d]) || ids.isSubset(of: [b, c]), "one event per stack: \(ids)")
        }
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        let records = try store.records()
        XCTAssertEqual(records["trip-burst"]?.stackID, "trip-new")
        XCTAssertEqual(records["party-burst"]?.stackID, "party-new")
        XCTAssertNil(records["trip-burst"]?.removedInImmich)
    }

    func testAStackTheAppRemovedItselfIsForgottenNotTombstoned() async throws {
        // Another group's app stack holds d, which now belongs to this group.
        let group = ImmichStackGroup(key: "g1", eventID: trip, kind: .burst, relativePaths: ["2026/T/c.arw", "2026/T/d.arw"])
        let assets = [asset("c", "2026/T/c.arw"), asset("d", "2026/T/d.arw")]
        let store = try ImmichStackStore(catalogURL: catalogURL)
        try store.save(ImmichStackRecord(key: "g2", stackID: "s2", eventID: trip, kind: .burst, assetIDs: ["d", "e"]))
        let transport = ScriptedTransport()
        transport.respond("GET", "/api/stacks", body: "[\(stackJSON("s2", primary: "d", ["d", "e"]))]")
        transport.respond("DELETE", "/api/stacks/s2", status: 204, body: "")
        transport.respond("POST", "/api/stacks", body: stackJSON("s1", primary: "c", ["c", "d"]))
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        _ = try await ImmichStackRunner.run(client: client, groups: [group], assets: assets, library: library(), store: store, dryRun: false)

        let records = try store.records()
        XCTAssertEqual(records["g1"]?.stackID, "s1")
        XCTAssertNil(records["g2"], "removed by the app, so made fresh next time rather than tombstoned")
    }

    func testStackingAgainClearsTheTombstone() throws {
        let files = burst(trip, folder: "2026/T/Originals/A", first: 1, count: 3, at: start)
        let groups = ImmichStackGrouping.groups(files: files)
        let store = try ImmichStackStore(catalogURL: catalogURL)
        try store.save(ImmichStackRecord(key: groups[0].key, stackID: "gone", eventID: trip, kind: .burst, assetIDs: [], removedInImmich: true))
        XCTAssertEqual(ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [], records: try store.records()).skippedRemoved, 1)
        try store.remove(keys: [groups[0].key])
        XCTAssertEqual(ImmichStackPlanner.plan(groups: groups, assets: assets(for: files), library: library(), accountStacks: [], records: try store.records()).creates.count, 1)
    }

    // MARK: P5, P6

    func testEditsNeverCrossBetweenAParentAndItsSubevent() {
        let parent = ImmichCatalogFile(eventAssetID: "p", relativePath: "2026/Trip/Originals/A/C0001.MP4", isOnNAS: true, eventID: trip, byteCount: 10, modifiedAt: start)
        let sub = ImmichCatalogFile(eventAssetID: "s", relativePath: "2026/Trip/Beach/Originals/A/C0002.MP4", isOnNAS: true, eventID: party, byteCount: 10, modifiedAt: start)
        let groups = ImmichStackGrouping.groups(files: [parent, sub], editPaths: [
            "2026/Trip/Edited/C0002_709.mp4",
            "2026/Trip/Beach/Edited/C0001_709.mp4"
        ])
        XCTAssertTrue(groups.isEmpty, "each edit sits in the other event's folder")
        let own = ImmichStackGrouping.groups(files: [parent, sub], editPaths: ["2026/Trip/Beach/Edited/C0002_709.mp4"])
        XCTAssertEqual(own.map(\.eventID), [party])
    }

    func testPrivateEventsAreStackedOnlyWithAllowAlbum() {
        let open = SavedCameraEvent(name: "Trip 2026", eventDate: start)
        let secret = SavedCameraEvent(name: "Secret", eventDate: start, storagePolicy: .archiveOnly)
        let allowed = SavedCameraEvent(name: "Allowed", eventDate: start, immichUploadEnabled: true, storagePolicy: .archiveOnly)
        var configuration = AppConfiguration(
            demoRootPath: "/tmp/demo", importSourcePath: "/tmp/card", archivePath: "/tmp/lib/Originals",
            bufferPath: "/tmp/buffer", cameraLibraryRootPath: "/tmp/lib", catalogDatabasePath: "/tmp/c.sqlite",
            activityLogPath: "/tmp/a.jsonl"
        )
        configuration.savedEvents = [open, secret, allowed]
        let ids = ImmichStackGrouping.stackableEventIDs(events: [open, secret, allowed], locations: EventStorageLocations(configuration: configuration))
        XCTAssertEqual(ids, [open.id, allowed.id])
    }

    func testCommandParsesAndPicksTheOnlyLibraryOrRefuses() throws {
        let parsed = try ImmichStacksCommand.parse(["CameraToolkit", "--immich-stacks", "--dry-run", "--event", "Beach Day"])
        XCTAssertTrue(parsed.dryRun)
        XCTAssertEqual(parsed.eventNames, ["Beach Day"])
        XCTAssertThrowsError(try ImmichStacksCommand.parse(["x", "--immich-stacks", "--bogus"]))
        let one = ImmichLibrary(id: "a", name: "A", importPaths: ["/a"])
        let two = ImmichLibrary(id: "b", name: "B", importPaths: ["/b"])
        XCTAssertEqual(try ImmichStacksCommand.library(chosenID: "", libraries: [one]).id, "a")
        XCTAssertEqual(try ImmichStacksCommand.library(chosenID: "b", libraries: [one, two]).id, "b")
        XCTAssertThrowsError(try ImmichStacksCommand.library(chosenID: "", libraries: [one, two]))
        XCTAssertThrowsError(try ImmichStacksCommand.library(chosenID: "gone", libraries: [one]))
    }

    func testPairCommandIsADryRunAndCountsReasons() throws {
        XCTAssertTrue(try ImmichPairCommand.parse(["x", "--immich-pair", "--dry-run", "--list"]).list)
        XCTAssertThrowsError(try ImmichPairCommand.parse(["x", "--immich-pair"]), "pairing for real happens in the app")
        let event = SavedCameraEvent(name: "Beach Day", eventDate: start)
        var result = ImmichPairingResult()
        result.pairs = [ImmichAlbumPair(album: ImmichAlbum(id: "a", name: "Beach Day"), eventID: event.id, basis: .name, matchedAssets: 0)]
        result.unpaired = [
            ImmichUnpairedAlbum(album: ImmichAlbum(id: "b", name: "Screenshots"), reason: .noMatch),
            ImmichUnpairedAlbum(album: ImmichAlbum(id: "c", name: "Favorites"), reason: .mixed(topShare: 0.4)),
            ImmichUnpairedAlbum(album: ImmichAlbum(id: "d", name: "Mixed Again"), reason: .mixed(topShare: 0.6))
        ]
        let counts = ImmichPairCommand.summaryText(result, albums: 4, events: [event], list: false)
        XCTAssertTrue(counts.contains("Would pair: 1 (by name 1"))
        XCTAssertTrue(counts.contains("Photos from several events: 2"))
        XCTAssertFalse(counts.contains("Screenshots"), "names only with --list")
        XCTAssertTrue(ImmichPairCommand.summaryText(result, albums: 4, events: [event], list: true).contains("pair  Beach Day  ↔  Beach Day"))

        let a = SavedCameraEvent(name: "Trip A", eventDate: start)
        let b = SavedCameraEvent(name: "Trip B", eventDate: start)
        let secret = SavedCameraEvent(name: "Family Party", eventDate: start)
        var more = ImmichPairingResult()
        more.links = [
            ImmichAlbumPair(album: ImmichAlbum(id: "p", name: "Island phone"), eventID: a.id, basis: .dates, matchedAssets: 0, dateSpan: start...start.addingTimeInterval(86_400)),
            ImmichAlbumPair(album: ImmichAlbum(id: "u", name: "Year in Review"), eventID: a.id, basis: .severalEvents, matchedAssets: 40),
            ImmichAlbumPair(album: ImmichAlbum(id: "u", name: "Year in Review"), eventID: b.id, basis: .severalEvents, matchedAssets: 30)
        ]
        more.privatePairs = [ImmichAlbumPair(album: ImmichAlbum(id: "s", name: "Party"), eventID: secret.id, basis: .name, matchedAssets: 0)]
        more.unpaired = [ImmichUnpairedAlbum(album: ImmichAlbum(id: "s", name: "Party"), eventID: secret.id, reason: .privateEvent)]
        let listed = ImmichPairCommand.summaryText(more, albums: 3, events: [a, b, secret], list: true)
        XCTAssertTrue(listed.contains("link (dates: Trip A)  Island phone  [dates, photos"))
        XCTAssertTrue(listed.contains("link (several events: Trip A, Trip B)  Year in Review  [40 / 30]"))
        XCTAssertTrue(listed.contains("Would link as also in: 3 link(s) on 2 album(s)"))
        XCTAssertTrue(listed.contains("Albums of private events: 1"))
        XCTAssertTrue(listed.contains("private  Party  ↔  Family Party"))
        XCTAssertTrue(listed.contains("skip  Party"), "still listed as before")
    }

    func testWebLinksForAnAssetAFolderAndHome() {
        XCTAssertEqual(ImmichClient.webURL(serverURL: "https://photos.example.com", assetID: "a-1")?.absoluteString, "https://photos.example.com/photos/a-1")
        XCTAssertEqual(ImmichClient.webURL(serverURL: "https://photos.example.com")?.absoluteString, "https://photos.example.com/")
        let folder = ImmichClient.webURL(serverURL: "https://photos.example.com", folder: "/external/library/2026/Trip 2026")
        XCTAssertEqual(folder?.path, "/folders")
        XCTAssertEqual(URLComponents(url: folder!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "path", value: "/external/library/2026/Trip 2026")])
    }
}

/// Stack log entries collected from a `@Sendable` callback.
private final class LockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ImmichStackLogEntry] = []
    var all: [ImmichStackLogEntry] { lock.withLock { entries } }
    func add(_ entry: ImmichStackLogEntry) { lock.withLock { entries.append(entry) } }
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
