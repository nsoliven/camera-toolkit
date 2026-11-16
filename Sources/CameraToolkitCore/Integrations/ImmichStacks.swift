import Foundation
import GRDB

// MARK: - Groups

public enum ImmichStackKind: String, Codable, Sendable {
    /// A burst as the board groups it; its cover frame on top.
    case burst
    /// A RAW file and the JPEG of the same shot.
    case rawPair
    /// An original with its edit (a Photomator export, a graded copy) on top.
    case edit
}

/// Files that belong in one Immich stack, top of the stack first.
public struct ImmichStackGroup: Equatable, Sendable {
    /// Stable across runs and renames: the event, the kind, and the first
    /// frame's name, size and time.
    public var key: String
    public var eventID: UUID
    public var kind: ImmichStackKind
    /// Paths under the NAS root, top first.
    public var relativePaths: [String]

    public init(key: String, eventID: UUID, kind: ImmichStackKind, relativePaths: [String]) {
        self.key = key
        self.eventID = eventID
        self.kind = kind
        self.relativePaths = relativePaths
    }
}

public enum ImmichStackGrouping {
    /// The stacks each event's files form: bursts, RAW+JPEG pairs, and edits.
    ///
    /// Bursts come from the board's own grouping (`OrganizeStacker`) on the
    /// catalog's files, with each file's modification time standing in for
    /// its camera time, so nothing is read from the NAS. A file whose time was
    /// changed after shooting may stay out of its burst; it is never pulled
    /// into another. Frames the board
    /// joins only after a visual check, and manual burst splits, are not
    /// known here; such a burst can come out as two smaller stacks, never a
    /// bigger one.
    ///
    /// `editPaths` are files in the events' `Edited` folders (from Immich's
    /// listing). An edit joins the original whose name its own name starts
    /// with (`DSC00001` → `DSC00001_709`), in the same event only.
    public static func groups(files: [ImmichCatalogFile], editPaths: [String] = []) -> [ImmichStackGroup] {
        var result: [ImmichStackGroup] = []
        let byEvent = Dictionary(grouping: files.filter { $0.eventID != nil }, by: { $0.eventID! })
        // Edits by the event folder that holds their `Edited` folder, so a
        // parent's edits never join a subevent's photos or the other way round.
        var editsByFolder: [String: [String]] = [:]
        for path in editPaths {
            guard let folder = ownFolder(of: path, marker: "Edited") else { continue }
            editsByFolder[folder, default: []].append(path)
        }

        for eventID in byEvent.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let eventFiles = byEvent[eventID] ?? []
            let organizeFiles = eventFiles.map { OrganizeFile(literalPath: "/" + $0.relativePath, size: $0.byteCount, modifiedAt: $0.modifiedAt) }
            // The camera set each file's modification time when it shot it, and
            // verified copies keep it, so it stands in for the capture time.
            let items = OrganizeScanner.items(for: organizeFiles, cache: nil, concurrency: 1, readMissingCaptureDates: false).items.map { item in
                OrganizeItem(
                    primary: item.primary,
                    companions: item.companions,
                    kind: item.kind,
                    captureDate: item.primary.modifiedAt,
                    hasCameraDate: true,
                    metadataCamera: item.metadataCamera
                )
            }
            let stacks = OrganizeStacker.stacks(for: items)

            var groups: [(key: String, kind: ImmichStackKind, paths: [String], stems: [String])] = []
            for stack in stacks {
                let first = stack.items[0].primary
                let identity = BurstFrameIdentity.key(fileName: first.name, byteCount: first.size, modifiedAt: first.modifiedAt)
                if stack.isBurst {
                    let cover = stack.coverItem
                    let ordered = [cover] + stack.items.filter { $0.id != cover.id }
                    groups.append(("\(eventID.uuidString)|burst|\(identity)", .burst, ordered.flatMap(paths(of:)), stack.items.map(\.primary.stem)))
                } else if let item = stack.items.first {
                    groups.append(("\(eventID.uuidString)|pair|\(identity)", item.companions.isEmpty ? .edit : .rawPair, paths(of: item), [item.primary.stem]))
                }
            }

            // Edits join their original's group: on top of a pair or a single,
            // right under the cover of a burst.
            let folders = Set(eventFiles.compactMap { ownFolder(of: $0.relativePath, marker: "Originals") })
            var edits: [Int: [String]] = [:]
            for folder in folders.sorted() {
                for edit in (editsByFolder[folder] ?? []).sorted() {
                    let editStem = ((edit as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                    var best: (index: Int, length: Int)?
                    for (index, group) in groups.enumerated() {
                        for stem in group.stems where isEdit(editStem, of: stem) && stem.count > (best?.length ?? 0) {
                            best = (index, stem.count)
                        }
                    }
                    if let best { edits[best.index, default: []].append(edit) }
                }
            }
            for (index, group) in groups.enumerated() {
                let groupEdits = edits[index] ?? []
                let paths: [String]
                switch group.kind {
                case .burst: paths = [group.paths[0]] + groupEdits + group.paths.dropFirst()
                case .rawPair, .edit: paths = groupEdits + group.paths
                }
                // A lone file with no edit is no stack.
                guard paths.count > 1 else { continue }
                let kind: ImmichStackKind = group.kind == .burst ? .burst : (groupEdits.isEmpty ? .rawPair : .edit)
                result.append(ImmichStackGroup(key: group.key, eventID: eventID, kind: kind, relativePaths: paths))
            }
        }
        return result
    }

    /// The event folder a file sits in: everything before its `Originals`
    /// (or `Edited`) folder, e.g. `2026/2026-01-01 Trip/Beach`.
    static func ownFolder(of path: String, marker: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.lastIndex(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }), index >= 1, index < parts.count - 1 else { return nil }
        return parts[..<index].joined(separator: "/").lowercased()
    }

