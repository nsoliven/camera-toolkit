import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A seeded, synthetic library — a parent with subevents, a private
/// subevent, private and shared top-level events, photos whose names and bytes
/// collide across events, sidecars, and unapplied files on a card — put
/// through random sequences of moves (from leaf and family boards, loaded or
/// not, queued behind a job or not), undos, renames, returns and deletes.
/// After every step the app must still tell the truth:
///
/// - every assignment's file is where the app implies it is (or still on its card);
/// - no file is lost or overwritten (the multiset of contents on drive, Trash and card is conserved);
/// - no event has two assignments pointing at one file;
/// - every count the boards and sidebar show is the catalog's count, and every
///   open board is exactly what a fresh read of the drive would draw;
/// - Undo returns the exact prior state (unless the move merged identical
///   copies into Trash, which is restored from the Trash window);
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
    }

    private enum UndoKind { case journal, sort }

    private struct Undoable {
        var kind: UndoKind
        var before: Snapshot
        var description: String
        /// False once the op merged copies into Trash: Undo then restores
        /// renames, not the merge.
        var exact: Bool
    }

    private let eventKeys = ["trip", "harbor", "island", "secret", "vault", "solo"]
    private let namePool = (1...9).map { String(format: "DSC%05d.ARW", $0) } + ["B0003_DSC00040.ARW", "B0003_DSC00041.ARW", "C0100.MP4"]

    // MARK: - Library

    private func makeLibrary(_ rng: inout Generator) throws -> AuditLibrary {
        let library = try AuditLibrary.make()
        let day = AuditLibrary.day
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("harbor", name: "Harbor", date: day.addingTimeInterval(86_400), policy: nil, parent: "trip")
        library.addEvent("island", name: "Sam&Alex Hangout", date: day.addingTimeInterval(3 * 86_400), policy: nil, parent: "trip")
        library.addEvent("secret", name: "Riley's 90th Birthday", date: day.addingTimeInterval(2 * 86_400), policy: .archiveOnly, parent: "trip")
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

    private func snapshot(_ library: AuditLibrary) -> Snapshot {
        let rows = library.model.configuration.photoEventAssignments.map {
            "\(library.key(of: $0.eventID))|\($0.sourceRootPath)|\($0.relativePath)|\($0.fileSize)|\($0.modifiedAt.timeIntervalSince1970)"
        }.sorted()
        let files = library.diskFiles()
            .filter { !$0.path.contains("/_Trash/") }
            .map { file in
                file.path.replacingOccurrences(of: library.root.path, with: "").lowercased() + "#" + String(decoding: file.content, as: UTF8.self)
            }.sorted()
        return Snapshot(rows: rows, files: files)
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

    private func check(_ library: AuditLibrary, opened: Set<String>, census: [Data: Int], context: String) async {
        let workspace = library.workspace
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
                }.map { library.exists($0.path) } ?? false
            }
            let onSource = library.locations.sourceURL(for: assignment).map { library.exists($0.path) } ?? false
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
        XCTAssertEqual(library.contentCensus(), census, "the files on disk changed — \(context)")

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
                    print("AUDIT drift on \(key): quiet=\(workspace.isQuiet) status=\(model.statusMessage)")
                    print("AUDIT   tree: " + model.configuration.savedEvents.map { "\(library.key(of: $0.id))<-\($0.parentEventID.map { library.key(of: $0) } ?? "-")" }.joined(separator: " "))
                    for row in library.familyAssignments(id) where row.relativePath.hasPrefix("CARD") {
                        print("AUDIT   card row \(library.key(of: row.eventID))/\(row.relativePath)")
                    }
                }
                XCTFail("the \(key) board drifted from the drive: \(diff(incremental, fresh, library)) — \(context)")
            }
            let expected = library.familyAssignments(id).compactMap { expectedBoardPath(library, $0) }.sorted()
            if fresh != expected {
                if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                    for row in library.familyAssignments(id) {
                        print("AUDIT   row \(library.key(of: row.eventID))/\(row.relativePath) source=\(row.sourceRootPath.replacingOccurrences(of: library.root.path, with: "")) size=\(row.fileSize) mtime=\(row.modifiedAt.timeIntervalSince1970)")
                    }
                    print("AUDIT   tree: " + model.configuration.savedEvents.map { "\(library.key(of: $0.id))<-\($0.parentEventID.map { library.key(of: $0) } ?? "-")" }.joined(separator: " "))
                    print("AUDIT   descendants: \(EventHierarchy.descendants(of: id, in: model.configuration.savedEvents).map { library.key(of: $0.id) })")
                    print("AUDIT   board stacks:\(workspace.eventStacks[id]?.map { $0.files.map(\.name).joined(separator: "+") } ?? [])")
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
        return "rows: \(rows) files: \(files)"
    }

    // MARK: - The run

    private func run(seed: UInt64, steps: Int) async throws {
        var rng = Generator(state: seed)
        let library = try makeLibrary(&rng)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        let census = library.contentCensus()
        var opened: Set<String> = []
        var undoables: [Undoable] = []
        var log: [String] = []
        func context(_ step: Int) -> String { "seed \(seed) step \(step): " + (log.last ?? "start") }

        for key in ["trip", "harbor"] {
            await library.open(key)
            opened.insert(key)
        }
        await check(library, opened: opened, census: census, context: "seed \(seed) start")

        for step in 1...steps {
            let roll = Int.random(in: 0..<100, using: &rng)
            let before = snapshot(library)
            let journalsBefore = DriveMoveService.journals(in: workspace.journalFolder).count
            let trashBefore = trashCount(library)
            let sortDepthBefore = workspace.undoableSortCount
            var madeChange = false

            switch roll {
            case 0..<55:
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
            case 55..<70:
                if let last = undoables.last {
                    log.append("undo \(last.description)")
                    switch last.kind {
                    case .journal: workspace.undoLastMove()
                    case .sort: workspace.undoLastSort()
                    }
                } else {
                    log.append("undo (nothing to undo)")
                    workspace.undoLastMove()
                }
            case 70..<80:
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
                workspace.renameEvent(
                    event.id, name: name, date: event.eventDate.addingTimeInterval(dayShift),
                    policy: event.storagePolicy, parentEventID: parent
                )
                undoables.removeAll()
            case 80..<90:
                let boardKey = eventKeys.randomElement(using: &rng)!
                await library.open(boardKey)
                opened.insert(boardKey)
                if let stacks = workspace.eventStacks[library.id(boardKey)], !stacks.isEmpty {
                    let ids = Set(stacks.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)).map(\.id))
                    log.append("return \(ids.count) stack(s) of \(boardKey) to Unsorted")
                    workspace.returnToUnsorted(ids, eventID: library.id(boardKey))
                    madeChange = true
                }
            case 90..<95:
                let key = eventKeys.randomElement(using: &rng)!
                log.append("delete \(key)")
                let owned = library.assignments(key).count + library.familyAssignments(library.id(key)).count
                workspace.deleteEmptyEvent(library.id(key))
                if owned > 0 {
                    XCTAssertNotNil(workspace.event(library.id(key)), "an event with rows was deleted — \(context(step))")
                } else if workspace.event(library.id(key)) == nil {
                    // Older Undos may name it; they refuse rather than put files into it.
                    undoables.removeAll()
                }
            default:
                let key = eventKeys.randomElement(using: &rng)!
                log.append("re-read \(key)")
                await library.open(key)
                opened.insert(key)
            }

            try await library.settle()
            if ProcessInfo.processInfo.environment["AUDIT_VERBOSE"] != nil {
                print("AUDIT seed \(seed) step \(step): \(log.suffix(2).joined(separator: " ;; ")) | \(model.statusMessage) | sortDepth=\(workspace.undoableSortCount) tracked=\(undoables.map { ($0.kind == .sort ? "S" : "J") + ($0.exact ? "" : "~") }.joined()) trash=\(trashCount(library))")
            }
            let journalsAfter = DriveMoveService.journals(in: workspace.journalFolder).count
            if madeChange {
                let exact = trashCount(library) == trashBefore
                if journalsAfter > journalsBefore {
                    // One journal per job: a click that queued a second move made
                    // two, and Undo takes them one at a time, latest first. The
                    // state between them is not one this harness saw.
                    let sorts = workspace.undoableSortCount - sortDepthBefore
                    for index in 0..<(journalsAfter - journalsBefore) {
                        undoables.append(Undoable(kind: .journal, before: before, description: log.last ?? "", exact: exact && index == 0 && sorts <= 0))
                    }
                    // A catalog-only move clicked beside a renaming one: which
                    // is undone first depends on click order, so neither is exact.
                    for _ in 0..<max(0, sorts) {
                        undoables.append(Undoable(kind: .sort, before: before, description: log.last ?? "", exact: false))
                    }
                } else if workspace.undoableSortCount > sortDepthBefore {
                    // Catalog-only: undone from the sort stack, one entry per click.
                    for index in 0..<(workspace.undoableSortCount - sortDepthBefore) {
                        undoables.append(Undoable(kind: .sort, before: before, description: log.last ?? "", exact: exact && index == 0))
                    }
                } else if snapshot(library) != before {
                    // Changed state without an Undo of its own (a merge): every
                    // older Undo now returns to a state this change is part of.
                    for index in undoables.indices { undoables[index].exact = false }
                }
                // A merge into Trash is not undone by Undo (it restores from the
                // Trash window), so every older Undo lands on a state that keeps it.
                if !exact { for index in undoables.indices { undoables[index].exact = false } }
            } else if roll >= 55 && roll < 70, let last = undoables.last {
                let after = snapshot(library)
                if last.exact {
                    if after != last.before {
                        XCTFail("Undo did not return the exact prior state (\(last.description)): \(diff(after, last.before)) — \(context(step))")
                    }
                }
                undoables.removeLast()
            }
            // Renames and deletes change the paths every older Undo names.
            await check(library, opened: opened, census: census, context: context(step))
        }
    }

    func testRandomizedMovesUndosRenamesAndReturnsKeepEveryInvariant() async throws {
        // AUDIT_SEEDS="7,8" reruns just those; a failure names its seed and step.
        let seeds = ProcessInfo.processInfo.environment["AUDIT_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } } ?? [1, 2, 3, 4, 5, 6]
        let steps = ProcessInfo.processInfo.environment["AUDIT_STEPS"].flatMap { Int($0) } ?? 24
        for seed in seeds {
            try await run(seed: seed, steps: steps)
        }
    }
}
