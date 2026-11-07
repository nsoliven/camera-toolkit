@testable import CameraToolkitCore
import Foundation
import XCTest

/// Resolving a Sync to NAS conflict never overwrites or deletes a version:
/// the loser moves to the NAS's `_Stale Copies` or the drive's `_Trash`,
/// the winner is copied in through a verified exclusive rename, and the
/// sync record says verified so the next sync reports no conflict. Every
/// fixture is a temporary folder standing in for the drive and the NAS.
final class ConflictResolverTests: XCTestCase {
    private var root: URL!
    private var driveRoot: URL!
    private var nasRoot: URL!
    private var trashRoot: URL!
    private var store: NASSyncStore!

    private let relative = "2026/Trip 2026/Originals/DSC00177.photo-edit"
    private let driveBytes = Data("drive version · newer edit".utf8)
    private let nasBytes = Data("NAS version · older edit, a little longer".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConflictResolver-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        driveRoot = root.appendingPathComponent("Buffer", isDirectory: true)
        nasRoot = root.appendingPathComponent("nas_share", isDirectory: true)
        trashRoot = root.appendingPathComponent("_Trash", isDirectory: true)
        try write(driveBytes, to: drivePath, modified: 1_790_000_000.25)
        try write(nasBytes, to: nasPath, modified: 1_788_000_000.5)
        store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
    }

    override func tearDownWithError() throws {
        NASFileIO.verificationHashOverride = nil
        CatalogDatabase.checkpointAndClose(url: root.appendingPathComponent("catalog.sqlite"))
        try? FileManager.default.removeItem(at: root)
    }

    private var drivePath: String { driveRoot.appendingPathComponent(relative).path }
    private var nasPath: String { nasRoot.appendingPathComponent(relative).path }
    private var pair: ConflictPair { ConflictPair(drivePath: drivePath, nasRoot: nasRoot.path, relativePath: relative) }
    private var resolver: ConflictResolver {
        ConflictResolver(store: store, removedFilesRoot: trashRoot, journalFolder: root.appendingPathComponent("Resolutions"), volumeRoot: { _ in nil })
    }