    /// The files whose events may be stacked: a private event's only when
    /// Allow album is on for it.
    public static func stackableEventIDs(events: [SavedCameraEvent], locations: EventStorageLocations) -> Set<UUID> {
        Set(events.filter { locations.resolvedPolicy(for: $0) != .archiveOnly || $0.sendsToImmich }.map(\.id))
    }

    private static func paths(of item: OrganizeItem) -> [String] {
        ([item.primary] + item.companions).map { String($0.path.dropFirst()) }
    }

    /// `DSC00001_709` and `DSC00001-Edit` are edits of `DSC00001`;
    /// `DSC000012` is not.
    static func isEdit(_ editStem: String, of stem: String) -> Bool {
        guard !stem.isEmpty, editStem.hasPrefix(stem) else { return false }
        let rest = editStem.dropFirst(stem.count)
        guard let next = rest.first else { return true }
        return !next.isLetter && !next.isNumber
    }
}

// MARK: - Plan

/// A stack as Immich has it.
public struct ImmichAccountStack: Equatable, Sendable {
    public var id: String
    public var primaryAssetID: String
    public var assetIDs: [String]

    public init(id: String, primaryAssetID: String, assetIDs: [String]) {
        self.id = id
        self.primaryAssetID = primaryAssetID
        self.assetIDs = assetIDs
    }
}

/// A stack the app made.
public struct ImmichStackRecord: Codable, Equatable, Sendable {
    public var key: String
    /// Empty while the app has removed its old stack to rebuild it.
    public var stackID: String
    public var eventID: UUID
    public var kind: ImmichStackKind
    public var assetIDs: [String]
    public var createdAt: Date
    /// The stack is gone from Immich (someone unstacked it there), so the app
    /// never makes it again.
    public var removedInImmich: Bool?

    public init(key: String, stackID: String, eventID: UUID, kind: ImmichStackKind, assetIDs: [String], createdAt: Date = Date(), removedInImmich: Bool? = nil) {
        self.key = key
        self.stackID = stackID
        self.eventID = eventID
        self.kind = kind
        self.assetIDs = assetIDs
        self.createdAt = createdAt
        self.removedInImmich = removedInImmich
    }
}

/// One line of the stack change log.
public struct ImmichStackLogEntry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case created
        /// The app removed its own earlier stack before making the group again.
        case removedOwn
        /// A create whose answer was lost: the stack with exactly these
        /// assets was found and taken as the app's.
        case adopted
    }

    public var at: Date
    public var action: Action
    public var stackID: String
    public var groupKey: String
    public var assetIDs: [String]

    public init(at: Date = Date(), action: Action, stackID: String, groupKey: String, assetIDs: [String]) {
        self.at = at
        self.action = action
        self.stackID = stackID
        self.groupKey = groupKey
        self.assetIDs = assetIDs
    }
}

public struct ImmichStackPlan: Equatable, Sendable {
    public struct Create: Equatable, Sendable {
        public var group: ImmichStackGroup
        /// Top first.
        public var assetIDs: [String]
        /// The app's own stack to remove first (a member left or a frame was
        /// renamed). Removing it, rather than letting Immich merge it, keeps a
        /// departed member from being pulled back in.
        public var replacing: String?
    }

