import CameraToolkitCore
import Foundation
import XCTest

final class MediaTrashServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)

    private func service(removedFilesRoot: URL, volumeRoot: (@Sendable (URL) -> URL?)? = nil) -> MediaTrashService {
        MediaTrashService(
            removedFilesRoot: removedFilesRoot,
            volumeRoot: volumeRoot ?? VolumeInfo.volumeRoot(for:),
            now: { [fixedNow] in fixedNow }
        )
    }

    private func file(_ url: URL) -> OrganizeFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return OrganizeFile(
            path: url.standardizedFileURL.path,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: (attributes?[.modificationDate] as? Date) ?? Date()
        )
    }

    private func batchName() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: fixedNow)
    }

    private func readManifest(_ url: URL) throws -> MediaTrashManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MediaTrashManifest.self, from: Data(contentsOf: url))
    }

    func testTrashPreservesRelativePathsAndWritesManifest() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Card/Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let nested = try writeFile(unsorted.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"), "one")
            let sidecar = try writeFile(unsorted.appendingPathComponent("DCIM/100MSDCF/DSC00001.xmp"), "<xmp/>")
            let other = try writeFile(unsorted.appendingPathComponent("Transfer 2/DSC00002.ARW"), "two")
            let eventID = UUID()

            let batch = try service(removedFilesRoot: trash).trash(
                files: [file(nested), file(sidecar), file(other)],
                originRoot: unsorted,
                context: TrashContext(
                    locationName: "Unsorted",
                    deviceID: "sony-a7v",
                    eventIDsByPathKey: [EventStorageLocations.pathKey(nested.path): eventID]
                )
            )

            let folder = trash.appendingPathComponent(batch.name, isDirectory: true)
            XCTAssertEqual(batch.segments.count, 1)
            XCTAssertEqual(batch.entries.count, 3)
            XCTAssertTrue(batch.skipped.isEmpty)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")), Data("one".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("DCIM/100MSDCF/DSC00001.xmp")), Data("<xmp/>".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Transfer 2/DSC00002.ARW")), Data("two".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))

            let manifest = try readManifest(folder.appendingPathComponent("manifest.json"))
            XCTAssertEqual(manifest.batchID, batch.name)
            XCTAssertEqual(manifest.entries.count, 3)
            let entry = try XCTUnwrap(manifest.entries.first { $0.trashedRelativePath == "DCIM/100MSDCF/DSC00001.ARW" })
            XCTAssertEqual(entry.originalAbsolutePath, nested.standardizedFileURL.path)
            XCTAssertEqual(entry.eventID, eventID)
            XCTAssertEqual(entry.deviceID, "sony-a7v")
            XCTAssertEqual(entry.originalLocationName, "Unsorted")
            XCTAssertEqual(entry.size, 3)
        }
    }

    func testTrashRoutesFilesToTheirOwnVolumesTrash() throws {
        try withTemporaryDirectory { root in
            let volumeNames = ["VolA", "VolB"]
            let mapper: @Sendable (URL) -> URL? = { url in
                let path = url.standardizedFileURL.path
                for name in volumeNames {
                    let base = root.appendingPathComponent(name).path
                    if path == base || path.hasPrefix(base + "/") {
                        return URL(fileURLWithPath: base, isDirectory: true)
                    }
                }
                return nil
            }
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("VolA/DCIM/a1.ARW"), "a1")
            let b = try writeFile(root.appendingPathComponent("VolB/DCIM/100MSDCF/b1.ARW"), "b1")
            let local = try writeFile(root.appendingPathComponent("Local Unsorted/c1.ARW"), "c1")

            let batch = try service(removedFilesRoot: trash, volumeRoot: mapper).trash(
                files: [file(a), file(b), file(local)],
                originRoot: root.appendingPathComponent("Local Unsorted"),
                context: TrashContext()
            )

            XCTAssertEqual(batch.entries.count, 3)
            XCTAssertEqual(batch.segments.count, 3)
            let name = batch.name
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("VolA/.Camera Toolkit/_Trash/\(name)/DCIM/a1.ARW")), Data("a1".utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("VolB/.Camera Toolkit/_Trash/\(name)/DCIM/100MSDCF/b1.ARW")), Data("b1".utf8))
            XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("\(name)/c1.ARW")), Data("c1".utf8))
            for segment in batch.segments {
                XCTAssertTrue(FileManager.default.fileExists(atPath: segment.folder.appendingPathComponent("manifest.json").path))
            }
        }
    }

    func testTrashSkipsMissingFilesAndStillMovesTheRest() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let real = try writeFile(unsorted.appendingPathComponent("a.ARW"), "real")
            let ghost = unsorted.appendingPathComponent("gone.ARW")

            let batch = try service(removedFilesRoot: trash).trash(
                files: [file(real), file(ghost)],
                originRoot: unsorted,
                context: TrashContext()
            )

            XCTAssertEqual(batch.entries.count, 1)
            XCTAssertEqual(batch.skipped.count, 1)
            XCTAssertEqual(batch.skipped[0].path, ghost.standardizedFileURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("\(batch.name)/a.ARW").path))
        }
    }

    func testTrashThrowsOnEmptySelection() throws {
        try withTemporaryDirectory { root in
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            XCTAssertThrowsError(try service(removedFilesRoot: trash).trash(files: [], originRoot: nil, context: TrashContext()))
        }
    }

    func testTrashUniquesFileNamesWhenRelativePathsCollide() throws {
        try withTemporaryDirectory { root in
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            // Files outside originRoot fall back to their bare name, so these collide.
            let first = try writeFile(root.appendingPathComponent("Elsewhere A/DSC1.ARW"), "first")
            let second = try writeFile(root.appendingPathComponent("Elsewhere B/DSC1.ARW"), "second")

            let batch = try service(removedFilesRoot: trash).trash(
                files: [file(first), file(second)],
                originRoot: nil,
                context: TrashContext()
            )

            XCTAssertEqual(batch.entries.count, 2)
            let folder = trash.appendingPathComponent(batch.name)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("DSC1.ARW")), Data("first".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("DSC1 2.ARW")), Data("second".utf8))
            XCTAssertEqual(Set(batch.entries.map(\.trashedRelativePath)), ["DSC1.ARW", "DSC1 2.ARW"])
        }
    }

    func testTrashUniquesBatchNameWhenFolderExists() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            try writeFile(trash.appendingPathComponent("\(batchName())/old.ARW"), "old")
            let fileURL = try writeFile(unsorted.appendingPathComponent("a.ARW"), "new")

            let batch = try service(removedFilesRoot: trash).trash(
                files: [file(fileURL)],
                originRoot: unsorted,
                context: TrashContext()
            )

            XCTAssertEqual(batch.name, "\(batchName())-2")
            XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("\(batch.name)/a.ARW")), Data("new".utf8))
            XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("\(batchName())/old.ARW")), Data("old".utf8))
        }
    }

    func testListBatchesReadsManifestsAndToleratesLegacyFolders() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let fileURL = try writeFile(unsorted.appendingPathComponent("a.ARW"), "new")
            // A legacy _Trash batch such as Free Up writes: no manifest.
            try writeFile(trash.appendingPathComponent("1999-01-01_000000/DCIM/old.ARW"), "legacy-bytes")

            let batch = try service(removedFilesRoot: trash).trash(
                files: [file(fileURL)],
                originRoot: unsorted,
                context: TrashContext()
            )

            let batches = service(removedFilesRoot: trash).listBatches(under: [trash])
            XCTAssertEqual(batches.map(\.name), [batch.name, "1999-01-01_000000"])

            let listed = try XCTUnwrap(batches.first)
            XCTAssertEqual(listed.fileCount, 1)
            XCTAssertEqual(listed.entries.count, 1)
            XCTAssertEqual(listed.segments.first?.hasManifest, true)

            let legacy = try XCTUnwrap(batches.last)
            XCTAssertEqual(legacy.fileCount, 1)
            XCTAssertEqual(legacy.byteCount, Int64("legacy-bytes".utf8.count))
            XCTAssertEqual(legacy.segments.first?.hasManifest, false)
            XCTAssertTrue(legacy.entries.isEmpty)
        }
    }

    func testRestorePutsFilesBackAndRemovesEmptyBatch() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let nested = try writeFile(unsorted.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"), "one")
            let flat = try writeFile(unsorted.appendingPathComponent("DSC00002.ARW"), "two")
            let svc = service(removedFilesRoot: trash)

            let batch = try svc.trash(files: [file(nested), file(flat)], originRoot: unsorted, context: TrashContext())
            let listed = try XCTUnwrap(svc.listBatches(under: [trash]).first)

            let report = svc.restore(batch: listed)

            XCTAssertEqual(report.restored.count, 2)
            XCTAssertTrue(report.conflicts.isEmpty)
            XCTAssertTrue(report.missing.isEmpty)
            XCTAssertTrue(report.failed.isEmpty)
            XCTAssertEqual(try Data(contentsOf: nested), Data("one".utf8))
            XCTAssertEqual(try Data(contentsOf: flat), Data("two".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent(batch.name).path))
        }
    }

    func testRestoreSkipsExistingAndNeverOverwrites() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let original = try writeFile(unsorted.appendingPathComponent("DCIM/DSC1.ARW"), "trashed-bytes")
            let svc = service(removedFilesRoot: trash)

            let batch = try svc.trash(files: [file(original)], originRoot: unsorted, context: TrashContext())
            try writeFile(unsorted.appendingPathComponent("DCIM/DSC1.ARW"), "newer-file")

            let report = svc.restore(batch: batch)

            XCTAssertEqual(report.conflicts, [original.standardizedFileURL.path])
            XCTAssertTrue(report.restored.isEmpty)
            XCTAssertEqual(try Data(contentsOf: original), Data("newer-file".utf8))
            // The trashed copy and its manifest entry stay so it can be restored later.
            XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("\(batch.name)/DCIM/DSC1.ARW")), Data("trashed-bytes".utf8))
            let manifest = try readManifest(trash.appendingPathComponent("\(batch.name)/manifest.json"))
            XCTAssertEqual(manifest.entries.count, 1)
        }
    }

    func testRestoreReportsMissingTrashedFile() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let original = try writeFile(unsorted.appendingPathComponent("DSC1.ARW"), "bytes")
            let svc = service(removedFilesRoot: trash)

            let batch = try svc.trash(files: [file(original)], originRoot: unsorted, context: TrashContext())
            try FileManager.default.removeItem(at: trash.appendingPathComponent("\(batch.name)/DSC1.ARW"))

            let report = svc.restore(batch: batch)

            XCTAssertEqual(report.missing, [original.standardizedFileURL.path])
            XCTAssertTrue(report.restored.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testRestoreLeavesManifestlessBatchUntouched() throws {
        try withTemporaryDirectory { root in
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let legacy = try writeFile(trash.appendingPathComponent("1999-01-01_000000/DCIM/old.ARW"), "precious")
            let svc = service(removedFilesRoot: trash)
            let batch = try XCTUnwrap(svc.listBatches(under: [trash]).first)

            let report = svc.restore(batch: batch)

            XCTAssertTrue(report.restored.isEmpty)
            XCTAssertEqual(report.failed.count, 1)
            XCTAssertEqual(try Data(contentsOf: legacy), Data("precious".utf8))
        }
    }
}