    private func write(_ data: Data, to path: String, modified: Double) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        ConflictResolver.setModificationTime(path, modified)
    }

    private func sha(_ data: Data) -> String {
        FileCompareTestsSupport.sha(data)
    }

    private func resolve(_ choice: ConflictChoice) throws -> ConflictResolution {
        try resolver.resolve(pair, choice: choice, expectedDrive: sha(driveBytes), expectedNAS: sha(nasBytes))
    }

    /// Every file under `folder`, by path relative to it, with its bytes.
    private func files(under folder: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.lastPathComponent != "manifest.json" else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))] = try? Data(contentsOf: url)
        }
        return result
    }

    // MARK: Compare

    func testCompareReadsEachSideFromItsOwnPath() {
        let comparison = FileCompare.compare(drivePath: drivePath, nasPath: nasPath)
        XCTAssertEqual(comparison.drive.sha256, sha(driveBytes))
        XCTAssertEqual(comparison.nas.sha256, sha(nasBytes))
        XCTAssertEqual(comparison.drive.size, Int64(driveBytes.count))
        XCTAssertFalse(comparison.identical)
        XCTAssertEqual(comparison.newer, .drive)
        XCTAssertNotNil(comparison.settingsProblem, "not a real edit file: the settings diff says why it could not read it")
        let missing = FileCompare.inspect(root.appendingPathComponent("nope").path)
        XCTAssertFalse(missing.exists)
        XCTAssertEqual(missing.problem, "Not found at this location.")
    }

    func testIdenticalCopiesCompareIdentical() throws {
        try write(driveBytes, to: nasPath, modified: 1_788_000_000)
        XCTAssertTrue(FileCompare.compare(drivePath: drivePath, nasPath: nasPath).identical)
    }

    // MARK: Resolve

    func testKeepDriveSetsTheNASVersionAsideAndVerifiesTheCopy() throws {
        let journal = try resolve(.keepDrive)
        XCTAssertEqual(journal.status, .done)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nasPath)), driveBytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: drivePath)), driveBytes, "the drive copy is only read")
        let stale = try XCTUnwrap(journal.staleNASPath)
        XCTAssertTrue(stale.contains("/.Camera Toolkit/_Stale Copies/"))
        XCTAssertTrue(stale.hasSuffix("/" + relative))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stale)), nasBytes, "the NAS version is kept, not deleted")
        XCTAssertFalse(files(under: nasRoot).keys.contains { $0.contains(ConflictResolver.temporaryMarker) }, "no temporary left behind")

        let record = try XCTUnwrap(store.records(nasRoot: nasRoot.path, pathKeys: [NASSyncStore.pathKey(relative)]).values.first)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(record.sha256, sha(driveBytes))
        XCTAssertEqual(record.byteCount, Int64(driveBytes.count))
        XCTAssertEqual(record.sourceModifiedAt ?? 0, try ConflictResolver.regularFile(drivePath).modified, accuracy: 0.001,
                       "the next sync's resume check matches the drive file's own date")
    }

    func testKeepNASTrashesTheDriveVersionAndCopiesTheNASOneBack() throws {
        let journal = try resolve(.keepNAS)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: drivePath)), nasBytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nasPath)), nasBytes, "the NAS copy is only read")
        XCTAssertEqual(try ConflictResolver.regularFile(drivePath).modified, 1_788_000_000.5, accuracy: 0.001, "the copy keeps the NAS version's date")
        let trashed = files(under: try XCTUnwrap(journal.trashBatchFolder).asURL)
        XCTAssertEqual(Array(trashed.values), [driveBytes], "the drive version waits in _Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(journal.trashBatchFolder) + "/manifest.json"))
        let record = try XCTUnwrap(store.records(nasRoot: nasRoot.path, pathKeys: [NASSyncStore.pathKey(relative)]).values.first)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(record.sha256, sha(nasBytes))
    }

    func testKeepBothLeavesBothVersionsOnBothSides() throws {
        let journal = try resolve(.keepBoth)
        let kept = "2026/Trip 2026/Originals/DSC00177 (NAS \(Self.day(1_788_000_000.5))).photo-edit"
        XCTAssertEqual(journal.keptNASPath, nasRoot.appendingPathComponent(kept).path)
        XCTAssertEqual(files(under: nasRoot)[relative], driveBytes)
        XCTAssertEqual(files(under: nasRoot)[kept], nasBytes)
        XCTAssertEqual(files(under: driveRoot)[relative], driveBytes)
        XCTAssertEqual(files(under: driveRoot)[kept], nasBytes)
        let records = try store.records(nasRoot: nasRoot.path, pathKeys: [NASSyncStore.pathKey(relative), NASSyncStore.pathKey(kept)])
        XCTAssertEqual(records.values.map(\.state), [.verified, .verified])
    }

    func testAKeptNameThatIsTakenGetsANumber() {
        let day = Self.day(1_788_000_000)
        let name = ConflictResolver.keptName(for: "DSC00177.photo-edit", modified: 1_788_000_000) { $0 != "DSC00177 (NAS \(day)).photo-edit" }
        XCTAssertEqual(name, "DSC00177 (NAS \(day) 2).photo-edit")
    }

    /// The local calendar day of `seconds`, as the kept name writes it.
    static func day(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    // MARK: The next sync

    /// The promise of a resolution: run the real Sync to NAS over the pair
    /// afterwards and it reports no conflict, for every choice.
    func testAfterEachChoiceTheNextSyncReportsNoConflict() throws {
        func plan() throws -> NASSyncPlan {
            var items: [NASSyncItem] = []
            let enumerator = FileManager.default.enumerator(atPath: driveRoot.path)
            while let relativePath = enumerator?.nextObject() as? String {
                let path = driveRoot.appendingPathComponent(relativePath).path
                guard let facts = try? ConflictResolver.regularFile(path) else { continue }
                items.append(NASSyncItem(sourcePath: path, relativePath: relativePath, byteCount: facts.size, modifiedAt: facts.modified, eventID: nil))
            }
            return NASSyncPlan(items: items, outsideLayout: [], skippedJunk: 0, refused: [], unreadable: [])
        }
        let before = try NASSyncService(store: store).sync(plan(), nasRoot: nasRoot)
        XCTAssertEqual(before.conflicts.map(\.path), [relative], "the fixture is a real conflict")

        for choice in ConflictChoice.allCases {
            try tearDownWithError()
            try setUpWithError()
            _ = try resolve(choice)
            let after = try NASSyncService(store: store).sync(plan(), nasRoot: nasRoot)
            XCTAssertTrue(after.conflicts.isEmpty, "\(choice): \(after.conflicts)")
            XCTAssertTrue(after.succeeded, "\(choice): \(after)")
            XCTAssertTrue(after.copied.isEmpty, "\(choice): nothing is copied again")
        }
    }

    // MARK: Refusals

    func testACopyThatChangedSinceItWasComparedRefuses() throws {
        XCTAssertThrowsError(try resolver.resolve(pair, choice: .keepDrive, expectedDrive: sha(driveBytes), expectedNAS: sha(Data("something else".utf8)))) {
            XCTAssertEqual($0 as? ConflictResolveError, .changedSinceCompared("NAS"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nasPath)), nasBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resolutions").path), "refused before anything was written")
    }

    func testIdenticalCopiesHaveNothingToResolve() throws {
        try write(driveBytes, to: nasPath, modified: 1_788_000_000)
        XCTAssertThrowsError(try resolver.resolve(pair, choice: .keepDrive, expectedDrive: sha(driveBytes), expectedNAS: sha(driveBytes))) {
            XCTAssertEqual($0 as? ConflictResolveError, .alreadyIdentical)
        }
    }

    func testALinkIsRefused() throws {
        try FileManager.default.removeItem(atPath: drivePath)
        try FileManager.default.createSymbolicLink(atPath: drivePath, withDestinationPath: nasPath)
        XCTAssertThrowsError(try resolve(.keepDrive)) { XCTAssertEqual($0 as? ConflictResolveError, .notAFile(drivePath)) }
    }

    func testAPathThatEscapesTheRootIsRefused() {
        let escaping = ConflictPair(drivePath: drivePath, nasRoot: nasRoot.path, relativePath: "../outside.photo-edit")
        XCTAssertThrowsError(try resolver.resolve(escaping, choice: .keepDrive, expectedDrive: "", expectedNAS: ""))
    }

    /// The NAS re-read does not match: nothing is put in place, the NAS
    /// version returns to its path, and no partial file remains.
    func testAFailedVerificationPutsTheNASVersionBack() throws {
        NASFileIO.verificationHashOverride = { path in path.contains(ConflictResolver.temporaryMarker) ? "0000" : nil }
        XCTAssertThrowsError(try resolve(.keepDrive)) { XCTAssertEqual($0 as? ConflictResolveError, .verifyFailed(nasPath)) }
        XCTAssertEqual(files(under: nasRoot), [relative: nasBytes], "the NAS is as it was: no temporary, nothing set aside")
        let journal = try XCTUnwrap(ConflictResolver.journals(in: root.appendingPathComponent("Resolutions")).first)
        XCTAssertEqual(journal.status, .failed)
        XCTAssertNil(journal.staleNASPath)
    }

    // MARK: Undo

    func testUndoingKeepDriveBringsTheNASVersionBack() throws {
        let undone = try resolver.undo(resolve(.keepDrive))
        XCTAssertEqual(undone.status, .undone)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nasPath)), nasBytes)
        XCTAssertEqual(Set(files(under: nasRoot).values), [nasBytes, driveBytes], "the copy that was put in place is set aside, not deleted")
        let record = try XCTUnwrap(store.records(nasRoot: nasRoot.path, pathKeys: [NASSyncStore.pathKey(relative)]).values.first)
        XCTAssertEqual(record.state, .conflict)
    }

    func testUndoingKeepNASRestoresTheDriveVersionFromTrash() throws {
        _ = try resolver.undo(resolve(.keepNAS))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: drivePath)), driveBytes)
        XCTAssertEqual(Array(files(under: trashRoot).values), [nasBytes], "the copied-back NAS version waits in _Trash")
    }

    func testUndoingKeepBothPutsTheNamesBack() throws {
        let journal = try resolve(.keepBoth)
        _ = try resolver.undo(journal)
        XCTAssertEqual(files(under: nasRoot)[relative], nasBytes)
        XCTAssertNil(files(under: driveRoot)[try XCTUnwrap(journal.keptDrivePath).replacingOccurrences(of: driveRoot.path + "/", with: "")])
        XCTAssertEqual(files(under: driveRoot)[relative], driveBytes)
    }

    func testUndoRefusesWhenTheFileInPlaceChanged() throws {
        let journal = try resolve(.keepDrive)
        try write(Data("edited again since".utf8), to: nasPath, modified: 1_791_000_000)
        XCTAssertThrowsError(try resolver.undo(journal)) { XCTAssertEqual($0 as? ConflictResolveError, .changedSinceCompared("NAS")) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nasPath)), Data("edited again since".utf8))
    }
}

enum FileCompareTestsSupport {
    static func sha(_ data: Data) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? FileCompare.sha256(of: url)) ?? ""
    }
}

private extension String {
    var asURL: URL { URL(fileURLWithPath: self) }
}
