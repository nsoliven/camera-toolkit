import Foundation

/// A photo only the NAS has can lose its NAS copy's *place*: the catalog
/// moved its entry to another event, but the rename that was to follow it
/// on the NAS never landed (a share error, a crash between the two, the
/// journal lost). Nothing on the drive says where the copy went, so neither
/// catch-up (it starts from drive files) nor reconcile (it needs the drive)
/// ever finds it, and the entry points at nothing.
///
/// This finds those entries from what is already known and, when exactly
/// one NAS copy fits, proposes the rename that puts it where the catalog
/// looks — never a copy, never anything replaced:
///
/// - the entry's NAS path has no file of its size (one listing per folder);
/// - a verified sync record sits at a path that no assignment owns, is not
///   on the drive, and has the entry's size and modification time;
/// - the file is still there, at that size;
/// - exactly one such copy fits (or exactly one has the entry's file name).
///
/// Several fits, or two entries wanting one copy, are reported and left.
extension NASCatchUp {
    /// One missing NAS copy and the copy that is very probably it.
    public struct Repair: Equatable, Sendable {
        public var assignment: PhotoEventAssignment
        /// Where the catalog looks for the copy (relative to the NAS root).
        public var expectedPath: String
        /// The record of the copy found at another path.
        public var orphan: NASSyncRecord
    }

    public struct RepairAnalysis: Equatable, Sendable {
        public var repairs: [Repair] = []
        /// Entries whose copy is missing and that more than one (or no
        /// unambiguous) NAS file fits. Left as they are.
        public var ambiguous: [PhotoEventAssignment] = []
        public init() {}
        public var isEmpty: Bool { repairs.isEmpty && ambiguous.isEmpty }
    }

    /// Modification times agree within this many seconds (an assignment
    /// keeps the file's time as the card gave it; a server may round).
    static let repairTimeTolerance: Double = 2

    public static func repairs(
        assignments: [PhotoEventAssignment],
        plan: NASSyncPlan,
        records: [String: NASSyncRecord],
        ownedKeys: Set<String>,
        locations: EventStorageLocations,
        nasRoot: String,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> RepairAnalysis {
        var analysis = RepairAnalysis()
        guard !assignments.isEmpty else { return analysis }
        let planKeys = Set(plan.items.map { NASSyncStore.pathKey($0.relativePath) })
        let driveMounted = driveIsMounted(locations)
        func onDrive(_ relative: String) -> Bool {
            driveMounted && [locations.bufferRoot, locations.privateStagingRoot].contains { DriveMoveService.exists($0.path + "/" + relative) }
        }

        // NAS copies no entry, no planned drive file and no drive file owns.
        var orphans: [NASSyncRecord] = []
        for record in records.values.sorted(by: { $0.pathKey < $1.pathKey }) {
            guard record.state == .verified, record.sha256 != nil, NASMoveFollower.isEventPath(record.relativePath),
                  isOriginalsPath(record.relativePath),
                  !ownedKeys.contains(record.pathKey), !planKeys.contains(record.pathKey), !onDrive(record.relativePath) else { continue }
            orphans.append(record)
        }
        // No candidate copy: nothing to find, so nothing is listed.
        guard !orphans.isEmpty else { return analysis }

        // Which entries have no file at their NAS path.
        let events = Dictionary(locations.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var listings: [String: [String: DirectoryListingEntry]] = [:]
        func entries(in folder: String) -> [String: DirectoryListingEntry] {
            if let known = listings[folder] { return known }
            let listed = (try? DirectoryListing.list(nasRoot + "/" + folder)) ?? []
            let byKey = Dictionary(listed.map { (NASSyncStore.pathKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
            listings[folder] = byKey
            return byKey
        }
        struct Missing {
            var assignment: PhotoEventAssignment
            var expected: String
        }
        var missing: [Missing] = []
        for assignment in assignments {
            if isCancelled() { return analysis }
            guard let event = events[assignment.eventID],
                  let expected = try? locations.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath),
                  NASMoveFollower.isEventPath(expected),
                  !planKeys.contains(NASSyncStore.pathKey(expected)) else { continue }
            let folder = (expected as NSString).deletingLastPathComponent
            let name = (expected as NSString).lastPathComponent
            // Anything at the path — the right file, or a different one — is
            // not a gap a rename can fill: nothing is ever replaced.
            if entries(in: folder)[NASSyncStore.pathKey(name)] != nil { continue }
            missing.append(Missing(assignment: assignment, expected: expected))
        }
        guard !missing.isEmpty else { return analysis }

        func leaf(_ path: String) -> String { NASSyncStore.pathKey((path as NSString).lastPathComponent) }
        var candidatesByEntry: [Int: [NASSyncRecord]] = [:]
        for (index, gap) in missing.enumerated() {
            let modified = gap.assignment.modifiedAt.timeIntervalSinceReferenceDate
            let fits = orphans.filter { orphan in
                orphan.byteCount == gap.assignment.fileSize
                    && orphan.sourceModifiedAt.map { abs($0 - modified) <= repairTimeTolerance } == true
            }
            candidatesByEntry[index] = fits
        }
        var claims: [String: Int] = [:]
        var chosen: [Int: NASSyncRecord] = [:]
        for index in missing.indices {
            var fits = candidatesByEntry[index] ?? []
            if fits.count > 1 {
                let sameName = fits.filter { leaf($0.relativePath) == leaf(missing[index].expected) }
                if sameName.count == 1 { fits = sameName }
            }
            guard fits.count == 1, let orphan = fits.first else {
                if !fits.isEmpty { analysis.ambiguous.append(missing[index].assignment) }
                continue
            }
            chosen[index] = orphan
            claims[orphan.pathKey, default: 0] += 1
        }
        for index in missing.indices.sorted() {
            guard let orphan = chosen[index] else { continue }
            guard claims[orphan.pathKey] == 1 else {
                analysis.ambiguous.append(missing[index].assignment)
                continue
            }
            // The copy must still be there, at the size the record says.
            guard let entry = LayoutMigrationDisk.lstatEntry(nasRoot + "/" + orphan.relativePath),
                  entry.kind == .file, entry.size == orphan.byteCount else { continue }
            analysis.repairs.append(Repair(assignment: missing[index].assignment, expectedPath: missing[index].expected, orphan: orphan))
        }
        return analysis
    }

    /// The renames the repairs owe, each orphan once.
    public static func renames(for repairs: [Repair]) -> [NASRename] {
        var used = Set<String>()
        return repairs.compactMap { repair in
            guard used.insert(repair.orphan.pathKey).inserted else { return nil }
            return NASRename(
                from: repair.orphan.relativePath,
                to: repair.expectedPath,
                byteCount: repair.assignment.fileSize,
                eventID: repair.assignment.eventID,
                previousEventID: repair.orphan.eventID
            )
        }
    }
}
