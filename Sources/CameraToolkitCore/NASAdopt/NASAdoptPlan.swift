import Foundation
import GRDB

/// A reviewed `--adopt-nas` dry run: which NAS event folders become which
/// events, and exactly the catalog rows that adds. `--execute` re-plans
/// and writes these rows only when the fingerprint still matches.
public struct NASAdoptPlan: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-nas-adopt-plan"
    public static let currentVersion = 1

    public struct Folder: Codable, Equatable, Sendable {
        /// `<year>/<event>[/<subevent>…]` under the NAS root.
        public var relativeFolderPath: String
        public var displayName: String
        public var eventID: UUID
        /// "Parent / Child" of the event the files go to.
        public var eventTitle: String
        public var isNewEvent: Bool
        /// Titles of the events this folder creates, root first (the
        /// folder's own event last when it is new).
        public var createdChain: [String]
        public var fileCount: Int
        public var byteCount: Int64
    }

    public struct Row: Codable, Equatable, Sendable {
        public var assignment: PhotoEventAssignment
        /// The NAS file the row stands for, relative to the NAS root.
        public var nasRelativePath: String
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        /// `LayoutMigrationCatalog.digest` of the catalog read for the plan.
        public var catalogDigest: String?
        /// Per planned folder: every file the listing found to adopt, with
        /// its size and modification time.
        public var folderListings: [String: String]
        /// The rows and new events, with each event named by its folder
        /// (new event ids differ between two plans of the same state).
        public var outcomeDigest: String
    }

    public var format: String
    public var version: Int
    public var id: UUID
    public var createdAt: Date
    public var supportFolderPath: String
    public var catalogPath: String
    public var nasRoot: String
    /// `--folder` values; empty means every folder discovery found.
    public var requestedFolders: [String]
    public var folders: [Folder]
    public var newEvents: [SavedCameraEvent]
    public var rows: [Row]
    /// Requested folders discovery did not offer.
    public var notFound: [String]
    public var problems: [NASDiscoveryProblem]
    public var fingerprint: Fingerprint

    public var isExecutable: Bool { !rows.isEmpty && notFound.isEmpty }

    /// Dates stay `Date`'s own number (not ISO 8601), so a file's
    /// modification time — part of its catalog id — survives exactly.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func read(_ url: URL) throws -> NASAdoptPlan {
        let decoder = JSONDecoder()
        let plan = try decoder.decode(NASAdoptPlan.self, from: Data(contentsOf: url))
        guard plan.format == formatName, plan.version == currentVersion else {
            throw ToolkitError.commandFailed("\(url.path) is not a NAS adopt plan (format \(plan.format) v\(plan.version)).")
        }
        return plan
    }

    public func summaryText(rowSample: Int = 20) -> String {
        var lines = ["NAS root:       \(nasRoot)"]
        if folders.isEmpty { lines.append("Nothing to add: no NAS event folder holds files the catalog does not cover.") }
        for folder in folders {
            let target = folder.isNewEvent
                ? "new event \(folder.eventTitle) [\(folder.eventID.uuidString)]"
                : "event \(folder.eventTitle) [\(folder.eventID.uuidString)]"
            lines.append("\(folder.relativeFolderPath)")
            lines.append("    → \(target)")
            if !folder.createdChain.isEmpty { lines.append("    creates: \(folder.createdChain.joined(separator: " → "))") }
            lines.append("    \(folder.fileCount) file(s), \(ByteCountFormatter.string(fromByteCount: folder.byteCount, countStyle: .file))")
        }
        for path in notFound { lines.append("Not found (nothing to add there): \(path)") }
        if !problems.isEmpty {
            lines.append("Left out (\(problems.count)):")
            for problem in problems.prefix(40) { lines.append("    \(problem.path): \(problem.reason)") }
            if problems.count > 40 { lines.append("    … and \(problems.count - 40) more (see the JSON plan)") }
        }
        lines.append("Catalog rows to add: \(newEvents.count) event(s), \(rows.count) assignment(s), nothing else.")
        for row in rows.prefix(rowSample) {
            lines.append("    + \(row.assignment.eventID.uuidString.prefix(8)) \(row.assignment.deviceID ?? "-") \(row.nasRelativePath) (\(row.assignment.fileSize) B)")
        }
        if rows.count > rowSample { lines.append("    … and \(rows.count - rowSample) more (see the JSON plan)") }
        lines.append(isExecutable ? "Plan is executable." : "Plan is NOT executable.")
        return lines.joined(separator: "\n")
    }
}

/// Builds `NASAdoptPlan`s from the same discovery and adoption the sidebar's
/// Add to Events uses. Read-only: the NAS is listed and the catalog read.
public enum NASAdoptPlanner {
    public struct Input {
        public var configuration: AppConfiguration
        public var supportFolder: URL
        public var catalogURL: URL
        public var folders: [String]

        public init(configuration: AppConfiguration, supportFolder: URL, catalogURL: URL, folders: [String]) {
            self.configuration = configuration
            self.supportFolder = supportFolder
            self.catalogURL = catalogURL
            self.folders = folders
        }
    }

