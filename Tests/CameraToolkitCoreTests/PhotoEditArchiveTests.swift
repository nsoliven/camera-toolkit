@testable import CameraToolkitCore
import Compression
import Foundation
import GRDB
import XCTest

/// `.photo-edit` files read without changing them: the ZIP, the settings
/// database inside it, and the readable diff between two versions. Every
/// fixture is built here — a synthetic ZIP around a generated SQLite file
/// and a stand-in WebP — with no real edit files.
final class PhotoEditArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoEditArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixture

    /// A settings database shaped like an edit's: key/value rows, JSON in
    /// some values, a binary blob in another.
    static func metadataDatabase(at url: URL, exposure: Double, crop: Double, writer: String, rawBlob: Data) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE layer_info (key TEXT PRIMARY KEY, value BLOB)")
            try db.execute(sql: "CREATE TABLE document_info (key TEXT PRIMARY KEY, value TEXT)")
            let adjustments = try JSONSerialization.data(withJSONObject: ["exposure": exposure, "contrast": 12, "enabled": true], options: [.sortedKeys])
            try db.execute(sql: "INSERT INTO layer_info VALUES (?, ?)", arguments: ["color-adjustments", adjustments])
            try db.execute(sql: "INSERT INTO layer_info VALUES (?, ?)", arguments: ["raw-parameters-data", rawBlob])
            try db.execute(sql: "INSERT INTO layer_info VALUES (?, ?)", arguments: ["crop", "{\"angle\":\(crop)}"])
            try db.execute(sql: "INSERT INTO document_info VALUES (?, ?)", arguments: ["content-writer", writer])
        }
        try queue.close()
    }

    /// A ZIP of `files`: stored, except names in `deflate`.
    static func zip(_ files: [(String, Data)], deflate: Set<String> = []) -> Data {
        var archive = Data()
        var central = Data()
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        for (name, contents) in files {
            let method = deflate.contains(name) ? 8 : 0
            let payload = method == 8 ? deflated(contents) : contents
            let offset = archive.count
            let nameData = Data(name.utf8)
            let parts: [Data] = [
                le32(0x0403_4b50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                le32(payload.count), le32(contents.count), le16(nameData.count), le16(0), nameData, payload,
            ]
            for part in parts { archive.append(part) }
            let header: [Data] = [
                le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                le32(payload.count), le32(contents.count), le16(nameData.count), le16(0), le16(0), le16(0), le16(0),
                le32(0), le32(offset), nameData,
            ]
            for part in header { central.append(part) }
        }
        let centralOffset = archive.count
        archive.append(central)
        let end: [Data] = [le32(0x0605_4b50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(centralOffset), le16(0)]
        for part in end { archive.append(part) }
        return archive
    }

    static func deflated(_ data: Data) -> Data {
        var output = Data(count: data.count + 1_024)
        let size = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, data.count + 1_024,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(size)
    }

    /// A whole synthetic edit file on disk.
    static func photoEdit(at url: URL, exposure: Double, crop: Double = 0, writer: String = "Device A", rawBlob: Data = Data([1, 2, 3, 4]), thumbnail: Data = Data("RIFF-thumb".utf8), deflateMetadata: Bool = false) throws {
        let folder = url.deletingLastPathComponent().appendingPathComponent("db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("metadata.info")
        try metadataDatabase(at: database, exposure: exposure, crop: crop, writer: writer, rawBlob: rawBlob)
        try zip([
            (PhotoEditArchive.metadataName, Data(contentsOf: database)),
            (PhotoEditArchive.thumbnailName, thumbnail),
            (PhotoEditArchive.iconName, Data("RIFF-icon".utf8)),
        ], deflate: deflateMetadata ? [PhotoEditArchive.metadataName] : []).write(to: url)
    }

    // MARK: Tests

    func testTheArchiveListsAndReadsItsEntries() throws {
        let url = root.appendingPathComponent("DSC00001.photo-edit")
        try Self.photoEdit(at: url, exposure: 0.3, thumbnail: Data("thumbnail bytes".utf8))
        let archive = try PhotoEditArchive(contentsOf: url)
        XCTAssertEqual(archive.entries.map(\.name), [PhotoEditArchive.metadataName, PhotoEditArchive.thumbnailName, PhotoEditArchive.iconName])
        XCTAssertEqual(try archive.contents(of: PhotoEditArchive.thumbnailName), Data("thumbnail bytes".utf8))
        XCTAssertThrowsError(try archive.contents(of: "nope")) { XCTAssertEqual($0 as? PhotoEditArchive.ReadError, .missing("nope")) }
        XCTAssertTrue(PhotoEditArchive.isPhotoEdit("a/b/DSC00001.photo-edit"))
        XCTAssertFalse(PhotoEditArchive.isPhotoEdit("a/b/DSC00001.ARW"))
    }

    func testADeflatedEntryIsInflated() throws {
        let url = root.appendingPathComponent("deflated.photo-edit")
        try Self.photoEdit(at: url, exposure: 0.5, deflateMetadata: true)
        let archive = try PhotoEditArchive(contentsOf: url)
        XCTAssertEqual(archive.entry(PhotoEditArchive.metadataName)?.method, 8)
        XCTAssertTrue(try PhotoEditSettings.read(archive).contains(PhotoEditSetting(key: "layer_info.color-adjustments.exposure", value: "0.5")))
    }

    func testSomethingElseIsNotAZip() {
        XCTAssertThrowsError(try PhotoEditArchive(data: Data("not a zip at all, just text".utf8))) {
            XCTAssertEqual($0 as? PhotoEditArchive.ReadError, .notAZip)
        }
    }

    func testSettingsFlattenRowsJSONAndBlobs() throws {
        let url = root.appendingPathComponent("a.photo-edit")
        try Self.photoEdit(at: url, exposure: 0.35, crop: 1.5, writer: "Device A", rawBlob: Data([0, 1, 2, 3, 0]))
        let settings = try PhotoEditSettings.read(PhotoEditArchive(contentsOf: url))
        let byKey = Dictionary(settings.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byKey["layer_info.color-adjustments.exposure"], "0.35")
        XCTAssertEqual(byKey["layer_info.color-adjustments.contrast"], "12")
        XCTAssertEqual(byKey["layer_info.color-adjustments.enabled"], "true")
        XCTAssertEqual(byKey["layer_info.crop.angle"], "1.5")
        XCTAssertEqual(byKey["document_info.content-writer"], "Device A")
        XCTAssertTrue(byKey["layer_info.raw-parameters-data"]?.hasPrefix("5 bytes · ") ?? false)
    }

    /// Two versions of one edit: the diff names exactly what changed.
    func testTheDiffNamesOnlyTheSettingsThatChanged() throws {
        let drive = root.appendingPathComponent("drive.photo-edit")
        let nas = root.appendingPathComponent("nas.photo-edit")
        try Self.photoEdit(at: drive, exposure: 0.35, crop: 0, writer: "Device A", rawBlob: Data([1, 2, 3]))
        try Self.photoEdit(at: nas, exposure: 0.1, crop: 0, writer: "Device B", rawBlob: Data([1, 2, 4]))
        let differences = PhotoEditSettings.differences(
            drive: try PhotoEditSettings.read(PhotoEditArchive(contentsOf: drive)),
            nas: try PhotoEditSettings.read(PhotoEditArchive(contentsOf: nas))
        )
        XCTAssertEqual(differences.map(\.key), [
            "document_info.content-writer",
            "layer_info.color-adjustments.exposure",
            "layer_info.raw-parameters-data",
        ])
        XCTAssertEqual(differences[1], PhotoEditDifference(key: "layer_info.color-adjustments.exposure", drive: "0.35", nas: "0.1"))
    }

    func testASettingOnOneSideOnlyShowsAsMissingOnTheOther() {
        let differences = PhotoEditSettings.differences(
            drive: [PhotoEditSetting(key: "a", value: "1"), PhotoEditSetting(key: "b", value: "2")],
            nas: [PhotoEditSetting(key: "a", value: "1")]
        )
        XCTAssertEqual(differences, [PhotoEditDifference(key: "b", drive: "2", nas: nil)])
    }

    func testReadingNeverChangesTheEditFile() throws {
        let url = root.appendingPathComponent("unchanged.photo-edit")
        try Self.photoEdit(at: url, exposure: 0.2)
        let before = try Data(contentsOf: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try PhotoEditSettings.read(PhotoEditArchive(contentsOf: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unchanged.photo-edit"], "nothing is written beside it")
    }
}
