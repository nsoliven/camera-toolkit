@testable import CameraToolkitCore
import CryptoKit
import Darwin
import Foundation
import XCTest

final class SyncLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// The parallel, unflushed copy engine and its two verification modes.
final class NASFastSyncTests: XCTestCase {
    override func tearDown() {
        NASFileIO.verificationHashOverride = nil
        NASFileIO.renameExclusivePrimitive = nil
        NASFileIO.copyCallObserver = nil
        super.tearDown()
    }

    private struct Fixture {
        var drive: URL
        var nas: URL
        var server: URL
        var plan: NASSyncPlan
        var contents: [String: Data]
    }

    /// `count` drive files under `drive/Event/…`, a NAS folder, and a
    /// "server" path that is a symlink to it (the NAS's own view of the
    /// share, for the prefix mapping).
    private func fixture(_ root: URL, count: Int = 7) throws -> Fixture {
        let drive = root.appendingPathComponent("Drive")
        let nas = root.appendingPathComponent("NAS")
        let server = root.appendingPathComponent("Server")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: server, withDestinationURL: nas)
        var items: [NASSyncItem] = []
        var contents: [String: Data] = [:]
        for index in 0..<count {
            let relative = "2026/Event/Originals/Cam \(index % 2)/IMG_\(index)'s copy.ARW"
            let data = Data((0..<(1_000 + index * 37)).map { UInt8(($0 * (index + 3)) & 0xFF) })
            let url = try writeFile(drive.appendingPathComponent(relative), data)
            let entry = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(url.path))
            items.append(NASSyncItem(sourcePath: url.path, relativePath: relative, byteCount: Int64(data.count), modifiedAt: entry.modifiedAt, eventID: nil))
            contents[relative] = data
        }
        return Fixture(drive: drive, nas: nas, server: server, plan: NASSyncPlan(items: items), contents: contents)
    }

    /// Runs the remote command with the local `/bin/sh`, with a `sync` stub
    /// on PATH that logs each call (a real `sync` would flush this Mac).
    private func localTransport(_ root: URL, syncLog: URL, rewrite: (@Sendable (Data) -> Data)? = nil, before: (@Sendable () -> Void)? = nil) throws -> NASRemoteVerifier.Transport {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("sync")
        try "#!/bin/sh\necho \"sync $*\" >> '\(syncLog.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        return { command in
            before?()
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
            return .init(status: process.terminationStatus, stdout: rewrite?(data) ?? data, stderr: Data())
        }
    }

    private func assertAllCopied(_ f: Fixture, _ report: NASSyncReport, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(report.succeeded, "\(report)", file: file, line: line)
        XCTAssertEqual(Set(report.copied), Set(f.contents.keys), file: file, line: line)
        for (relative, data) in f.contents {
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(relative)), data, relative, file: file, line: line)
        }
        let leftovers = LayoutMigrationDisk.walk(f.nas.path, fileManager: .default).filter { $0.name.contains(NASSyncPlanner.temporaryMarker) }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)", file: file, line: line)
    }

    // MARK: No flush

    func testTheSyncCopyPathIssuesNoFlushAndNoUncachedWrite() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let calls = SyncLocked<[String]>([])
            NASFileIO.copyCallObserver = { call in calls.mutate { $0.append(call) } }
            let report = try NASSyncService(store: nil).sync(f.plan, nasRoot: f.nas)
            try assertAllCopied(f, report)
            XCTAssertFalse(calls.value.contains("F_FULLFSYNC"))
            XCTAssertFalse(calls.value.contains("fsync"))
            XCTAssertFalse(calls.value.contains("F_NOCACHE destination"))
            XCTAssertEqual(report.timings.flushSeconds, 0)
            XCTAssertFalse(report.timings.flushEachFile)
            XCTAssertEqual(report.timings.parallelTransfers, NASSyncOptions.defaultParallelTransfers)

            // The legacy engine, kept for benchmarks, flushes every file.
            let legacyNAS = root.appendingPathComponent("NAS2")
            try FileManager.default.createDirectory(at: legacyNAS, withIntermediateDirectories: true)
            calls.mutate { $0 = [] }
            let legacy = try NASSyncService(store: nil, options: .legacy).sync(f.plan, nasRoot: legacyNAS)
            XCTAssertTrue(legacy.succeeded)
            XCTAssertEqual(calls.value.filter { $0 == "fsync" }.count, f.plan.items.count)
            XCTAssertEqual(calls.value.filter { $0 == "F_FULLFSYNC" }.count, f.plan.items.count)
            XCTAssertEqual(calls.value.filter { $0 == "F_NOCACHE destination" }.count, f.plan.items.count)
            XCTAssertEqual(legacy.timings.parallelTransfers, 1)
        }
    }

    // MARK: Concurrency bound

    func testTheTransferPoolNeverRunsMoreThanItsWidth() {
        for width in [1, 3, 8] {
            let pool = NASTransferPool(width: width)
            let state = SyncLocked((running: 0, peak: 0, done: 0))
            for _ in 0..<(width * 4 + 3) {
                pool.acquire(tick: {})
                pool.submitAcquired {
                    state.mutate { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                    usleep(20_000)
                    state.mutate { $0.running -= 1; $0.done += 1 }
                }
            }
            pool.waitForAll(tick: {})
            XCTAssertEqual(state.value.done, width * 4 + 3)
            XCTAssertLessThanOrEqual(state.value.peak, width)
            if width > 1 { XCTAssertGreaterThan(state.value.peak, 1, "width \(width) never ran in parallel") }
        }
    }

    func testASyncRunsAtMostParallelTransfersFilesAtOnce() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 9)
            let state = SyncLocked((running: 0, peak: 0))
            // The SMB re-read runs inside each transfer; slow it down so
            // transfers overlap.
            NASFileIO.verificationHashOverride = { _ in
                state.mutate { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                usleep(60_000)
                state.mutate { $0.running -= 1 }
                return nil
            }
            XCTAssertEqual(NASSyncOptions(parallelTransfers: 0).parallelTransfers, 1)
            XCTAssertEqual(NASSyncOptions(parallelTransfers: 99).parallelTransfers, 8)
            let report = try NASSyncService(store: nil, options: NASSyncOptions(parallelTransfers: 3)).sync(f.plan, nasRoot: f.nas)
            try assertAllCopied(f, report)
            XCTAssertLessThanOrEqual(state.value.peak, 3)
            XCTAssertGreaterThan(state.value.peak, 1)
        }
    }

    // MARK: NAS-side verification

    func testNASSideVerificationHashesEachBatchOnTheServerAfterOneSync() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 7)
            let syncLog = root.appendingPathComponent("sync.log")
            let verifier = NASRemoteVerifier(localPrefix: f.nas.path + "/", serverPrefix: f.server.path, label: "test", transport: try localTransport(root, syncLog: syncLog))
            let smbReads = SyncLocked(0)
            NASFileIO.verificationHashOverride = { _ in smbReads.mutate { $0 += 1 }; return nil }
            let store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
            let options = NASSyncOptions(parallelTransfers: 4, remoteVerifier: verifier, remoteBatchFiles: 3)
            let report = try NASSyncService(store: store, options: options).sync(f.plan, nasRoot: f.nas)
            try assertAllCopied(f, report)
            // Nothing was re-read over SMB; 7 files in batches of 3.
            XCTAssertEqual(smbReads.value, 0)
            XCTAssertEqual(report.timings.remoteBatches, 3)
            XCTAssertEqual(report.timings.remoteFallbacks, 0)
            XCTAssertEqual(report.timings.remoteVerifyBytes, f.plan.totalBytes)
            XCTAssertEqual(report.timings.smbVerifyBytes, 0)
            XCTAssertTrue(report.timings.verification.contains("NAS SHA-256"))
            // One sync per batch, on the server's paths — never per file.
            let syncs = try String(contentsOf: syncLog, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(syncs.count, 3)
            XCTAssertTrue(syncs.allSatisfy { $0.hasPrefix("sync -f -- \(f.server.path)/") })
            let records = try store.records(nasRoot: f.nas.path)
            XCTAssertEqual(records.count, f.plan.items.count)
            XCTAssertTrue(records.values.allSatisfy { $0.state == .verified && $0.sha256?.count == 64 })

            // Resume: a second run hashes nothing, locally or remotely.
            let again = try NASSyncService(store: store, options: options).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(again.alreadyVerified.count, f.plan.items.count)
            XCTAssertEqual(again.timings.remoteBatches, 0)
            XCTAssertEqual(try String(contentsOf: syncLog, encoding: .utf8).split(separator: "\n").count, 3)
        }
    }

    func testANASSideMismatchFailsOnlyThatFileRemovesItsTemporaryAndIsRetried() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 5)
            let bad = try XCTUnwrap(f.plan.items.first { $0.relativePath.contains("IMG_2") })
            let badName = "." + (bad.relativePath as NSString).lastPathComponent
            // The NAS reports a different hash for one file (a flaky pool).
            let rewrite: @Sendable (Data) -> Data = { data in
                let records = data.split(separator: 0).map { record -> Data in
                    let line = String(decoding: record, as: UTF8.self)
                    guard line.contains(badName) else { return Data(record) }
                    return Data((String(repeating: "0", count: 64) + line.dropFirst(64)).utf8)
                }
                return records.reduce(into: Data()) { $0.append($1); $0.append(0) }
            }
            let syncLog = root.appendingPathComponent("sync.log")
            let verifier = NASRemoteVerifier(localPrefix: f.nas.path, serverPrefix: f.server.path, label: "test", transport: try localTransport(root, syncLog: syncLog, rewrite: rewrite))
            let store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
            let report = try NASSyncService(store: store, options: NASSyncOptions(remoteVerifier: verifier)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(report.failed.map(\.path), [bad.relativePath])
            XCTAssertEqual(report.hashMismatches.map(\.path), [bad.relativePath])
            XCTAssertTrue(report.hashMismatches[0].reason.contains("MISMATCH"))
            XCTAssertEqual(report.copied.count, f.plan.items.count - 1)
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(bad.relativePath).path))
            let folder = f.nas.appendingPathComponent(bad.relativePath).deletingLastPathComponent().path
            XCTAssertTrue(LayoutMigrationDisk.names(in: folder, fileManager: .default).allSatisfy { !$0.contains(NASSyncPlanner.temporaryMarker) })
            XCTAssertEqual(try store.records(nasRoot: f.nas.path)[NASSyncStore.pathKey(bad.relativePath)]?.state, .failed)
            // The drive copy is untouched.
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bad.sourcePath)), f.contents[bad.relativePath])

            // The next run (NAS healthy) copies only that file again.
            let healthy = NASRemoteVerifier(localPrefix: f.nas.path, serverPrefix: f.server.path, label: "test", transport: try localTransport(root, syncLog: syncLog))
            let retry = try NASSyncService(store: store, options: NASSyncOptions(remoteVerifier: healthy)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(retry.copied, [bad.relativePath])
            XCTAssertTrue(retry.succeeded)
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(bad.relativePath)), f.contents[bad.relativePath])
        }
    }

    func testAnSMBReReadMismatchIsReportedAsAHashMismatch() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 4)
            let bad = try XCTUnwrap(f.plan.items.first)
            let badName = "." + (bad.relativePath as NSString).lastPathComponent
            NASFileIO.verificationHashOverride = { path in
                (path as NSString).lastPathComponent.hasPrefix(badName) ? String(repeating: "f", count: 64) : nil
            }
            let report = try NASSyncService(store: nil).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(report.hashMismatches.map(\.path), [bad.relativePath])
            XCTAssertEqual(report.copied.count, 3)
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(bad.relativePath).path))
        }
    }

    func testWhenTheNASCannotHashAFileItIsVerifiedOverSMBInstead() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 4)
            let smbReads = SyncLocked(0)
            NASFileIO.verificationHashOverride = { _ in smbReads.mutate { $0 += 1 }; return nil }
            // SSH itself fails (host down, key refused).
            let down = NASRemoteVerifier(localPrefix: f.nas.path, serverPrefix: f.server.path, label: "down") { _ in
                .init(status: 255, stdout: Data(), stderr: Data("ssh: connect to host nas port 22: Connection refused".utf8))
            }
            let report = try NASSyncService(store: nil, options: NASSyncOptions(remoteVerifier: down)).sync(f.plan, nasRoot: f.nas)
            try assertAllCopied(f, report)
            XCTAssertEqual(smbReads.value, 4)
            XCTAssertEqual(report.timings.remoteFallbacks, 4)
            XCTAssertTrue(report.timings.remoteFallbackReason?.contains("Connection refused") == true)

            // A wrong server path: sha256sum finds nothing, same fallback.
            let other = root.appendingPathComponent("NAS-b")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            smbReads.mutate { $0 = 0 }
            let wrong = NASRemoteVerifier(localPrefix: other.path, serverPrefix: root.appendingPathComponent("nowhere").path, label: "wrong", transport: try localTransport(root, syncLog: root.appendingPathComponent("s.log")))
            let second = try NASSyncService(store: nil, options: NASSyncOptions(remoteVerifier: wrong)).sync(f.plan, nasRoot: other)
            XCTAssertTrue(second.succeeded)
            XCTAssertEqual(smbReads.value, 4)
            XCTAssertEqual(second.timings.remoteFallbacks, 4)
        }
    }

    // MARK: Never overwrite

    func testAFileThatAppearsAtTheNASPathDuringVerificationIsNeverOverwritten() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 3)
            let target = try XCTUnwrap(f.plan.items.first)
            let intruder = f.nas.appendingPathComponent(target.relativePath)
            let intruderData = Data("someone else's file".utf8)
            // Between the copy and the rename, another writer creates the
            // final file.
            let verifier = NASRemoteVerifier(localPrefix: f.nas.path, serverPrefix: f.server.path, label: "test", transport: try localTransport(root, syncLog: root.appendingPathComponent("s.log"), before: {
                if LayoutMigrationDisk.lstatEntry(intruder.path) == nil { try? intruderData.write(to: intruder) }
            }))
            let report = try NASSyncService(store: nil, options: NASSyncOptions(remoteVerifier: verifier, remoteBatchFiles: 8)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(report.conflicts.map(\.path), [target.relativePath])
            XCTAssertEqual(try Data(contentsOf: intruder), intruderData)
            XCTAssertEqual(report.copied.count, 2)
            XCTAssertTrue(LayoutMigrationDisk.walk(f.nas.path, fileManager: .default).allSatisfy { !$0.name.contains(NASSyncPlanner.temporaryMarker) })
        }
    }

    func testParallelSyncNeverTouchesExistingFilesAndResumesAfterAStop() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 8)
            let existing = try XCTUnwrap(f.plan.items.last)
            try writeFile(f.nas.appendingPathComponent(existing.relativePath), Data("different".utf8))
            let store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
            var checks = 0
            let first = try NASSyncService(store: store, options: NASSyncOptions(parallelTransfers: 4), isCancelled: {
                checks += 1
                return checks > 3
            }).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(first.copied.count, 3)
            XCTAssertEqual(first.conflicts.map(\.path), [existing.relativePath])
            XCTAssertEqual(first.notAttempted, f.plan.items.count - 1 - 3)
            XCTAssertNotNil(first.stoppedReason)

            let second = try NASSyncService(store: store, options: NASSyncOptions(parallelTransfers: 4)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(Set(second.alreadyVerified), Set(first.copied))
            XCTAssertEqual(second.copied.count, f.plan.items.count - 1 - 3)
            XCTAssertEqual(second.conflicts.map(\.path), [existing.relativePath])
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(existing.relativePath)), Data("different".utf8))
        }
    }

    // MARK: Command, parsing, settings

    func testTheRemoteCommandQuotesEveryPathAndParsesZeroTerminatedOutput() throws {
        let paths = ["/mnt/p/d/2026/It's here/.a b.ARW.ctsync-1234ABCD", "/mnt/p/d/2026/x/$(rm -rf).JPG"]
        let command = NASRemoteVerifier.command(serverPaths: paths)
        XCTAssertTrue(command.contains("'/mnt/p/d/2026/It'\\''s here/.a b.ARW.ctsync-1234ABCD'"))
        XCTAssertTrue(command.contains("'/mnt/p/d/2026/x/$(rm -rf).JPG'"))
        XCTAssertTrue(command.hasPrefix("sync -f -- "))
        XCTAssertTrue(command.contains("sha256sum -z -- "))

        let hash = String(repeating: "ab", count: 32)
        var output = Data("\(hash)  \(paths[0])".utf8)
        output.append(0)
        output.append(Data("\(hash.uppercased()) *\(paths[1])".utf8))
        output.append(0)
        output.append(Data("garbage".utf8))
        output.append(0)
        XCTAssertEqual(NASRemoteVerifier.parse(output), [paths[0]: hash, paths[1]: hash])

        let verifier = NASRemoteVerifier(localPrefix: "/Volumes/share/", serverPrefix: "/mnt/pool/ds/", label: "x") { _ in .init(status: 0, stdout: Data(), stderr: Data()) }
        XCTAssertEqual(verifier.serverPath(for: "/Volumes/share/a/b"), "/mnt/pool/ds/a/b")
        XCTAssertNil(verifier.serverPath(for: "/Volumes/shared/a"))
        XCTAssertNil(verifier.serverPath(for: "/Volumes/other/a"))
    }

    func testSettingsRoundTripAndOnlyEnableSSHVerificationWhenComplete() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            XCTAssertEqual(configuration.nasSyncParallelTransfers, 4)
            XCTAssertFalse(configuration.nasSyncVerifyViaSSH)
            configuration.nasSyncParallelTransfers = 6
            configuration.nasSyncVerifyViaSSH = true
            configuration.nasSyncSSHHost = "nas"
            configuration.nasSyncSSHServerPath = "/mnt/pool/ds"
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(decoded.nasSyncParallelTransfers, 6)
            XCTAssertTrue(decoded.nasSyncVerifyViaSSH)
            XCTAssertEqual(decoded.nasSyncSSHHost, "nas")
            XCTAssertEqual(decoded.nasSyncSSHServerPath, "/mnt/pool/ds")

            // An older file has none of the keys: defaults.
            let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8))
            XCTAssertEqual(legacy.nasSyncParallelTransfers, 4)
            XCTAssertFalse(legacy.nasSyncVerifyViaSSH)

            let options = NASSyncOptions.from(configuration: decoded, nasRoot: root)
            XCTAssertEqual(options.parallelTransfers, 6)
            // `root` is on the boot volume, whose mount point is "/": no mapping.
            XCTAssertNil(options.remoteVerifier)
            var incomplete = decoded
            incomplete.nasSyncSSHServerPath = ""
            XCTAssertNil(NASSyncOptions.from(configuration: incomplete, nasRoot: root).remoteVerifier)
        }
    }
}
