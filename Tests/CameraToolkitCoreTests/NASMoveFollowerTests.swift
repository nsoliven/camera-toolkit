@testable import CameraToolkitCore
import CryptoKit
import Darwin
import Foundation
import XCTest

/// The NAS mirror follows the drive when files move: the NAS copy is
/// renamed on the NAS (no bytes read or sent), its sync record moves with
/// it, and everything is journaled so it resumes and undoes.
final class NASMoveFollowerTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        super.tearDown()
    }

    private struct World {
        var root: URL
        var buffer: URL
        var nas: URL
        var locations: EventStorageLocations
        var store: NASSyncStore
        var queue: NASRenameQueue
        var journals: URL
        var eventA: SavedCameraEvent
        var eventB: SavedCameraEvent
        var configuration: AppConfiguration

        func follower(remote: NASRemoteVerifier? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) -> NASMoveFollower {
            NASMoveFollower(store: store, remoteVerifier: remote, queue: queue, retryDelay: 0, isCancelled: isCancelled)
        }

        func mirror(_ event: SavedCameraEvent, _ name: String) throws -> String {
            try locations.layout(for: event, deviceID: "sony-a7v").mirrorRelativePath(for: name)
        }

        func record(_ relative: String) throws -> NASSyncRecord? {
            try store.records(nasRoot: nas.path)[NASSyncStore.pathKey(relative)]
        }

        /// Every file under `folder`, relative, without reading any.
        func files(under folder: URL) -> [String] {
            let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
            return subpaths.filter { subpath in
                (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(subpath).path))?[.type] as? FileAttributeType == .typeRegular
            }.sorted()
        }
    }

    private struct Seed {
        var relative: String
        var buffer: URL
        var nas: URL
        var data: Data
    }

    private func world(_ root: URL) throws -> World {
        var configuration = testConfiguration(root: root)
        let a = SavedCameraEvent(name: "Trip A", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-01")))
        let b = SavedCameraEvent(name: "Trip B", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-02")))
        configuration.savedEvents = [a, b]
        let locations = EventStorageLocations(configuration: configuration)
        try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
        let journals = root.appendingPathComponent("Move Journals")
        return World(
            root: root,
            buffer: locations.bufferRoot,
            nas: locations.nasRoot,
            locations: locations,
            store: try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite")),
            queue: NASRenameQueue(journalFolder: journals),
            journals: journals,
            eventA: a,
            eventB: b,
            configuration: configuration
        )
    }

    private func data(_ seed: Int, count: Int = 2_000) -> Data {
        Data((0..<count).map { UInt8(($0 &* (seed + 3)) & 0xFF) })
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A drive file with its NAS copy, verified by a sync record.
    @discardableResult
    private func seed(
        _ w: World,
        _ event: SavedCameraEvent,
        _ name: String,
        _ content: Data,
        onDrive: Bool = true,
        onNAS: Bool = true,
        verified: Bool = true
    ) throws -> Seed {
        let relative = try w.mirror(event, name)
        let buffer = w.buffer.appendingPathComponent(relative)
        let nas = w.nas.appendingPathComponent(relative)
        var modified = 1_000.0
        if onDrive {
            try writeFile(buffer, content)
            modified = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(buffer.path)).modifiedAt
        }
        if onNAS {
            try writeFile(nas, content)
            if verified {
                try w.store.upsert([NASSyncRecord(
                    nasRoot: w.nas.path,
                    relativePath: relative,
                    eventID: event.id,
                    byteCount: Int64(content.count),
                    sourceModifiedAt: modified,
                    sha256: sha(content),
                    state: .verified,
                    checkedAt: Date(timeIntervalSinceReferenceDate: 900_000_000),
                    verifiedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
                )])
            }
        }
        return Seed(relative: relative, buffer: buffer, nas: nas, data: content)
    }

    /// Moves a drive file to another event (or name) the way Move to Event
    /// does, journaled; returns the report.
    private func moveOnDrive(_ w: World, _ seed: Seed, to event: SavedCameraEvent, name: String? = nil) throws -> DriveMoveReport {
        let target = try w.mirror(event, name ?? (seed.relative as NSString).lastPathComponent)
        let move = DriveMove(
            sourcePath: seed.buffer.path,
            destinationPath: w.buffer.appendingPathComponent(target).path,
            byteCount: Int64(seed.data.count)
        )
        return try DriveMoveService().apply([move], title: "Move to Trip", journalFolder: w.journals, pruneBoundaries: [w.buffer])
    }

    private func batch(_ w: World, _ report: DriveMoveReport, title: String = "Move to Trip B") -> NASRenameBatch {
        NASRenameBatch(
            title: title,
            origin: .move,
            nasRoot: w.nas.path,
            moveJournalID: report.journalID,
            ops: NASMoveFollower.renames(forMoves: report.moved, locations: w.locations)
        )
    }

    /// Runs the remote command with the local `/bin/sh`, with a `sync`
    /// stub on PATH (a real `sync` would flush this Mac).
    private func localVerifier(_ w: World, commands: SyncLocked<[String]>? = nil) throws -> NASRemoteVerifier {
        let bin = w.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("sync")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let server = w.root.appendingPathComponent("Server")
        try FileManager.default.createSymbolicLink(at: server, withDestinationURL: w.nas)
        return NASRemoteVerifier(localPrefix: w.nas.path, serverPrefix: server.path, label: "local sh") { command in
            commands?.mutate { $0.append(command) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": "\(bin.path):/usr/bin:/bin:/sbin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, stdout: data, stderr: Data())
        }
    }

    private func sync(_ w: World) throws -> NASSyncReport {
        let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)
        return try NASSyncService(store: w.store).sync(plan, nasRoot: w.nas)
    }

    private func staleFiles(_ w: World) -> [String] {
        w.files(under: w.nas).filter { $0.hasPrefix(NASMoveFollower.staleFolderPath + "/") }
    }

    // MARK: Following a move

    /// The heart of it: the copy is renamed on the NAS, its record moves,
    /// so the next sync copies nothing and the NAS never holds two copies.
    /// Every NAS file is unreadable (mode 000): a rename needs no read, so
    /// nothing may open one.
    func testMoveRenamesTheNASCopyAndItsRecordSoTheNextSyncCopiesNothing() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moving = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let staying = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            for path in w.files(under: w.nas) { XCTAssertEqual(chmod(w.nas.appendingPathComponent(path).path, 0o000), 0) }

            let report = try moveOnDrive(w, moving, to: w.eventB)
            var renames = batch(w, report)
            XCTAssertEqual(renames.ops.count, 1)
            let result = try w.follower().apply(&renames, nasRoot: w.nas)

            XCTAssertEqual(result.renamed, 1)
            XCTAssertTrue(result.succeeded, result.summary)
            let newRelative = try w.mirror(w.eventB, "IMG_0001.ARW")
            XCTAssertFalse(FileManager.default.fileExists(atPath: moving.nas.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(newRelative).path))
            XCTAssertEqual(w.files(under: w.nas).count, 2, "renamed, not copied: still two files on the NAS")
            XCTAssertEqual(renames.ops[0].state, .renamed)
            XCTAssertNotNil(renames.completedAt)

            // The record followed with its hash, size and time intact.
            XCTAssertNil(try w.record(moving.relative))
            let moved = try XCTUnwrap(try w.record(newRelative))
            XCTAssertEqual(moved.state, .verified)
            XCTAssertEqual(moved.sha256, sha(moving.data))
            XCTAssertEqual(moved.byteCount, Int64(moving.data.count))
            XCTAssertEqual(moved.relativePath, newRelative)

            // Sync to NAS: nothing to copy, both files already verified.
            let synced = try sync(w)
            XCTAssertTrue(synced.copied.isEmpty, "\(synced)")
            XCTAssertEqual(synced.alreadyVerified.count, 2)
            XCTAssertTrue(synced.succeeded)
            XCTAssertEqual(w.files(under: w.nas).count, 2)
            _ = staying
        }
    }

    func testTheNASFolderTheMoveEmptiedIsPrunedUpToTheRoot() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let only = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            try writeFile(only.nas.deletingLastPathComponent().appendingPathComponent(".DS_Store"), "x")
            let report = try moveOnDrive(w, only, to: w.eventB)
            var renames = batch(w, report)
            let result = try w.follower().apply(&renames, nasRoot: w.nas)

            XCTAssertEqual(result.renamed, 1)
            let eventAFolder = w.nas.appendingPathComponent(NASMoveFollower.mirrorEventFolder(of: w.eventA, locations: w.locations))
            XCTAssertFalse(FileManager.default.fileExists(atPath: eventAFolder.path), "the emptied event folder is gone, as on the drive")
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.path), "the NAS root itself is never removed")
            XCTAssertGreaterThan(result.prunedFolders, 0)
            // A folder that still holds something is left alone.
            let kept = try seed(w, w.eventA, "IMG_0009.ARW", data(9))
            let sibling = try seed(w, w.eventA, "IMG_0010.ARW", data(10))
            let second = try moveOnDrive(w, kept, to: w.eventB)
            var next = batch(w, second)
            _ = try w.follower().apply(&next, nasRoot: w.nas)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.nas.path))
        }
    }

    func testAMovedFileThatWasNeverOnTheNASOwesNothing() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let unsynced = try seed(w, w.eventA, "IMG_0001.ARW", data(1), onNAS: false)
            let report = try moveOnDrive(w, unsynced, to: w.eventB)
            var renames = batch(w, report)
            let result = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.absent, 1)
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(w.files(under: w.nas).isEmpty)
            XCTAssertEqual(renames.ops[0].state, .absent)
        }
    }

    func testOnlyMovesBetweenEventFoldersOweARename() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let target = try w.mirror(w.eventB, "IMG_0001.ARW")
            let unsorted = w.buffer.appendingPathComponent("Unsorted/IMG_0001.ARW").path
            let privateRoot = w.locations.privateStagingRoot.appendingPathComponent(file.relative).path

            func moves(_ pairs: [(String, String)]) -> [DriveMove] {
                pairs.map { DriveMove(sourcePath: $0.0, destinationPath: $0.1, byteCount: 1) }
            }
            let between = NASMoveFollower.renames(forMoves: moves([(file.buffer.path, w.buffer.appendingPathComponent(target).path)]), locations: w.locations)
            XCTAssertEqual(between.map(\.to), [target])
            // Buffer ↔ Private keeps the mirror path; Unsorted is not an event.
            XCTAssertTrue(NASMoveFollower.renames(forMoves: moves([(file.buffer.path, privateRoot)]), locations: w.locations).isEmpty)
            XCTAssertTrue(NASMoveFollower.renames(forMoves: moves([(file.buffer.path, unsorted)]), locations: w.locations).isEmpty)
            XCTAssertTrue(NASMoveFollower.renames(forMoves: moves([(unsorted, w.buffer.appendingPathComponent(target).path)]), locations: w.locations).isEmpty)
            XCTAssertTrue(NASMoveFollower.renames(forMoves: moves([("/elsewhere/a.ARW", "/elsewhere/b.ARW")]), locations: w.locations).isEmpty)
        }
    }

    // MARK: NAS away or busy

    func testAnOfflineNASQueuesTheRenamesAndAppliesThemOnceItIsBack() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, file, to: w.eventB)
            let away = root.appendingPathComponent("NAS.away")
            try FileManager.default.moveItem(at: w.nas, to: away)

            var renames = batch(w, report)
            let offline = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(offline.changed, 0)
            XCTAssertEqual(offline.notAttempted, 1)
            XCTAssertNotNil(offline.stoppedReason)
            XCTAssertEqual(w.queue.pendingRenameCount(nasRoot: w.nas.path), 1, "the journal is on disk")
            let stillAway = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(stillAway.changed, 0, "applyPending with no NAS changes nothing …")
            XCTAssertEqual(w.queue.pendingRenameCount(), 1, "… and keeps the rename queued")

            // The share mounts again: the queue is applied.
            try FileManager.default.moveItem(at: away, to: w.nas)
            let applied = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(applied.renamed, 1)
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(try w.mirror(w.eventB, "IMG_0001.ARW")).path))
            XCTAssertNotNil(try w.record(try w.mirror(w.eventB, "IMG_0001.ARW")))
        }
    }

    func testABatchLeftPendingBySavingStaysQueuedAcrossRelaunch() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, file, to: w.eventB)
            try w.queue.save(batch(w, report))
            // A new queue over the same folder (a relaunch) finds it.
            let reopened = NASRenameQueue(journalFolder: w.journals)
            XCTAssertEqual(reopened.pending(nasRoot: w.nas.path).count, 1)
            XCTAssertEqual(reopened.pending(nasRoot: root.appendingPathComponent("Other").path).count, 0, "another NAS root's batches are not applied here")
            XCTAssertEqual(reopened.batches(forMoveJournal: try XCTUnwrap(report.journalID)).count, 1)
        }
    }

    /// Sync to NAS applies what is queued before it plans, so the moved
    /// file is found at its new NAS path and never copied.
    func testSyncAppliesQueuedRenamesFirstAndNeverRecopiesAMovedFile() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            _ = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            let report = try moveOnDrive(w, file, to: w.eventB)
            try w.queue.save(batch(w, report))

            let prepared = try w.follower().prepareSync(
                events: w.configuration.savedEvents,
                locations: w.locations,
                nasRoot: w.nas,
                ownedKeys: [],
                catchUp: true
            )
            XCTAssertEqual(prepared.follow.renamed, 1)
            let synced = try NASSyncService(store: w.store).sync(prepared.plan, nasRoot: w.nas)
            XCTAssertTrue(synced.copied.isEmpty, "\(synced)")
            XCTAssertEqual(synced.alreadyVerified.count, 2)
            XCTAssertEqual(w.files(under: w.nas).count, 2)
        }
    }

    // MARK: A new path that is already taken

    func testAnIdenticalFileAtTheNewPathKeepsItAndTheStaleCopyGoesToTheNASSetAsideFolder() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", content)
            // An earlier sync already copied the file to its new path.
            let keeper = try seed(w, w.eventB, "IMG_0001.ARW", content, onDrive: false)
            let report = try moveOnDrive(w, stale, to: w.eventB)
            var renames = batch(w, report)

            let result = try w.follower().apply(&renames, nasRoot: w.nas)

            XCTAssertEqual(result.merged, 1)
            XCTAssertEqual(result.renamed, 0)
            XCTAssertTrue(result.succeeded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.nas.path), "the file at the new path stays")
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.nas.path))
            let aside = staleFiles(w)
            XCTAssertEqual(aside.count, 1, "nothing was deleted: the stale copy is set aside")
            XCTAssertTrue(aside[0].hasSuffix("/" + stale.relative))
            let asideURL = w.nas.appendingPathComponent(aside[0])
            XCTAssertEqual(chmod(asideURL.path, 0o644), 0)
            XCTAssertEqual(try Data(contentsOf: asideURL), content)
            XCTAssertEqual(renames.ops[0].state, .merged)
            XCTAssertEqual(renames.ops[0].stalePath, aside[0])
            XCTAssertNil(try w.record(stale.relative))
            XCTAssertEqual(try w.record(keeper.relative)?.sha256, sha(content), "the keeper's own record stays")
        }
    }

    func testTheNASSideHashProvesIdentityWhenThereAreNoRecords() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(4)
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", content, verified: false)
            let keeper = try seed(w, w.eventB, "IMG_0001.ARW", content, onDrive: false, verified: false)
            let report = try moveOnDrive(w, stale, to: w.eventB)
            var renames = batch(w, report)
            let commands = SyncLocked<[String]>([])

            let result = try w.follower(remote: try localVerifier(w, commands: commands)).apply(&renames, nasRoot: w.nas)

            XCTAssertEqual(result.merged, 1, result.summary)
            XCTAssertEqual(commands.value.count, 1, "one NAS-side hash command for the pair")
            XCTAssertTrue(commands.value[0].contains("sha256sum"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.nas.path))
            XCTAssertEqual(staleFiles(w).count, 1)
        }
    }

    /// Two matching records used to prove a merge without reading either
    /// copy. A copy verified once can hold other bytes now (the NAS pool has
    /// shown rare corruption), so bytes decide: with SSH set up both copies
    /// are hashed on the NAS, even when both records exist and agree.
    func testMatchingRecordsAloneNeverProveAMergeTheNASHashesBothCopies() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            _ = try seed(w, w.eventB, "IMG_0001.ARW", data(1), onDrive: false)
            let report = try moveOnDrive(w, stale, to: w.eventB)
            var renames = batch(w, report)
            let commands = SyncLocked<[String]>([])
            let result = try w.follower(remote: try localVerifier(w, commands: commands)).apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.merged, 1)
            XCTAssertEqual(commands.value.count, 1, "one NAS-side hash command for the pair")
            XCTAssertTrue(commands.value[0].contains("sha256sum"))
        }
    }

    func testADifferentFileAtTheNewPathLeavesBothUntouchedAndIsReported() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moving = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            // Same name, same size, other bytes — a different photo.
            let other = try seed(w, w.eventB, "IMG_0001.ARW", data(7), onDrive: false)
            let sizeDiffers = try seed(w, w.eventA, "IMG_0002.ARW", data(2, count: 1_500))
            _ = try seed(w, w.eventB, "IMG_0002.ARW", data(2, count: 2_500), onDrive: false)
            let first = try moveOnDrive(w, moving, to: w.eventB)
            let second = try moveOnDrive(w, sizeDiffers, to: w.eventB)
            var renames = NASRenameBatch(
                title: "two",
                origin: .move,
                nasRoot: w.nas.path,
                ops: NASMoveFollower.renames(forMoves: first.moved + second.moved, locations: w.locations)
            )

            let result = try w.follower().apply(&renames, nasRoot: w.nas)

            XCTAssertEqual(result.differs.count, 2, result.summary)
            XCTAssertEqual(result.changed, 0)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(try Data(contentsOf: moving.nas), moving.data)
            XCTAssertEqual(try Data(contentsOf: other.nas), data(7))
            XCTAssertEqual(try Data(contentsOf: sizeDiffers.nas), sizeDiffers.data)
            XCTAssertTrue(staleFiles(w).isEmpty)
            XCTAssertNotNil(try w.record(moving.relative), "records stay where their files are")
            // Reported, and not retried forever.
            XCTAssertEqual(renames.pendingCount, 0)
            XCTAssertTrue(result.summary.contains("left untouched"))
        }
    }

    func testASameSizeFileNothingCanProveIdenticalIsLeftForSyncToCompare() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moving = try seed(w, w.eventA, "IMG_0001.ARW", data(1), verified: false)
            let there = try seed(w, w.eventB, "IMG_0001.ARW", data(1), onDrive: false, verified: false)
            let report = try moveOnDrive(w, moving, to: w.eventB)
            var renames = batch(w, report)
            for path in w.files(under: w.nas) { chmod(w.nas.appendingPathComponent(path).path, 0o000) }
            let result = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.unproven.count, 1)
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moving.nas.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: there.nas.path))
            XCTAssertTrue(staleFiles(w).isEmpty)
        }
    }

    func testANASCopyOfAnotherSizeAtTheOldPathIsNotTheMovedFile() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moving = try seed(w, w.eventA, "IMG_0001.ARW", data(1), onNAS: false)
            try writeFile(w.nas.appendingPathComponent(moving.relative), data(1, count: 900))
            let report = try moveOnDrive(w, moving, to: w.eventB)
            var renames = batch(w, report)
            let result = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.differs.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(moving.relative).path))
            XCTAssertEqual(w.files(under: w.nas).count, 1)
        }
    }

    // MARK: Never overwrites

    func testARenameNeverReplacesAFileThatAppearsAtTheNewPath() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moving = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, moving, to: w.eventB)
            var renames = batch(w, report)
            let target = w.nas.appendingPathComponent(renames.ops[0].to)
            // Another writer takes the name between the check and the rename.
            NASFileIO.renameExclusivePrimitive = { _, destination in
                _ = try? writeFile(URL(fileURLWithPath: destination), Data("someone else's".utf8))
                errno = EEXIST
                return -1
            }
            let result = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.failed.count, 1)
            XCTAssertEqual(try Data(contentsOf: target), Data("someone else's".utf8))
            XCTAssertEqual(try Data(contentsOf: moving.nas), moving.data)
            XCTAssertNotNil(try w.record(moving.relative))
        }
    }

    func testTheRenameUsesTheExclusivePrimitiveOncePerFile() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            var seeds: [Seed] = []
            for index in 0..<5 { seeds.append(try seed(w, w.eventA, "IMG_000\(index).ARW", data(index))) }
            var moves: [DriveMove] = []
            for item in seeds {
                let target = try w.mirror(w.eventB, (item.relative as NSString).lastPathComponent)
                moves.append(DriveMove(sourcePath: item.buffer.path, destinationPath: w.buffer.appendingPathComponent(target).path, byteCount: 2_000))
            }
            var renames = NASRenameBatch(title: "five", origin: .move, nasRoot: w.nas.path, ops: NASMoveFollower.renames(forMoves: moves, locations: w.locations))
            let calls = SyncLocked<[String]>([])
            NASFileIO.renameExclusivePrimitive = { source, destination in
                calls.mutate { $0.append(destination) }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            let result = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 5)
            XCTAssertEqual(calls.value.count, 5, "one server-side rename per file, nothing else")
        }
    }

    // MARK: Undo

    func testUndoOfAMoveAlsoReversesItsNASRenames() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            _ = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            let report = try moveOnDrive(w, file, to: w.eventB)
            var renames = batch(w, report)
            _ = try w.follower().apply(&renames, nasRoot: w.nas)
            let newRelative = try w.mirror(w.eventB, "IMG_0001.ARW")
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(newRelative).path))

            // The drive move is undone from its journal, then the NAS side.
            let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: w.journals))
            _ = try DriveMoveService().undo(journalURL: journal.url, pruneBoundaries: [w.buffer])
            let undone = try w.follower().undo(moveJournalID: journal.journal.id, nasRoot: w.nas)

            XCTAssertEqual(undone.follow.renamed, 1)
            XCTAssertEqual(undone.queued, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.nas.path), "back at the old NAS path")
            XCTAssertFalse(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(newRelative).path))
            XCTAssertEqual(try Data(contentsOf: file.nas), file.data)
            let back = try XCTUnwrap(try w.record(file.relative))
            XCTAssertEqual(back.sha256, sha(file.data))
            XCTAssertEqual(back.eventID, w.eventA.id, "the record belongs to the old event again")
            XCTAssertNil(try w.record(newRelative))
            // The original batch is closed; a second undo does nothing.
            XCTAssertNotNil(w.queue.batches(forMoveJournal: journal.journal.id).first?.undoneAt)
            XCTAssertEqual(try w.follower().undo(moveJournalID: journal.journal.id, nasRoot: w.nas).follow.changed, 0)
            // And the sync after the undo copies nothing.
            let synced = try sync(w)
            XCTAssertTrue(synced.copied.isEmpty, "\(synced)")
        }
    }

    func testUndoBringsAMergedStaleCopyBackOutOfTheSetAsideFolder() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", content)
            _ = try seed(w, w.eventB, "IMG_0001.ARW", content, onDrive: false)
            let report = try moveOnDrive(w, stale, to: w.eventB)
            var renames = batch(w, report)
            _ = try w.follower().apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(staleFiles(w).count, 1)

            let undone = try w.follower().undo(moveJournalID: try XCTUnwrap(report.journalID), nasRoot: w.nas)
            XCTAssertEqual(undone.follow.renamed, 1)
            XCTAssertEqual(try Data(contentsOf: stale.nas), content)
            XCTAssertTrue(staleFiles(w).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(try w.mirror(w.eventB, "IMG_0001.ARW")).path))
        }
    }

    func testUndoBeforeTheNASWasEverReachedDropsTheQueuedRenames() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, file, to: w.eventB)
            try w.queue.save(batch(w, report))
            let undone = try w.follower().undo(moveJournalID: try XCTUnwrap(report.journalID), nasRoot: w.nas)
            XCTAssertEqual(undone.cancelled, 1)
            XCTAssertEqual(undone.follow.changed, 0)
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.nas.path), "the NAS copy never moved")
        }
    }

    func testUndoWithTheNASAwayQueuesTheReverseRenames() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, file, to: w.eventB)
            var renames = batch(w, report)
            _ = try w.follower().apply(&renames, nasRoot: w.nas)
            let away = root.appendingPathComponent("NAS.away")
            try FileManager.default.moveItem(at: w.nas, to: away)

            let undone = try w.follower().undo(moveJournalID: try XCTUnwrap(report.journalID), nasRoot: w.nas)
            XCTAssertEqual(undone.queued, 1)
            XCTAssertEqual(w.queue.pendingRenameCount(), 1)

            try FileManager.default.moveItem(at: away, to: w.nas)
            XCTAssertEqual(try w.follower().applyPending(nasRoot: w.nas).renamed, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.nas.path))
        }
    }

    // MARK: What each drive operation owes the NAS

    private func assignment(_ w: World, _ event: SavedCameraEvent, _ name: String, size: Int) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: w.locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer).path,
            relativePath: name,
            fileSize: Int64(size),
            modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
            eventID: event.id,
            deviceID: "sony-a7v"
        )
    }

    /// Move to Event end to end: a plain move and a Keep Both rename follow
    /// on the NAS (one journal id, so one Undo), and the extra copy merged
    /// into an identical file has its NAS twin set aside.
    func testMoveToEventOwesRenamesForMovesAndKeepBothAndSetsAsideMergedTwins() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let plain = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let merged = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            let clash = try seed(w, w.eventA, "IMG_0003.ARW", data(3))
            let keptMerge = try seed(w, w.eventB, "IMG_0002.ARW", data(2))
            let keptClash = try seed(w, w.eventB, "IMG_0003.ARW", data(8))

            func item(_ seed: Seed, takenBy: [Seed] = []) throws -> EventMoveItem {
                let name = (seed.relative as NSString).lastPathComponent
                let removed = assignment(w, w.eventA, name, size: seed.data.count)
                var added = assignment(w, w.eventB, name, size: seed.data.count)
                added.sourceRootPath = w.locations.originalsRoot(for: w.eventB, deviceID: "sony-a7v", policy: .buffer).path
                return EventMoveItem(
                    removed: removed,
                    added: added,
                    move: DriveMove(sourcePath: seed.buffer.path, destinationPath: w.buffer.appendingPathComponent(try w.mirror(w.eventB, name)).path, byteCount: Int64(seed.data.count)),
                    currentPath: seed.buffer.path,
                    takenBy: takenBy.map(\.buffer.path)
                )
            }
            let outcome = try EventMoveService(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).move(
                [try item(plain), try item(merged, takenBy: [keptMerge]), try item(clash, takenBy: [keptClash])],
                title: "Move to Trip B",
                journalFolder: w.journals,
                pruneBoundaries: [w.buffer]
            )
            XCTAssertEqual(outcome.merged.count, 1)
            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["IMG_0003 (2).ARW"])

            let owed = NASMoveFollower.renames(forEventMove: outcome, locations: w.locations)
            XCTAssertEqual(owed.moves.map { ($0.from as NSString).lastPathComponent }.sorted(), ["IMG_0001.ARW", "IMG_0003.ARW"])
            XCTAssertEqual(owed.moves.first { $0.from.hasSuffix("IMG_0003.ARW") }.map { ($0.to as NSString).lastPathComponent }, "IMG_0003 (2).ARW")
            XCTAssertEqual(owed.moves.first?.eventID, w.eventB.id)
            XCTAssertEqual(owed.moves.first?.previousEventID, w.eventA.id)
            XCTAssertEqual(owed.merges.map(\.from), [merged.relative])
            XCTAssertEqual(owed.merges.map(\.to), [keptMerge.relative])

            var moves = NASRenameBatch(title: "Move to Trip B", origin: .move, nasRoot: w.nas.path, moveJournalID: outcome.report.journalID, ops: owed.moves)
            var merges = NASRenameBatch(title: "Move to Trip B (merged duplicates)", origin: .merge, nasRoot: w.nas.path, ops: owed.merges)
            let follower = w.follower()
            let moved = try follower.apply(&moves, nasRoot: w.nas)
            let set = try follower.apply(&merges, nasRoot: w.nas)

            XCTAssertEqual(moved.renamed, 2)
            XCTAssertEqual(set.merged, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plain.nas.path))
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(try w.mirror(w.eventB, "IMG_0003 (2).ARW"))), clash.data)
            XCTAssertEqual(try Data(contentsOf: keptClash.nas), data(8), "the different photo already there is untouched")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keptMerge.nas.path))
            XCTAssertEqual(staleFiles(w).count, 1)
            XCTAssertNil(try w.record(merged.relative))

            // Everything on the drive is on the NAS at its own path: a sync
            // copies nothing.
            let synced = try sync(w)
            XCTAssertTrue(synced.copied.isEmpty, "\(synced)")
            XCTAssertTrue(synced.succeeded)
            XCTAssertEqual(w.files(under: w.nas).filter { !$0.hasPrefix(".Camera Toolkit") }.count, 4)
        }
    }

    func testKeepInOnlyOwesTheRemovedCopiesNASTwinASetAside() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(5)
            let dropped = try seed(w, w.eventA, "IMG_0001.ARW", content)
            let kept = try seed(w, w.eventB, "IMG_0001.ARW", content)
            func candidate(_ seed: Seed, _ event: SavedCameraEvent) throws -> DuplicateCandidate {
                DuplicateCandidate(owner: .event(event.id), path: seed.buffer.path, assignment: assignment(w, event, "IMG_0001.ARW", size: content.count))
            }
            let group = try XCTUnwrap(DuplicateScanner(store: nil, readsCaptureDates: false)
                .scan([try candidate(kept, w.eventB), try candidate(dropped, w.eventA)]).groups.first)
            let resolution = DuplicateResolution(group: group, keep: .event(w.eventB.id), drop: [.event(w.eventA.id)])
            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil }))
                .resolve([resolution])
            XCTAssertEqual(outcome.trashed.count, 1)

            let owed = NASMoveFollower.renames(forDuplicates: [resolution], outcome: outcome, locations: w.locations)
            XCTAssertEqual(owed.map(\.from), [dropped.relative])
            XCTAssertEqual(owed.map(\.to), [kept.relative])
            var batch = NASRenameBatch(title: "Removed duplicate copies", origin: .merge, nasRoot: w.nas.path, ops: owed)
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.merged, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.nas.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.nas.path))
            XCTAssertEqual(staleFiles(w).count, 1)
        }
    }

    // MARK: Event folder renames

    func testAnEventRenameIsOneFolderRenameOnTheNAS() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let one = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            _ = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            try writeFile(w.nas.appendingPathComponent(NASMoveFollower.mirrorEventFolder(of: w.eventA, locations: w.locations) + "/Edited/tag/x.jpg"), "edit")
            var renamed = w.eventA
            renamed.name = "Trip A Renamed"
            renamed.eventDate = try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2027-01-05"))
            let op = try XCTUnwrap(NASMoveFollower.folderRename(from: w.eventA, to: renamed, locations: w.locations))
            XCTAssertEqual(op.from, "2026/2026-08-01 Trip A")
            XCTAssertEqual(op.to, "2027/2027-01-05 Trip A Renamed", "a date change moves across years")
            var batch = NASRenameBatch(title: "Rename Trip A", origin: .folderRename, nasRoot: w.nas.path, ops: [op])
            let calls = SyncLocked<[String]>([])
            NASFileIO.renameExclusivePrimitive = { source, destination in
                calls.mutate { $0.append(destination) }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            for path in w.files(under: w.nas) { chmod(w.nas.appendingPathComponent(path).path, 0o000) }

            let result = try w.follower().apply(&batch, nasRoot: w.nas)

            XCTAssertEqual(result.foldersRenamed, 1)
            XCTAssertEqual(calls.value.count, 1, "one rename for the whole event")
            XCTAssertFalse(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent("2026").path), "the emptied year folder goes too")
            XCTAssertEqual(w.files(under: w.nas.appendingPathComponent("2027/2027-01-05 Trip A Renamed")).count, 3)
            // Every record under the old folder followed.
            let records = try w.store.records(nasRoot: w.nas.path)
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.values.allSatisfy { $0.relativePath.hasPrefix("2027/2027-01-05 Trip A Renamed/") })
            XCTAssertNil(try w.record(one.relative))

            // Undo puts the folder back with one more rename.
            let inverse = try XCTUnwrap(NASMoveFollower.inverse(of: batch))
            var reverse = inverse
            calls.mutate { $0 = [] }
            let back = try w.follower().apply(&reverse, nasRoot: w.nas)
            XCTAssertEqual(back.foldersRenamed, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: one.nas.path))
            XCTAssertEqual(try w.store.records(nasRoot: w.nas.path).count, 2)
        }
    }

    /// The new folder already exists on the NAS (an earlier sync copied
    /// there): the old folder's files are renamed one by one into it, the
    /// identical ones set aside, the different ones left.
    func testWhenTheNewEventFolderAlreadyExistsTheFilesAreRenamedOneByOne() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let unique = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let same = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            let different = try seed(w, w.eventA, "IMG_0003.ARW", data(3))
            var renamed = w.eventA
            renamed.name = "Trip A Renamed"
            var futureConfiguration = w.configuration
            futureConfiguration.savedEvents = [renamed, w.eventB]
            let future = EventStorageLocations(configuration: futureConfiguration)
            // The re-copy under the new name.
            for (name, content) in [("IMG_0002.ARW", data(2)), ("IMG_0003.ARW", data(9))] {
                let relative = try future.layout(for: renamed, deviceID: "sony-a7v").mirrorRelativePath(for: name)
                try writeFile(w.nas.appendingPathComponent(relative), content)
                try w.store.upsert([NASSyncRecord(
                    nasRoot: w.nas.path, relativePath: relative, byteCount: Int64(content.count),
                    sourceModifiedAt: 1, sha256: sha(content), state: .verified, checkedAt: Date(), verifiedAt: Date()
                )])
            }
            let op = try XCTUnwrap(NASMoveFollower.folderRename(from: w.eventA, to: renamed, locations: w.locations))
            var batch = NASRenameBatch(title: "Rename Trip A", origin: .folderRename, nasRoot: w.nas.path, ops: [op])

            let result = try w.follower().apply(&batch, nasRoot: w.nas)

            XCTAssertEqual(result.foldersRenamed, 0)
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertEqual(result.merged, 1)
            XCTAssertEqual(result.differs.count, 1)
            XCTAssertEqual(batch.ops[0].state, .expanded)
            let base = "2026/2026-08-01 Trip A Renamed/Originals/Sony A7V/"
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(base + "IMG_0001.ARW")), unique.data)
            XCTAssertEqual(try Data(contentsOf: different.nas), different.data, "the different file stays under the old name")
            XCTAssertFalse(FileManager.default.fileExists(atPath: same.nas.path))
            XCTAssertEqual(staleFiles(w).count, 1)
        }
    }

    // MARK: Crash and resume

    func testAStoppedRunResumesFromTheJournalWithoutRepeatingWork() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            var moves: [DriveMove] = []
            for index in 0..<4 {
                let item = try seed(w, w.eventA, "IMG_000\(index).ARW", data(index))
                let target = try w.mirror(w.eventB, "IMG_000\(index).ARW")
                moves.append(DriveMove(sourcePath: item.buffer.path, destinationPath: w.buffer.appendingPathComponent(target).path, byteCount: 2_000))
            }
            var renames = NASRenameBatch(title: "four", origin: .move, nasRoot: w.nas.path, ops: NASMoveFollower.renames(forMoves: moves, locations: w.locations))
            let done = SyncLocked<Int>(0)
            NASFileIO.renameExclusivePrimitive = { source, destination in
                done.mutate { $0 += 1 }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            let stopped = try w.follower(isCancelled: { done.value >= 2 }).apply(&renames, nasRoot: w.nas)
            XCTAssertEqual(stopped.renamed, 2)
            XCTAssertEqual(stopped.notAttempted, 2)
            XCTAssertNotNil(stopped.stoppedReason)
            XCTAssertEqual(w.queue.pendingRenameCount(), 2, "the journal says what is left")

            // A new run (a relaunch) resumes from the saved batch.
            let resumed = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(resumed.renamed, 2)
            XCTAssertEqual(done.value, 4, "the first two were not renamed again")
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
            XCTAssertEqual(try w.store.records(nasRoot: w.nas.path).values.filter { $0.relativePath.contains("Trip B") }.count, 4)
        }
    }

    func testARenameThatLandedBeforeACrashIsRecognisedAndItsRecordMoved() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let file = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, file, to: w.eventB)
            let renames = batch(w, report)
            try w.queue.save(renames)
            // The process died right after the rename: the batch still says
            // pending and the record is still at the old path.
            let destination = w.nas.appendingPathComponent(renames.ops[0].to)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.nas, to: destination)

            let result = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1)
            XCTAssertTrue(result.succeeded)
            XCTAssertNotNil(try w.record(renames.ops[0].to))
            XCTAssertNil(try w.record(file.relative))
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
        }
    }

    // MARK: Catch-up: moves made before the NAS followed them

    private func owned(_ w: World, _ assignments: [PhotoEventAssignment]) -> Set<String> {
        NASCatchUp.ownedKeys(assignments: assignments, locations: w.locations)
    }

    func testCatchUpRenamesAMovedCopyFromItsVerifiedRecordInsteadOfCopying() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moved = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            _ = try seed(w, w.eventA, "IMG_0002.ARW", data(2))
            // The move happened earlier and nothing followed it on the NAS.
            _ = try moveOnDrive(w, moved, to: w.eventB)
            let bytesBefore = w.files(under: w.nas)
            let hashed = SyncLocked<[String]>([])

            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)
            let result = try w.follower().catchUp(
                plan: plan,
                ownedKeys: [],
                locations: w.locations,
                nasRoot: w.nas,
                hasher: { path in
                    hashed.mutate { $0.append(path) }
                    return try FileScanner.sha256(URL(fileURLWithPath: path))
                }
            )

            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertEqual(hashed.value.count, 1, "only the one candidate's drive file is hashed")
            XCTAssertEqual(w.files(under: w.nas).count, bytesBefore.count)
            let synced = try NASSyncService(store: w.store).sync(plan, nasRoot: w.nas)
            XCTAssertTrue(synced.copied.isEmpty, "\(synced)")
            XCTAssertEqual(synced.alreadyVerified.count, 2)
        }
    }

    func testCatchUpNeverTakesACopyThatAnAssignmentOrADriveFileStillOwns() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            // Event A's photo is on the NAS (verified at drive time 1000) and
            // still assigned, though its drive copy was taken off.
            let assigned = try seed(w, w.eventA, "IMG_0001.ARW", content, onDrive: false)
            let assignment = PhotoEventAssignment(
                sourceRootPath: "/Volumes/Card/DCIM",
                relativePath: "IMG_0001.ARW",
                fileSize: Int64(content.count),
                modifiedAt: Date(),
                eventID: w.eventA.id,
                deviceID: "sony-a7v"
            )
            // Event B holds a duplicate on the drive: same size, time, bytes.
            let duplicate = try seed(w, w.eventB, "IMG_0001.ARW", content, onNAS: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 1_000)], ofItemAtPath: duplicate.buffer.path)
            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)
            let records = try w.store.records(nasRoot: w.nas.path)

            // Without ownership A's copy would look abandoned.
            XCTAssertEqual(NASCatchUp.analyze(plan: plan, records: records, ownedKeys: [], locations: w.locations).candidates.count, 1)
            // The assignment owns it.
            let ownedByAssignment = owned(w, [assignment])
            XCTAssertEqual(ownedByAssignment, [NASSyncStore.pathKey(assigned.relative)])
            XCTAssertTrue(NASCatchUp.analyze(plan: plan, records: records, ownedKeys: ownedByAssignment, locations: w.locations).candidates.isEmpty)
            let result = try w.follower().catchUp(plan: plan, ownedKeys: ownedByAssignment, locations: w.locations, nasRoot: w.nas)
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assigned.nas.path))

            // So does a drive file at that very path, assignment or not.
            try writeFile(w.buffer.appendingPathComponent(assigned.relative), content)
            XCTAssertTrue(NASCatchUp.analyze(plan: plan, records: records, ownedKeys: [], locations: w.locations).candidates.isEmpty)
        }
    }

    func testCatchUpRequiresTheDriveFileToHashToTheRecordedContent() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let moved = try seed(w, w.eventA, "IMG_0001.ARW", data(1))
            let report = try moveOnDrive(w, moved, to: w.eventB)
            // The drive file has the same size and time but other bytes.
            let newURL = URL(fileURLWithPath: try XCTUnwrap(report.moved.first).destinationPath)
            let entry = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(newURL.path))
            try data(9).write(to: newURL)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: entry.modifiedAt)], ofItemAtPath: newURL.path)
            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)
            let result = try w.follower().catchUp(plan: plan, ownedKeys: [], locations: w.locations, nasRoot: w.nas)
            XCTAssertEqual(result.changed, 0, "different content: it is copied, not adopted")
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.nas.path))
        }
    }

    // MARK: Reconcile

    func testReconcileSetsAsideStaleDuplicatesOfFilesAlreadyAtTheirRightPath() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            // A move made earlier was re-copied by a sync: the NAS holds the
            // old path and the new one.
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", content, onDrive: false)
            let right = try seed(w, w.eventB, "IMG_0001.ARW", content)
            // A stale file with no counterpart is only reported by absence.
            let alone = try seed(w, w.eventA, "IMG_0500.ARW", data(5), onDrive: false)
            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)

            let analysis = NASCatchUp.analyze(plan: plan, records: try w.store.records(nasRoot: w.nas.path), ownedKeys: [], locations: w.locations)
            XCTAssertEqual(analysis.staleDuplicates.map(\.stale.relativePath), [stale.relative], "the counts the confirmation shows")

            let result = try w.follower().reconcile(plan: plan, ownedKeys: [], locations: w.locations, nasRoot: w.nas)

            XCTAssertEqual(result.merged, 1, result.summary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: right.nas.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.nas.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: alone.nas.path), "no identical file at a right path: untouched")
            XCTAssertEqual(staleFiles(w).count, 1)
            XCTAssertNil(try w.record(stale.relative))
            XCTAssertNotNil(try w.record(right.relative))
            // Running it again finds nothing.
            XCTAssertEqual(try w.follower().reconcile(plan: plan, ownedKeys: [], locations: w.locations, nasRoot: w.nas).changed, 0)
        }
    }

    /// An edit exported unchanged is byte-identical to its original but has
    /// no assignment by design: it is never a leftover of a move.
    func testReconcileNeverSetsAsideAnEditedFileIdenticalToItsOriginal() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            let original = try seed(w, w.eventA, "IMG_0001.ARW", content)
            let originals = original.relative.components(separatedBy: "/\(EventStorageLocations.originalsFolderName)/")[0]
            let edited = "\(originals)/\(EventStorageLocations.editedFolderName)/Picks/IMG_0001.ARW"
            try writeFile(w.nas.appendingPathComponent(edited), content)
            try w.store.upsert([NASSyncRecord(
                nasRoot: w.nas.path, relativePath: edited, eventID: w.eventA.id, byteCount: Int64(content.count),
                sourceModifiedAt: 1_000, sha256: sha(content), state: .verified,
                checkedAt: Date(timeIntervalSinceReferenceDate: 900_000_000), verifiedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
            )])
            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)

            let analysis = NASCatchUp.analyze(plan: plan, records: try w.store.records(nasRoot: w.nas.path), ownedKeys: [], locations: w.locations)
            XCTAssertTrue(analysis.staleDuplicates.isEmpty, "\(analysis.staleDuplicates.map(\.stale.relativePath))")
            let result = try w.follower().reconcile(plan: plan, ownedKeys: [], locations: w.locations, nasRoot: w.nas)
            XCTAssertEqual(result.changed, 0, result.summary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(edited).path))
            XCTAssertTrue(staleFiles(w).isEmpty)
        }
    }

    /// With the drive away nothing proves a NAS path is a leftover, so
    /// reconcile sets nothing aside — the Buffer is usually unplugged.
    func testReconcileSetsNothingAsideWhileTheDriveIsAway() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let content = data(1)
            let stale = try seed(w, w.eventA, "IMG_0001.ARW", content, onDrive: false)
            let right = try seed(w, w.eventB, "IMG_0001.ARW", content, onDrive: false)
            for folder in [w.locations.bufferRoot, w.locations.privateStagingRoot] {
                try? FileManager.default.removeItem(at: folder)
            }
            let plan = NASSyncPlanner.plan(events: w.configuration.savedEvents, locations: w.locations)
            let owned: Set<String> = [NASSyncStore.pathKey(right.relative)]

            let analysis = NASCatchUp.analyze(plan: plan, records: try w.store.records(nasRoot: w.nas.path), ownedKeys: owned, locations: w.locations)
            XCTAssertTrue(analysis.staleDuplicates.isEmpty)
            let result = try w.follower().reconcile(plan: plan, ownedKeys: owned, locations: w.locations, nasRoot: w.nas)
            XCTAssertEqual(result.changed, 0, result.summary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stale.nas.path), "kept until the drive can prove it is a leftover")
            XCTAssertTrue(staleFiles(w).isEmpty)
        }
    }

    // MARK: Listing and store

    func testTheListingFollowsRenamesAndFolderRenames() {
        var listing = NASTreeListing(root: "/nas", method: .smb)
        listing.cover("2026/2026-08-01 A", at: Date())
        listing.cover("2026/2026-08-02 B", at: Date())
        listing.insert("2026/2026-08-01 A/Originals/Cam/x.ARW", size: 10, modifiedAt: 5)
        listing.insert("2026/2026-08-01 A/Originals/Cam/y.ARW", size: 11, modifiedAt: 6)
        listing.recordRenamed(from: "2026/2026-08-01 A/Originals/Cam/x.ARW", to: "2026/2026-08-02 B/Originals/Cam/x.ARW")
        XCTAssertNil(listing.entry("2026/2026-08-01 A/Originals/Cam/x.ARW"))
        XCTAssertEqual(listing.entry("2026/2026-08-02 B/Originals/Cam/x.ARW")?.size, 10)

        listing.recordFolderRenamed(from: "2026/2026-08-01 A", to: "2027/2027-01-01 A2")
        XCTAssertEqual(listing.entry("2027/2027-01-01 A2/Originals/Cam/y.ARW")?.size, 11)
        XCTAssertNil(listing.entry("2026/2026-08-01 A/Originals/Cam/y.ARW"))
        XCTAssertTrue(listing.covers("2027/2027-01-01 A2/Originals/Cam/anything.ARW"))
        XCTAssertFalse(listing.covers("2026/2026-08-01 A/Originals/Cam/anything.ARW"))

        listing.recordRemoved("2026/2026-08-02 B/Originals/Cam/x.ARW")
        XCTAssertNil(listing.entry("2026/2026-08-02 B/Originals/Cam/x.ARW"))
    }

    func testRecordMovesKeepTheExistingRecordWhenTheNewPathIsTheIdenticalFile() throws {
        try withTemporaryDirectory { root in
            let store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
            func record(_ path: String, hash: String) -> NASSyncRecord {
                NASSyncRecord(nasRoot: "/nas", relativePath: path, byteCount: 5, sourceModifiedAt: 1, sha256: hash, state: .verified, checkedAt: Date(), verifiedAt: Date())
            }
            try store.upsert([record("a/x", hash: "h1"), record("b/x", hash: "h1"), record("a/y", hash: "h2"), record("b/y", hash: "other")])
            XCTAssertEqual(try store.relocate(nasRoot: "/nas", [.init(from: "a/x", to: "b/x", replaceExisting: false), .init(from: "a/y", to: "b/y")]), 1)
            let records = try store.records(nasRoot: "/nas")
            XCTAssertNil(records["a/x"])
            XCTAssertEqual(records["b/x"]?.sha256, "h1")
            XCTAssertEqual(records["b/y"]?.sha256, "h2", "a rename that succeeded replaces whatever stale record was at the new path")
            XCTAssertEqual(try store.records(nasRoot: "/nas", pathKeys: ["b/x", "nope"]).keys.sorted(), ["b/x"])
        }
    }
}
