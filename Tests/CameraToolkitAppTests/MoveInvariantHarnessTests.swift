import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A seeded, synthetic library — a parent with subevents, a private
/// subevent, private and shared top-level events, photos whose names and bytes
/// collide across events, sidecars, and unapplied files on a card — put
/// through random sequences of moves (from leaf and family boards, loaded or
/// not, queued behind a job or not; many of them merges of identical copies),
/// Trash, Trash-window restores, renames and re-parents, returns, deletes,
/// and ⌘Z / ⌘⇧Z interleaved with all of it — and with the Buffer unplugged
/// and plugged back in. After every step the app must still tell the truth:
///
/// - every assignment's file is where the app implies it is (or still on its
///   card, or on the NAS, or on the unplugged Buffer);
/// - no file is lost or overwritten (the multiset of contents on drive, Trash, card and NAS is conserved);
/// - no event has two assignments pointing at one file;
/// - every count the boards and sidebar show is the catalog's count, and every
///   open board is exactly what a fresh read of the drive would draw;
/// - Undo returns the exact prior state — merges, Trash and renames included —
///   and Redo the exact state after; while the Buffer is away Undo and Redo
///   act on the NAS and the catalog and the invariants still hold;
/// - a click on visible tiles is never answered "Nothing to move".
@MainActor
final class MoveInvariantHarnessTests: XCTestCase {
    /// SplitMix64: same seed, same run.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private struct Snapshot: Equatable {
        var rows: [String]
        var files: [String]
        /// Name, date, parent and storage setting of every event, or "deleted".
        var events: [String]
    }

    /// Verbose progress, unbuffered so a run that stops at its first failure still shows its steps.
    private func audit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// The first broken invariant ends the run: everything after it is fallout.
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private let eventKeys = ["trip", "beach", "city", "secret", "vault", "solo"]
    private let namePool = (1...9).map { String(format: "DSC%05d.ARW", $0) } + ["B0003_DSC00040.ARW", "B0003_DSC00041.ARW", "C0100.MP4"]

    // MARK: - Library

    private func makeLibrary(_ rng: inout Generator) throws -> AuditLibrary {
        let library = try AuditLibrary.make()
        let day = AuditLibrary.day
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: day.addingTimeInterval(86_400), policy: nil, parent: "trip")
        library.addEvent("city", name: "Alex&Sam Private Hangout", date: day.addingTimeInterval(3 * 86_400), policy: nil, parent: "trip")
        library.addEvent("secret", name: "Jordan's 90th Birthday", date: day.addingTimeInterval(2 * 86_400), policy: .archiveOnly, parent: "trip")
        library.addEvent("vault", name: "Private Trip", date: day.addingTimeInterval(10 * 86_400), policy: .archiveOnly)
        library.addEvent("solo", name: "Solo Day", date: day.addingTimeInterval(20 * 86_400))
        let unsorted = library.drive.appendingPathComponent("Unsorted A7V")
        try FileManager.default.createDirectory(at: unsorted, withIntermediateDirectories: true)
        var stamp = 0.0
        for key in eventKeys {
            let count = Int.random(in: 4...8, using: &rng)
            for name in namePool.shuffled(using: &rng).prefix(count) {
                stamp += 11
                // The same photo in several events half the time; a different
                // photo that happens to share the name otherwise.
                let identical = Bool.random(using: &rng)
                let content = identical ? "ARW-shared-\(name)-pad-pad-pad" : "ARW-\(key)-\(name)-pad-pad-pad"
                let stale = Int.random(in: 0..<4, using: &rng) == 0
                // One photo sorted into two events comes from one place; a
                // different photo that shares its name comes from another card.
                let origin = identical ? unsorted.path : unsorted.appendingPathComponent(key).path
                try library.place(
                    key, name: name, content: content,
                    sourceRoot: stale ? library.drive.appendingPathComponent("Gone Folder/\(key)").path : origin,
                    modifiedAt: AuditLibrary.day.addingTimeInterval(stamp), commit: false
                )
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    try library.place(
                        key, name: (name as NSString).deletingPathExtension + ".xmp", content: "xmp-\(key)-\(name)",
                        sourceRoot: unsorted.appendingPathComponent(key).path, modifiedAt: AuditLibrary.day.addingTimeInterval(stamp), commit: false
                    )
                }
            }
        }
        // Sorted from a card that is plugged in: on the card, not on the drive.
        for index in 0..<3 {
            let key = eventKeys.randomElement(using: &rng)!
            try library.place(key, name: "CARD_\(index).ARW", content: "card-\(index)-pad-pad-pad-pad", onDrive: false, commit: false)
        }
        library.commit()
        // The NAS is there: some drive files have a copy at their mirror path,
        // and two photos were taken off the drive and live only on the NAS.
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        for assignment in library.model.configuration.photoEventAssignments {
            guard let path = library.impliedPath(assignment), library.exists(path),
                  Int.random(in: 0..<5, using: &rng) < 2,
                  let event = library.workspace.event(assignment.eventID),
                  let copy = library.locations.archiveURL(for: assignment, event: event) else { continue }
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: URL(fileURLWithPath: path)).write(to: copy)
        }
        for index in 0..<2 {
            try library.placeOnNASOnly(eventKeys.randomElement(using: &rng)!, name: "NASONLY_\(index).ARW", content: "nas-only-\(index)-pad-pad-pad-pad")
        }
        library.workspace.refreshConnectivity()
        return library
    }

    // MARK: - Snapshots and invariants

    /// The state, with the unplugged Buffer's files counted where they would
    /// be if it were plugged in — so a state is comparable across plugging.
    private func snapshot(_ library: AuditLibrary, unplugged: URL? = nil) -> Snapshot {
        let rows = library.model.configuration.photoEventAssignments.map {
            "\(library.key(of: $0.eventID))|\($0.sourceRootPath)|\($0.relativePath)|\($0.fileSize)|\($0.modifiedAt.timeIntervalSince1970)"
        }.sorted()
        let files = allFiles(library, unplugged: unplugged)
            .filter { !$0.path.contains("/_Trash/") }
            .map { file in
                file.path.replacingOccurrences(of: library.root.path, with: "").lowercased() + "#" + String(decoding: file.content, as: UTF8.self)
            }.sorted()
        let events = eventKeys.map { key -> String in
            guard let event = library.workspace.event(library.id(key)) else { return "\(key)|deleted" }
            let parent = event.parentEventID.map { library.key(of: $0) } ?? "-"
            return "\(key)|\(event.name)|\(event.eventDate.timeIntervalSince1970)|\(parent)|\(event.storagePolicy.map(\.rawValue) ?? "-")"
        }
        return Snapshot(rows: rows, files: files, events: events)
    }

    /// Every file on disk, plus those on the unplugged Buffer under the paths
    /// they would have plugged in.
    private func allFiles(_ library: AuditLibrary, unplugged: URL?) -> [(path: String, content: Data)] {
        var files = library.diskFiles()
        guard let unplugged, let walker = FileManager.default.enumerator(at: unplugged, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != MediaTrashService.manifestFileName else { continue }
            let plugged = library.drive.path + String(url.path.dropFirst(unplugged.path.count))
            files.append((plugged, (try? Data(contentsOf: url)) ?? Data()))
        }
        return files
    }

    private func census(_ library: AuditLibrary, unplugged: URL?) -> [Data: Int] {
        var census: [Data: Int] = [:]
        for file in allFiles(library, unplugged: unplugged) { census[file.content, default: 0] += 1 }
        return census
    }

    private func trashCount(_ library: AuditLibrary) -> Int { library.trashedNames().count }

    /// The path a board should draw an assignment at: its drive copy, then the
    /// other drive, then its source — what `bestLocalPath` answers here.
    private func expectedBoardPath(_ library: AuditLibrary, _ assignment: PhotoEventAssignment) -> String? {
        let locations = library.locations
        guard let event = library.workspace.event(assignment.eventID) else { return nil }
        let policy = locations.resolvedPolicy(for: event)
        let other: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
        for candidate in [
            locations.driveURL(for: assignment, event: event, policy: policy)?.path,
            locations.driveURL(for: assignment, event: event, policy: other)?.path,
            locations.sourceURL(for: assignment)?.path,
            locations.archiveURL(for: assignment, event: event)?.path,
        ].compactMap({ $0 }) where library.exists(candidate) {
            return candidate.lowercased()
        }
        return nil
    }

    private func check(_ library: AuditLibrary, opened: Set<String>, census expectedCensus: [Data: Int], unplugged: URL?, context: String) async {
        let workspace = library.workspace
        /// A path exists, or would if the unplugged Buffer were plugged in.
        func reachable(_ path: String) -> Bool {
            if library.exists(path) { return true }
            guard let unplugged, path.hasPrefix(library.drive.path + "/") else { return false }
            return library.exists(unplugged.path + String(path.dropFirst(library.drive.path.count)))
        }
        let model = library.model
        let assignments = model.configuration.photoEventAssignments
        let eventIDs = Set(model.configuration.savedEvents.map(\.id))

        // Every assignment belongs to a real event, once.
        XCTAssertEqual(Set(assignments.map(CatalogStore.eventAssetID)).count, assignments.count, "duplicate assignment rows — \(context)")
        for assignment in assignments {
            XCTAssertTrue(eventIDs.contains(assignment.eventID), "orphan assignment \(assignment.relativePath) — \(context)")
        }

        // Every assignment's file is where the app implies (or still on its card).
        var pathsByEvent: [UUID: [String: String]] = [:]
        for assignment in assignments {
            let implied = library.impliedPath(assignment)
            // On the drive it is meant for — or, after an event changed policy
            // by moving under another parent, still in the other root (the
            // board says so and offers Move to Private / Put on Buffer).
            let onDrive = EventStoragePolicy.allCases.contains { policy in
                library.workspace.event(assignment.eventID).flatMap {
                    library.locations.driveURL(for: assignment, event: $0, policy: policy)
                }.map { reachable($0.path) } ?? false
            }
            let onSource = library.locations.sourceURL(for: assignment).map { reachable($0.path) } ?? false
            let onNAS = library.workspace.event(assignment.eventID).flatMap { library.locations.archiveURL(for: assignment, event: $0) }
                .map { library.exists($0.path) } ?? false
            XCTAssertTrue(onDrive || onSource || onNAS, "\(library.key(of: assignment.eventID))/\(assignment.relativePath) is nowhere the app looks — \(context)")
            // One file per row within an event.
            if let implied {
                let key = EventStorageLocations.pathKey(implied)
                if let clash = pathsByEvent[assignment.eventID]?[key] {
                    XCTFail("two rows of \(library.key(of: assignment.eventID)) point at \(implied) (\(clash)) — \(context)")
                }
                pathsByEvent[assignment.eventID, default: [:]][key] = assignment.relativePath
            }
        }
        var names: [UUID: Set<String>] = [:]
        for assignment in assignments {
            let inserted = names[assignment.eventID, default: []].insert(EventsWorkspace.nameKey(assignment.relativePath)).inserted
            XCTAssertTrue(inserted, "\(library.key(of: assignment.eventID)) has \(assignment.relativePath) twice — \(context)")
        }

        // Nothing lost, nothing overwritten.
        XCTAssertEqual(self.census(library, unplugged: unplugged), expectedCensus, "the files on disk changed — \(context)")

        // Counts are the catalog's.
        for event in model.configuration.savedEvents {
            let family = library.familyAssignments(event.id)
            XCTAssertEqual(workspace.assignmentCount(for: event.id), family.count, "count of \(library.key(of: event.id)) — \(context)")
            XCTAssertEqual(workspace.assignmentBytes(for: event.id), family.reduce(Int64(0)) { $0 + $1.fileSize }, "bytes of \(library.key(of: event.id)) — \(context)")
        }

        // Open boards are exactly what a fresh read draws — and that is what the catalog owns.
        for key in opened.sorted() {
            guard let id = library.ids[key], model.configuration.savedEvents.contains(where: { $0.id == id }) else { continue }
            let incremental = library.boardFiles(id)
            await workspace.refreshEvent(id)
            let fresh = library.boardFiles(id)
            if incremental != fresh {
                if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                    audit("AUDIT drift on \(key): quiet=\(workspace.isQuiet) status=\(model.statusMessage)")
                    audit("AUDIT   tree: " + model.configuration.savedEvents.map { "\(library.key(of: $0.id))<-\($0.parentEventID.map { library.key(of: $0) } ?? "-")" }.joined(separator: " "))
                    for row in library.familyAssignments(id) where row.relativePath.hasPrefix("CARD") {
                        audit("AUDIT   card row \(library.key(of: row.eventID))/\(row.relativePath)")
                    }
                }
                XCTFail("the \(key) board drifted from the drive: \(diff(incremental, fresh, library)) — \(context)")
            }
            let expected = library.familyAssignments(id).compactMap { expectedBoardPath(library, $0) }.sorted()
            // With the Buffer away the board keeps drawing a file where its
            // event implies it is — a place it cannot reach — instead of
            // searching for another copy, so only its own consistency is asked.
            if unplugged == nil, fresh != expected {
                if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                    for row in library.familyAssignments(id) {
                        audit("AUDIT   row \(library.key(of: row.eventID))/\(row.relativePath) source=\(row.sourceRootPath.replacingOccurrences(of: library.root.path, with: "")) size=\(row.fileSize) mtime=\(row.modifiedAt.timeIntervalSince1970)")
                    }
                    audit("AUDIT   tree: " + model.configuration.savedEvents.map { "\(library.key(of: $0.id))<-\($0.parentEventID.map { library.key(of: $0) } ?? "-")" }.joined(separator: " "))
                    audit("AUDIT   descendants: \(EventHierarchy.descendants(of: id, in: model.configuration.savedEvents).map { library.key(of: $0.id) })")
                    audit("AUDIT   board stacks:\(workspace.eventStacks[id]?.map { $0.files.map(\.name).joined(separator: "+") } ?? [])")
                }
                XCTFail("the \(key) board is not what the catalog owns: \(diff(fresh, expected, library)) — \(context)")
            }
        }
    }

    /// What is only in `a` (marked -) and only in `b` (marked +), without the temp folder.
    private func diff(_ a: [String], _ b: [String], _ library: AuditLibrary) -> String {
        let prefix = library.root.path.lowercased()
        func short(_ path: String) -> String { path.replacingOccurrences(of: prefix, with: "").replacingOccurrences(of: "/drive/.camera toolkit", with: "~") }
        // Counted, so a file drawn twice (or once too few) shows up.
        let left = Dictionary(a.map { ($0, 1) }, uniquingKeysWith: +), right = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        var lines: [String] = []
        for key in Set(left.keys).union(right.keys).sorted() where left[key, default: 0] != right[key, default: 0] {
            lines.append("\(short(key)) ×\(left[key, default: 0]) vs ×\(right[key, default: 0])")
        }
        return lines.joined(separator: "; ")
    }

    private func diff(_ a: Snapshot, _ b: Snapshot) -> String {
        func short(_ text: String) -> String {
            text.replacingOccurrences(of: #"/var/folders/[^ ]*?/T/CameraToolkitAudit-[0-9A-F-]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "/private", with: "")
        }
        func side(_ x: [String], _ y: [String], _ mark: String) -> [String] { Set(x).subtracting(y).sorted().prefix(8).map { mark + short($0) } }
        let rows = side(a.rows, b.rows, "after only: ") + side(b.rows, a.rows, "before only: ")
        let files = side(a.files, b.files, "after only: ") + side(b.files, a.files, "before only: ")
        let events = side(a.events, b.events, "after only: ") + side(b.events, a.events, "before only: ")
        return "rows: \(rows) files: \(files) events: \(events)"
    }

    // MARK: - The run

    /// What the harness expects a history entry to leave behind: the whole
    /// state after Undo of it (`before`) and after Redo of it (`after`). Nil
    /// where the state in between is not known (one click that queued two jobs).
    private struct Expectation {
        var before: Snapshot?
        var after: Snapshot?
        var description: String
    }

    private func run(seed: UInt64, steps: Int) async throws {
        var rng = Generator(state: seed)
        let library = try makeLibrary(&rng)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        let census = library.contentCensus()
        let start = snapshot(library)
        var opened: Set<String> = []
        var log: [String] = []
        /// By history entry id.
        var expectations: [UUID: Expectation] = [:]
        /// Entries whose last step left the drive one step behind (the Buffer
        /// was unplugged): while one is in the redo stack, older entries'
        /// exact states are not what they were, and only the invariants hold.
        var laggingIDs: Set<UUID> = []
        /// Something changed the state without a history entry, or the
        /// history was cut while a step lagged: exact states no longer known.
        var exactnessLost = false
        var unplugged: URL?
        func context(_ step: Int) -> String { "seed \(seed) step \(step): " + (log.last ?? "start") }
        func exactnessHolds() -> Bool { !exactnessLost && laggingIDs.isEmpty && unplugged == nil }

        for key in ["trip", "beach"] {
            await library.open(key)
            opened.insert(key)
        }
        await check(library, opened: opened, census: census, unplugged: nil, context: "seed \(seed) start")

        func settleAll() async throws {
            try await library.settle()
            // The NAS is connected here, so its renames drain on their own — a
            // NAS Rename job that starts after the step would make the next
            // click (an Undo, say) answer "another job is running".
            try await library.waitUntil(timeout: 30, "the NAS renames never drained") { workspace.pendingNASRenameCount == 0 && workspace.isQuiet }
            try await library.settle()
        }

        for step in 1...steps {
            // While the Buffer is unplugged only Undo, Redo, reads and the
            // plug back in run: a click on files the app cannot reach would
            // rewrite entries the drive's files do not follow.
            // 44 = Undo, 55 = Redo, 86 = plug in, 95 = re-read.
            let roll = unplugged == nil ? Int.random(in: 0..<100, using: &rng) : [44, 44, 55, 55, 86, 95].randomElement(using: &rng)!
            let before = snapshot(library, unplugged: unplugged)
            let undoIDsBefore = Set(workspace.undoHistory.undoStack.map(\.id))
            let redoIDsBefore = Set(workspace.undoHistory.redoStack.map(\.id))
            let topUndo = workspace.undoHistory.nextUndo
            let topRedo = workspace.undoHistory.nextRedo
            var madeChange = false
            var stepKind = ""

            switch roll {
            case 0..<34:
                // Move from a random board to a random event.
                let boardKey = eventKeys.randomElement(using: &rng)!
                let loaded = opened.contains(boardKey) || Bool.random(using: &rng)
                if loaded {
                    await library.open(boardKey)
                    opened.insert(boardKey)
                }
                let targetKey = eventKeys.randomElement(using: &rng)!
                let queued = Int.random(in: 0..<5, using: &rng) == 0
                var ids: Set<String> = []
                if let stacks = workspace.eventStacks[library.id(boardKey)], !stacks.isEmpty {
                    ids = Set(stacks.shuffled(using: &rng).prefix(Int.random(in: 1...5, using: &rng)).map(\.id))
                } else if !loaded {
                    // An unopened board: the id of a tile it will draw first.
                    let owned = library.familyAssignments(library.id(boardKey))
                    if let first = owned.first, let path = library.impliedPath(first) { ids = [path] }
                }
                guard !ids.isEmpty else { log.append("move from \(boardKey): empty board"); continue }
                log.append("move \(ids.count) stack(s) \(boardKey) → \(targetKey)\(queued ? " (queued behind a job)" : "")\(loaded ? "" : " (board not loaded)")")
                stepKind = "move"
                if queued { model.isStorageBenchmarkRunning = true }
                workspace.moveStacks(ids, fromEvent: library.id(boardKey), toEvent: library.id(targetKey))
                if loaded {
                    XCTAssertFalse(model.statusMessage.hasPrefix("Nothing to move"), "\(model.statusMessage) — \(context(step))")
                }
                // Queued behind the same job, a second click on another board:
                // the two run one after the other, in click order.
                if queued, Bool.random(using: &rng) {
                    let otherKey = eventKeys.randomElement(using: &rng)!
                    let otherTarget = eventKeys.randomElement(using: &rng)!
                    await library.open(otherKey)
                    opened.insert(otherKey)
                    if let stacks = workspace.eventStacks[library.id(otherKey)], !stacks.isEmpty {
                        log.append("… and a second click while queued: \(otherKey) → \(otherTarget)")
                        workspace.moveStacks(Set(stacks.shuffled(using: &rng).prefix(2).map(\.id)), fromEvent: library.id(otherKey), toEvent: library.id(otherTarget))
                    }
                }
                if queued { model.isStorageBenchmarkRunning = false }
                madeChange = true
            case 34..<40:
                // Move to Trash from an event board.
                let boardKey = eventKeys.randomElement(using: &rng)!
                await library.open(boardKey)
                opened.insert(boardKey)
                if let stacks = workspace.eventStacks[library.id(boardKey)], !stacks.isEmpty {
                    let ids = Set(stacks.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)).map(\.id))
                    log.append("trash \(ids.count) stack(s) of \(boardKey)")
                    stepKind = "trash"
                    workspace.requestTrash(stackIDs: ids, fromEvent: library.id(boardKey))
                    if let pending = workspace.pendingTrash { workspace.confirmTrash(pending) }
                    madeChange = true
                }
            case 40..<52:
                // Undo — the newest entry, whatever it is.
                log.append("undo \(topUndo?.displayName ?? "(nothing)")")
                stepKind = "undo"
                workspace.undo()
            case 52..<62:
                log.append("redo \(topRedo?.displayName ?? "(nothing)")")
                stepKind = "redo"
                workspace.redo()
            case 62..<70:
                let key = eventKeys.randomElement(using: &rng)!
                guard let event = workspace.event(library.id(key)) else { log.append("rename \(key): deleted"); continue }
                let dayShift = Double(Int.random(in: -1...2, using: &rng)) * 86_400
                // Sometimes the name only changes case, sometimes the event
                // moves under another parent (or out to the top level).
                let name = Int.random(in: 0..<4, using: &rng) == 0 ? event.name.uppercased() : "Renamed \(step) \(key)"
                var parent = event.parentEventID
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    let candidates = workspace.parentCandidates(excluding: event.id).map(\.event.id)
                    parent = (candidates + [nil]).randomElement(using: &rng)!
                }
                log.append("rename \(key)\(parent == event.parentEventID ? "" : " (re-parented)")")
                stepKind = "rename"
                workspace.renameEvent(
                    event.id, name: name, date: event.eventDate.addingTimeInterval(dayShift),
                    policy: event.storagePolicy, parentEventID: parent
                )
                madeChange = true
            case 70..<77:
                let boardKey = eventKeys.randomElement(using: &rng)!
                await library.open(boardKey)
                opened.insert(boardKey)
                if let stacks = workspace.eventStacks[library.id(boardKey)], !stacks.isEmpty {
                    let ids = Set(stacks.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)).map(\.id))
                    log.append("return \(ids.count) stack(s) of \(boardKey) to Unsorted")
                    stepKind = "return"
                    workspace.returnToUnsorted(ids, eventID: library.id(boardKey))
                    madeChange = true
                }
            case 77..<80:
                let key = eventKeys.randomElement(using: &rng)!
                log.append("delete \(key)")
                stepKind = "delete"
                let owned = library.assignments(key).count + library.familyAssignments(library.id(key)).count
                workspace.deleteEmptyEvent(library.id(key))
                if owned > 0 {
                    XCTAssertNotNil(workspace.event(library.id(key)), "an event with rows was deleted — \(context(step))")
                }
                madeChange = true
            case 80..<84:
                // The Trash window's Restore: files back, entries back, no history entry.
                let service = MediaTrashService(removedFilesRoot: library.locations.removedFilesRoot)
                let items = service.listItems(under: library.locations.trashRoots())
                if !items.isEmpty {
                    let picked = Array(items.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)))
                    log.append("restore \(picked.count) file(s) from the Trash window")
                    let report = service.restore(items: picked)
                    workspace.reinstateTrashedAssignments(report)
                    for key in opened { await library.open(key) }
                    // The state changed and no entry says how to change it back.
                    if !report.restored.isEmpty { exactnessLost = true }
                }
            case 84..<88:
                if let away = unplugged {
                    log.append("plug the Buffer back in")
                    try FileManager.default.moveItem(at: away, to: library.drive)
                    unplugged = nil
                    workspace.refreshConnectivity()
                } else if workspace.undoHistory.canUndo || workspace.undoHistory.canRedo {
                    log.append("unplug the Buffer")
                    let away = library.root.appendingPathComponent("Drive.unplugged")
                    try FileManager.default.moveItem(at: library.drive, to: away)
                    unplugged = away
                    workspace.refreshConnectivity()
                }
            default:
                let key = eventKeys.randomElement(using: &rng)!
                log.append("re-read \(key)")
                await library.open(key)
                opened.insert(key)
            }

            try await settleAll()
            if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                audit("AUDIT seed \(seed) step \(step): \(log.suffix(2).joined(separator: " ;; ")) | \(model.statusMessage) | undo=\(workspace.undoHistory.undoStack.count) redo=\(workspace.undoHistory.redoStack.count) lagging=\(laggingIDs.count) exact=\(exactnessHolds()) trash=\(trashCount(library))")
            }
            let after = snapshot(library, unplugged: unplugged)
            let undoStack = workspace.undoHistory.undoStack
            let redoStack = workspace.undoHistory.redoStack

            // --- which entries last acted on the NAS and catalog alone
            var nowLagging: Set<UUID> = []
            for entry in undoStack + redoStack {
                if case .files(let files) = entry.action, files.driveLagging != nil { nowLagging.insert(entry.id) }
                if case .eventEdit(let edit) = entry.action, edit.driveLagging == true { nowLagging.insert(entry.id) }
            }
            let allIDs = Set(undoStack.map(\.id) + redoStack.map(\.id))
            // A lagging entry that left the history (a new action forgot the
            // Redo it sat in) never brings the drive level again.
            if !laggingIDs.subtracting(allIDs).isEmpty { exactnessLost = true }
            laggingIDs = nowLagging

            // --- what the history did with an Undo or Redo
            if stepKind == "undo" || stepKind == "redo" {
                let top = stepKind == "undo" ? topUndo : topRedo
                if let top {
                    let idsBefore = stepKind == "undo" ? redoIDsBefore : undoIDsBefore
                    let other = stepKind == "undo" ? redoStack : undoStack
                    let same = stepKind == "undo" ? undoStack : redoStack
                    if other.contains(where: { $0.id == top.id }), !idsBefore.contains(top.id) {
                        // It worked: the exact state, when it is known.
                        let expectation = expectations[top.id]
                        if let expected = stepKind == "undo" ? expectation?.before : expectation?.after, exactnessHolds() {
                            if after != expected {
                                XCTFail("\(stepKind == "undo" ? "Undo did not return the exact prior state" : "Redo did not return the exact state after the action") (\(expectation?.description ?? "")): \(diff(after, expected)) — \(context(step))")
                            }
                        }
                    } else if same.contains(where: { $0.id == top.id }) {
                        // Refused, or done in part and kept: a state nothing recorded.
                        if after != before { exactnessLost = true }
                    } else {
                        // It can never run: it left the history without being undone.
                        exactnessLost = true
                    }
                }
            }

            // --- entries the step recorded
            if stepKind != "undo", stepKind != "redo" {
                let newEntries = undoStack.filter { !undoIDsBefore.contains($0.id) && !redoIDsBefore.contains($0.id) }
                if !newEntries.isEmpty {
                    // One click that queued two jobs made two entries: only the
                    // state before the first and after the last is known.
                    for (index, entry) in newEntries.enumerated() {
                        expectations[entry.id] = Expectation(
                            before: index == 0 ? before : nil,
                            after: index == newEntries.count - 1 ? after : nil,
                            description: log.last ?? ""
                        )
                    }
                } else if madeChange, after != before {
                    // Changed state without an Undo of its own.
                    exactnessLost = true
                }
            }

            // Renames and deletes change the paths every older Undo names, and
            // the Buffer's return changes what is reachable: invariants only.
            await check(library, opened: opened, census: census, unplugged: unplugged, context: context(step))
        }
        if let away = unplugged {
            try FileManager.default.moveItem(at: away, to: library.drive)
            unplugged = nil
        }
        // Whatever the run left, Undo takes it all back to the start without
        // losing a byte — every Undo that can run, newest first.
        var guardSteps = 0
        while workspace.undoHistory.canUndo, guardSteps < 60 {
            guardSteps += 1
            let count = workspace.undoHistory.undoStack.count
            let name = workspace.undoHistory.nextUndo?.displayName ?? ""
            workspace.undo()
            try await settleAll()
            if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                audit("AUDIT seed \(seed) finish: undo \(name) | \(model.statusMessage)")
            }
            if workspace.undoHistory.undoStack.count >= count { break }
        }
        await check(library, opened: opened, census: census, unplugged: nil, context: "seed \(seed) after undoing everything")
        if !exactnessLost, !workspace.undoHistory.canUndo, laggingIDs.isEmpty {
            let end = snapshot(library)
            XCTAssertEqual(end, start, "undoing everything returned the library to where it started: \(diff(end, start)) — seed \(seed)")
        }
    }

    func testRandomizedMovesTrashMergesRenamesUndoRedoAndUnpluggedBuffersKeepEveryInvariant() async throws {
        // AUDIT_SEEDS="7,8" reruns just those; a failure names its seed and step.
        let seeds = ProcessInfo.processInfo.environment["AUDIT_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } } ?? [1, 2, 3, 4, 5, 6]
        let steps = ProcessInfo.processInfo.environment["AUDIT_STEPS"].flatMap { Int($0) } ?? 30
        for seed in seeds {
            try await run(seed: seed, steps: steps)
        }
    }
}
