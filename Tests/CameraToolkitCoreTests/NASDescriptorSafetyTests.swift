@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// "Could not close …: Bad file descriptor" — the descriptor a copy opened
/// was not open at `close()`. These tests pin down what the copy does about
/// it (never closes a number that is not its own, never writes through one,
/// retries the file once from a fresh open and verifies it) and stress the
/// copy pool next to everything else in the process that owns descriptors.
final class NASDescriptorSafetyTests: XCTestCase {
    override func tearDown() {
        NASFileIO.closePrimitive = nil
        NASFileIO.copyCallObserver = nil
        NASFileIO.verificationHashOverride = nil
        super.tearDown()
    }

    private struct Fixture {
        var drive: URL
        var nas: URL
        var server: URL
        var plan: NASSyncPlan
        var contents: [String: Data]
    }

    private func fixture(_ root: URL, count: Int, bytes: (Int) -> Int = { 1_000 + $0 * 37 }) throws -> Fixture {
        let drive = root.appendingPathComponent("Drive")
        let nas = root.appendingPathComponent("NAS")
        let server = root.appendingPathComponent("Server")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: server, withDestinationURL: nas)
        var items: [NASSyncItem] = []
        var contents: [String: Data] = [:]
        for index in 0..<count {
            let relative = "2026/Event/Originals/Cam \(index % 3)/DSC\(String(format: "%05d", index)).ARW"
            let data = Data((0..<bytes(index)).map { UInt8(($0 &* (index &+ 3) &+ index) & 0xFF) })
            let url = try writeFile(drive.appendingPathComponent(relative), data)
            let entry = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(url.path))
            items.append(NASSyncItem(sourcePath: url.path, relativePath: relative, byteCount: Int64(data.count), modifiedAt: entry.modifiedAt, eventID: nil))
            contents[relative] = data
        }
        return Fixture(drive: drive, nas: nas, server: server, plan: NASSyncPlan(items: items), contents: contents)
    }

    private func temporaries(in nas: URL) -> [String] {
        LayoutMigrationDisk.walk(nas.path, fileManager: .default).map(\.name).filter { $0.contains(NASSyncPlanner.temporaryMarker) }
    }

    private func assertAllCopied(_ f: Fixture, _ report: NASSyncReport, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(report.succeeded, "\(report)", file: file, line: line)
        XCTAssertEqual(Set(report.copied), Set(f.contents.keys), file: file, line: line)
        for (relative, data) in f.contents {
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(relative)), data, relative, file: file, line: line)
        }
        XCTAssertEqual(temporaries(in: f.nas), [], file: file, line: line)
    }

    /// Makes the next `failures` closes fail the way smbfs does: the
    /// descriptor is gone and `close` answers `code`.
    private func failCloses(_ failures: Int, with code: Int32) -> SyncLocked<Int> {
        let remaining = SyncLocked(failures)
        NASFileIO.closePrimitive = { descriptor in
            let fail = remaining.mutateReturning { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            guard fail else { return Darwin.close(descriptor) }
            _ = Darwin.close(descriptor)
            errno = code
            return -1
        }
        return remaining
    }

    // MARK: Retry

    func testACloseThatFailsWithBadFileDescriptorIsRetriedOnceAndVerified() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 6)
            _ = failCloses(3, with: EBADF)
            let options = NASSyncOptions(parallelTransfers: 4, retryDelay: 0.01)
            let report = try NASSyncService(store: nil, options: options).sync(f.plan, nasRoot: f.nas)
            try assertAllCopied(f, report)
            XCTAssertEqual(report.retried.count, 3)
            XCTAssertEqual(report.timings.transientRetries, 3)
            XCTAssertTrue(report.retried.allSatisfy { $0.reason.contains("Bad file descriptor") && $0.reason.contains("copied again") })
            XCTAssertTrue(report.failed.isEmpty)
            XCTAssertEqual(report.bytesCopied, f.plan.totalBytes)
        }
    }

    func testARetriedCopyIsStillHashedBeforeItsRenameAndAWrongOneNeverLandsUnderTheRealName() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 1)
            _ = failCloses(1, with: EBADF)
            // The second attempt's re-read is corrupted: it must not be placed.
            NASFileIO.verificationHashOverride = { _ in String(repeating: "0", count: 64) }
            let report = try NASSyncService(store: nil, options: NASSyncOptions(retryDelay: 0.01)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(report.retried.count, 1)
            XCTAssertEqual(report.hashMismatches.count, 1)
            XCTAssertTrue(report.copied.isEmpty)
            let item = try XCTUnwrap(f.plan.items.first)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.nas.appendingPathComponent(item.relativePath).path))
            XCTAssertEqual(temporaries(in: f.nas), [])
        }
    }

    func testACopyThatFailsTwiceIsReportedFailedWithNoTemporaryLeft() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 2)
            _ = failCloses(Int.max, with: EBADF)
            let report = try NASSyncService(store: nil, options: NASSyncOptions(retryDelay: 0.01)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(Set(report.failed.map(\.path)), Set(f.contents.keys))
            XCTAssertTrue(report.failed.allSatisfy { $0.reason.contains("Bad file descriptor") && $0.reason.contains("retried once") })
            XCTAssertEqual(report.retried.count, 2, "one retry each, never a second")
            XCTAssertTrue(report.copied.isEmpty)
            XCTAssertEqual(temporaries(in: f.nas), [])
            for relative in f.contents.keys {
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.nas.appendingPathComponent(relative).path))
            }
        }
    }

    func testAnErrorThatIsNotTransientIsNotRetried() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 1)
            _ = failCloses(Int.max, with: ENOSPC)
            let report = try NASSyncService(store: nil, options: NASSyncOptions(retryDelay: 0.01)).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(report.failed.count, 1)
            XCTAssertTrue(report.retried.isEmpty)
            XCTAssertNil(report.timings.transientRetries)
            XCTAssertEqual(temporaries(in: f.nas), [])
        }
    }

    func testReportsWrittenBeforeRetriesExistedStillDecode() throws {
        let old = #"{"copied":["a"],"matchedExisting":[],"alreadyVerified":[],"conflicts":[],"failed":[],"notAttempted":0,"bytesCopied":1,"foldersCreated":0,"hashMismatches":[],"timings":{"parallelTransfers":4,"verification":"","flushEachFile":false,"wallSeconds":1,"checkSeconds":0,"copySeconds":0,"flushSeconds":0,"verifySeconds":0,"renameSeconds":0,"copyBytes":0,"smbVerifyBytes":0,"remoteVerifyBytes":0,"remoteBatches":0,"remoteFallbacks":0}}"#
        let report = try JSONDecoder().decode(NASSyncReport.self, from: Data(old.utf8))
        XCTAssertEqual(report.copied, ["a"])
        XCTAssertTrue(report.retried.isEmpty)
        XCTAssertNil(report.timings.transientRetries)
        let again = try JSONDecoder().decode(NASSyncReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(again, report)
    }

    // MARK: Descriptor ownership

    /// Finds the descriptor of `path` the way `copyNew` sees it.
    private func descriptor(naming name: String) -> Int32? {
        (3..<Int(getdtablesize())).map(Int32.init).first { NASFileIO.path(of: $0).map { ($0 as NSString).lastPathComponent == name } == true }
    }

    func testADescriptorClosedBehindTheCopyIsDetectedNeverClosedAgainAndNothingIsWrittenElsewhere() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("source.bin"), Data(repeating: 0xAB, count: 9 * 1024 * 1024))
            let destination = root.appendingPathComponent(".source.bin.ctsync-TESTTEST")
            let victimURL = try writeFile(root.appendingPathComponent("victim.bin"), "precious")
            let events = SyncLocked<[String]>([])
            NASFileIO.copyCallObserver = { call in events.mutate { $0.append(call) } }

            var victim: Int32 = -1
            var stolen: Int32 = -1
            var chunks = 0
            XCTAssertThrowsError(try NASFileIO.copyNew(
                from: source.path, to: destination.path, expectedByteCount: 9 * 1024 * 1024,
                progress: { _ in
                    chunks += 1
                    guard chunks == 1 else { return }
                    // Somebody else closes this copy's output descriptor
                    // and their next open gets the same number.
                    stolen = self.descriptor(naming: destination.lastPathComponent) ?? -1
                    XCTAssertGreaterThan(stolen, 2)
                    Darwin.close(stolen)
                    victim = Darwin.open(victimURL.path, O_RDWR)
                }
            )) { error in
                guard let transient = error as? NASFileIO.TransientIOError else { return XCTFail("\(error)") }
                XCTAssertEqual(transient.code, EBADF)
                XCTAssertTrue(transient.detail?.contains("now names another file") == true, "\(transient)")
            }
            defer { if victim >= 0 { Darwin.close(victim) } }
            guard victim == stolen else { throw XCTSkip("The descriptor number was not reused (\(victim) vs \(stolen)).") }
            XCTAssertEqual(chunks, 1, "the next chunk was never written")
            XCTAssertTrue(events.value.contains { $0.hasPrefix("descriptor lost") })
            // The other file's descriptor is still open, untouched and unwritten.
            XCTAssertNotEqual(fcntl(victim, F_GETFD), -1, "copyNew closed a descriptor that was not its own")
            XCTAssertEqual(try String(contentsOf: victimURL, encoding: .utf8), "precious")
        }
    }

    func testADescriptorThatIsNotOpenAnymoreIsNotClosedEither() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("source.bin"), Data(repeating: 1, count: 9 * 1024 * 1024))
            let destination = root.appendingPathComponent(".source.bin.ctsync-TESTTEST")
            var chunks = 0
            var closedNumber: Int32 = -1
            XCTAssertThrowsError(try NASFileIO.copyNew(
                from: source.path, to: destination.path, expectedByteCount: 9 * 1024 * 1024,
                progress: { _ in
                    chunks += 1
                    guard chunks == 1 else { return }
                    closedNumber = self.descriptor(naming: destination.lastPathComponent) ?? -1
                    Darwin.close(closedNumber)
                }
            )) { error in
                XCTAssertTrue((error as? NASFileIO.TransientIOError)?.detail?.contains("is not open") == true, "\(error)")
            }
            XCTAssertGreaterThan(closedNumber, 2)
            XCTAssertEqual(chunks, 1, "nothing was written after the descriptor was lost")
        }
    }

    // MARK: Descriptor hygiene of the process helpers

    /// Foundation keeps a `Pipe`'s read ends open until the autorelease pool
    /// that holds them drains. On a thread that never drains one (a detached
    /// task, a long-lived worker) that is two descriptors per process, held
    /// for good — so the helpers close them themselves.
    func testProcessHelpersLeaveNoDescriptorOpenEvenWithoutAnAutoreleasePoolDraining() throws {
        let finished = DispatchSemaphore(value: 0)
        let result = SyncLocked<(before: Int, after: Int)>((0, 0))
        Thread.detachNewThread {
            let before = self.openDescriptorCount()
            for _ in 0..<40 {
                _ = try? NASRemoteVerifier.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"], timeout: 30)
                _ = try? NASRemoteShell.stream(executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"], timeout: 30) { _ in true }
            }
            result.mutate { $0 = (before, self.openDescriptorCount()) }
            finished.signal()
        }
        finished.wait()
        XCTAssertEqual(result.value.after, result.value.before, "80 process runs left descriptors open")
    }

    func testAProcessThatTimesOutLeavesNoDescriptorOpenEither() throws {
        let before = openDescriptorCount()
        XCTAssertThrowsError(try NASRemoteVerifier.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3))
        XCTAssertLessThanOrEqual(openDescriptorCount(), before)
    }

    func testEveryDescriptorTheSyncPathOpensIsCloseOnExec() throws {
        try withTemporaryDirectory { root in
            let file = try writeFile(root.appendingPathComponent("a"), "a")
            let descriptor = try NASFileIO.open(file.path, O_RDONLY)
            defer { Darwin.close(descriptor) }
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        }
    }

    // MARK: Stress

    /// A local `/bin/sh` standing in for the NAS's shell, with a `sync` stub.
    private func localTransport(_ root: URL) throws -> NASRemoteVerifier.Transport {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("sync")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        return { command in
            try NASRemoteVerifier.run(executable: "/bin/sh", arguments: ["-c", command], environment: ["PATH": "\(bin.path):/usr/bin:/bin:/sbin"], timeout: 60)
        }
    }

    private func openDescriptorCount() -> Int {
        (0..<Int(getdtablesize())).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    /// The real copy pool, the NAS-side verifier and per-file NAS hashes
    /// (Process + Pipe), the lister's streaming shell, connection-probe
    /// style commands, directory listings and drive scans — all at once,
    /// several rounds. No copy may lose its descriptor, no file may land
    /// with another file's bytes, and no descriptor may leak.
    func testTheCopyPoolNextToHeavyProcessSpawningAndOtherDescriptorUsersNeverLosesADescriptor() throws {
        let rounds = 4
        let filesPerRound = 90
        let baseline = openDescriptorCount()
        for round in 0..<rounds {
            try withTemporaryDirectory { root in
                let f = try fixture(root, count: filesPerRound) { 40_000 + (($0 * 7_919) % 600_000) }
                // A third are already on the NAS: those take the compare
                // path, which spawns one hash process per file, in the pool.
                for item in f.plan.items.enumerated() where item.offset % 3 == 0 {
                    try writeFile(f.nas.appendingPathComponent(item.element.relativePath), try XCTUnwrap(f.contents[item.element.relativePath]))
                }
                let verifier = NASRemoteVerifier(localPrefix: f.nas.path, serverPrefix: f.server.path, label: "local sh", transport: try localTransport(root))
                let events = SyncLocked<[String]>([])
                NASFileIO.copyCallObserver = { call in if call.hasPrefix("descriptor lost") { events.mutate { $0.append(call) } } }

                let stop = SyncLocked(false)
                let noise = DispatchGroup()
                let failures = SyncLocked<[String]>([])
                func spin(_ name: String, _ body: @escaping @Sendable (Int) throws -> Void) {
                    noise.enter()
                    Thread.detachNewThread {
                        var iteration = 0
                        while !stop.value {
                            do { try body(iteration) } catch { failures.mutate { $0.append("\(name): \(error)") } }
                            iteration += 1
                        }
                        noise.leave()
                    }
                }
                let nasPath = f.nas.path
                let drivePath = f.drive.path
                // Probe-style commands (smbutil/netstat/ifconfig go through this).
                for name in ["probe-a", "probe-b"] {
                    spin(name) { _ in
                        let result = try NASRemoteVerifier.run(executable: "/bin/sh", arguments: ["-c", "echo ok; echo err 1>&2"], timeout: 30)
                        if result.status != 0 || String(decoding: result.stdout, as: UTF8.self) != "ok\n" { throw ToolkitError.commandFailed("probe answered \(result.status)") }
                    }
                }
                // The presence lister's streaming shell.
                spin("lister") { _ in
                    var received = 0
                    let result = try NASRemoteShell.stream(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 200 ]; do echo line $i; i=$((i+1)); done"], timeout: 30) { data in
                        received += data.count
                        return true
                    }
                    if result.status != 0 || received == 0 { throw ToolkitError.commandFailed("lister answered \(result.status)") }
                }
                // Directory listings (getattrlistbulk) of the folders being written.
                spin("listing") { _ in
                    _ = try DirectoryListing.list(nasPath)
                    for cam in 0..<3 { _ = try? DirectoryListing.list(nasPath + "/2026/Event/Originals/Cam \(cam)") }
                }
                // Drive scans (streaming reads with their own descriptors).
                spin("scan") { iteration in
                    let files = LayoutMigrationDisk.walk(drivePath, fileManager: .default).filter { $0.kind == .file }
                    if let file = files.dropFirst(iteration % max(files.count, 1)).first {
                        try StreamingFileIO.readChunks(from: URL(fileURLWithPath: file.path), chunkSize: 64 * 1024) { _ in }
                    }
                }

                let options = NASSyncOptions(parallelTransfers: 4, remoteVerifier: verifier, remoteBatchFiles: 8, retryDelay: 0.01)
                let report: NASSyncReport
                do {
                    report = try NASSyncService(store: nil, options: options).sync(f.plan, nasRoot: f.nas)
                } catch {
                    stop.mutate { $0 = true }
                    noise.wait()
                    throw error
                }
                stop.mutate { $0 = true }
                noise.wait()
                NASFileIO.copyCallObserver = nil

                XCTAssertEqual(failures.value, [], "round \(round)")
                XCTAssertEqual(events.value, [], "round \(round): a copy lost a descriptor")
                XCTAssertTrue(report.failed.isEmpty, "round \(round): \(report.failed)")
                XCTAssertTrue(report.retried.isEmpty, "round \(round): \(report.retried)")
                XCTAssertTrue(report.conflicts.isEmpty && report.hashMismatches.isEmpty, "round \(round)")
                XCTAssertEqual(Set(report.copied).union(report.matchedExisting), Set(f.contents.keys), "round \(round)")
                XCTAssertEqual(report.matchedExisting.count, (0..<filesPerRound).filter { $0 % 3 == 0 }.count)
                for (relative, data) in f.contents {
                    XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(relative)), data, "round \(round): \(relative) holds other bytes")
                }
                XCTAssertEqual(temporaries(in: f.nas), [])
            }
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), baseline + 2, "descriptors leaked")
    }
}

extension SyncLocked {
    func mutateReturning<T>(_ change: (inout Value) -> T) -> T {
        var result: T?
        mutate { result = change(&$0) }
        return result!
    }
}
