import Foundation
import GRDB

/// Where one catalog file stands against an Immich external library. The raw
/// values are stored in `immich_assets.status`.
public enum ImmichPresenceStatus: String, CaseIterable, Sendable {
    /// Immich has an asset at this file's NAS path.
    case present
    /// Immich has an asset at this path but its last scan could not find the file.
    case offline
    /// The NAS has the file and Immich does not list it yet.
    case pendingScan
    /// The library will never import it: a file type Immich does not read,
    /// or a path its exclusion patterns cover.
    case excluded
    /// No verified NAS copy on record, so Immich cannot see it.
    case notOnNAS
}

extension ImmichCatalogStatus {
    /// Nil for a row this mode did not write.
    public var presence: ImmichPresenceStatus? { ImmichPresenceStatus(rawValue: status) }
}

/// What one event's storage strip says about Immich.
public struct ImmichEventSummary: Equatable, Sendable {
    public var inImmich = 0
    public var inTrash = 0
    public var pendingScan = 0
    public var offline = 0

    public init(statuses: some Sequence<ImmichCatalogStatus>) {
        for status in statuses {
            switch status.presence {
            case .present:
                if status.isTrashed { inTrash += 1 } else { inImmich += 1 }
            case .pendingScan: pendingScan += 1
            case .offline: offline += 1
            case .excluded, .notOnNAS, nil: break
            }
        }
    }

    public var needsAttention: Bool { pendingScan > 0 || offline > 0 || inTrash > 0 }
    public var isEmpty: Bool { inImmich == 0 && !needsAttention }

