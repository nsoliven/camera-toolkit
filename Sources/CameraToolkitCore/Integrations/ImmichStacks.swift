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
        // Edits by event folder (`<year>/<event folder>`).
        var editsByFolder: [String: [String]] = [:]
        for path in editPaths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count > 3, let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("Edited") == .orderedSame }), index >= 2 else { continue }
            editsByFolder[parts.prefix(2).joined(separator: "/"), default: []].append(path)
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
            let folders = Set(eventFiles.compactMap { file -> String? in
                let parts = file.relativePath.split(separator: "/", omittingEmptySubsequences: true)
                return parts.count > 2 ? parts.prefix(2).joined(separator: "/") : nil
            })
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
    public var stackID: String
    public var eventID: UUID
    public var kind: ImmichStackKind
    public var assetIDs: [String]
    public var createdAt: Date

    public init(key: String, stackID: String, eventID: UUID, kind: ImmichStackKind, assetIDs: [String], createdAt: Date = Date()) {
        self.key = key
        self.stackID = stackID
        self.eventID = eventID
        self.kind = kind
        self.assetIDs = assetIDs
        self.createdAt = createdAt
    }
}

public struct ImmichStackPlan: Equatable, Sendable {
    public struct Create: Equatable, Sendable {
        public var group: ImmichStackGroup
        /// Top first.
        public var assetIDs: [String]
        /// The app's own stack this one replaces (a frame was added or renamed).
        public var replacing: String?
    }

    public struct Skip: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// Fewer than two of its files are in Immich.
            case notInImmich(found: Int, of: Int)
            /// Some of its photos are in a stack the app did not make.
            case inSomeoneElsesStack(stackID: String)
        }

        public var group: ImmichStackGroup
        public var reason: Reason
    }

    public var creates: [Create] = []
    public var unchanged = 0
    public var skipped: [Skip] = []

    public var skippedNotInImmich: Int { skipped.count { if case .notInImmich = $0.reason { true } else { false } } }
    public var skippedForeign: Int { skipped.count { if case .inSomeoneElsesStack = $0.reason { true } else { false } } }

    public var summary: String {
        var parts = ["\(creates.count.formatted()) stack\(creates.count == 1 ? "" : "s") to make", "\(unchanged.formatted()) already stacked by the app"]
        if skippedNotInImmich > 0 { parts.append("\(skippedNotInImmich.formatted()) not matched in Immich") }
        if skippedForeign > 0 { parts.append("\(skippedForeign.formatted()) left alone (already in a stack the app did not make)") }
        return parts.joined(separator: ", ")
    }
}

public enum ImmichStackPlanner {
    /// What to create so each group is one stack, never touching a stack the
    /// app did not make. Immich's create merges any stack whose top photo is
    /// among the IDs and pulls other members out of their stacks, so a group
    /// with any photo in someone else's stack is skipped, not created.
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
        let ours = Set(records.values.map(\.stackID))

        var plan = ImmichStackPlan()
        for group in groups {
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
            let record = records[group.key]
            if let record, let current = accountByID[record.stackID],
               current.primaryAssetID == ids[0], Set(current.assetIDs) == Set(ids) {
                plan.unchanged += 1
                continue
            }
            plan.creates.append(.init(group: group, assetIDs: ids, replacing: record?.stackID))
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

    /// Stacks per event, for the event header.
    public func countsByEvent() throws -> [UUID: Int] {
        try records().values.reduce(into: [:]) { $0[$1.eventID, default: 0] += 1 }
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
    /// Plans and, unless `dryRun`, creates the stacks. Only ever creates or
    /// replaces the app's own stacks; never deletes one.
    public static func run(
        client: ImmichClient,
        groups: [ImmichStackGroup],
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        store: ImmichStackStore,
        dryRun: Bool,
        log: ((ImmichStackRecord) -> Void)? = nil
    ) async throws -> ImmichStackRunReport {
        let accountStacks = try await client.stacks()
        let plan = ImmichStackPlanner.plan(groups: groups, assets: assets, library: library, accountStacks: accountStacks, records: try store.records())
        var report = ImmichStackRunReport(plan: plan)
        guard !dryRun else { return report }
        for create in plan.creates {
            do {
                var stack = try await client.createStack(assetIDs: create.assetIDs)
                if stack.primaryAssetID != create.assetIDs[0] {
                    try await client.setStackPrimary(stackID: stack.id, assetID: create.assetIDs[0])
                    stack.primaryAssetID = create.assetIDs[0]
                }
                let record = ImmichStackRecord(key: create.group.key, stackID: stack.id, eventID: create.group.eventID, kind: create.group.kind, assetIDs: create.assetIDs)
                try store.save(record)
                log?(record)
                report.created.append(record)
            } catch {
                report.problems.append(error.localizedDescription)
            }
        }
        return report
    }
}