    /// The events and assignments the catalog owns, and its digest — read
    /// through a read-only connection.
    public static func readCatalog(_ catalogURL: URL) throws -> (state: CatalogOwnedState, digest: String) {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw ToolkitError.commandFailed("There is no catalog at \(catalogURL.path).")
        }
        var options = Configuration()
        options.readonly = true
        let queue = try DatabaseQueue(path: catalogURL.path, configuration: options)
        defer { try? queue.close() }
        return try queue.read { db in
            guard try CatalogStateStore.ownsState(db) else {
                throw ToolkitError.commandFailed("The catalog does not hold the events yet (the app has not moved them out of config.json).")
            }
            return (try CatalogStateStore.load(db), try LayoutMigrationCatalog.digest(database: db))
        }
    }

    public static func plan(_ input: Input, list: NASEventDiscovery.Lister = DirectoryListing.list, now: Date = Date()) throws -> NASAdoptPlan {
        let catalog = try readCatalog(input.catalogURL)
        return plan(input, state: catalog.state, catalogDigest: catalog.digest, list: list, now: now)
    }

    static func plan(
        _ input: Input,
        state: CatalogOwnedState,
        catalogDigest: String?,
        list: NASEventDiscovery.Lister,
        now: Date
    ) -> NASAdoptPlan {
        var before = input.configuration
        state.apply(to: &before)
        let found = NASEventDiscovery.discover(configuration: before, list: list)
        let requested = input.folders.map(NASTreeListing.trimmed)
        let requestedKeys = Set(requested.map(NASSyncStore.pathKey))
        let selected = requested.isEmpty ? found.events : found.events.filter { requestedKeys.contains(NASSyncStore.pathKey($0.relativeFolderPath)) }
        let foundKeys = Set(found.events.map { NASSyncStore.pathKey($0.relativeFolderPath) })
        let notFound = requested.filter { !foundKeys.contains(NASSyncStore.pathKey($0)) }

        var after = before
        let summary = NASEventDiscovery.adopt(selected, into: &after)
        let existingEventIDs = Set(before.savedEvents.map(\.id))
        let newEvents = after.savedEvents.filter { !existingEventIDs.contains($0.id) }
        let newEventIDs = Set(newEvents.map(\.id))
        let existingRowIDs = Set(before.photoEventAssignments.map(CatalogStore.eventAssetID))
        let added = after.photoEventAssignments.filter { !existingRowIDs.contains(CatalogStore.eventAssetID($0)) }

        let afterLocations = EventStorageLocations(configuration: after)
        let eventsByID = EventHierarchy.index(after.savedEvents)
        func folderPath(_ eventID: UUID) -> String? {
            eventsByID[eventID].map { afterLocations.layout(for: $0, deviceID: nil).mirrorEventFolderPath }
        }
        let rows = added.compactMap { assignment -> NASAdoptPlan.Row? in
            guard let event = eventsByID[assignment.eventID],
                  let mirror = try? afterLocations.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath)
            else { return nil }
            return NASAdoptPlan.Row(assignment: assignment, nasRelativePath: mirror)
        }

        var folders: [NASAdoptPlan.Folder] = []
        var listings: [String: String] = [:]
        for folder in selected {
            let key = NASSyncStore.pathKey(folder.relativeFolderPath)
            listings[folder.relativeFolderPath] = LayoutMigrationHash.sha256(folder.cameras.flatMap { camera in
                camera.files.map { "\(camera.folderName)/\($0.path)\t\($0.size)\t\($0.modifiedAt.timeIntervalSinceReferenceDate)" }
            }.sorted().joined(separator: "\n"))
            guard let event = after.savedEvents.first(where: { folderPath($0.id).map(NASSyncStore.pathKey) == key }) else { continue }
            let chain = EventHierarchy.ancestors(of: event, byID: eventsByID) + [event]
            let ownRows = rows.filter { $0.assignment.eventID == event.id }
            folders.append(NASAdoptPlan.Folder(
                relativeFolderPath: folder.relativeFolderPath,
                displayName: folder.displayName,
                eventID: event.id,
                eventTitle: afterLocations.displayName(for: event),
                isNewEvent: newEventIDs.contains(event.id),
                createdChain: chain.filter { newEventIDs.contains($0.id) }.map { afterLocations.displayName(for: $0) },
                fileCount: ownRows.count,
                byteCount: ownRows.reduce(Int64(0)) { $0 + $1.assignment.fileSize }
            ))
        }

        // The outcome named by folders, not ids: two plans of one state agree.
        var outcome = newEvents.map { event -> String in
            let parent = event.parentEventID.flatMap(folderPath) ?? "-"
            return "event\t\(folderPath(event.id) ?? "?")\t\(event.name)\t\(EventStorageLocations.eventDateString(event.eventDate))\t\(parent)\t\(event.storagePolicy?.rawValue ?? "-")"
        }
        outcome += rows.map { row in
            let a = row.assignment
            return "row\t\(folderPath(a.eventID) ?? "?")\t\(a.sourceRootPath)\t\(a.relativePath)\t\(a.fileSize)\t\(a.modifiedAt.timeIntervalSinceReferenceDate)\t\(a.deviceID ?? "-")\t\(row.nasRelativePath)"
        }
        let selectedPaths = selected.map(\.relativeFolderPath)
        let problems = (found.problems + summary.problems).filter { problem in
            requested.isEmpty || selectedPaths.contains { NASSyncStore.pathKey(problem.path).hasPrefix(NASSyncStore.pathKey($0) + "/") || NASSyncStore.pathKey(problem.path) == NASSyncStore.pathKey($0) }
        }

        return NASAdoptPlan(
            format: NASAdoptPlan.formatName,
            version: NASAdoptPlan.currentVersion,
            id: UUID(),
            createdAt: now,
            supportFolderPath: input.supportFolder.standardizedFileURL.path,
            catalogPath: input.catalogURL.standardizedFileURL.path,
            nasRoot: afterLocations.nasRoot.path,
            requestedFolders: requested,
            folders: folders,
            newEvents: newEvents,
            rows: rows,
            notFound: notFound,
            problems: problems,
            fingerprint: NASAdoptPlan.Fingerprint(
                catalogDigest: catalogDigest,
                folderListings: listings,
                outcomeDigest: LayoutMigrationHash.sha256(outcome.sorted().joined(separator: "\n"))
            )
        )
    }
}