    /// "12 waiting for scan · 3 offline", or nil when nothing is outstanding.
    public var outstandingText: String? {
        var parts: [String] = []
        if pendingScan > 0 { parts.append("\(pendingScan.formatted()) waiting for scan") }
        if offline > 0 { parts.append("\(offline.formatted()) offline") }
        if inTrash > 0 { parts.append("\(inTrash.formatted()) in Immich trash") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension SavedCameraEvent {
    /// The album this event keeps in Immich, if any. A private event gets
    /// none unless it was opted in by hand (`immichUploadEnabled`).
    public func immichAlbumTitle(isPrivate: Bool) -> String? {
        if isPrivate, !sendsToImmich { return nil }
        switch resolvedImmichAlbumPolicy {
        case .none: return nil
        case .event: return name
        case .custom:
            let custom = immichAlbumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return custom.isEmpty ? name : custom
        }
    }
}

/// One catalog file as the external-library check sees it.
public struct ImmichCatalogFile: Equatable, Sendable {
    public var eventAssetID: String
    /// The file's path under the NAS root.
    public var relativePath: String
    public var isOnNAS: Bool
    public var albumName: String?

    public init(eventAssetID: String, relativePath: String, isOnNAS: Bool, albumName: String? = nil) {
        self.eventAssetID = eventAssetID
        self.relativePath = relativePath
        self.isOnNAS = isOnNAS
        self.albumName = albumName
    }

    /// Every assignment that has a NAS path. `verifiedPathKeys` are the
    /// `NASSyncStore.pathKey`s Sync to NAS has verified.
    public static func build(
        assignments: [PhotoEventAssignment],
        events: [SavedCameraEvent],
        locations: EventStorageLocations,
        verifiedPathKeys: Set<String>
    ) -> [ImmichCatalogFile] {
        let eventsByID = Dictionary(events.map { ($0.id, $0) }) { first, _ in first }
        return assignments.compactMap { assignment in
            guard let event = eventsByID[assignment.eventID],
                  let relative = locations.archiveRelativePath(for: assignment, event: event) else { return nil }
            let isPrivate = locations.resolvedPolicy(for: event) == .archiveOnly
            return ImmichCatalogFile(
                eventAssetID: CatalogStore.eventAssetID(assignment),
                relativePath: relative,
                isOnNAS: verifiedPathKeys.contains(NASSyncStore.pathKey(relative)),
                albumName: assignment.immichUploadOverride == false ? nil : event.immichAlbumTitle(isPrivate: isPrivate)
            )
        }
    }
}

/// Turns the server's paths into paths under the NAS root: the library's
/// import folder on the server is the NAS root the app syncs to.
public struct ImmichLibraryPaths: Sendable {
    private let roots: [String]

    public init(importPaths: [String]) {
        roots = importPaths
            .map { path in
                var root = path
                while root.count > 1, root.hasSuffix("/") { root.removeLast() }
                return root
            }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public func relativePath(forOriginalPath path: String) -> String? {
        for root in roots where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return nil
    }

    public func originalPath(forRelativePath relative: String) -> String? {
        roots.last.map { "\($0)/\(relative)" }
    }
}

/// The library's exclusion globs, matched against the full server path the
/// way the server matches them.
public struct ImmichExclusionMatcher {
    private let expressions: [NSRegularExpression]

    public init(patterns: [String]) {
        expressions = patterns.compactMap { try? NSRegularExpression(pattern: Self.regex(forGlob: $0)) }
    }

    public func isExcluded(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return expressions.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    static func regex(forGlob glob: String) -> String {
        let characters = Array(glob)
        var result = "^"
        var braceDepth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        result += "(?:.*/)?"
                        index += 2
                    } else {
                        result += ".*"
                        index += 1
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case "[":
                if let close = characters[index...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(characters[(index + 1)..<close]).replacingOccurrences(of: "\\", with: "\\\\")
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    result += "[\(body)]"
                    index = close
                } else {
                    result += "\\["
                }
            case "{":
                braceDepth += 1
                result += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                result += ")"
            case "," where braceDepth > 0:
                result += "|"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        // An unclosed brace is a broken pattern; it matches nothing.
        return braceDepth == 0 ? result + "$" : "(?!)"
    }
}

/// The answer of one comparison between the catalog and the library.
public struct ImmichReconcileReport: Equatable, Sendable {
    public var statuses: [ImmichCatalogStatus] = []
    public var counts: [ImmichPresenceStatus: Int] = [:]
    /// Paths with more than one asset. An external library should have none.
    public var duplicatedPaths = 0
    /// Offline assets no catalog file points at: usually a renamed file's old path.
    public var offlineOutsideCatalog = 0
    /// Assets under the library that no catalog file claims.
    public var assetsOutsideCatalog = 0
    /// False when the library has assets and files are on the NAS but no path
    /// matched: the library is not reading the NAS root the app syncs to.
    public var pathsLineUp = true
    /// Album name → assets the album should hold.
    public var albumAssets: [String: [String]] = [:]

    public func count(_ status: ImmichPresenceStatus) -> Int { counts[status, default: 0] }
}

public enum ImmichReconciler {
    public static func reconcile(
        files: [ImmichCatalogFile],
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        mediaExtensions: Set<String>,
        now: Date = Date()
    ) -> ImmichReconcileReport {
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        let exclusions = ImmichExclusionMatcher(patterns: library.exclusionPatterns)
        var report = ImmichReconcileReport()

        var index: [String: ImmichLibraryAsset] = [:]
        index.reserveCapacity(assets.count)
        for asset in assets {
            guard let relative = paths.relativePath(forOriginalPath: asset.originalPath) else { continue }
            let key = NASSyncStore.pathKey(relative)
            if let existing = index[key] {
                report.duplicatedPaths += 1
                // The copy that is really there speaks for the path.
                if rank(asset) > rank(existing) { index[key] = asset }
            } else {
                index[key] = asset
            }
        }

        var claimed = Set<String>()
        var matched = 0
        for file in files {
            let key = NASSyncStore.pathKey(file.relativePath)
            let status: ImmichPresenceStatus
            var assetID: String?
            var isTrashed = false
            if let asset = index[key] {
                claimed.insert(key)
                matched += 1
                assetID = asset.id
                if asset.isOffline {
                    status = .offline
                } else {
                    status = .present
                    isTrashed = asset.isTrashed
                    if !isTrashed, let album = file.albumName {
                        report.albumAssets[album, default: []].append(asset.id)
                    }
                }
            } else if isExcluded(file.relativePath, paths: paths, exclusions: exclusions, mediaExtensions: mediaExtensions) {
                status = .excluded
            } else {
                status = file.isOnNAS ? .pendingScan : .notOnNAS
            }
            report.counts[status, default: 0] += 1
            report.statuses.append(ImmichCatalogStatus(
                eventAssetID: file.eventAssetID,
                status: status.rawValue,
                immichAssetID: assetID,
                isTrashed: isTrashed,
                checkedAt: now
            ))
        }

        for (key, asset) in index where !claimed.contains(key) {
            report.assetsOutsideCatalog += 1
            if asset.isOffline { report.offlineOutsideCatalog += 1 }
        }
        report.pathsLineUp = matched > 0 || index.isEmpty || !files.contains(where: \.isOnNAS)
        return report
    }

    private static func rank(_ asset: ImmichLibraryAsset) -> Int {
        (asset.isOffline ? 0 : 2) + (asset.isTrashed ? 0 : 1)
    }

    private static func isExcluded(
        _ relativePath: String,
        paths: ImmichLibraryPaths,
        exclusions: ImmichExclusionMatcher,
        mediaExtensions: Set<String>
    ) -> Bool {
        let fileExtension = "." + (relativePath as NSString).pathExtension.lowercased()
        if !mediaExtensions.isEmpty, !mediaExtensions.contains(fileExtension) { return true }
        return paths.originalPath(forRelativePath: relativePath).map(exclusions.isExcluded) ?? false
    }
}

/// A NAS rename Immich has yet to catch up with.
public struct ImmichPathMove: Equatable, Sendable {
    public var from: String
    public var to: String
    public var isFolder: Bool
    public var movedAt: Date

    public init(from: String, to: String, isFolder: Bool = false, movedAt: Date = Date()) {
        self.from = from
        self.to = to
        self.isFolder = isFolder
        self.movedAt = movedAt
    }

    public var key: String { NASSyncStore.pathKey(from) }
}

/// Immich has no "this file moved": a renamed file's old asset goes offline
/// and the new path becomes a new asset, so album membership stays behind.
/// These rows remember which old path became which new one until a check has
/// dealt with it.
public final class ImmichPathMoveStore: @unchecked Sendable {
    public static let tableName = "immich_path_moves"
    /// Longer than Immich's trash window, after which the old asset is gone.
    public static let retention: TimeInterval = 90 * 86_400

    static let schema = """
    CREATE TABLE IF NOT EXISTS immich_path_moves (
        from_key TEXT PRIMARY KEY,
        from_path TEXT NOT NULL,
        to_path TEXT NOT NULL,
        is_folder INTEGER NOT NULL,
        moved_at REAL NOT NULL
    );
    """

    public let catalogURL: URL

    public init(catalogURL: URL) throws {
        self.catalogURL = catalogURL
        try writer().write { try $0.execute(sql: Self.schema) }
    }

    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: catalogURL)
    }

    /// Keeps the renames that really happened on the NAS.
    public func record(_ renames: [NASRename], at date: Date = Date()) throws {
        let moves = renames.compactMap { rename -> ImmichPathMove? in
            switch (rename.kind, rename.state) {
            case (.folder, .renamed), (.file, .renamed), (.file, .merged):
                return ImmichPathMove(from: rename.from, to: rename.to, isFolder: rename.kind == .folder, movedAt: date)
            default:
                return nil
            }
        }
        guard !moves.isEmpty else { return }
        try writer().write { database in
            for move in moves {
                try database.execute(
                    sql: """
                    INSERT INTO immich_path_moves(from_key, from_path, to_path, is_folder, moved_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(from_key) DO UPDATE SET
                        from_path = excluded.from_path,
                        to_path = excluded.to_path,
                        is_folder = excluded.is_folder,
                        moved_at = excluded.moved_at
                    """,
                    arguments: [move.key, move.from, move.to, move.isFolder ? 1 : 0, move.movedAt.timeIntervalSince1970]
                )
            }
        }
    }

    public func moves(now: Date = Date()) throws -> [ImmichPathMove] {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        return try writer().write { database in
            try database.execute(sql: "DELETE FROM immich_path_moves WHERE moved_at < ?", arguments: [cutoff])
            return try Row.fetchAll(database, sql: "SELECT * FROM immich_path_moves ORDER BY moved_at").map { row in
                ImmichPathMove(
                    from: row["from_path"],
                    to: row["to_path"],
                    isFolder: (row["is_folder"] as Int64) != 0,
                    movedAt: Date(timeIntervalSince1970: row["moved_at"])
                )
            }
        }
    }

    public func remove(keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        try writer().write { database in
            for key in keys {
                try database.execute(sql: "DELETE FROM immich_path_moves WHERE from_key = ?", arguments: [key])
            }
        }
    }
}

/// Pairs each offline asset left by a NAS rename with the asset now at the
/// new path, so the new asset can join the same albums. It only ever adds:
/// the old asset is left for Immich to age out.
public enum ImmichAlbumCarryOver {
    public struct Pair: Equatable, Sendable {
        public var oldAssetID: String
        public var newAssetID: String
        public var moveKey: String

        public init(oldAssetID: String, newAssetID: String, moveKey: String) {
            self.oldAssetID = oldAssetID
            self.newAssetID = newAssetID
            self.moveKey = moveKey
        }
    }

    public struct Plan: Equatable, Sendable {
        public var pairs: [Pair] = []
        /// Moves with nothing left to wait for once the pairs are done.
        public var settledMoveKeys: Set<String> = []
    }

    public static func plan(moves: [ImmichPathMove], assets: [ImmichLibraryAsset], library: ImmichLibrary) -> Plan {
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        var index: [String: ImmichLibraryAsset] = [:]
        for asset in assets {
            guard let relative = paths.relativePath(forOriginalPath: asset.originalPath) else { continue }
            let key = NASSyncStore.pathKey(relative)
            // A path that is back online speaks for itself.
            if let existing = index[key], !existing.isOffline { continue }
            index[key] = asset
        }
        let fileMoves = Dictionary(moves.filter { !$0.isFolder }.map { ($0.key, NASSyncStore.pathKey($0.to)) }) { _, latest in latest }
        let folderMoves = moves.filter(\.isFolder).map { (from: $0.key + "/", to: NASSyncStore.pathKey($0.to) + "/") }

        func nextKey(after key: String) -> String? {
            if let to = fileMoves[key] { return to }
            for folder in folderMoves where key.hasPrefix(folder.from) {
                return folder.to + key.dropFirst(folder.from.count)
            }
            return nil
        }

        /// The online asset at the end of a chain of renames.
        func onlineAsset(startingAt key: String) -> ImmichLibraryAsset? {
            var current = key
            var seen: Set<String> = []
            while seen.insert(current).inserted {
                if let asset = index[current], !asset.isOffline, !asset.isTrashed { return asset }
                guard let next = nextKey(after: current) else { return nil }
                current = next
            }
            return nil
        }

        var plan = Plan()
        for move in moves {
            let prefix = move.key + "/"
            let oldKeys = move.isFolder
                ? index.keys.filter { $0.hasPrefix(prefix) }
                : (index[move.key] == nil ? [] : [move.key])
            // No asset at the old path leaves nothing to carry. An asset
            // still online there means Immich has not scanned since the
            // rename, so the move waits.
            var isSettled = true
            for key in oldKeys {
                guard let old = index[key], old.isOffline,
                      let next = nextKey(after: key),
                      let new = onlineAsset(startingAt: next), new.id != old.id else {
                    isSettled = false
                    continue
                }
                plan.pairs.append(Pair(oldAssetID: old.id, newAssetID: new.id, moveKey: move.key))
            }
            if isSettled { plan.settledMoveKeys.insert(move.key) }
        }
        return plan
    }
}

public struct ImmichLibrarySyncOutcome: Equatable, Sendable {
    public var report: ImmichReconcileReport
    public var albumsCreated = 0
    public var addedToAlbums = 0
    public var carriedOver = 0
    public var problems: [String] = []

    public var summary: String {
        var parts = ["\(report.count(.present).formatted()) in Immich"]
        if report.count(.pendingScan) > 0 { parts.append("\(report.count(.pendingScan).formatted()) waiting for scan") }
        if report.count(.offline) > 0 { parts.append("\(report.count(.offline).formatted()) offline") }
        if addedToAlbums > 0 { parts.append("\(addedToAlbums.formatted()) added to event albums") }
        if carriedOver > 0 { parts.append("\(carriedOver.formatted()) renamed file(s) kept in their albums") }
        if !problems.isEmpty { parts.append("\(problems.count) problem(s): \(problems.prefix(3).joined(separator: "; "))") }
        return parts.joined(separator: ", ")
    }
}

/// External-library mode: Immich reads the NAS itself, so the app only asks
/// for a scan, compares paths, and keeps albums. It never uploads, and never
/// removes anything from Immich.
public struct ImmichLibrarySync: Sendable {
    public var client: ImmichClient
    public var libraryID: String
    public var catalogURL: URL
    public var carriesAlbumsAcrossRenames: Bool

    private static let albumBatchSize = 500

    public init(client: ImmichClient, libraryID: String, catalogURL: URL, carriesAlbumsAcrossRenames: Bool = false) {
        self.client = client
        self.libraryID = libraryID
        self.catalogURL = catalogURL
        self.carriesAlbumsAcrossRenames = carriesAlbumsAcrossRenames
    }

    public func requestScan() async throws {
        try await client.requestLibraryScan(libraryID: libraryID)
    }

    public func check(files: [ImmichCatalogFile]) async throws -> ImmichLibrarySyncOutcome {
        let library = try await client.library(id: libraryID)
        let mediaExtensions = try await client.supportedMediaExtensions()
        let assets = try await client.libraryAssets(libraryID: libraryID)
        let inspector = CatalogInspector(url: catalogURL)

        // Status rows reference catalog rows; a file the catalog has not
        // written yet is picked up by the next check.
        let known = try inspector.eventAssetIDs()
        var report = ImmichReconciler.reconcile(
            files: files.filter { known.contains($0.eventAssetID) },
            assets: assets,
            library: library,
            mediaExtensions: mediaExtensions
        )
        guard report.pathsLineUp else {
            throw ToolkitError.commandFailed(
                "“\(library.name)” does not look like your NAS library: none of its \(assets.count.formatted()) assets match a synced file. Nothing was recorded."
            )
        }
        try inspector.saveImmichStatuses(report.statuses)
        report.statuses = []

        var outcome = ImmichLibrarySyncOutcome(report: report)
        await syncAlbums(report.albumAssets, into: &outcome)
        try await carryOverAlbums(assets: assets, library: library, into: &outcome)
        return outcome
    }

    private func syncAlbums(_ albumAssets: [String: [String]], into outcome: inout ImmichLibrarySyncOutcome) async {
        guard !albumAssets.isEmpty else { return }
        do {
            var albums = Dictionary(try await client.albums().map { ($0.name, $0) }) { first, _ in first }
            for name in albumAssets.keys.sorted() {
                do {
                    let album: ImmichAlbum
                    if let existing = albums[name] {
                        album = existing
                    } else {
                        album = try await client.createAlbum(named: name)
                        albums[name] = album
                        outcome.albumsCreated += 1
                    }
                    let ids = albumAssets[name] ?? []
                    for start in stride(from: 0, to: ids.count, by: Self.albumBatchSize) {
                        let batch = Array(ids[start..<min(start + Self.albumBatchSize, ids.count)])
                        let result = try await client.addAssets(batch, toAlbum: album.id)
                        outcome.addedToAlbums += result.added
                        if !result.failed.isEmpty {
                            outcome.problems.append("\(result.failed.count) not added to album “\(name)”")
                        }
                    }
                } catch {
                    outcome.problems.append("album “\(name)”: \(error.localizedDescription)")
                }
            }
        } catch {
            outcome.problems.append("albums: \(error.localizedDescription)")
        }
    }

    private func carryOverAlbums(
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        into outcome: inout ImmichLibrarySyncOutcome
    ) async throws {
        let store = try ImmichPathMoveStore(catalogURL: catalogURL)
        let moves = try store.moves()
        guard !moves.isEmpty else { return }
        let plan = ImmichAlbumCarryOver.plan(moves: moves, assets: assets, library: library)
        // With the option off the moves wait, so turning it on still helps
        // while the old assets remain.
        guard carriesAlbumsAcrossRenames || plan.pairs.isEmpty else { return }

        var failedMoves: Set<String> = []
        for pair in plan.pairs {
            do {
                for album in try await client.albums(containingAsset: pair.oldAssetID) {
                    let result = try await client.addAssets([pair.newAssetID], toAlbum: album.id)
                    if !result.failed.isEmpty { failedMoves.insert(pair.moveKey) }
                }
                outcome.carriedOver += 1
            } catch {
                failedMoves.insert(pair.moveKey)
                outcome.problems.append("album carry-over: \(error.localizedDescription)")
            }
        }
        try store.remove(keys: plan.settledMoveKeys.subtracting(failedMoves))
    }
}
