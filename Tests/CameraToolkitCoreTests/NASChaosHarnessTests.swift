@testable import CameraToolkitCore
import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest

/// A permanent, seeded chaos harness for the drive → NAS mirror.
///
/// Random interleavings of: Move to Event (`EventMoveService` and the NAS
/// renames it owes), Undo (journal and catalog-only), event renames (the
/// folder renames), Sync to NAS (prepareSync → sync → reconcile), NAS-rename
/// drains, Take Off Drive (through the real presence rule), Duplicates "Keep
/// in X only", the NAS going offline and back, crashes at the k-th NAS
/// rename/close (the disk image is restored to that point), transient share
/// errors, and — behind `CHAOS_UNDO_RACE` — the ungated catalog-only Undo
/// running concurrently with a NAS job. The Buffer is usually unplugged,
/// sometimes wiped, sometimes an older copy of it comes back.
///
/// Temp folders stand in for the Buffer, Private and the NAS; the SSH
/// verifier runs `sha256sum` with the local `/bin/sh`; smbfs rename semantics
/// are simulated. Every step ends in hard invariants, and each run ends in a
/// quiescence check: connect, drain the queue, Sync All with reconcile —
/// then the NAS mirror must be exactly what the catalog owns.
///
/// Invariants:
///  - content is never lost or overwritten (drive, NAS, Trash, `_Stale Copies`);
///  - a verified record never names bytes other than its own;
///  - nothing is set aside unless an identical copy is at an owned path;
///  - an entry's NAS copy holds the photo the entry names;
///  - verification is visible through the event folder's name however it is
///    composed (accented events);
///  - after quiescence the NAS mirror equals what the catalog owns for the
///    synced events: no duplicates, nothing missing, nothing stranded, no
///    leftover temporary, and every unowned Buffer folder reported;
///  - a queued rename never sits failed for a transient error.
///
/// Findings that belong to the undo code paths (a ⌘Z whose entries moved on,
/// an undo that restores a taken name, the ungated undo race) are counted and
/// printed under `[undo-owned]`, and so is whatever a seed finds after its
/// first undo (`[undo-owned cascade]`: an entry restored under a taken name
/// leaves a NAS rename reversed onto another photo). They do not fail the run
/// unless `CHAOS_INCLUDE_UNDO` is set; those paths are replaced by the unified
/// undo history. `CHAOS_NO_UNDO` runs the same seeds with undo switched off,
/// which isolates everything else.
///
/// Where the throwaway audit harness copied the app's decisions, this one
/// calls the same Core code the app calls (`EventMoveService` with its NAS
/// check, `NASMoveFollower.folderRenameBatch`, `prepareSync` with
/// assignments, the real `EventPresenceScanner` trust rule for Take Off
/// Drive). The move *planning* that still lives in `EventsWorkspace` (which
/// assignments move where, and which names count as taken) is mirrored here.
///
/// Determinism: run with `SWIFT_DETERMINISTIC_HASHING=1`; ids, paths and
/// contents derive from the seed; one transfer at a time while mischief is
/// armed.
///
/// Default: 8 seeds × 30 steps (a few seconds). Environment:
///  - `CHAOS_SEEDS=1,5,9` an explicit list, or `CHAOS_START` / `CHAOS_COUNT`;
///  - `CHAOS_STEPS` steps per seed;
///  - `CHAOS_TRACE` prints every step as it runs; `CHAOS_VERBOSE` prints the
///    last steps of each finding's example; `CHAOS_KEEP` keeps the temp world;
///  - `CHAOS_ASCII` no accented event; `CHAOS_DAMAGE` outside bit rot on NAS
///    copies (and a scrub that must find it); `CHAOS_REAL_ORDER` catalog
///    restore after the NAS undo; `CHAOS_LEGACY_MIX` the flat operation mix;
///  - `CHAOS_UNDO_RACE`, `CHAOS_INCLUDE_UNDO`, `CHAOS_NO_UNDO` as above;
///    `CHAOS_NO_OFFLINE_MOVES` refuses a move with a drive rename while the
///    NAS is away (its names are chosen without seeing the NAS). Findings
///    after such a move, after an undo, or after a reported conflict are
///    labelled `[after …]` and do not fail the run (`CHAOS_INCLUDE_UNDO`
///    makes them count): a mirror that already disagrees with the drive has
///    duplicates and leftovers around the disagreement.
/// Outcomes that lose nothing and are reported to the owner are counted under
/// a kind containing "(expected": a sync conflict with a stale Buffer or a
/// deliberately damaged copy, and the leftovers of outside damage.
/// The wide sweep: `CHAOS_COUNT=500 CHAOS_STEPS=50` (about eight minutes).
final class NASChaosHarnessTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        NASFileIO.closePrimitive = nil
        super.tearDown()
    }

    // MARK: - RNG

    struct Gen: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &self) < percent }
    }

    // MARK: - Chaos seam (the NASFileIO test seams)

    final class Chaos: @unchecked Sendable {
        private let lock = NSLock()
        var smb = false
        private var count = 0
        private var fireAt: Int?
        private var action: (() -> Void)?
        private var _crashed = false
        var crashed: Bool { lock.withLock { _crashed } }
        func setCrashed(_ value: Bool) { lock.withLock { _crashed = value } }
        private var _failNext = false
        func failNext() { lock.withLock { _failNext = true } }
        func takeFailNext() -> Bool { lock.withLock { defer { _failNext = false }; return _failNext } }
        func arm(at n: Int, _ body: @escaping () -> Void) { lock.withLock { count = 0; fireAt = n; action = body } }
        func disarm() { lock.withLock { fireAt = nil; action = nil } }
        func tick() {
            let body: (() -> Void)? = lock.withLock {
                count += 1
                guard let fireAt, count >= fireAt, let action else { return nil }
                self.fireAt = nil
                self.action = nil
                return action
            }
            body?()
        }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // MARK: - Findings

    final class Findings: @unchecked Sendable {
        struct Example { var seed: UInt64; var step: Int; var detail: String; var log: [String] }
        private let lock = NSLock()
        private(set) var byKind: [String: [Example]] = [:]
        private(set) var counts: [String: Int] = [:]
        private(set) var seedsByKind: [String: Set<UInt64>] = [:]
        func add(_ kind: String, seed: UInt64, step: Int, _ detail: String, log: [String]) {
            let label: String = lock.withLock {
                if Self.isUndoOwned(kind) { return "[undo-owned] " + kind }
                if kind.contains("(expected") {
                    // A reported conflict (or damage) leaves the mirror
                    // disagreeing with the drive until the owner decides; the
                    // duplicates and leftovers around it are its consequences.
                    if taints[seed] == nil, !kind.contains("outside damage"), !kind.contains("damaged") { taints[seed] = "reported conflict" }
                    return kind
                }
                // Once a seed has run an undo (an entry restored under a taken
                // name, a rename reversed onto another photo), or moved a file
                // while the NAS was away (the name was chosen blind), or had
                // a conflict reported, what follows may be its doing.
                guard let reason = taints[seed] else { return kind }
                return reason == "undo" ? "[undo-owned cascade] " + kind : "[after \(reason)] " + kind
            }
            lock.withLock {
                counts[label, default: 0] += 1
                seedsByKind[label, default: []].insert(seed)
                if byKind[label, default: []].count < 4 {
                    byKind[label, default: []].append(Example(seed: seed, step: step, detail: detail, log: Array(log.suffix(18))))
                }
            }
        }

        /// Why a seed's later findings may be consequences: the first cause.
        private var taints: [UInt64: String] = [:]
        func taint(seed: UInt64, reason: String = "undo") {
            lock.withLock { if taints[seed] == nil { taints[seed] = reason } }
        }

        /// The undo code paths are being replaced by the unified undo history.
        static func isUndoOwned(_ kind: String) -> Bool {
            kind.contains("Cmd-Z") || kind.contains("journal undo") || kind.contains(", undo)")
        }
    }

    // MARK: - World

    struct SortChange {
        var title: String
        var removed: [PhotoEventAssignment]
        var added: [PhotoEventAssignment]
        var nasLink: UUID?
        var eventFolders: [String: String]?
    }

    struct Image {
        var dir: URL
        var records: [NASSyncRecord]
        var configuration: AppConfiguration
        var nasOnline: Bool
        var bufferOnline: Bool
    }

    final class World: @unchecked Sendable {
        let seed: UInt64
        let root: URL
        let imageRoot: URL
        var configuration: AppConfiguration { didSet { locations = EventStorageLocations(configuration: configuration) } }
        private(set) var locations: EventStorageLocations
        let catalogURL: URL
        let store: NASSyncStore
        let journals: URL
        let queue: NASRenameQueue
        let chaos = Chaos()
        var remote: NASRemoteVerifier?
        var nasOnline = true
        var sortUndo: [SortChange] = []
        private let logLock = NSLock()
        private var lines: [String] = []
        var tagsEver: Set<String> = []
        var driveBaseline: [String: Int] = [:]
        var nasFloor: [String: Int] = [:]
        var staleSeen: Set<String> = []
        var step = 0
        var keys: [UUID: String] = [:]
        var lastSync: NASSyncReport?
        var lastPlan: NASSyncPlan?
        var findings: Findings?
        var bufferOnline = true
        var bufferImages: [URL] = []
        var editedTags: Set<String> = []
        var staleBufferReturned = false
        /// The photo each entry names, by `CatalogStore.eventAssetID`. An
        /// entry keeps its photo through moves; a kept-both name is the same
        /// photo under a new id.
        var tagOfEntry: [String: String] = [:]
        var bufferAway: URL { root.appendingPathComponent("BufferVolume.away", isDirectory: true) }
        var vault: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-vault", isDirectory: true) }
        var toolkitFolder: URL { root.appendingPathComponent(EventStorageLocations.toolkitFolderName, isDirectory: true) }
        func driveParts() -> [(URL, String)] { [(locations.bufferRoot, "Buffer"), (toolkitFolder, EventStorageLocations.toolkitFolderName)] }
        func unplugBuffer() {
            guard bufferOnline else { return }
            try? FileManager.default.createDirectory(at: bufferAway, withIntermediateDirectories: true)
            for (url, name) in driveParts() where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(at: url, to: bufferAway.appendingPathComponent(name))
            }
            bufferOnline = false
            note("Buffer unplugged")
        }
        func plugBuffer() {
            guard !bufferOnline else { return }
            for (url, name) in driveParts() {
                let from = bufferAway.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.moveItem(at: from, to: url) }
            }
            bufferOnline = true
            note("Buffer plugged in")
        }
        var seenOps: Set<String> = []
        func flag(_ kind: String, _ detail: String) { findings?.add(kind, seed: seed, step: step, detail, log: log) }

        init(seed: UInt64, root: URL, configuration: AppConfiguration) throws {
            self.seed = seed
            self.root = root
            self.imageRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-images", isDirectory: true)
            self.configuration = configuration
            self.locations = EventStorageLocations(configuration: configuration)
            self.catalogURL = root.appendingPathComponent("catalog.sqlite")
            self.store = try NASSyncStore(catalogURL: catalogURL)
            self.journals = root.appendingPathComponent("Move Journals", isDirectory: true)
            self.queue = NASRenameQueue(journalFolder: journals)
        }

        var log: [String] { logLock.withLock { lines } }
        func note(_ line: String) {
            let entry = "[" + String(step) + "] " + line
            logLock.withLock { lines.append(entry) }
            if ProcessInfo.processInfo.environment["CHAOS_TRACE"] != nil { print("CHAOS " + String(seed) + " " + entry) }
        }

        var nas: URL { locations.nasRoot }
        var away: URL { root.appendingPathComponent("Library.away", isDirectory: true) }
        var nasBase: URL { nasOnline ? nas : away }
        var assignments: [PhotoEventAssignment] { configuration.photoEventAssignments }
        func event(_ id: UUID) -> SavedCameraEvent? { configuration.savedEvents.first { $0.id == id } }
        func key(_ id: UUID) -> String { keys[id] ?? String(id.uuidString.prefix(4)) }

        func follower(remote useRemote: Bool = false) -> NASMoveFollower {
            NASMoveFollower(store: store, remoteVerifier: useRemote ? remote : nil, queue: queue, retryDelay: 0, isCancelled: { false })
        }

        func goOffline() {
            guard nasOnline else { return }
            do {
                try FileManager.default.moveItem(at: nas, to: away)
                nasOnline = false
                note("NAS went offline")
            } catch { note("offline failed: " + error.localizedDescription) }
        }

        func goOnline() {
            guard !nasOnline else { return }
            do {
                try FileManager.default.moveItem(at: away, to: nas)
                nasOnline = true
                note("NAS back online")
            } catch { note("online failed: " + error.localizedDescription) }
        }

        func replaceAssignments(removing removed: [PhotoEventAssignment], adding added: [PhotoEventAssignment]) {
            let removedIDs = Set(removed.map(CatalogStore.eventAssetID))
            var rows = configuration.photoEventAssignments.filter { !removedIDs.contains(CatalogStore.eventAssetID($0)) }
            var present = Set(rows.map(CatalogStore.eventAssetID))
            for row in added where present.insert(CatalogStore.eventAssetID(row)).inserted { rows.append(row) }
            configuration.photoEventAssignments = rows
        }

        func existingDrivePath(_ a: PhotoEventAssignment) -> String? {
            guard let e = event(a.eventID) else { return nil }
            let p = locations.resolvedPolicy(for: e)
            let o: EventStoragePolicy = p == .buffer ? .archiveOnly : .buffer
            return [locations.driveURL(for: a, event: e, policy: p), locations.driveURL(for: a, event: e, policy: o)]
                .compactMap { $0?.path }.first { DriveMoveService.isRegularFile($0) }
        }

        func archiveRelative(_ a: PhotoEventAssignment) -> String? {
            guard let e = event(a.eventID), let url = locations.archiveURL(for: a, event: e) else { return nil }
            return locations.nasRelativePath(url.path)
        }

        func eventFolderSnapshot(_ ids: Set<UUID>) -> [String: String] {
            var folders: [String: String] = [:]
            for id in ids {
                if let e = event(id) { folders[id.uuidString] = locations.eventFolder(for: e, policy: locations.resolvedPolicy(for: e)).path }
            }
            return folders
        }

        func eventMoved(since recorded: [String: String]) -> Bool {
            for (idText, path) in recorded {
                guard let id = UUID(uuidString: idText), let owner = event(id) else { continue }
                if locations.eventFolder(for: owner, policy: locations.resolvedPolicy(for: owner)).path != path { return true }
            }
            return false
        }

        // MARK: Crash images

        func snapshot() -> Image {
            let dir = imageRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where !child.lastPathComponent.hasPrefix("catalog.sqlite") {
                try? FileManager.default.copyItem(at: child, to: dir.appendingPathComponent(child.lastPathComponent))
            }
            let records = Array(((try? store.records(nasRoot: nas.path)) ?? [:]).values)
            return Image(dir: dir, records: records, configuration: configuration, nasOnline: nasOnline, bufferOnline: bufferOnline)
        }

        func restore(_ image: Image) {
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where !child.lastPathComponent.hasPrefix("catalog.sqlite") {
                try? FileManager.default.removeItem(at: child)
            }
            for child in (try? FileManager.default.contentsOfDirectory(at: image.dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.copyItem(at: child, to: root.appendingPathComponent(child.lastPathComponent))
            }
            if let writer = try? CatalogDatabase.writer(for: catalogURL) {
                try? writer.write { try $0.execute(sql: "DELETE FROM \(NASSyncStore.tableName)") }
            }
            try? store.upsert(image.records)
            configuration = image.configuration
            nasOnline = image.nasOnline
            bufferOnline = image.bufferOnline
            try? FileManager.default.removeItem(at: image.dir)
        }
    }

    // MARK: - Content

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    static func content(_ tag: String, size: Int) -> Data {
        var bytes = Array("T\(tag)|".utf8)
        var x = fnv(tag)
        while bytes.count < size {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: x >> 33))
        }
        return Data(bytes.prefix(max(size, bytes.count)))
    }

    static func tag(_ data: Data) -> String? {
        guard data.first == UInt8(ascii: "T"), let bar = data.prefix(96).firstIndex(of: UInt8(ascii: "|")) else { return nil }
        return String(decoding: data[(data.startIndex + 1)..<bar], as: UTF8.self)
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func regularFiles(under root: URL) -> [(path: String, data: Data)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, Data)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out.append((url.path, (try? Data(contentsOf: url)) ?? Data()))
        }
        return out
    }

    static func relative(_ path: String, to root: URL) -> String? {
        let prefix = root.resolvingSymlinksInPath().path + "/"; let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : nil
    }

    static func isTemporary(_ path: String) -> Bool { (path as NSString).lastPathComponent.contains(NASSyncPlanner.temporaryMarker) }
    static func isJunk(_ path: String) -> Bool { JunkPolicy.isJunkFile((path as NSString).lastPathComponent) }

    static func id(_ seed: UInt64, _ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", UInt32(truncatingIfNeeded: seed), n))!
    }

    // MARK: - Building a world

    func makeWorld(seed: UInt64, rng: inout Gen) throws -> World {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CTChaos-\(seed)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-images"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = testConfiguration(root: root)
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 1
        let day = Calendar.current.date(from: parts)!
        let a = SavedCameraEvent(id: Self.id(seed, 1), name: "Trip A", eventDate: day, storagePolicy: .buffer)
        let b = SavedCameraEvent(id: Self.id(seed, 2), name: "Trip B", eventDate: day.addingTimeInterval(86_400), storagePolicy: .buffer)
        let c = SavedCameraEvent(id: Self.id(seed, 3), name: "Private C", eventDate: day.addingTimeInterval(2 * 86_400), storagePolicy: .archiveOnly)
        let d = SavedCameraEvent(id: Self.id(seed, 4), name: "Sub D", eventDate: day.addingTimeInterval(3 * 86_400), storagePolicy: nil, parentEventID: a.id)
        let e = SavedCameraEvent(id: Self.id(seed, 5), name: ProcessInfo.processInfo.environment["CHAOS_ASCII"] == nil ? "Caf\u{00E9} Day" : "Cafe Day", eventDate: day.addingTimeInterval(4 * 86_400), storagePolicy: .buffer)
        configuration.savedEvents = [a, b, c, d, e]
        let w = try World(seed: seed, root: root, configuration: configuration)
        w.keys = [a.id: "A", b.id: "B", c.id: "C", d.id: "D", e.id: "E"]
        let names = ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW", "DSC00004.ARW", "DSC00005.ARW", "DSC00006.ARW", "C0001.MP4"]
        var rows: [PhotoEventAssignment] = []
        var serial = 0
        for event in configuration.savedEvents {
            let loc = w.locations
            let policy = loc.resolvedPolicy(for: event)
            for (index, name) in names.enumerated().shuffled(using: &rng).prefix(Int.random(in: 3...6, using: &rng)) {
                serial += 1
                let shared = rng.chance(40)
                let tag = shared ? "S-\(name)" : "U-\(w.key(event.id))-\(name)-\(serial)"
                let size = shared ? 900 + index : [700, 700, 1_300].randomElement(using: &rng)!
                // The same photo in two events keeps the card time; others differ.
                let stamp = shared ? 1_780_000_000 + Double(index) * 60 : 1_780_100_000 + Double(serial) * 7
                let row = PhotoEventAssignment(
                    sourceRootPath: loc.originalsRoot(for: event, deviceID: "sony-a7v", policy: policy).path,
                    relativePath: name, fileSize: Int64(size), modifiedAt: Date(timeIntervalSince1970: stamp),
                    eventID: event.id, deviceID: "sony-a7v"
                )
                let url = try XCTUnwrap(loc.driveURL(for: row, event: event, policy: policy))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Self.content(tag, size: size), attributes: [.modificationDate: row.modifiedAt]))
                rows.append(row)
                w.tagsEver.insert(tag)
                w.tagOfEntry[CatalogStore.eventAssetID(row)] = tag
            }
        }
        // Edited files no assignment names: a pick copied byte for byte from
        // an original, and an export of its own.
        var editSerial = 0
        for event in configuration.savedEvents {
            let folder = w.locations.eventFolder(for: event, policy: w.locations.resolvedPolicy(for: event)).appendingPathComponent("Edited", isDirectory: true)
            if rng.chance(60), let pick = rows.filter({ $0.eventID == event.id }).randomElement(using: &rng),
               let original = w.locations.driveURL(for: pick, event: event, policy: w.locations.resolvedPolicy(for: event)),
               let bytes = FileManager.default.contents(atPath: original.path) {
                let url = folder.appendingPathComponent("Picks/" + pick.relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.modificationDate: pick.modifiedAt]))
                if let t = Self.tag(bytes) { w.editedTags.insert(t) }
            }
            if rng.chance(50) {
                editSerial += 1
                let t = "X-" + w.key(event.id) + "-" + String(editSerial)
                let url = folder.appendingPathComponent("Export/EXPORT_" + String(editSerial) + ".JPG")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Self.content(t, size: 640), attributes: [.modificationDate: Date(timeIntervalSince1970: 1_780_200_000 + Double(editSerial))]))
                w.tagsEver.insert(t)
                w.editedTags.insert(t)
            }
        }
        w.configuration.photoEventAssignments = rows
        try FileManager.default.createDirectory(at: w.nas, withIntermediateDirectories: true)
        w.remote = try NASSafetyFixtures.localVerifier(root: w.root, nas: w.nas)
        return w
    }

    func install(_ chaos: Chaos) {
        NASFileIO.renameExclusivePrimitive = { source, destination in
            chaos.tick()
            if chaos.crashed { errno = EIO; return -1 }
            if chaos.takeFailNext() { errno = EIO; return -1 }
            if chaos.smb {
                var info = stat()
                errno = lstat(destination, &info) == 0 ? EEXIST : ENOTSUP
                return -1
            }
            return renamex_np(source, destination, UInt32(RENAME_EXCL))
        }
        NASFileIO.closePrimitive = { descriptor in
            chaos.tick()
            if chaos.crashed { Darwin.close(descriptor); errno = EIO; return -1 }
            if chaos.takeFailNext() { Darwin.close(descriptor); errno = EIO; return -1 }
            return Darwin.close(descriptor)
        }
    }

    // MARK: - Mischief around a NAS job

    enum Mischief: CustomStringConvertible {
        case none, offline(Int), crash(Int), concurrentUndo(Int), flaky(Int)
        var description: String {
            switch self {
            case .none: ""
            case .offline(let k): " [NAS drops at NAS op #\(k)]"
            case .crash(let k): " [CRASH at NAS op #\(k)]"
            case .concurrentUndo(let k): " [catalog-only Undo runs concurrently at NAS op #\(k)]"
            case .flaky(let k): " [transient EIO on NAS op #\(k), share stays mounted]"
            }
        }
    }

    var undoRaceEnabled: Bool { ProcessInfo.processInfo.environment["CHAOS_UNDO_RACE"] != nil }

    func pickMischief(_ rng: inout Gen) -> Mischief {
        let roll = Int.random(in: 0..<100, using: &rng)
        let k = Int.random(in: 1...6, using: &rng)
        if roll < 55 { return .none }
        if roll < 67 { return .offline(k) }
        if roll < 80 { return .crash(k) }
        if roll < 90 { return undoRaceEnabled ? .concurrentUndo(k) : .flaky(k) }
        return .flaky(k)
    }

    /// Runs a NAS job with the mischief armed. A crash restores the disk
    /// image taken at the crash point, then relaunches.
    func withMischief(_ w: World, _ m: Mischief, _ body: () throws -> Void) {
        let image = Box<Image?>(nil)
        switch m {
        case .none: break
        case .offline(let k): w.chaos.arm(at: k) { w.goOffline() }
        case .crash(let k): w.chaos.arm(at: k) { image.value = w.snapshot(); w.chaos.setCrashed(true) }
        case .flaky(let k): w.chaos.arm(at: k) { w.chaos.failNext() }
        case .concurrentUndo(let k): w.chaos.arm(at: k) { [unowned self] in
            w.note("  ... meanwhile: Cmd-Z undo last sort (ungated)")
            self.opUndoSort(w)
        }
        }
        do { try body() } catch { w.note("  job threw: " + error.localizedDescription) }
        w.chaos.disarm()
        w.chaos.setCrashed(false)
        if let saved = image.value {
            w.restore(saved)
            w.note("  CRASH: disk restored to the crash point; relaunch")
            relaunch(w)
        }
    }

    func relaunch(_ w: World) {
        // The sort undo stack lives in memory; the NAS rename queue is
        // drained at launch when the NAS is connected (refreshNASRenameBacklog).
        w.sortUndo = []
        if w.nasOnline {
            let r = try? w.follower().applyPending(nasRoot: w.nas)
            w.note("  launch drain: " + (r?.summary ?? "threw"))
        }
    }

    // MARK: - Operations

    func opMove(_ w: World, _ rng: inout Gen) throws {
        let events = w.configuration.savedEvents
        let withFiles = events.filter { e in w.assignments.contains { $0.eventID == e.id } }
        guard let from = withFiles.randomElement(using: &rng),
              let to = events.filter({ $0.id != from.id }).randomElement(using: &rng) else { return }
        let loc = w.locations
        let drawable: (PhotoEventAssignment) -> Bool = { a in w.existingDrivePath(a) != nil || (w.nasOnline && (w.archiveRelative(a).map { FileManager.default.fileExists(atPath: w.nas.appendingPathComponent($0).path) } ?? false)) }
        let picked = Array(w.assignments.filter { $0.eventID == from.id && drawable($0) }.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)))
        guard !picked.isEmpty else { return }
        let toPolicy = loc.resolvedPolicy(for: to)
        let toOther: EventStoragePolicy = toPolicy == .buffer ? .archiveOnly : .buffer
        var targetByName: [String: PhotoEventAssignment] = [:]
        for row in w.assignments where row.eventID == to.id { targetByName[(row.relativePath as NSString).lastPathComponent.lowercased()] = row }
        var claimed: [String: String] = [:]
        var items: [EventMoveItem] = []
        for a in picked {
            var moved = a
            moved.eventID = to.id
            let source = w.existingDrivePath(a)
            var move: DriveMove?
            if let source {
                moved.sourceRootPath = loc.originalsRoot(for: to, deviceID: moved.deviceID, policy: toPolicy).path
                if let dest = loc.driveURL(for: moved, event: to, policy: toPolicy) {
                    move = DriveMove(sourcePath: source, destinationPath: dest.path, byteCount: moved.fileSize)
                }
            }
            var nasCopy: NASCopyMove?
            if move == nil, w.nasOnline, let archive = loc.archiveURL(for: a, event: from),
               FileManager.default.fileExists(atPath: archive.path),
               let target = loc.archiveURL(for: moved, event: to),
               let f = loc.nasRelativePath(archive.path), let t = loc.nasRelativePath(target.path) {
                nasCopy = NASCopyMove(from: f, to: t, driveDestination: loc.driveURL(for: moved, event: to, policy: toPolicy)?.path)
            }
            let name = (moved.relativePath as NSString).lastPathComponent.lowercased()
            var takenBy: [String] = []
            if let existing = targetByName[name] {
                takenBy = [loc.driveURL(for: existing, event: to, policy: toPolicy), loc.driveURL(for: existing, event: to, policy: toOther), loc.sourceURL(for: existing)].compactMap { $0?.path }
            } else if let earlier = claimed[name] {
                takenBy = [earlier]
            } else {
                claimed[name] = source ?? ""
            }
            items.append(EventMoveItem(removed: a, added: moved, move: move, currentPath: source, takenBy: takenBy, nasCopy: nasCopy))
        }
        let names = picked.map { ($0.relativePath as NSString).lastPathComponent }.joined(separator: ",")
        let title = "Move " + names + " " + w.key(from.id) + " to " + w.key(to.id)
        try finishMove(w, &rng, items: items, picked: picked, to: to, title: title)
    }

    /// The photo an entry names follows it to its new entry.
    func carryTags(_ w: World, _ items: [EventMoveItem]) {
        for item in items {
            if let tag = w.tagOfEntry[CatalogStore.eventAssetID(item.removed)] { w.tagOfEntry[CatalogStore.eventAssetID(item.added)] = tag }
        }
    }

    func finishMove(_ w: World, _ rng: inout Gen, items: [EventMoveItem], picked: [PhotoEventAssignment], to: SavedCameraEvent, title: String) throws {
        let loc = w.locations
        let toPolicy = loc.resolvedPolicy(for: to)
        if ProcessInfo.processInfo.environment["CHAOS_ALLOW_OFFLINE_NASONLY"] == nil, !w.nasOnline, items.contains(where: { $0.move == nil && $0.nasCopy == nil && $0.takenBy.isEmpty }) {
            w.note(title + " refused in harness: a NAS-only file cannot follow while the NAS is offline")
            return
        }
        // With the NAS away the names are chosen blind: a different file
        // the NAS holds at a new name can only be found when it is back, and
        // is then reported by the rename or by the next sync.
        if !w.nasOnline, items.contains(where: { $0.move != nil }) {
            if ProcessInfo.processInfo.environment["CHAOS_NO_OFFLINE_MOVES"] != nil {
                w.note(title + " refused in harness: CHAOS_NO_OFFLINE_MOVES")
                return
            }
            w.findings?.taint(seed: w.seed, reason: "a move made while the NAS was offline")
        }
        for item in items where item.move == nil {
            let there = w.archiveRelative(item.removed).map { FileManager.default.fileExists(atPath: w.nasBase.appendingPathComponent($0).path) } ?? false
            if item.nasCopy == nil, there, item.takenBy.isEmpty { w.flag("NAS-only file moved with no NAS follow (NAS offline)", w.key(item.removed.eventID) + "/" + item.removed.relativePath + " to " + w.key(item.added.eventID)) }
        }
        guard items.contains(where: { $0.move != nil || !$0.takenBy.isEmpty || $0.nasCopy != nil }) else {
            w.replaceAssignments(removing: items.map(\.removed), adding: items.map(\.added))
            carryTags(w, items)
            w.sortUndo.append(SortChange(title: title, removed: items.map(\.removed), added: items.map(\.added), nasLink: nil, eventFolders: nil))
            w.note(title + " (catalog only" + (w.nasOnline ? "" : ", NAS offline") + ")")
            return
        }
        let leaving = Set(items.map { CatalogStore.eventAssetID($0.removed) })
        var protectedKeys: Set<String> = []
        for row in w.assignments where !leaving.contains(CatalogStore.eventAssetID(row)) {
            protectedKeys.insert(EventStorageLocations.pathKey((row.sourceRootPath as NSString).appendingPathComponent(row.relativePath)))
        }
        let takenKeys = Set(w.assignments.filter { $0.eventID == to.id }.compactMap { loc.impliedDrivePath(for: $0, event: to, policy: toPolicy) }.map(EventStorageLocations.pathKey))
        let moveID = UUID()
        let folders = w.eventFolderSnapshot(Set(picked.map(\.eventID)).union([to.id]))
        let outcome = try EventMoveService(
            trash: MediaTrashService(removedFilesRoot: loc.removedFilesRoot, volumeRoot: { _ in nil }),
            nasCheck: EventMoveNASCheck(locations: loc)
        ).move(
            items, title: title, journalFolder: w.journals, pruneBoundaries: [loc.bufferRoot, loc.privateStagingRoot],
            protectedPathKeys: protectedKeys, takenPathKeys: takenKeys, eventFolders: folders
        )
        let owed = NASMoveFollower.renames(forEventMove: outcome, locations: loc)
        if !owed.moves.isEmpty {
            try w.queue.save(NASRenameBatch(title: title, origin: .move, nasRoot: w.nas.path, moveJournalID: outcome.report.journalID ?? moveID, ops: owed.moves))
        }
        if !owed.merges.isEmpty {
            try w.queue.save(NASRenameBatch(title: title + " (merged)", origin: .merge, nasRoot: w.nas.path, ops: owed.merges))
        }
        w.replaceAssignments(removing: outcome.removedAssignments, adding: outcome.addedAssignments)
        carryTags(w, outcome.moved + outcome.keptBoth.map(\.item))
        if outcome.report.journalPath == nil, !outcome.moved.isEmpty {
            let linked = outcome.moved.contains { $0.nasCopy != nil }
            w.sortUndo.append(SortChange(
                title: title, removed: outcome.moved.map(\.removed), added: outcome.moved.map(\.added),
                nasLink: linked ? moveID : nil, eventFolders: linked ? folders : nil
            ))
        }
        if ProcessInfo.processInfo.environment["CHAOS_TRACE"] != nil {
            for op in owed.moves + owed.merges { w.note("    owes " + op.from + " -> " + op.to) }
            for kept in outcome.keptBoth { w.note("    kept both as " + kept.newName) }
            for stay in outcome.stayed { w.note("    stayed: " + stay.item.fileName + " - " + stay.reason) }
            for m in outcome.report.moved { w.note("    drive " + m.sourcePath + " -> " + m.destinationPath) }
        }
        let journal = outcome.report.journalPath == nil ? " (no journal)" : ""
        w.note(title + ": moved \(outcome.moved.count) keptBoth \(outcome.keptBoth.count) merged \(outcome.merged.count) stayed \(outcome.stayed.count); NAS owes \(owed.moves.count)+\(owed.merges.count)" + journal)
        // The app drains right after the job when the NAS is there.
        if w.nasOnline, rng.chance(70) {
            let m = pickMischief(&rng)
            withMischief(w, m) {
                let r = try w.follower().applyPending(nasRoot: w.nas)
                w.note("  drain\(m): " + r.summary)
            }
        }
    }

    func opUndoJournal(_ w: World, _ rng: inout Gen) throws {
        guard ProcessInfo.processInfo.environment["CHAOS_NO_UNDO"] == nil else { return }
        guard let latest = DriveMoveService.latestUndoableJournal(in: w.journals) else { return }
        guard w.bufferOnline else { w.note("undo [" + latest.journal.title + "] refused: the Buffer is not connected"); return }
        if let folders = latest.journal.eventFolders, w.eventMoved(since: folders) {
            try DriveMoveService.abandon(journalURL: latest.url)
            w.note("undo [" + latest.journal.title + "] refused (event renamed since), journal abandoned")
            return
        }
        let loc = w.locations
        let currentIDs = Set(w.assignments.map(CatalogStore.eventAssetID))
        var catalogOnly: Set<String> = []
        for (position, index) in (latest.journal.assignmentMoveIndices ?? []).enumerated()
        where index == nil && position < latest.journal.addedAssignments.count {
            let added = latest.journal.addedAssignments[position]
            if currentIDs.contains(CatalogStore.eventAssetID(added)), let rel = w.archiveRelative(added) {
                catalogOnly.insert(NASSyncStore.pathKey(rel))
            }
        }
        let undone = try DriveMoveService().undo(journalURL: latest.url, pruneBoundaries: [loc.bufferRoot, loc.privateStagingRoot])
        w.findings?.taint(seed: w.seed)
        let reversed = Set(undone.report.moved.compactMap { loc.mirrorRelativePath(forDrivePath: $0.sourcePath).map(NASSyncStore.pathKey) }).union(catalogOnly)
        let current = Set(w.assignments.map(CatalogStore.eventAssetID))
        let restore = undone.journal.assignmentsToRestore(
            reversed: undone.report.reversedIndices,
            fullyUndone: undone.report.skipped.isEmpty,
            isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
        )
        let takenOut = Set(restore.added.map(CatalogStore.eventAssetID))
        for back in restore.removed {
            let leaf = (back.relativePath as NSString).lastPathComponent.lowercased()
            let clash = w.assignments.contains { $0.eventID == back.eventID && !takenOut.contains(CatalogStore.eventAssetID($0)) && CatalogStore.eventAssetID($0) != CatalogStore.eventAssetID(back) && ($0.relativePath as NSString).lastPathComponent.lowercased() == leaf }
            if clash { w.flag("PRECURSOR journal undo restores an entry whose name is taken in its event now", w.key(back.eventID) + "/" + back.relativePath) }
        }
        let realOrder = ProcessInfo.processInfo.environment["CHAOS_REAL_ORDER"] != nil
        w.note("  catalog restore: take out " + restore.added.map { w.key($0.eventID) + "/" + $0.relativePath }.joined(separator: ",") + " put back " + restore.removed.map { w.key($0.eventID) + "/" + $0.relativePath }.joined(separator: ",") + " indices \(undone.journal.assignmentMoveIndices.map { $0.map { $0.map(String.init) ?? "nil" } } ?? []) reversed \(undone.report.reversedIndices)"); if !realOrder { w.replaceAssignments(removing: restore.added, adding: restore.removed) }
        let m = pickMischief(&rng)
        w.note("undo [" + latest.journal.title + "]: drive back \(undone.report.moved.count) stayed \(undone.report.skipped.count)\(m)")
        withMischief(w, m) {
            let nas = try NASMoveFollower(store: w.store, queue: w.queue, retryDelay: 0, isCancelled: { false })
                .undo(moveJournalID: undone.journal.id, nasRoot: loc.nasRoot, reversedMirrorKeys: reversed)
            let stuck = nas.follow.differs.count + nas.follow.unproven.count + nas.follow.failed.count
            w.note("  NAS undo: renamed back \(nas.follow.renamed) cancelled \(nas.cancelled) queued \(nas.queued) stuck \(stuck)")
            if realOrder { w.replaceAssignments(removing: restore.added, adding: restore.removed) }
        }
    }

    func hasDriveCopy(_ w: World, _ a: PhotoEventAssignment) -> Bool {
        guard let e = w.event(a.eventID) else { return false }
        let sourceKey = w.locations.sourceURL(for: a).map { EventStorageLocations.pathKey($0.path) }
        return EventStoragePolicy.allCases.contains { policy in
            guard let url = w.locations.driveURL(for: a, event: e, policy: policy), EventStorageLocations.pathKey(url.path) != sourceKey else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    func opUndoSort(_ w: World) {
        guard ProcessInfo.processInfo.environment["CHAOS_NO_UNDO"] == nil else { return }
        guard let change = w.sortUndo.popLast() else { return }
        if change.nasLink != nil, w.eventMoved(since: change.eventFolders ?? [:]) {
            w.note("undo sort [" + change.title + "] refused (event renamed)")
            return
        }
        let events = Set(change.added.map(\.eventID))
        let inCatalog = Set(w.assignments.filter { events.contains($0.eventID) }.map(CatalogStore.eventAssetID))
        let kept = change.added.filter { inCatalog.contains(CatalogStore.eventAssetID($0)) && hasDriveCopy(w, $0) }
        guard kept.isEmpty else {
            w.note("undo sort [" + change.title + "] refused (applied since)")
            return
        }
        let currentNow = Set(w.assignments.map(CatalogStore.eventAssetID))
        let movedOn = change.added.filter { !currentNow.contains(CatalogStore.eventAssetID($0)) }
        if !movedOn.isEmpty { w.flag("PRECURSOR Cmd-Z sort undo of a change whose entries moved on since", movedOn.map { w.key($0.eventID) + "/" + $0.relativePath }.joined(separator: ",") + (change.nasLink == nil ? "" : " (NAS-linked)")) }
        w.replaceAssignments(removing: change.added, adding: change.removed)
        w.findings?.taint(seed: w.seed)
        w.note("undo sort [" + change.title + "]" + (change.nasLink == nil ? "" : " + NAS undo"))
        if let link = change.nasLink {
            let undone = try? NASMoveFollower(store: w.store, queue: w.queue, retryDelay: 0, isCancelled: { false }).undo(moveJournalID: link, nasRoot: w.nas)
            w.note("  NAS undo (sort): renamed back \(undone?.follow.renamed ?? -1) cancelled \(undone?.cancelled ?? -1) queued \(undone?.queued ?? -1)")
        }
    }

    func opRename(_ w: World, _ rng: inout Gen) throws {
        guard let event = w.configuration.savedEvents.randomElement(using: &rng) else { return }
        guard w.bufferOnline else { w.note("rename " + w.key(event.id) + " refused: the Buffer is not connected"); return }
        var renamed = event
        let variant = Int.random(in: 0..<6, using: &rng)
        switch variant {
        case 0: renamed.name = event.name.uppercased() == event.name ? event.name.lowercased() : event.name.uppercased()
        case 1: renamed.eventDate = event.eventDate.addingTimeInterval(Double(Int.random(in: -1...1, using: &rng) * 86_400))
        case 2:
            let hasChildren = w.configuration.savedEvents.contains { $0.parentEventID == event.id }
            let candidates = w.configuration.savedEvents.filter { $0.id != event.id && $0.parentEventID == nil }.map(\.id)
            renamed.parentEventID = hasChildren ? event.parentEventID : (candidates.map { Optional($0) } + [nil]).randomElement(using: &rng)!
        default: renamed.name = "R\(w.step) " + w.key(event.id)
        }
        let oldLoc = w.locations
        var future = w.configuration
        if let i = future.savedEvents.firstIndex(where: { $0.id == event.id }) { future.savedEvents[i] = renamed }
        let newLoc = EventStorageLocations(configuration: future)
        var folderMoves: [(URL, URL, Bool)] = []
        for policy in EventStoragePolicy.allCases {
            let old = oldLoc.eventFolder(for: event, policy: policy)
            let new = newLoc.eventFolder(for: renamed, policy: policy)
            let same = EventStorageLocations.pathKey(old.path) == EventStorageLocations.pathKey(new.path)
            let caseOnly = same && old.path != new.path
            guard FileManager.default.fileExists(atPath: old.path), !same || caseOnly else { continue }
            guard caseOnly || !FileManager.default.fileExists(atPath: new.path) else {
                w.note("rename " + w.key(event.id) + " refused (folder exists)")
                return
            }
            folderMoves.append((old, new, caseOnly))
        }
        for (old, new, caseOnly) in folderMoves {
            if caseOnly { try DriveMoveService().renameFolderChangingCase(from: old, to: new) } else { try DriveMoveService().moveFolder(from: old, to: new) }
        }
        let touched = Set(EventHierarchy.descendants(of: event.id, in: w.configuration.savedEvents).map(\.id)).union([event.id])
        var config = w.configuration
        if let i = config.savedEvents.firstIndex(where: { $0.id == event.id }) { config.savedEvents[i] = renamed }
        for (old, new, _) in folderMoves {
            let oldPrefix = old.standardizedFileURL.path + "/"
            for i in config.photoEventAssignments.indices where touched.contains(config.photoEventAssignments[i].eventID) {
                let root = config.photoEventAssignments[i].sourceRootPath
                if root.hasPrefix(oldPrefix) { config.photoEventAssignments[i].sourceRootPath = new.standardizedFileURL.path + "/" + root.dropFirst(oldPrefix.count) }
            }
        }
        // The catalog rows carry the folder in their source root, so their
        // ids change with a rename: the photo each names follows.
        let before = w.assignments
        w.configuration = config
        for (old, new) in zip(before, w.assignments) {
            if let tag = w.tagOfEntry[CatalogStore.eventAssetID(old)] { w.tagOfEntry[CatalogStore.eventAssetID(new)] = tag }
        }
        // Always queued, like the app: a folder that is not at its old name
        // yet is an earlier rename's, still queued.
        var queued = ""
        if let batch = NASMoveFollower.folderRenameBatch(from: event, to: renamed, locations: oldLoc, title: "Rename " + w.key(event.id)) {
            try w.queue.save(batch)
            queued = " NAS folder rename queued " + batch.ops[0].from + " to " + batch.ops[0].to
        }
        let parent = renamed.parentEventID.map { w.key($0) } ?? "-"
        w.note("rename " + w.key(event.id) + " v\(variant) to [" + renamed.name + "] " + EventStorageLocations.eventDateString(renamed.eventDate) + " parent " + parent + "; drive folders moved \(folderMoves.count)." + queued)
        if w.nasOnline, rng.chance(60) {
            let m = pickMischief(&rng)
            withMischief(w, m) {
                let r = try w.follower().applyPending(nasRoot: w.nas)
                w.note("  drain\(m): " + r.summary)
            }
        }
    }

    func syncAll(_ w: World, catchUp: Bool, reconcile: Bool, parallel: Int, ssh: Bool) throws -> NASSyncReport? {
        guard w.nasOnline else { return nil }
        let loc = w.locations
        let follower = w.follower(remote: ssh)
        let owned = NASCatchUp.ownedKeys(assignments: w.assignments, locations: loc)
        let events = w.configuration.savedEvents
        let prepared = try follower.prepareSync(events: events, locations: loc, nasRoot: loc.nasRoot, ownedKeys: owned, catchUp: catchUp, assignments: w.assignments)
        if !prepared.follow.isEmpty { w.note("  prepare: " + prepared.follow.summary) }
        w.lastPlan = prepared.plan
        let options = NASSyncOptions(parallelTransfers: parallel, remoteVerifier: ssh ? w.remote : nil, remoteBatchFiles: 3, retryDelay: 0)
        let report = try NASSyncService(store: w.store, options: options, isCancelled: { false }).sync(prepared.plan, nasRoot: loc.nasRoot)
        let conflicts = report.conflicts.map { $0.path }.joined(separator: " | ")
        w.note("  sync: copied \(report.copied.count) matched \(report.matchedExisting.count) already \(report.alreadyVerified.count) conflicts [" + conflicts + "] failed \(report.failed.count) notAttempted \(report.notAttempted) cleared \(report.clearedTemporaries) " + (report.stoppedReason ?? ""))
        w.lastSync = report
        // What the app does: a drive away means nothing can be proven stale.
        if reconcile, w.nasOnline, NASCatchUp.driveIsMounted(loc) {
            let r = try follower.reconcile(plan: prepared.plan, ownedKeys: owned, locations: loc, nasRoot: loc.nasRoot)
            if !r.isEmpty { w.note("  reconcile: " + r.summary) }
        }
        return report
    }

    func opSync(_ w: World, _ rng: inout Gen) {
        guard w.nasOnline else { w.note("sync refused: NAS offline"); return }
        let catchUp = rng.chance(60)
        var ssh = rng.chance(50)
        let m = pickMischief(&rng)
        var parallel = [1, 2, 4].randomElement(using: &rng)!
        if case .none = m {} else { parallel = 1; ssh = false }  // one writer: a point-in-time image and a replayable k-th op
        w.note("Sync All (catchUp+reconcile \(catchUp), \(parallel)x, " + (ssh ? "SSH" : "SMB") + " verify, " + (w.chaos.smb ? "smbfs" : "apfs") + " renames)\(m)")
        withMischief(w, m) { _ = try syncAll(w, catchUp: catchUp, reconcile: catchUp, parallel: parallel, ssh: ssh) }
    }

    func opDrain(_ w: World, _ rng: inout Gen) {
        guard w.nasOnline else { return }
        let m = pickMischief(&rng)
        withMischief(w, m) {
            let r = try w.follower().applyPending(nasRoot: w.nas)
            w.note("drain\(m): " + r.summary)
        }
    }

    /// The pairs the app would offer to take off the drive: found by the real
    /// presence sweep and its trust rule (`archiveIsTrusted`), not by the
    /// harness's own reading of the records.
    func trustedPairs(_ w: World) -> [(pair: VerifiedRemovalPair, assignment: PhotoEventAssignment)] {
        let loc = w.locations
        var out: [(VerifiedRemovalPair, PhotoEventAssignment)] = []
        for event in w.configuration.savedEvents {
            let rows = w.assignments.filter { $0.eventID == event.id }
            guard !rows.isEmpty else { continue }
            let prefix = NASMoveFollower.mirrorEventFolder(of: event, locations: loc)
            let facts = (try? w.store.verifiedFacts(nasRoot: loc.nasRoot.path, prefixes: [prefix])) ?? [:]
            guard let summary = EventPresenceScanner.scan(event: event, assignments: rows, locations: loc, nasFacts: facts) else { continue }
            for asset in summary.assets where asset.archiveIsTrusted {
                guard let archive = asset.archivePath, let rel = w.archiveRelative(asset.assignment) else { continue }
                let drive = asset.drive == .present ? asset.drivePath : (asset.otherDrive == .present ? asset.otherDrivePath : nil)
                guard let drive else { continue }
                out.append((VerifiedRemovalPair(driveCopyPath: drive, referencePath: archive, batchRelativePath: rel, byteCount: asset.assignment.fileSize), asset.assignment))
            }
        }
        return out
    }

    func opTakeOff(_ w: World, _ rng: inout Gen) throws {
        guard w.nasOnline else { return }
        let loc = w.locations
        let trusted = trustedPairs(w)
        guard let choice = trusted.randomElement(using: &rng) else { return }
        let report = try VerifiedRemovalService().moveVerifiedCopiesAside(
            pairs: [choice.pair],
            trashRoot: loc.removedFilesRoot, confirmation: VerifiedRemovalService.confirmationToken, pruneBoundaries: [loc.bufferRoot, loc.privateStagingRoot]
        )
        w.note("take off drive " + w.key(choice.assignment.eventID) + "/" + choice.assignment.relativePath + ": moved \(report.moved.count) differ \(report.differ.count)")
    }

    func opDuplicates(_ w: World, _ rng: inout Gen) throws {
        var byTag: [String: [(PhotoEventAssignment, String)]] = [:]
        for a in w.assignments {
            guard let path = w.existingDrivePath(a), let data = FileManager.default.contents(atPath: path), let t = Self.tag(data) else { continue }
            byTag[t, default: []].append((a, path))
        }
        let groups = byTag.keys.sorted().compactMap { byTag[$0] }.filter { Set($0.map(\.0.eventID)).count >= 2 }
        guard let chosen = groups.randomElement(using: &rng) else { return }
        let candidates = chosen.map { DuplicateCandidate(owner: .event($0.0.eventID), path: $0.1, assignment: $0.0) }
        guard let group = DuplicateScanner(store: nil, readsCaptureDates: false).scan(candidates).groups.first else { return }
        let keep = group.owners.randomElement(using: &rng)!
        let resolution = DuplicateResolution(group: group, keep: keep, drop: Set(group.owners).subtracting([keep]))
        let leaving = Set(chosen.filter { resolution.drop.contains(.event($0.0.eventID)) }.map { CatalogStore.eventAssetID($0.0) })
        var protectedKeys: Set<String> = []
        for row in w.assignments where !leaving.contains(CatalogStore.eventAssetID(row)) {
            protectedKeys.insert(EventStorageLocations.pathKey((row.sourceRootPath as NSString).appendingPathComponent(row.relativePath)))
        }
        let loc = w.locations
        let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: loc.removedFilesRoot, volumeRoot: { _ in nil }))
            .resolve([resolution], protectedPathKeys: protectedKeys)
        let owed = NASMoveFollower.renames(forDuplicates: [resolution], outcome: outcome, locations: loc)
        if !owed.isEmpty { try w.queue.save(NASRenameBatch(title: "Removed duplicate copies", origin: .merge, nasRoot: w.nas.path, ops: owed)) }
        w.replaceAssignments(removing: outcome.removedAssignments, adding: [])
        let keptKey = keep.eventID.map { w.key($0) } ?? "?"
        w.note("duplicates: keep " + keptKey + " of " + (Self.tag(FileManager.default.contents(atPath: chosen[0].1) ?? Data()) ?? "?") + ": trashed \(outcome.trashed.count) unassigned \(outcome.unassigned.count) refused \(outcome.refused.count); NAS owes \(owed.count)")
    }

    /// Bit rot or an outside edit: a NAS copy that also has a drive copy
    /// changes in place, same size, same mtime. Its record is now stale by an
    /// outside cause; the scrub must find it.
    func opDamage(_ w: World, _ rng: inout Gen) {
        guard w.nasOnline, let records = try? w.store.records(nasRoot: w.nas.path) else { return }
        let drive = driveCensus(w)
        let candidates = records.values.filter { $0.state == .verified }.sorted { $0.pathKey < $1.pathKey }.filter { r in
            guard let data = FileManager.default.contents(atPath: w.nas.appendingPathComponent(r.relativePath).path), let t = Self.tag(data) else { return false }
            return drive[t, default: 0] > 0 && !t.contains("~dmg")
        }
        guard let r = candidates.randomElement(using: &rng) else { return }
        let path = w.nas.appendingPathComponent(r.relativePath).path
        guard let data = FileManager.default.contents(atPath: path), let t = Self.tag(data) else { return }
        let newTag = t + "~dmg\(w.step)"
        let damaged = Self.content(newTag, size: data.count).prefix(data.count)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        try? Data(damaged).write(to: URL(fileURLWithPath: path))
        if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path) }
        w.nasFloor[t, default: 1] -= 1
        w.tagsEver.insert(newTag)
        w.note("DAMAGE (outside cause) NAS " + r.relativePath)
        // The scrub is what turns the stale record into a finding.
        if let report = try? NASVerifyScrub(store: w.store, remoteVerifier: rng.chance(50) ? w.remote : nil, isCancelled: { false }).run(nasRoot: w.nas) {
            if !report.hashMismatches.contains(where: { NASSyncStore.pathKey($0.path) == NASSyncStore.pathKey(r.relativePath) }) {
                w.flag("SCRUB MISSED A DAMAGED NAS COPY", r.relativePath + ": " + report.summary)
            }
            w.note("  scrub: " + report.summary)
        }
    }

    // MARK: - Invariants

    func driveCensus(_ w: World) -> [String: Int] {
        var census: [String: Int] = [:]
        for base in [w.locations.bufferRoot, w.toolkitFolder, w.bufferAway] {
            for file in Self.regularFiles(under: base) where !Self.isJunk(file.path) && (file.path as NSString).lastPathComponent != MediaTrashService.manifestFileName {
                census[Self.tag(file.data) ?? ("?untagged:" + file.path), default: 0] += 1
            }
        }
        return census
    }

    /// Drive files in event trees and their mirror paths.
    func driveMirror(_ w: World) -> [(mirror: String, path: String, data: Data)] {
        var out: [(String, String, Data)] = []
        for base in [w.locations.bufferRoot, w.locations.privateStagingRoot] {
            for file in Self.regularFiles(under: base) where !Self.isJunk(file.path) {
                guard let mirror = w.locations.mirrorRelativePath(forDrivePath: file.path), NASMoveFollower.isEventPath(mirror) else { continue }
                out.append((mirror, file.path, file.data))
            }
        }
        return out
    }

    func ownedNASKeys(_ w: World) -> Set<String> {
        var keys = Set(w.assignments.compactMap { w.archiveRelative($0) }.map(NASSyncStore.pathKey))
        keys.formUnion(driveMirror(w).map { NASSyncStore.pathKey($0.mirror) })
        return keys
    }

    func nasFiles(_ w: World) -> [(rel: String, data: Data)] {
        let base = w.nasBase
        return Self.regularFiles(under: base).compactMap { file -> (rel: String, data: Data)? in
            Self.relative(file.path, to: base).map { ($0, file.data) }
        }
    }

    func check(_ w: World, _ f: Findings) {
        let fail = { (kind: String, detail: String) in f.add(kind, seed: w.seed, step: w.step, detail, log: w.log) }
        // 1. The drive side is only ever renamed: its multiset of contents never changes.
        let drive = driveCensus(w)
        if drive != w.driveBaseline {
            let lost = w.driveBaseline.filter { drive[$0.key, default: 0] < $0.value }.map(\.key).sorted()
            let gained = drive.filter { w.driveBaseline[$0.key, default: 0] < $0.value }.map(\.key).sorted()
            fail("drive census changed", "lost \(lost) gained \(gained)")
            w.driveBaseline = drive
        }
        // 2. NAS copies are never removed or overwritten (temporaries aside).
        let files = nasFiles(w)
        var nas: [String: Int] = [:]
        for file in files where !Self.isTemporary(file.rel) && !Self.isJunk(file.rel) {
            guard let t = Self.tag(file.data) else {
                fail("untagged NAS file (placeholder?)", file.rel + " \(file.data.count) bytes")
                continue
            }
            nas[t, default: 0] += 1
        }
        for (t, floor) in w.nasFloor where nas[t, default: 0] < floor {
            fail("NAS copy lost or overwritten", t + ": \(nas[t, default: 0]) copies < \(floor)")
        }
        for (t, count) in nas { w.nasFloor[t] = max(w.nasFloor[t, default: 0], count) }
        // 3. Every content survives somewhere.
        for t in w.tagsEver where drive[t, default: 0] == 0 && nas[t, default: 0] == 0 && !t.contains("~dmg") {
            fail("CONTENT LOST EVERYWHERE", t)
        }
        // 4. A verified record never names a different file of its size.
        if let records = try? w.store.records(nasRoot: w.nas.path) {
            let byKey = Dictionary(files.map { (NASSyncStore.pathKey($0.rel), $0.data) }, uniquingKeysWith: { a, _ in a })
            for r in records.values where r.state == .verified {
                guard let data = byKey[r.pathKey], Int64(data.count) == r.byteCount else { continue }
                if Self.sha(data) != r.sha256 {
                    let t = Self.tag(data) ?? "?"
                    fail(t.contains("~dmg") ? "record stale after outside damage (expected)" : "FALSE VERIFIED RECORD", r.relativePath + " holds " + t)
                }
            }
        }
        for batch in w.queue.batches() {
            for (i, op) in batch.ops.enumerated() where op.state == .differs || op.state == .unproven || op.state == .failed {
                guard w.seenOps.insert(batch.id.uuidString + "#" + String(i)).inserted else { continue }
                let transient = op.state == .failed && (op.attempts ?? 0) > 0 ? " after \(op.attempts ?? 0) transient error(s)" : ""
                let touchesDamage = [op.from, op.to].contains { rel in
                    (FileManager.default.contents(atPath: w.nasBase.appendingPathComponent(rel).path).flatMap(Self.tag) ?? "").contains("~dmg")
                }
                // Two identical drive copies merged, but the NAS holds another
                // file where the surviving one belongs: the mirror already
                // disagrees with the drive, and the next sync reports it.
                let reportedConflict = op.state == .differs && batch.origin == .merge
                fail("NAS rename left untouched (" + op.state.rawValue + ", " + batch.origin.rawValue + ")" + transient + (touchesDamage ? " (expected: a damaged copy)" : reportedConflict ? " (expected: a reported conflict)" : ""), op.from + " to " + op.to + ": " + (op.detail ?? ""))
            }
        }
        checkEdited(w, files)
        checkEntriesShowTheirOwnPhoto(w, files)
        checkVerificationIsVisibleByEventFolder(w)
        // 5. A copy set aside has an identical copy at an owned path.
        let owned = ownedNASKeys(w)
        let staleRoot = NASMoveFollower.staleFolderPath + "/"
        let toolkit = EventStorageLocations.toolkitFolderName + "/"
        for s in files where s.rel.hasPrefix(staleRoot) && !w.staleSeen.contains(s.rel) {
            w.staleSeen.insert(s.rel)
            let ok = files.contains { !$0.rel.hasPrefix(toolkit) && owned.contains(NASSyncStore.pathKey($0.rel)) && $0.data == s.data }
            let anywhere = files.contains { !$0.rel.hasPrefix(toolkit) && $0.data == s.data }
            let t = Self.tag(s.data) ?? "?"
            if !anywhere, drive[t, default: 0] == 0 { fail("SET ASIDE THE ONLY COPY (no twin on the NAS or drive)", s.rel + " [" + t + "]") } else if !ok { w.note("  (set aside while its twin is not at an owned path yet: " + s.rel + ")") }
        }
    }

    /// An entry's NAS copy holds the photo the entry names. A different photo
    /// of the same size at the entry's NAS path is what presence cannot tell
    /// from the right one, so a move that lands one there shows the wrong
    /// photo until someone notices.
    func checkEntriesShowTheirOwnPhoto(_ w: World, _ files: [(rel: String, data: Data)]) {
        let byKey = Dictionary(files.map { (NASSyncStore.pathKey($0.rel), $0.data) }, uniquingKeysWith: { a, _ in a })
        for a in w.assignments {
            guard let expected = w.tagOfEntry[CatalogStore.eventAssetID(a)], let rel = w.archiveRelative(a),
                  let data = byKey[NASSyncStore.pathKey(rel)], Int64(data.count) == a.fileSize,
                  let actual = Self.tag(data), actual != expected, !actual.contains("~dmg") else { continue }
            // A pending rename may still owe the right file; only flag once nothing is queued.
            guard w.queue.pendingRenameCount(nasRoot: w.nas.path) == 0 else { continue }
            let key = "shows:" + CatalogStore.eventAssetID(a) + actual
            guard w.seenOps.insert(key).inserted else { continue }
            w.flag("ENTRY SHOWS ANOTHER PHOTO (same size, other bytes at its NAS path)", w.key(a.eventID) + "/" + a.relativePath + " should be " + expected + " but the NAS path holds " + actual)
        }
    }

    /// The records under an event folder are found by that folder's name,
    /// whatever composition the drive listing used when they were written.
    func checkVerificationIsVisibleByEventFolder(_ w: World) {
        guard let all = try? w.store.records(nasRoot: w.nas.path) else { return }
        for event in w.configuration.savedEvents {
            let prefix = NASMoveFollower.mirrorEventFolder(of: event, locations: w.locations)
            let key = NASSyncStore.pathKey(prefix) + "/"
            let expected = all.keys.filter { $0.hasPrefix(key) }.count
            let seen = ((try? w.store.records(nasRoot: w.nas.path, prefixes: [prefix])) ?? [:]).count
            if seen != expected {
                let marker = "prefix:" + w.key(event.id) + String(w.step)
                if w.seenOps.insert(marker).inserted { w.flag("RECORDS INVISIBLE BY EVENT FOLDER NAME (composition)", prefix + ": \(seen) of \(expected)") }
            }
        }
        // And the byte-level truth: every key is the current spelling.
        if NASSyncKeyMigration.needsMigration(catalogURL: w.catalogURL) {
            w.flag("RECORD KEYED BY AN OLD SPELLING", "\(w.catalogURL.lastPathComponent)")
        }
    }

    /// What the user does to converge: connect, let the queue drain, Sync
    /// All with Reconcile NAS after moves. Then the mirror must match.
    func settle(_ w: World, _ f: Findings, _ rng: inout Gen, final: Bool = false) {
        w.goOnline()
        if final || rng.chance(50) { w.plugBuffer() }
        let fail = { (kind: String, detail: String) in f.add(kind, seed: w.seed, step: w.step, detail, log: w.log) }
        do {
            let drained = try w.follower().applyPending(nasRoot: w.nas)
            if !drained.isEmpty { w.note("settle drain: " + drained.summary) }
            w.note("settle: Sync All + reconcile")
            _ = try syncAll(w, catchUp: true, reconcile: true, parallel: 2, ssh: rng.chance(50))
        } catch {
            fail("settle threw", error.localizedDescription)
        }
        check(w, f)
        let pending = w.queue.pendingRenameCount(nasRoot: w.nas.path)
        if pending > 0 { fail("NAS renames still pending after settle", "\(pending)") }
        let files = nasFiles(w)
        let byKey = Dictionary(files.map { (NASSyncStore.pathKey($0.rel), $0) }, uniquingKeysWith: { a, _ in a })
        let conflicts = Set((w.lastSync?.conflicts ?? []).map { NASSyncStore.pathKey($0.path) })
        let toolkit = EventStorageLocations.toolkitFolderName + "/"
        // Buffer folders no event owns (an old Buffer under old event names)
        // are only reported: never synced, never a "missing" file.
        let unowned = (w.lastPlan?.unownedFolders ?? []) + (w.lastPlan?.outsideLayout ?? [])
        let canon = { (path: String) in NASSyncStore.pathKey(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
        let unownedKeys = Set(unowned.map { canon($0) + "/" })
        // a) Every drive file is on the NAS at its mirror path, byte for byte.
        let mirror = driveMirror(w)
        for d in mirror {
            if unownedKeys.contains(where: { canon(d.path).hasPrefix($0) }) { continue }
            guard let there = byKey[NASSyncStore.pathKey(d.mirror)] else {
                fail("drive file missing on NAS after Sync All", d.mirror)
                continue
            }
            if there.data != d.data {
                let kind = conflicts.contains(NASSyncStore.pathKey(d.mirror)) ? "NAS mirror path holds a different file (reported sync conflict) (expected)" : "NAS mirror differs from drive (no conflict reported)"
                let tagged = kind + (w.staleBufferReturned ? " [after an old Buffer returned]" : "")
                fail(tagged, d.mirror + ": drive " + (Self.tag(d.data) ?? "?") + " NAS " + (Self.tag(there.data) ?? "?"))
            }
        }
        // a2) Every Buffer event folder with files that no event owns was
        // reported (`<root>/<year>/<event>`, whatever its spelling).
        let bufferRoot = canon(w.locations.bufferRoot.path) + "/"
        let ownedFolders = Set(w.configuration.savedEvents.flatMap { e in
            EventStoragePolicy.allCases.map { canon(w.locations.eventFolder(for: e, policy: $0).path) }
        })
        for d in mirror {
            let full = canon(d.path)
            guard full.hasPrefix(bufferRoot) else { continue }
            let parts = full.dropFirst(bufferRoot.count).split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let folder = bufferRoot + parts[0] + "/" + parts[1]
            if !ownedFolders.contains(folder), !unownedKeys.contains(folder + "/") {
                fail("BUFFER EVENT FOLDER NOTHING OWNS WAS NOT REPORTED", folder)
            }
        }
        // b) Records are true.
        if let records = try? w.store.records(nasRoot: w.nas.path) {
            for r in records.values where r.state == .verified {
                guard let there = byKey[r.pathKey] else { fail("verified record for a missing NAS file (after settle)", r.relativePath); continue }
                if Int64(there.data.count) != r.byteCount { fail("verified record size differs from NAS file (after settle)", r.relativePath) }
            }
        }
        // b2) Every copy set aside has an identical copy at an owned path now.
        let ownedNow = ownedNASKeys(w)
        for s in files where s.rel.hasPrefix(NASMoveFollower.staleFolderPath + "/") {
            if !files.contains(where: { !$0.rel.hasPrefix(toolkit) && ownedNow.contains(NASSyncStore.pathKey($0.rel)) && $0.data == s.data }) {
                let t = Self.tag(s.data) ?? "?"
                let damagedTwin = files.contains { (Self.tag($0.data) ?? "").hasPrefix(t + "~dmg") }
                fail(damagedTwin ? "set-aside copy whose twin was damaged since (expected)" : "set-aside copy has no identical copy at an owned path (after settle)", s.rel + " [" + t + "]")
            }
        }
        // c) No extra copies: every NAS event file is a drive file mirror or an assignment copy.
        let expected = Set(mirror.map { NASSyncStore.pathKey($0.mirror) }).union(w.assignments.compactMap { w.archiveRelative($0) }.map(NASSyncStore.pathKey))
        for file in files where !file.rel.hasPrefix(toolkit) && !Self.isJunk(file.rel) && !file.rel.contains("/Edited/") {
            if Self.isTemporary(file.rel) { fail("leftover sync temporary", file.rel); continue }
            if file.data.isEmpty { fail("leftover 0-byte placeholder", file.rel); continue }
            guard !expected.contains(NASSyncStore.pathKey(file.rel)) else { continue }
            // Which NAS paths are owned is the drive's word as much as the
            // catalog's: with the Buffer away nothing is set aside (by
            // design), so a copy no entry owns is only a finding once the
            // Buffer is back (the final settle plugs it in).
            guard w.bufferOnline else { continue }
            let t = Self.tag(file.data) ?? "?"
            let ownedTwin = files.contains { expected.contains(NASSyncStore.pathKey($0.rel)) && $0.data == file.data }
            let damaged = t.contains("~dmg") || files.contains { (Self.tag($0.data) ?? "").hasPrefix(t + "~dmg") }
            fail(damaged ? "copy left by outside damage (expected)" : ownedTwin ? "stale NAS duplicate left after reconcile" : "orphan NAS copy (its content is at no owned path)", file.rel + " [" + t + "]")
        }
        for file in files where Self.isTemporary(file.rel) && file.rel.contains("/Edited/") { fail("leftover sync temporary", file.rel) }
        // c2) No empty folder is kept alive by nothing.
        // d) Every assignment file is where the app looks.
        for a in w.assignments {
            if let p = w.existingDrivePath(a), (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int64 == a.fileSize { continue }
            if let rel = w.archiveRelative(a), let there = byKey[NASSyncStore.pathKey(rel)], Int64(there.data.count) == a.fileSize { continue }
            let leaf = (a.relativePath as NSString).lastPathComponent.lowercased()
            let elsewhere = files.filter { ($0.rel as NSString).lastPathComponent.lowercased() == leaf }.map(\.rel)
            fail("assignment file is nowhere the app looks", w.key(a.eventID) + "/" + a.relativePath + " (\(a.fileSize) B); NAS has that name at \(elsewhere)")
        }
        // f) Every Edited file is still in an Edited folder on the NAS, or on the drive.
        let driveNow = driveCensus(w)
        for t in w.editedTags.sorted() where w.tagsEver.contains(t) {
            let inEdited = files.contains { !$0.rel.hasPrefix(toolkit) && $0.rel.contains("/Edited/") && Self.tag($0.data) == t }
            let damagedTwin = files.contains { (Self.tag($0.data) ?? "").hasPrefix(t + "~dmg") }
            if driveNow[t, default: 0] == 0, !inEdited { fail(damagedTwin ? "edited file changed by outside damage (expected)" : "EDITED FILE IN NO EDITED FOLDER on the NAS (drive gone)", t) }
        }
        // e) Two events never own one NAS path.
        var owners: [String: UUID] = [:]
        for a in w.assignments {
            guard let rel = w.archiveRelative(a) else { continue }
            let k = NASSyncStore.pathKey(rel)
            if let other = owners[k], other != a.eventID { fail("two events own one NAS path", rel + ": " + w.key(other) + " and " + w.key(a.eventID)) }
            owners[k] = a.eventID
        }
    }

    // MARK: - Run

    func run(seed: UInt64, steps: Int, findings: Findings) throws {
        var rng = Gen(state: seed)
        let w = try makeWorld(seed: seed, rng: &rng)
        w.findings = findings
        defer {
            CatalogDatabase.checkpointAndClose(url: w.catalogURL)
            if ProcessInfo.processInfo.environment["CHAOS_KEEP"] == nil {
                try? FileManager.default.removeItem(at: w.root)
                try? FileManager.default.removeItem(at: w.imageRoot)
                try? FileManager.default.removeItem(at: w.vault)
                for image in w.bufferImages { try? FileManager.default.removeItem(at: image) }
            } else {
                print("CHAOS kept " + w.root.path)
            }
        }
        install(w.chaos)
        w.chaos.smb = rng.chance(50)
        let damage = ProcessInfo.processInfo.environment["CHAOS_DAMAGE"] != nil
        w.driveBaseline = driveCensus(w)
        _ = try syncAll(w, catchUp: false, reconcile: false, parallel: 2, ssh: false)
        for _ in 0..<2 { try opTakeOff(w, &rng) }
        check(w, findings)
        for step in 1...steps {
            w.step = step
            let roll = Int.random(in: 0..<100, using: &rng)
            do {
                if ProcessInfo.processInfo.environment["CHAOS_LEGACY_MIX"] == nil {
                    try nasOnlyStep(w, roll, &rng, findings, damage: damage)
                } else {
                    switch roll {
                    case 0..<30: try opMove(w, &rng)
                    case 30..<42: try opUndoJournal(w, &rng)
                    case 42..<49: opUndoSort(w)
                    case 49..<57: try opRename(w, &rng)
                    case 57..<70: opSync(w, &rng)
                    case 70..<75: opDrain(w, &rng)
                    case 75..<82:
                        if w.nasOnline { w.goOffline() } else { w.goOnline(); if rng.chance(70) { relaunch(w) } }
                    case 82..<86: try opTakeOff(w, &rng)
                    case 86..<90: try opDuplicates(w, &rng)
                    case 90..<94:
                        w.note("quit and relaunch")
                        relaunch(w)
                    case 94..<97:
                        if damage { opDamage(w, &rng) } else { try opMove(w, &rng) }
                    default: settle(w, findings, &rng)
                    }
                }
            } catch {
                w.note("op threw: " + error.localizedDescription)
            }
            check(w, findings)
        }
        w.step = steps + 1
        settle(w, findings, &rng, final: true)
    }

    /// The sweep. `CHAOS_COUNT=500 CHAOS_STEPS=50` is the wide one.
    func testChaosMovesAndSyncsKeepEveryInvariant() throws {
        let env = ProcessInfo.processInfo.environment
        let seeds: [UInt64]
        if let list = env["CHAOS_SEEDS"] {
            seeds = list.split(separator: ",").compactMap { UInt64($0) }
        } else {
            let count = env["CHAOS_COUNT"].flatMap { UInt64($0) } ?? 8
            let start = env["CHAOS_START"].flatMap { UInt64($0) } ?? 1
            seeds = Array(start..<(start + count))
        }
        let steps = env["CHAOS_STEPS"].flatMap { Int($0) } ?? 30
        let findings = Findings()
        for seed in seeds {
            do { try run(seed: seed, steps: steps, findings: findings) } catch { findings.add("run threw", seed: seed, step: -1, error.localizedDescription, log: []) }
        }
        var lines = ["CHAOS SUMMARY: \(seeds.count) seeds x \(steps) steps"]
        for kind in findings.counts.keys.sorted() {
            let hit = findings.seedsByKind[kind, default: []].sorted()
            lines.append("== " + kind + ": \(findings.counts[kind]!) hit(s) in \(hit.count) seed(s): " + hit.prefix(25).map(String.init).joined(separator: ","))
            for example in findings.byKind[kind] ?? [] {
                lines.append("   seed \(example.seed) step \(example.step): " + example.detail)
                if env["CHAOS_VERBOSE"] != nil { for line in example.log { lines.append("      " + line) } }
            }
        }
        let hard = findings.counts.keys.filter { !$0.contains("(expected") && (env["CHAOS_INCLUDE_UNDO"] != nil || !$0.hasPrefix("[undo-owned") && !$0.hasPrefix("[after ")) }
        lines.append("CHAOS RESULT: \(hard.count) violating class(es), \(hard.reduce(0) { $0 + (findings.counts[$1] ?? 0) }) violation(s) in \(seeds.count) seeds x \(steps) steps")
        print(lines.joined(separator: "\n"))
        XCTAssertTrue(hard.isEmpty, "chaos findings: \(hard.sorted())")
    }
}

extension NASChaosHarnessTests {
    /// What the user does with the Buffer: Take Off Drive on everything the
    /// app trusts, empty the drive trash, and sometimes reformat the whole
    /// Buffer. Every copy the app trusts must hold the drive's bytes.
    func opWipeBuffer(_ w: World, _ rng: inout Gen) throws {
        guard w.nasOnline, w.bufferOnline else { return }
        let loc = w.locations
        let trusted = trustedPairs(w)
        var pairs: [VerifiedRemovalPair] = []
        for (pair, assignment) in trusted {
            let nasBytes = FileManager.default.contents(atPath: pair.referencePath) ?? Data()
            if FileManager.default.contents(atPath: pair.driveCopyPath) != nasBytes {
                let t = Self.tag(nasBytes) ?? "?"
                w.flag(t.contains("~dmg") ? "app trusts a damaged NAS copy for Take Off Drive (outside damage; re-hash refuses)" : "WIPE-UNSAFE: the app trusts a NAS copy that is not the drive file", assignment.relativePath + " NAS holds " + t)
            }
            pairs.append(pair)
        }
        var moved = 0
        for pair in pairs {
            let report = try? VerifiedRemovalService().moveVerifiedCopiesAside(
                pairs: [pair], trashRoot: loc.removedFilesRoot, confirmation: VerifiedRemovalService.confirmationToken,
                pruneBoundaries: [loc.bufferRoot, loc.privateStagingRoot]
            )
            moved += report?.moved.count ?? 0
        }
        let reformat = rng.chance(50)
        var roots = [loc.removedFilesRoot]
        if reformat { roots += [loc.bufferRoot, loc.privateStagingRoot] }
        var gone: [String] = []
        try? FileManager.default.createDirectory(at: w.vault, withIntermediateDirectories: true)
        for base in roots {
            for file in Self.regularFiles(under: base) {
                if let t = Self.tag(file.data) { gone.append(t) }
                try? FileManager.default.moveItem(atPath: file.path, toPath: w.vault.appendingPathComponent(UUID().uuidString).path)
            }
        }
        w.driveBaseline = driveCensus(w)
        let nas = Dictionary(nasFiles(w).compactMap { Self.tag($0.data).map { ($0, 1) } }, uniquingKeysWith: +)
        var destroyed: [String] = []
        for t in Set(gone) where nas[t, default: 0] == 0 && w.driveBaseline[t, default: 0] == 0 {
            w.tagsEver.remove(t)
            destroyed.append(t)
        }
        w.note("WIPE Buffer: took off \(moved) of \(pairs.count) trusted, emptied the drive trash" + (reformat ? ", reformatted the Buffer" : "") + (destroyed.isEmpty ? "" : "; never-synced content destroyed by the user: \(destroyed.sorted())"))
    }

    /// Keeps a copy of today s Buffer, to come back later as a stale drive.
    func opSnapshotBuffer(_ w: World) {
        guard w.bufferOnline else { return }
        let dir = w.root.deletingLastPathComponent().appendingPathComponent(w.root.lastPathComponent + "-old-\(w.bufferImages.count)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (url, name) in w.driveParts() where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        }
        w.bufferImages.append(dir)
        w.note("an old copy of the Buffer is kept aside (image \(w.bufferImages.count - 1))")
    }

    /// An older (or partial) Buffer is plugged in instead of the current one.
    func opOldBufferReturns(_ w: World, _ rng: inout Gen) {
        guard let image = w.bufferImages.randomElement(using: &rng) else { return }
        let partial = rng.chance(50)
        try? FileManager.default.createDirectory(at: w.vault, withIntermediateDirectories: true)
        var shelved: [String] = []
        for base in [w.locations.bufferRoot, w.toolkitFolder, w.bufferAway] {
            for file in Self.regularFiles(under: base) { if let t = Self.tag(file.data) { shelved.append(t) } }
            if FileManager.default.fileExists(atPath: base.path) {
                try? FileManager.default.moveItem(at: base, to: w.vault.appendingPathComponent(UUID().uuidString))
            }
        }
        for (url, name) in w.driveParts() {
            let from = image.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.copyItem(at: from, to: url) }
        }
        var dropped = 0
        if partial {
            for file in Self.regularFiles(under: w.locations.bufferRoot) where rng.chance(35) {
                try? FileManager.default.moveItem(atPath: file.path, toPath: w.vault.appendingPathComponent(UUID().uuidString).path)
                dropped += 1
            }
        }
        w.bufferOnline = true
        w.staleBufferReturned = true
        w.driveBaseline = driveCensus(w)
        let nas = Dictionary(nasFiles(w).compactMap { Self.tag($0.data).map { ($0, 1) } }, uniquingKeysWith: +)
        for t in Set(shelved) where nas[t, default: 0] == 0 && w.driveBaseline[t, default: 0] == 0 { w.tagsEver.remove(t) }
        w.note("an OLD Buffer is plugged in instead of the current one" + (partial ? " (partial: \(dropped) files missing)" : ""))
    }

    /// A sync that dropped mid-copy leaves `.<name>.ctsync-<id>` next to the
    /// file it was writing. The file may move on afterwards; the temporary
    /// must still be cleared by a later sync.
    func opLeftoverTemporary(_ w: World, _ rng: inout Gen) {
        guard w.nasOnline else { return }
        let candidates = nasFiles(w).filter { !$0.rel.hasPrefix(EventStorageLocations.toolkitFolderName + "/") && !Self.isTemporary($0.rel) && !Self.isJunk($0.rel) && NASMoveFollower.isEventPath($0.rel) }
        guard let file = candidates.randomElement(using: &rng) else { return }
        let folder = (file.rel as NSString).deletingLastPathComponent
        let name = (file.rel as NSString).lastPathComponent
        let suffix = String(format: "%08X", UInt32(truncatingIfNeeded: rng.next()))
        let url = w.nas.appendingPathComponent(folder).appendingPathComponent(".\(name)\(NASSyncPlanner.temporaryMarker)\(suffix)")
        try? Data(file.data.prefix(max(1, file.data.count / 3))).write(to: url)
        // Old enough to be a previous run's.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: url.path)
        w.note("a dropped sync's temporary is left beside " + file.rel)
    }

    /// Edited files have no assignment. Once the Buffer is gone they are
    /// orphans to reconcile: none may be set aside against an Originals copy.
    func checkEdited(_ w: World, _ files: [(rel: String, data: Data)]) {
        let staleRoot = NASMoveFollower.staleFolderPath + "/"
        for s in files where s.rel.hasPrefix(staleRoot) && s.rel.contains("/Edited/") && !w.staleSeen.contains("edited:" + s.rel) {
            w.staleSeen.insert("edited:" + s.rel)
            let twinInEdited = files.contains { !$0.rel.hasPrefix(EventStorageLocations.toolkitFolderName + "/") && $0.rel.contains("/Edited/") && $0.data == s.data }
            if !twinInEdited {
                w.flag("EDITED FILE SET ASIDE (no Edited twin left; the Buffer " + (w.bufferOnline ? "is connected" : "is absent") + ")", s.rel + " [" + (Self.tag(s.data) ?? "?") + "]")
            }
        }
    }
}

extension NASChaosHarnessTests {
    /// The mix weighted toward NAS-only operation: the Buffer is usually
    /// unplugged, sometimes wiped, sometimes an old copy of it comes back.
    func nasOnlyStep(_ w: World, _ roll: Int, _ rng: inout Gen, _ findings: Findings, damage: Bool) throws {
        switch roll {
        case 0..<26: try opMove(w, &rng)
        case 26..<32: try opUndoJournal(w, &rng)
        case 32..<41: opUndoSort(w)
        case 41..<47: try opRename(w, &rng)
        case 47..<58: opSync(w, &rng)
        case 58..<62: opDrain(w, &rng)
        case 62..<67: if w.nasOnline { w.goOffline() } else { w.goOnline(); if rng.chance(70) { relaunch(w) } }
        case 67..<70: try opTakeOff(w, &rng)
        case 70..<73: try opDuplicates(w, &rng)
        case 73..<76:
            w.note("quit and relaunch")
            relaunch(w)
        case 76..<84: if w.bufferOnline { if rng.chance(75) { w.unplugBuffer() } } else if rng.chance(35) { w.plugBuffer() }
        case 84..<87: opSnapshotBuffer(w)
        case 87..<89: opOldBufferReturns(w, &rng)
        case 89..<92: try opWipeBuffer(w, &rng)
        case 92..<96: if damage { opDamage(w, &rng) } else { try opMove(w, &rng) }
        case 96..<98: opLeftoverTemporary(w, &rng)
        default: settle(w, findings, &rng)
        }
    }
}
