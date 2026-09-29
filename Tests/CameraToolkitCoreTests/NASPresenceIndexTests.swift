@testable import CameraToolkitCore
import Foundation
import XCTest

/// "Which event files are not on the NAS yet": records first, then one
/// listing of the NAS (SSH `find`, or bulk SMB reads), then the compare.
final class NASPresenceIndexTests: XCTestCase {
    /// Names a NAS listing must carry through byte for byte.
    private static let oddNames = [
        "plain.ARW",
        "with space.JPG",
        "it's \"quoted\".XMP",
        "new\nline.MOV",
        "tab\tinside.ARW",
        "Été à Kyōto 東京.HEIC",
        "-dash first.JPG",
        "$(not a command).JPG",
    ]

    private struct Fixture {
        var root: URL
        /// Stands in for `/Volumes/<share>`: the SMB mount point.
        var mount: URL
        /// The NAS mirror root under the mount.
        var mirror: URL
        /// The share's server path (a symlink to the mount), so the local
        /// shell sees what the NAS would.
        var server: URL
    }

    private func fixture(_ root: URL) throws -> Fixture {
        let mount = root.appendingPathComponent("Share")
        let mirror = mount.appendingPathComponent("Mirror")
        let server = root.appendingPathComponent("Server")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: server, withDestinationURL: mount)
        return Fixture(root: root, mount: mount, mirror: mirror, server: server)
    }

    /// Runs the remote command with the local `/bin/sh`, streaming.
    private func localLister(_ f: Fixture, commands: SyncLocked<[String]>? = nil) -> NASRemoteLister {
        NASRemoteLister(localPrefix: f.mount.path, serverPrefix: f.server.path, label: "local sh") { command, onOutput in
            commands?.mutate { $0.append(command) }
            return try NASRemoteShell.stream(
                executable: "/bin/sh",
                arguments: ["-c", command],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                timeout: 60,
                onOutput: onOutput
            )
        }
    }

    private func item(_ relative: String, size: Int64, modifiedAt: Double = 1_000, event: UUID? = nil) -> NASSyncItem {
        NASSyncItem(sourcePath: "/drive/" + relative, relativePath: relative, byteCount: size, modifiedAt: modifiedAt, eventID: event)
    }

    // MARK: Parsing

    func testParserKeepsOddNamesAcrossEveryChunkBoundary() {
        var bytes = Data()
        for (index, name) in Self.oddNames.enumerated() {
            bytes += Data("\(100 + index)\t1790640708.965654879\t./2026/Event/\(name)".utf8) + Data([0])
        }
        // Every split point, including inside a multi-byte character.
        for split in stride(from: 0, through: bytes.count, by: 7) {
            var parser = NASListingParser()
            let records = parser.feed(bytes.prefix(split)) + parser.feed(bytes.dropFirst(split))
            parser.finish()
            XCTAssertEqual(records.map(\.path), Self.oddNames.map { "2026/Event/" + $0 }, "split \(split)")
            XCTAssertEqual(records.map(\.size), (0..<Self.oddNames.count).map { Int64(100 + $0) })
            XCTAssertEqual(records.first?.mtime1970 ?? 0, 1_790_640_708.965654879, accuracy: 1e-6)
            XCTAssertEqual(parser.malformed, 0)
        }
    }

    func testParserCountsMalformedAndTruncatedRecords() {
        var parser = NASListingParser()
        let records = parser.feed(Data("12\t1.0\tok.JPG\0garbage\0x\t1\tbad size\0".utf8) + Data("9\t2.0\ttruncated".utf8))
        parser.finish()
        XCTAssertEqual(records.map(\.path), ["ok.JPG"])
        XCTAssertEqual(parser.malformed, 3)
    }

    // MARK: Listing

    func testSSHListingStreamsTheTreeThroughThePathMapping() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let event = "2026/2026-08-26 Trip"
            var expected: [String: Int] = [:]
            for (index, name) in Self.oddNames.enumerated() {
                let relative = "\(event)/Originals/Sony A7V/\(index % 2 == 0 ? "" : "Transfer 2/")\(name)"
                try writeFile(f.mirror.appendingPathComponent(relative), Data(repeating: 7, count: 10 + index))
                expected[relative] = 10 + index
            }
            // Junk and another event's folder are not in the listing.
            try writeFile(f.mirror.appendingPathComponent("\(event)/Originals/Sony A7V/._plain.ARW"), "ad")
            try writeFile(f.mirror.appendingPathComponent("2026/2026-09-01 Other/Originals/Cam/a.JPG"), "a")
            let commands = SyncLocked<[String]>([])
            let listed = SyncLocked<[Int]>([])
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

            let listing = try localLister(f, commands: commands).list(
                root: f.mirror,
                folders: [event, "2026/2026-08-30 Never Synced"],
                now: now,
                progress: { count in listed.mutate { $0.append(count) } }
            )

            XCTAssertEqual(commands.value.count, 1, "one command for the whole listing")
            XCTAssertTrue(commands.value[0].contains(f.server.path + "/Mirror"), "the server path, not the SMB mount")
            XCTAssertEqual(listing.method, .ssh)
            XCTAssertEqual(listing.entries.count, expected.count)
            for (relative, size) in expected {
                let entry = try XCTUnwrap(listing.entry(relative), relative)
                XCTAssertEqual(entry.size, Int64(size), relative)
                let stat = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(f.mirror.appendingPathComponent(relative).path))
                XCTAssertEqual(entry.modifiedAt, stat.modifiedAt, accuracy: 0.01, relative)
            }
            // The missing event folder is covered, so its files are missing,
            // not unknown; the other event is not covered.
            XCTAssertTrue(listing.covers("2026/2026-08-30 Never Synced/Originals/Cam/x.JPG"))
            XCTAssertNil(listing.entry("2026/2026-08-30 Never Synced/Originals/Cam/x.JPG"))
            XCTAssertFalse(listing.covers("2026/2026-09-01 Other/Originals/Cam/a.JPG"))
            XCTAssertEqual(listing.listedAt("\(event)/x"), now)
            XCTAssertEqual(listed.value.last, expected.count)
        }
    }

    func testSSHListingMatchesTheSMBListingAndNormalizesNames() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let event = "2026/2026-08-26 Trip"
            for name in Self.oddNames {
                try writeFile(f.mirror.appendingPathComponent("\(event)/Originals/Cam/\(name)"), Data(name.utf8))
            }
            // Stored decomposed; the drive's relative path is composed.
            let decomposed = "Cafe\u{301}.JPG"
            try writeFile(f.mirror.appendingPathComponent("\(event)/Edited/Web/\(decomposed)"), "edit")

            let ssh = try localLister(f).list(root: f.mirror, folders: [event])
            let smb = try NASSMBLister.list(root: f.mirror, folders: [event, "\(event)/Edited"])
            XCTAssertEqual(smb.method, .smb)
            XCTAssertEqual(Set(ssh.entries.keys), Set(smb.entries.keys))
            for (key, entry) in ssh.entries {
                XCTAssertEqual(smb.entries[key]?.size, entry.size, key)
                XCTAssertEqual(smb.entries[key]?.modifiedAt ?? 0, entry.modifiedAt, accuracy: 0.01, key)
            }
            XCTAssertEqual(ssh.entry("\(event)/Edited/Web/Café.JPG")?.size, 4)
            XCTAssertEqual(ssh.entry("\(event.uppercased())/EDITED/WEB/CAFÉ.JPG")?.size, 4, "case-insensitive like the share")
        }
    }

    func testSSHListingFailureFallsBackToSMBAndSaysWhy() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            try writeFile(f.mirror.appendingPathComponent("2026/E/Originals/Cam/a.JPG"), "a")
            let refused = NASRemoteLister(localPrefix: f.mount.path, serverPrefix: f.server.path, label: "ssh nas") { _, _ in
                .init(status: 255, stderr: Data("Permission denied (publickey).".utf8))
            }
            let result = try NASPresenceIndex.list(nasRoot: f.mirror, folders: ["2026/E"], remote: refused)
            XCTAssertEqual(result.listing.method, .smb)
            XCTAssertEqual(result.listing.entry("2026/E/Originals/Cam/a.JPG")?.size, 1)
            XCTAssertTrue(result.sshFallbackReason?.contains("Permission denied") == true, result.sshFallbackReason ?? "")
        }
    }

    func testSSHListingOutsideTheMappingThrows() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let lister = localLister(f)
            XCTAssertThrowsError(try lister.list(root: root.appendingPathComponent("Elsewhere"), folders: [""]))
            XCTAssertEqual(lister.serverPath(for: f.mount.path + "/Mirror/a"), f.server.path + "/Mirror/a")
            XCTAssertNil(lister.serverPath(for: f.mount.path + "Other/a"), "a sibling with the same prefix is not under the mount")
        }
    }

    func testSMBListingOfAGoneNASThrowsInsteadOfCallingEverythingMissing() throws {
        try withTemporaryDirectory { root in
            XCTAssertThrowsError(try NASSMBLister.list(root: root.appendingPathComponent("Unmounted"), folders: ["2026/E"]))
        }
    }

    func testCancelledListingThrows() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            try writeFile(f.mirror.appendingPathComponent("2026/E/a.JPG"), "a")
            XCTAssertThrowsError(try localLister(f).list(root: f.mirror, folders: ["2026/E"], isCancelled: { true })) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertThrowsError(try NASSMBLister.list(root: f.mirror, folders: ["2026/E"], isCancelled: { true }))
        }
    }

    // MARK: Compare

    func testRecordsAloneAnswerWithoutAnyListing() {
        let event = UUID()
        let verifiedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let synced = item("2026/E/Originals/Cam/a.ARW", size: 100, modifiedAt: 5, event: event)
        let changed = item("2026/E/Originals/Cam/b.ARW", size: 100, modifiedAt: 9, event: event)
        let fresh = item("2026/E/Originals/Cam/c.ARW", size: 50, event: event)
        let records = [
            NASSyncStore.pathKey(synced.relativePath): NASSyncRecord(nasRoot: "/nas", relativePath: synced.relativePath, byteCount: 100, sourceModifiedAt: 5, state: .verified, checkedAt: verifiedAt, verifiedAt: verifiedAt),
            // Verified before the drive copy changed: not proof any more.
            NASSyncStore.pathKey(changed.relativePath): NASSyncRecord(nasRoot: "/nas", relativePath: changed.relativePath, byteCount: 100, sourceModifiedAt: 4, state: .verified, checkedAt: verifiedAt, verifiedAt: verifiedAt),
        ]
        let report = NASPresenceIndex.report(plan: NASSyncPlan(items: [synced, changed, fresh]), records: records, listing: nil)
        XCTAssertEqual(NASPresenceIndex.state(for: synced, record: records[NASSyncStore.pathKey(synced.relativePath)], listing: nil), .verified(verifiedAt))
        XCTAssertEqual(report.total.verifiedFiles, 1)
        XCTAssertEqual(report.total.pendingFiles, 2)
        XCTAssertEqual(report.total.unknownFiles, 2)
        XCTAssertEqual(report.total.pendingBytes, 150)
        XCTAssertEqual(report.pending.map(\.relativePath), [changed.relativePath, fresh.relativePath])
        XCTAssertNil(report.listedAt, "no listing was used")
        XCTAssertEqual(report.byEvent[event], report.total)
    }

    func testListingSaysMissingDifferentAndPresentAndWinsOverRecords() {
        let event = UUID()
        let other = UUID()
        let listedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var listing = NASTreeListing(root: "/nas", method: .ssh)
        listing.cover("2026/E", at: listedAt)
        listing.insert("2026/E/same.ARW", size: 100, modifiedAt: 1_000.4)
        listing.insert("2026/E/touched.ARW", size: 100, modifiedAt: 5_000)
        listing.insert("2026/E/bigger.ARW", size: 999, modifiedAt: 1_000)
        listing.insert("2026/E/verified.ARW", size: 100, modifiedAt: 1_000)

        let same = item("2026/E/same.ARW", size: 100, event: event)
        let touched = item("2026/E/touched.ARW", size: 100, event: event)
        let bigger = item("2026/E/bigger.ARW", size: 100, event: event)
        let verified = item("2026/E/verified.ARW", size: 100, event: event)
        let gone = item("2026/E/gone.ARW", size: 300, event: event)
        let uncovered = item("2026/Other/x.ARW", size: 7, event: other)
        let at = Date(timeIntervalSinceReferenceDate: 790_000_000)
        func verifiedRecord(_ item: NASSyncItem) -> NASSyncRecord {
            NASSyncRecord(nasRoot: "/nas", relativePath: item.relativePath, byteCount: item.byteCount, sourceModifiedAt: item.modifiedAt, state: .verified, checkedAt: at, verifiedAt: at)
        }
        // `gone` was verified once, then removed from the NAS.
        let records = Dictionary(uniqueKeysWithValues: [verified, gone].map { (NASSyncStore.pathKey($0.relativePath), verifiedRecord($0)) })

        func state(_ item: NASSyncItem) -> NASFilePresence {
            NASPresenceIndex.state(for: item, record: records[NASSyncStore.pathKey(item.relativePath)], listing: listing)
        }
        XCTAssertEqual(state(same), .onNAS(timeMatches: true))
        XCTAssertEqual(state(touched), .onNAS(timeMatches: false))
        XCTAssertEqual(state(bigger), .differs(nasSize: 999))
        XCTAssertEqual(state(verified), .verified(at))
        XCTAssertEqual(state(gone), .missing)
        XCTAssertEqual(state(uncovered), .unknown)

        let report = NASPresenceIndex.report(plan: NASSyncPlan(items: [same, touched, bigger, verified, gone, uncovered], inLegacyLayout: ["legacy"]), records: records, listing: listing)
        XCTAssertEqual(report.byEvent[event]?.pendingFiles, 1)
        XCTAssertEqual(report.byEvent[event]?.pendingBytes, 300)
        XCTAssertEqual(report.byEvent[event]?.differentFiles, 1)
        XCTAssertEqual(report.byEvent[event]?.onNASFiles, 3)
        XCTAssertEqual(report.byEvent[other]?.unknownFiles, 1)
        XCTAssertEqual(report.totals(for: [event, other]), report.total)
        XCTAssertEqual(report.total.pendingFiles, 2)
        XCTAssertEqual(report.inLegacyLayout, 1)
        XCTAssertEqual(report.listedAt, listedAt)
        XCTAssertEqual(report.method, .ssh)
    }

    func testMergeReplacesOnlyRelistedFoldersAndSyncedFilesPatchTheListing() {
        let old = Date(timeIntervalSinceReferenceDate: 1)
        let new = Date(timeIntervalSinceReferenceDate: 2)
        var listing = NASTreeListing(root: "/nas", method: .smb)
        listing.cover("2026/A", at: old)
        listing.cover("2026/B", at: old)
        listing.insert("2026/A/deleted.ARW", size: 1, modifiedAt: 0)
        listing.insert("2026/B/kept.ARW", size: 2, modifiedAt: 0)

        var relisted = NASTreeListing(root: "/nas", method: .ssh)
        relisted.cover("2026/A", at: new)
        relisted.insert("2026/A/new.ARW", size: 3, modifiedAt: 0)
        listing.merge(relisted)
        XCTAssertNil(listing.entry("2026/A/deleted.ARW"))
        XCTAssertEqual(listing.entry("2026/A/new.ARW")?.size, 3)
        XCTAssertEqual(listing.entry("2026/B/kept.ARW")?.size, 2)
        XCTAssertEqual(listing.listedAt("2026/A/x"), new)
        XCTAssertEqual(listing.listedAt("2026/B/x"), old)
        XCTAssertEqual(listing.oldestListing, old)

        listing.recordSynced([item("2026/B/copied.ARW", size: 9), item("2026/C/uncovered.ARW", size: 9)])
        XCTAssertEqual(listing.entry("2026/B/copied.ARW")?.size, 9)
        XCTAssertNil(listing.entry("2026/C/uncovered.ARW"), "never claims coverage it does not have")
        XCTAssertFalse(listing.covers("2026/C/uncovered.ARW"))

        var whole = NASTreeListing(root: "/nas", method: .ssh)
        whole.cover(".", at: new)
        listing.merge(whole)
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertTrue(listing.covers("anything/at/all"))
    }

    func testFoldersListEachTopLevelEventOnce() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let parent = SavedCameraEvent(name: "Mountain Trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-26")))
            let child = SavedCameraEvent(name: "Summit", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-27")), parentEventID: parent.id)
            let other = SavedCameraEvent(name: "Beach", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2025-07-01")))
            configuration.savedEvents = [parent, child, other]
            let locations = EventStorageLocations(configuration: configuration)
            XCTAssertEqual(
                NASPresenceIndex.folders(for: [parent, child, other], locations: locations),
                ["2025/2025-07-01 Beach", "2026/2026-08-26 Mountain Trip"]
            )
            // A subevent synced on its own lists only its own folder.
            XCTAssertEqual(
                NASPresenceIndex.folders(for: [child], locations: locations),
                ["2026/2026-08-26 Mountain Trip/2026-08-27 Summit"]
            )
        }
    }

    /// End to end: a plan from the drive, a sync, then the index agrees
    /// with the sync and with the board's presence sweep — which answers
    /// the NAS from the listing without stat-ing a single NAS file.
    func testIndexAgreesWithSyncAndFeedsThePresenceSweep() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            configuration.archiveLayoutRootPath = root.appendingPathComponent("NAS").path
            let event = SavedCameraEvent(name: "Mountain Trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-26")))
            configuration.savedEvents = [event]
            try FileManager.default.createDirectory(at: root.appendingPathComponent("NAS"), withIntermediateDirectories: true)
            let locations = EventStorageLocations(configuration: configuration)
            let originals = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let names = ["DSC00001.ARW", "DSC00002.ARW", "it's odd.ARW"]
            for (index, name) in names.enumerated() {
                try writeFile(originals.appendingPathComponent(name), Data(repeating: UInt8(index), count: 100 + index))
            }
            let assignments = names.enumerated().map { index, name in
                PhotoEventAssignment(sourceRootPath: originals.path, relativePath: name, fileSize: Int64(100 + index), modifiedAt: Date(), eventID: event.id, deviceID: "sony-a7v")
            }
            let catalog = root.appendingPathComponent("Support/catalog.sqlite")
            let folders = NASPresenceIndex.folders(for: [event], locations: locations)

            var plan = NASSyncPlanner.plan(events: [event], locations: locations)
            var listing = try NASSMBLister.list(root: locations.nasRoot, folders: folders)
            var report = NASPresenceIndex.report(plan: plan, records: NASSyncStore.existingRecords(catalogURL: catalog, nasRoot: locations.nasRoot.path), listing: listing)
            XCTAssertEqual(report.byEvent[event.id]?.pendingFiles, 3)
            XCTAssertEqual(report.total.unknownFiles, 0, "covered by the listing")
            XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path), "the index never creates the catalog")

            // Sync one file, then patch the listing from what the sync proved.
            let store = try NASSyncStore(catalogURL: catalog)
            let first = NASSyncPlan(items: [plan.items[0]])
            let synced = try NASSyncService(store: store).sync(first, nasRoot: locations.nasRoot)
            XCTAssertEqual(synced.copied.count, 1)
            listing.recordSynced(first.items.filter { synced.copied.contains($0.relativePath) })
            plan = NASSyncPlanner.plan(events: [event], locations: locations)
            report = NASPresenceIndex.report(plan: plan, records: NASSyncStore.existingRecords(catalogURL: catalog, nasRoot: locations.nasRoot.path), listing: listing)
            XCTAssertEqual(report.byEvent[event.id]?.pendingFiles, 2)
            XCTAssertEqual(report.byEvent[event.id]?.verifiedFiles, 1)
            // A relisting says the same.
            let relisted = try NASSMBLister.list(root: locations.nasRoot, folders: folders)
            XCTAssertEqual(NASPresenceIndex.report(plan: plan, records: NASSyncStore.existingRecords(catalogURL: catalog, nasRoot: locations.nasRoot.path), listing: relisted).byEvent[event.id], report.byEvent[event.id])

            // The sweep, fed the listing, stats no NAS file.
            let nasProbes = SyncLocked(0)
            let nasPrefix = locations.nasRoot.path + "/"
            let summary = try XCTUnwrap(EventPresenceScanner.scan(
                event: event,
                assignments: assignments,
                locations: locations,
                probe: { url, size, mounted in
                    if url?.path.hasPrefix(nasPrefix) == true { nasProbes.mutate { $0 += 1 } }
                    return EventPresenceScanner.state(url, size: size, mounted: mounted)
                },
                archiveListing: relisted
            ))
            XCTAssertEqual(nasProbes.value, 0)
            XCTAssertEqual(summary.onArchive, 1)
            XCTAssertEqual(summary.total - summary.onArchive, report.byEvent[event.id]?.pendingFiles)
            // Without a listing the sweep probes and finds the same.
            let probed = try XCTUnwrap(EventPresenceScanner.scan(event: event, assignments: assignments, locations: locations))
            XCTAssertEqual(probed.onArchive, summary.onArchive)
        }
    }
}