    public struct Skip: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// Fewer than two of its files are in Immich.
            case notInImmich(found: Int, of: Int)
            /// Some of its photos are in a stack the app did not make.
            case inSomeoneElsesStack(stackID: String)
            /// The app made it once and it was unstacked in Immich since.
            case removedInImmich
        }

        public var group: ImmichStackGroup
        public var reason: Reason
    }

    public var creates: [Create] = []
    public var unchanged = 0
    public var skipped: [Skip] = []
    /// Groups whose stack disappeared from Immich since the last run.
    public var newlyRemoved: [String] = []

    public var skippedNotInImmich: Int { skipped.count { if case .notInImmich = $0.reason { true } else { false } } }
    public var skippedForeign: Int { skipped.count { if case .inSomeoneElsesStack = $0.reason { true } else { false } } }
    public var skippedRemoved: Int { skipped.count { $0.reason == .removedInImmich } }

    public var summary: String {
        var parts = ["\(creates.count.formatted()) stack\(creates.count == 1 ? "" : "s") to make", "\(unchanged.formatted()) already stacked by the app"]
        if skippedNotInImmich > 0 { parts.append("\(skippedNotInImmich.formatted()) not matched in Immich") }
        if skippedForeign > 0 { parts.append("\(skippedForeign.formatted()) left alone (already in a stack the app did not make)") }
        if skippedRemoved > 0 { parts.append("\(skippedRemoved.formatted()) unstacked in Immich, not made again") }
        return parts.joined(separator: ", ")
    }
}

public enum ImmichStackPlanner {
    /// What to create so each group is one stack, never touching a stack the
    /// app did not make. Immich's create merges any stack whose top photo is
    /// among the IDs and pulls other members out of their stacks, so a group
    /// with any photo in someone else's stack is skipped, not created.
    /// A stack the user unstacked is not made again; one whose cover they
    /// changed is left as it is.
    public static func plan(
        groups: [ImmichStackGroup],
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        accountStacks: [ImmichAccountStack],
        records: [String: ImmichStackRecord]
    ) -> ImmichStackPlan {
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        var assetByKey: [String: String] = [:]
        for asset in assets where !asset.isOffline && !asset.isTrashed {
            guard let relative = paths.relativePath(forOriginalPath: asset.originalPath) else { continue }
            assetByKey[NASSyncStore.pathKey(relative)] = asset.id
        }
        var stackOfAsset: [String: ImmichAccountStack] = [:]
        for stack in accountStacks {
            for id in stack.assetIDs { stackOfAsset[id] = stack }
        }
        let accountByID = Dictionary(accountStacks.map { ($0.id, $0) }) { first, _ in first }
        let ours = Set(records.values.map(\.stackID).filter { !$0.isEmpty })

        var plan = ImmichStackPlan()
        for group in groups {
            let record = records[group.key]
            if record?.removedInImmich == true {
                plan.skipped.append(.init(group: group, reason: .removedInImmich))
                continue
            }
            if let record, !record.stackID.isEmpty, accountByID[record.stackID] == nil {
                plan.skipped.append(.init(group: group, reason: .removedInImmich))
                plan.newlyRemoved.append(group.key)
                continue
            }
            var ids: [String] = []
            for path in group.relativePaths {
                if let id = assetByKey[NASSyncStore.pathKey(path)], !ids.contains(id) { ids.append(id) }
            }
            guard ids.count >= 2 else {
                plan.skipped.append(.init(group: group, reason: .notInImmich(found: ids.count, of: group.relativePaths.count)))
                continue
            }
            if let foreign = ids.compactMap({ stackOfAsset[$0] }).first(where: { !ours.contains($0.id) }) {
                plan.skipped.append(.init(group: group, reason: .inSomeoneElsesStack(stackID: foreign.id)))
                continue
            }
            if let record, let current = accountByID[record.stackID], Set(current.assetIDs) == Set(ids) {
                // Any cover: the user may have picked another.
                plan.unchanged += 1
                continue
            }
            let replacing = record.flatMap { accountByID[$0.stackID] != nil ? $0.stackID : nil }
            plan.creates.append(.init(group: group, assetIDs: ids, replacing: replacing))
        }
        return plan
    }
}

// MARK: - Store and run

/// The stacks the app made, by group, in the catalog: what tells the app's
/// stacks from everyone else's, and the list to undo from.
public final class ImmichStackStore: @unchecked Sendable {
    static let schema = """
    CREATE TABLE IF NOT EXISTS immich_stacks (
        group_key TEXT PRIMARY KEY,
        event_id TEXT NOT NULL,
        record TEXT NOT NULL
    );
    """

    public let catalogURL: URL

    public init(catalogURL: URL) throws {
        self.catalogURL = catalogURL
        try CatalogDatabase.writer(for: catalogURL).write { try $0.execute(sql: Self.schema) }
    }

