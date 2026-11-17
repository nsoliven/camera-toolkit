import GRDB
import XCTest
@testable import CameraToolkitCore

/// The "also in" links table: added beside the older one-album-per-event
/// table without touching its rows, and read without writing anything.
final class ImmichAlbumLinkStoreTests: XCTestCase {
    private func temporaryCatalog() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ct-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("catalog.sqlite")
    }

    func testAnOlderCatalogKeepsItsAlbumRowsAndGainsTheLinksTable() throws {
        let catalog = try temporaryCatalog()
        let eventID = UUID()
        let state = ImmichEventAlbumState(albumID: "album-1", albumName: "Beach Day", albumCount: 12, inAlbum: 10, checkedAt: Date(timeIntervalSince1970: 1_780_000_000))
        // A catalog as the previous build left it: only immich_event_albums.
        try CatalogDatabase.writer(for: catalog).write { database in
            try database.execute(sql: ImmichEventAlbumStore.schema)
            try database.execute(
                sql: "INSERT INTO immich_event_albums(event_id, state) VALUES (?, ?)",
                arguments: [eventID.uuidString, String(decoding: try JSONEncoder().encode(state), as: UTF8.self)]
            )
        }
        XCTAssertEqual(ImmichEventAlbumStore.existingLinks(catalogURL: catalog), [])
        XCTAssertFalse(try CatalogDatabase.writer(for: catalog).read { try $0.tableExists("immich_event_album_links") }, "reading links creates nothing")

        let store = try ImmichEventAlbumStore(catalogURL: catalog)
        XCTAssertEqual(try store.all(), [eventID: state], "the older rows are untouched")
        XCTAssertTrue(try CatalogDatabase.writer(for: catalog).read { try $0.tableExists("immich_event_album_links") })
        XCTAssertEqual(try store.links(), [])

        // Opening it again is a no-op.
        let again = try ImmichEventAlbumStore(catalogURL: catalog)
        XCTAssertEqual(try again.all(), [eventID: state])
    }

    func testLinksAddDismissAndPrune() throws {
        let catalog = try temporaryCatalog()
        let store = try ImmichEventAlbumStore(catalogURL: catalog)
        let first = UUID()
        let second = UUID()
        // One album on two events, and two albums on one event.
        let links = [
            ImmichEventAlbumLink(eventID: first, albumID: "u", albumName: "Year in Review", basis: "severalEvents"),
            ImmichEventAlbumLink(eventID: second, albumID: "u", albumName: "Year in Review", basis: "severalEvents"),
            ImmichEventAlbumLink(eventID: first, albumID: "p", albumName: "Island phone", basis: "dates")
        ]
        try store.addLinks(links)
        try store.addLinks(links)
        XCTAssertEqual(Set(try store.links()), Set(links), "adding twice changes nothing")
        XCTAssertEqual(links[2].basisText, "dates")

        try store.dismissLink(eventID: first, albumID: "p")
        try store.addLinks([links[2]])
        XCTAssertFalse(try store.links().contains(links[2]), "a removed link stays removed")
        XCTAssertEqual(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: catalog), ["u", "p"], "pairing still leaves it alone")

        try store.removeLinks(toAlbumsNotIn: ["p"])
        XCTAssertEqual(try store.links(), [])
        XCTAssertEqual(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: catalog), ["p"])

        // An album missing from one listing (another key or server) keeps
        // its removed row, so the link never comes back.
        try store.removeLinks(toAlbumsNotIn: [])
        XCTAssertEqual(ImmichEventAlbumStore.handledAlbumIDs(catalogURL: catalog), ["p"])
    }
}
