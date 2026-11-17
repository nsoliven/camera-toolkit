@testable import CameraToolkitApp
import CameraToolkitCore
import XCTest

/// View in Immich always opens the event's folder; Show Album lists the
/// event's own album first, then the albums it is also in; and links saved
/// in the catalog reach the model.
@MainActor
final class ImmichAlbumLinkModelTests: XCTestCase {
    private let server = "https://photos.example.com"
    private let mainID = "aaaaaaaa-0000-4000-8000-000000000001"
    private let linkA = "aaaaaaaa-0000-4000-8000-000000000002"
    private let linkB = "aaaaaaaa-0000-4000-8000-000000000003"

    private func makeModel(root: URL) -> (DashboardModel, SavedCameraEvent) {
        var configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Demo").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Buffer").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
        configuration.immichServerURL = server
        configuration.immichLibraryID = "11111111-1111-4111-8111-111111111111"
        var event = SavedCameraEvent(name: "Trip A", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
        event.pairImmichAlbum(ImmichAlbum(id: mainID, name: "Trip A"), fills: false)
        configuration.savedEvents = [event]
        let model = DashboardModel(jobs: [], configuration: configuration, configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")))
        model.immichLibrary = ImmichLibrary(id: configuration.immichLibraryID, name: "Archive", importPaths: ["/external/library/"])
        return (model, event)
    }

    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-immich-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testViewInImmichOpensTheFolderEvenWhenAnAlbumIsPaired() throws {
        try withTemporaryFolder { root in
            let (model, event) = makeModel(root: root)
            let url = try XCTUnwrap(model.immichWebURL(for: event))
            XCTAssertEqual(url.path, "/folders")
            let folder = EventStorageLocations(configuration: model.configuration).nasEventFolderRelativePath(for: event)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, "/external/library/\(folder)")
        }
        XCTAssertEqual(DashboardModel.immichFolderURL(server: server, importRoot: nil, eventFolder: "2026/Trip A")?.absoluteString, "https://photos.example.com/", "no library folder yet: the home page")
        XCTAssertNil(DashboardModel.immichFolderURL(server: " ", importRoot: "/x", eventFolder: "y"))
    }

    func testShowAlbumListsTheOwnAlbumFirstThenAlsoIn() throws {
        try withTemporaryFolder { root in
            let (model, event) = makeModel(root: root)
            XCTAssertEqual(model.immichAlbumChoices(for: event).map(\.albumID), [mainID])

            model.immichAlbumLinks[event.id] = [
                ImmichEventAlbumLink(eventID: event.id, albumID: linkB, albumName: "Year in Review", basis: "severalEvents"),
                ImmichEventAlbumLink(eventID: event.id, albumID: linkA, albumName: "Beach 2021", basis: "dates"),
                ImmichEventAlbumLink(eventID: event.id, albumID: mainID, albumName: "Trip A", basis: "dates")
            ]
            model.immichAlbums = [ImmichAlbum(id: linkB, name: "Year in Review (renamed)")]
            let choices = model.immichAlbumChoices(for: event)
            XCTAssertEqual(choices.map(\.albumID), [mainID, linkA, linkB], "own album first, the rest by name, no duplicate")
            XCTAssertEqual(choices.map(\.isMain), [true, false, false])
            XCTAssertEqual(choices.last?.name, "Year in Review (renamed)", "the album's current name")
            XCTAssertEqual(choices.first?.url.absoluteString, "https://photos.example.com/albums/\(mainID)")

            var bare = event
            bare.unpairImmichAlbum()
            model.immichAlbumLinks = [:]
            XCTAssertTrue(model.immichAlbumChoices(for: bare).isEmpty, "Show Album is hidden without an album")
        }
        XCTAssertTrue(DashboardModel.immichAlbumChoices(server: "", main: (mainID, "Trip A"), links: []).isEmpty, "no server, no album links")
    }

    func testLinksSavedInTheCatalogReachTheModel() throws {
        try withTemporaryFolder { root in
            let (model, event) = makeModel(root: root)
            let store = try ImmichEventAlbumStore(catalogURL: model.catalogURLForImmich)
            try store.addLinks([ImmichEventAlbumLink(eventID: event.id, albumID: linkA, albumName: "Beach 2021", basis: "dates")])
            model.loadImmichAlbumStates()
            let deadline = Date().addingTimeInterval(5)
            while model.immichAlbumLinks.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertEqual(model.immichAlbumLinks[event.id]?.map(\.albumID), [linkA])
            XCTAssertEqual(model.immichLinkRows.map(\.albumName), ["Beach 2021"])
            XCTAssertEqual(model.immichLinkRows.first?.basis, "dates")

            model.removeImmichAlbumLink(eventID: event.id, albumID: linkA)
            XCTAssertNil(model.immichAlbumLinks[event.id])
            let gone = Date().addingTimeInterval(5)
            while !ImmichEventAlbumStore.existingLinks(catalogURL: model.catalogURLForImmich).isEmpty, Date() < gone {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(ImmichEventAlbumStore.existingLinks(catalogURL: model.catalogURLForImmich).isEmpty)
            XCTAssertEqual(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: model.catalogURLForImmich), [linkA], "removed for good")
        }
    }