    public func records() throws -> [String: ImmichStackRecord] {
        let decoder = JSONDecoder()
        return try CatalogDatabase.writer(for: catalogURL).read { database in
            var result: [String: ImmichStackRecord] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT record FROM immich_stacks") {
                if let record = try? decoder.decode(ImmichStackRecord.self, from: Data((row["record"] as String).utf8)) {
                    result[record.key] = record
                }
            }
            return result
        }
    }

    public func save(_ record: ImmichStackRecord) throws {
        let data = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try CatalogDatabase.writer(for: catalogURL).write { database in
            try database.execute(
                sql: "INSERT INTO immich_stacks(group_key, event_id, record) VALUES (?, ?, ?) ON CONFLICT(group_key) DO UPDATE SET event_id = excluded.event_id, record = excluded.record",
                arguments: [record.key, record.eventID.uuidString, data]
            )
        }
    }

    /// Live stacks per event, for the event header.
    public func countsByEvent() throws -> [UUID: Int] {
        try records().values.filter { !$0.stackID.isEmpty && $0.removedInImmich != true }.reduce(into: [:]) { $0[$1.eventID, default: 0] += 1 }
    }
}

public struct ImmichStackRunReport: Equatable, Sendable {
    public var plan: ImmichStackPlan
    public var created: [ImmichStackRecord] = []
    public var problems: [String] = []

    public var summary: String {
        var text = plan.summary
        if !created.isEmpty { text += "; made \(created.count.formatted())" }
        if !problems.isEmpty { text += "; \(problems.count) problem(s): \(problems.prefix(3).joined(separator: "; "))" }
        return text
    }
}

public enum ImmichStackRunner {
    /// Plans and, unless `dryRun`, makes the stacks. Only ever makes, replaces
    /// or removes the app's own stacks. The writes run to the end even when
    /// the caller is cancelled, so no stack is made without being recorded.
    public static func run(
        client: ImmichClient,
        groups: [ImmichStackGroup],
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        store: ImmichStackStore,
        dryRun: Bool,
        log: (@Sendable (ImmichStackLogEntry) -> Void)? = nil
    ) async throws -> ImmichStackRunReport {
        let accountStacks = try await client.stacks()
        let records = try store.records()
        let plan = ImmichStackPlanner.plan(groups: groups, assets: assets, library: library, accountStacks: accountStacks, records: records)
        guard !dryRun else { return ImmichStackRunReport(plan: plan) }
        return await Task.detached {
            await execute(plan, client: client, store: store, records: records, log: log)
        }.value
    }

    private static func execute(
        _ plan: ImmichStackPlan,
        client: ImmichClient,
        store: ImmichStackStore,
        records: [String: ImmichStackRecord],
        log: (@Sendable (ImmichStackLogEntry) -> Void)?
    ) async -> ImmichStackRunReport {
        var report = ImmichStackRunReport(plan: plan)
        for key in plan.newlyRemoved {
            guard var record = records[key] else { continue }
            record.removedInImmich = true
            try? store.save(record)
        }
        for create in plan.creates {
            let group = create.group
            do {
                if let old = create.replacing {
                    try await client.deleteStack(stackID: old)
                    log?(ImmichStackLogEntry(action: .removedOwn, stackID: old, groupKey: group.key, assetIDs: records[group.key]?.assetIDs ?? []))
                    // Until the new stack exists, the record says the app is rebuilding it.
                    try store.save(ImmichStackRecord(key: group.key, stackID: "", eventID: group.eventID, kind: group.kind, assetIDs: create.assetIDs))
                }
                var stack: ImmichAccountStack
                var action = ImmichStackLogEntry.Action.created
                do {
                    stack = try await client.createStack(assetIDs: create.assetIDs)
                } catch {
                    // The answer may have been lost after Immich made it.
                    guard let found = try? await client.stacks().first(where: { Set($0.assetIDs) == Set(create.assetIDs) }) else { throw error }
                    stack = found
                    action = .adopted
                }
                if stack.primaryAssetID != create.assetIDs[0], stack.assetIDs.contains(create.assetIDs[0]) {
                    try await client.setStackPrimary(stackID: stack.id, assetID: create.assetIDs[0])
                    stack.primaryAssetID = create.assetIDs[0]
                }
                if Set(stack.assetIDs) != Set(create.assetIDs) {
                    report.problems.append("stack \(stack.id) holds \(stack.assetIDs.count) assets, not the \(create.assetIDs.count) asked for")
                }
                let record = ImmichStackRecord(key: group.key, stackID: stack.id, eventID: group.eventID, kind: group.kind, assetIDs: stack.assetIDs)
                try store.save(record)
                log?(ImmichStackLogEntry(action: action, stackID: stack.id, groupKey: group.key, assetIDs: stack.assetIDs))
                report.created.append(record)
            } catch {
                report.problems.append(error.localizedDescription)
            }
        }
        return report
    }
}