    func testAllowAlbumAndPairTurnsOnExactlyThosePrivateEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-immich-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = makeModel(root: root)
        let secret = SavedCameraEvent(name: "Family Party", eventDate: Date(timeIntervalSince1970: 1_780_000_000), storagePolicy: .archiveOnly)
        let other = SavedCameraEvent(name: "Other Party", eventDate: Date(timeIntervalSince1970: 1_780_000_000), storagePolicy: .archiveOnly)
        model.updateConfiguration { $0.savedEvents += [secret, other] }
        var result = ImmichPairingResult()
        result.privatePairs = [ImmichAlbumPair(album: ImmichAlbum(id: linkA, name: "Party"), eventID: secret.id, basis: .name, matchedAssets: 0)]
        result.privateLinks = [ImmichAlbumPair(album: ImmichAlbum(id: linkB, name: "Year in Review"), eventID: secret.id, basis: .severalEvents, matchedAssets: 8)]
        result.unpaired = [ImmichUnpairedAlbum(album: ImmichAlbum(id: linkA, name: "Party"), eventID: secret.id, reason: .privateEvent)]
        model.immichPairing = result
        XCTAssertEqual(model.immichPrivateAlbumCount, 2)
        XCTAssertEqual(model.immichPrivateEventNames, ["Family Party"])

        await model.allowAlbumAndPairPrivateEvents()?.value
        let saved = try XCTUnwrap(model.configuration.savedEvents.first { $0.id == secret.id })
        XCTAssertTrue(saved.sendsToImmich)
        XCTAssertEqual(saved.immichAlbumID, linkA)
        XCTAssertFalse(model.configuration.savedEvents.first { $0.id == other.id }?.sendsToImmich ?? true, "only the events with albums")
        XCTAssertEqual(model.immichPrivateAlbumCount, 0)
        XCTAssertTrue(model.immichPairing?.unpaired.isEmpty ?? false)
        XCTAssertEqual(model.immichAlbumLinks[secret.id]?.map(\.albumID), [linkB])
        XCTAssertEqual(ImmichEventAlbumStore.existingLinks(catalogURL: model.catalogURLForImmich).map(\.albumID), [linkB], "in the catalog when the task ends")
    }

    func testLinkedAlbumsAreNotReservedAgainstFindingByName() throws {
        try withTemporaryFolder { root in
            let (model, event) = makeModel(root: root)
            model.immichAlbumLinks[event.id] = [ImmichEventAlbumLink(eventID: event.id, albumID: linkA, albumName: "Beach 2021", basis: "dates")]
            // Only events' own albums are reserved, so a by-name album that is
            // also someone's link is found, not made again as a duplicate.
            XCTAssertEqual(model.immichReservedAlbumIDs, [mainID])
        }
    }

    func testANewAlbumByNameForgetsTheOldAlbumsStateAndIsNotRepaired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-immich-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, event) = makeModel(root: root)
        let store = try ImmichEventAlbumStore(catalogURL: model.catalogURLForImmich)
        try store.save([event.id: ImmichEventAlbumState(albumID: mainID, albumName: "Trip A", albumCount: 10, inAlbum: 10)])

        await model.useNewImmichAlbum(for: event.id).value
        XCTAssertNil(try store.all()[event.id], "Show Album no longer offers the old album")
        let updated = try XCTUnwrap(model.configuration.savedEvents.first { $0.id == event.id })
        XCTAssertTrue(model.immichAlbumChoices(for: updated).isEmpty)
        XCTAssertTrue(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: model.catalogURLForImmich).contains(mainID), "Pair Albums leaves it alone")
        XCTAssertTrue(ImmichEventAlbumStore.existingLinks(catalogURL: model.catalogURLForImmich).isEmpty, "a record, not a link")
    }

    func testMovingAnEventOffAnAlbumIsRecorded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-immich-pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, event) = makeModel(root: root)
        model.immichCurrentUserID = "me"
        await model.forgetImmichAlbum(mainID, name: "Trip A", for: event.id).value
        XCTAssertEqual(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: model.catalogURLForImmich), [mainID])
    }

    func testAFailedUnlinkSaysSoAndKeepsTheLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-immich-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, event) = makeModel(root: root)
        // The catalog's folder is a file, so nothing can be written there.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        model.updateConfiguration { $0.catalogDatabasePath = blocker.appendingPathComponent("catalog.sqlite").path }
        let link = ImmichEventAlbumLink(eventID: event.id, albumID: linkA, albumName: "Beach 2021", basis: "dates")
        model.immichAlbumLinks[event.id] = [link]

        await model.removeImmichAlbumLink(eventID: event.id, albumID: linkA).value
        XCTAssertTrue(model.statusMessage.hasPrefix("Could not remove the link to “Beach 2021”"), model.statusMessage)
        XCTAssertEqual(model.immichAlbumLinks[event.id], [link], "shown again, since it was not removed")
    }

    func testPairingSummarySaysWhatWasLinked() {
        var result = ImmichPairingResult()
        result.pairs = [ImmichAlbumPair(album: ImmichAlbum(id: "p", name: "Beach 2021"), eventID: UUID(), basis: .dates, matchedAssets: 0)]
        let a = UUID()
        let b = UUID()
        result.links = [
            ImmichAlbumPair(album: ImmichAlbum(id: "u", name: "Year in Review"), eventID: a, basis: .severalEvents, matchedAssets: 40),
            ImmichAlbumPair(album: ImmichAlbum(id: "u", name: "Year in Review"), eventID: b, basis: .severalEvents, matchedAssets: 30)
        ]
        XCTAssertEqual(
            DashboardModel.immichPairingSummary(result, picks: 1),
            "Paired 1 album (1 picks, linked only); linked 1 more as also in (2 event links); 0 not paired. Nothing was changed in Immich."
        )
    }
}
