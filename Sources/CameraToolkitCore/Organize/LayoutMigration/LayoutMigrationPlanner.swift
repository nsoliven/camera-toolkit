import Darwin
import Foundation

/// Pure path mapping between the legacy and the current drive layout.
public enum LayoutMigrationPaths {
    /// The camera folder a legacy device folder becomes: "DJI Osmo 360" →
    /// "Osmo 360", "DJI Nano" → "Osmo Nano", "Sony A7V" → "Sony A7V".
    public static func cameraFolder(forLegacyDeviceFolder name: String) -> String {
        OrganizedArchiveLayout(
            eventDate: "2000-01-01",
            eventName: "E",
            deviceID: DriveEventDiscovery.deviceID(forDeviceFolder: name)
        ).cameraFolder
    }

    /// `<root>/<yyyy>/<dated>[/<dated>…]/<device>/Card Copy/<rest>` →
    /// `<root>/<yyyy>/<dated>[/<dated>…]/Originals/<Camera>/<rest>`, for a
    /// path under one of `driveRoots`. Nil when the path is not in the
    /// legacy layout.
    public static func currentPath(forLegacy path: String, driveRoots: [String]) -> String? {
        for root in driveRoots where path.hasPrefix(root + "/") {
            let components = String(path.dropFirst(root.count + 1)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count >= 5,
                  components[0].count == 4, components[0].allSatisfy(\.isNumber),
                  DriveEventDiscovery.parseEventFolder(components[1]) != nil else { continue }
            var index = 2
            while index < components.count, DriveEventDiscovery.parseEventFolder(components[index]) != nil {
                index += 1
            }
            // components[index] is the device folder, then "Card Copy", then
            // at least one more component.
            guard index + 2 < components.count,
                  components[index + 1] == EventStorageLocations.legacyCardCopyFolderName,
                  !EventStorageLocations.reservedEventFolderNames.contains(components[index]) else { continue }
            let mapped = Array(components[..<index])
                + [EventStorageLocations.originalsFolderName, cameraFolder(forLegacyDeviceFolder: components[index])]
                + Array(components[(index + 2)...])
            return root + "/" + mapped.joined(separator: "/")
        }
        return nil
    }
}

/// `lstat` facts for one directory entry.
struct LayoutMigrationEntry: Sendable {
    enum Kind: String { case file, directory, symlink, other }
    var path: String
    var name: String
    var kind: Kind
    var size: Int64
    var inode: UInt64
    var device: UInt64
    var modifiedAt: Double

    var modifiedDate: Date { Date(timeIntervalSinceReferenceDate: modifiedAt) }
}

enum LayoutMigrationDisk {
    static func lstatEntry(_ path: String) -> LayoutMigrationEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: LayoutMigrationEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return LayoutMigrationEntry(
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: kind,
            size: Int64(info.st_size),
            inode: UInt64(info.st_ino),
            device: UInt64(bitPattern: Int64(info.st_dev)),
            modifiedAt: Date(timeIntervalSince1970: seconds).timeIntervalSinceReferenceDate
        )
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Every name in `path`, hidden ones included, sorted. Empty for an
    /// unreadable folder. `readdir`, not `FileManager`: `contentsOfDirectory`
    /// hides `._` AppleDouble files on APFS and exFAT alike, and a listing
    /// that misses them would leave sidecar metadata behind.
    static func names(in path: String, fileManager: FileManager) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// Every entry below `path`, depth first, directories before their
    /// contents. Symlinks are reported, never followed.
    static func walk(_ path: String, fileManager: FileManager) -> [LayoutMigrationEntry] {
        var result: [LayoutMigrationEntry] = []
        for name in names(in: path, fileManager: fileManager) {
            let child = (path as NSString).appendingPathComponent(name)
            guard let entry = lstatEntry(child) else { continue }
            result.append(entry)
            if entry.kind == .directory {
                result += walk(child, fileManager: fileManager)
            }
        }
        return result
    }

    /// The listing digest the plan fingerprints a legacy device folder with.
    static func listingDigest(of folder: String, fileManager: FileManager) -> String {
        let lines = walk(folder, fileManager: fileManager).map { entry -> String in
            let relative = String(entry.path.dropFirst(folder.count + 1))
            return "\(relative)\t\(entry.kind.rawValue)\t\(entry.kind == .directory ? 0 : entry.size)\t\(entry.kind == .directory ? 0 : entry.inode)"
        }
        return LayoutMigrationHash.sha256(lines.joined(separator: "\n"))
    }

    static func appleDoubleTwin(of path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("._" + (path as NSString).lastPathComponent)
    }
}

/// Builds a `LayoutMigrationPlan`. Read-only: it lists folders, `lstat`s
/// files, reads the catalog through a read-only connection, and reads the
/// capture-date cache, trash manifests and journal folder. It never
/// creates, renames, or writes anything.
public struct LayoutMigrationPlanner {
    public struct Inputs {
        /// Settings from `config.json`; the planner lays the catalog's
        /// events and assignments over it.
        public var configuration: AppConfiguration
        public var supportFolder: URL
        public var configurationURL: URL
        public var catalogURL: URL

        public init(configuration: AppConfiguration, supportFolder: URL, configurationURL: URL, catalogURL: URL) {
            self.configuration = configuration
            self.supportFolder = supportFolder
            self.configurationURL = configurationURL
            self.catalogURL = catalogURL
        }
    }

    private let fileManager: FileManager
    private let now: () -> Date

    public init(fileManager: FileManager = .default, now: @escaping () -> Date = { Date() }) {
        self.fileManager = fileManager
        self.now = now
    }

    public static func captureDateCacheURL(supportFolder: URL) -> URL {
        supportFolder.appendingPathComponent("capture-dates.json")
    }

    public static func moveJournalFolder(supportFolder: URL) -> URL {
        supportFolder.appendingPathComponent("Move Journals", isDirectory: true)
    }

    // MARK: - Working state

    private struct Draft {
        var folders: [LayoutMigrationPlan.Folder] = []
        var conflicts: [LayoutMigrationPlan.Conflict] = []
        var leftInPlace: [LayoutMigrationPlan.LeftInPlace] = []
        var refused: [LayoutMigrationPlan.Refusal] = []
        var oddFolders: [LayoutMigrationPlan.OddFolder] = []
        var blockers: [String] = []
        var listings: [String: String] = [:]
        var legacyCameraFolders: [String] = []
    }

    // MARK: - Planning

    public func plan(_ inputs: Inputs) throws -> LayoutMigrationPlan {
        let snapshot = try LayoutMigrationCatalog.snapshot(catalogURL: inputs.catalogURL)
        var configuration = inputs.configuration
        var draft = Draft()
        if snapshot.ownsState {
            snapshot.state.apply(to: &configuration)
        } else {
            draft.blockers.append("The catalog does not hold the events yet (it was never migrated from config.json). Open Camera Toolkit once, quit it, and plan again.")
        }
        let locations = EventStorageLocations(configuration: configuration)

        var roots: [LayoutMigrationPlan.Root] = []
        var seenRoots: Set<String> = []
        for (url, policy) in [(locations.bufferRoot, EventStoragePolicy.buffer), (locations.privateStagingRoot, .archiveOnly)] {
            let path = url.standardizedFileURL.path
            guard seenRoots.insert(path.lowercased()).inserted else { continue }
            var isDirectory: ObjCBool = false
            if !VolumeInfo.isAvailable(url) {
                roots.append(.init(path: path, policy: policy, scanned: false, note: "volume not mounted"))
            } else if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                roots.append(.init(path: path, policy: policy, scanned: false, note: "folder does not exist"))
            } else {
                roots.append(.init(path: path, policy: policy, scanned: true, note: nil))
            }
        }

        for root in roots where root.scanned {
            scanRoot(root, locations: locations, configuration: configuration, into: &draft)
        }
        for index in draft.folders.indices {
            draft.folders[index].id = String(format: "F%04d", index + 1)
        }
        resolveCollisions(&draft)

        // Index every planned move by its source key.
        var moveBySource: [String: (folder: Int, move: Int)] = [:]
        for (folderIndex, folder) in draft.folders.enumerated() {
            for (moveIndex, move) in folder.moves.enumerated() {
                moveBySource[move.source.lowercased()] = (folderIndex, moveIndex)
            }
        }

        let catalog = catalogChanges(
            snapshot: snapshot,
            configuration: configuration,
            locations: locations,
            moveBySource: moveBySource,
            draft: &draft
        )
        let missing = missingRows(
            configuration: configuration,
            locations: locations,
            moveBySource: moveBySource,
            draft: draft
        )

        let stores = storeChanges(
            inputs: inputs,
            locations: locations,
            roots: roots,
            draft: draft,
            blockers: &draft.blockers
        )

        let plan = LayoutMigrationPlan(
            format: LayoutMigrationPlan.formatName,
            version: LayoutMigrationPlan.currentVersion,
            id: UUID(),
            // Whole seconds: exactly what the plan's JSON reads back.
            createdAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)),
            supportFolderPath: inputs.supportFolder.standardizedFileURL.path,
            configurationPath: inputs.configurationURL.standardizedFileURL.path,
            catalogPath: inputs.catalogURL.standardizedFileURL.path,
            driveRoots: roots,
            folders: draft.folders,
            conflicts: draft.conflicts,
            leftInPlace: draft.leftInPlace,
            missingRows: missing,
            refused: draft.refused,
            oddFolders: draft.oddFolders,
            blockers: draft.blockers,
            catalog: catalog,
            stores: stores,
            fingerprint: .init(
                folderListings: draft.listings,
                legacyCameraFolders: draft.legacyCameraFolders.sorted(),
                catalogDigest: snapshot.digest
            ),
            summary: .init(
                events: 0, folders: 0, files: 0, byteCount: 0, catalogKnownFiles: 0, unknownFilesMoved: 0,
                appleDoubleFiles: 0, conflicts: 0, renamedFiles: 0, leftInPlace: 0, leftInPlaceFiles: 0,
                missingRows: 0, refused: 0, oddFolders: 0, assignmentRewrites: 0, facePhotoRewrites: 0,
                faceIdentityRenames: 0, confirmedFaces: 0, confirmedFacesAffected: 0, burstSplitRewrites: 0,
                orientationCopies: 0, trashEntriesRewritten: 0, captureDateKeys: 0, moveJournalsSuperseded: 0,
                perEvent: []
            )
        )
        return Self.summarized(plan)
    }

    // MARK: - Walking the drive

    private func scanRoot(
        _ root: LayoutMigrationPlan.Root,
        locations: EventStorageLocations,
        configuration: AppConfiguration,
        into draft: inout Draft
    ) {
        for year in LayoutMigrationDisk.names(in: root.path, fileManager: fileManager)
        where year.count == 4 && year.allSatisfy(\.isNumber) {
            let yearPath = (root.path as NSString).appendingPathComponent(year)
            guard LayoutMigrationDisk.lstatEntry(yearPath)?.kind == .directory else { continue }
            for name in LayoutMigrationDisk.names(in: yearPath, fileManager: fileManager)
            where DriveEventDiscovery.parseEventFolder(name) != nil {
                let eventPath = (yearPath as NSString).appendingPathComponent(name)
                guard LayoutMigrationDisk.lstatEntry(eventPath)?.kind == .directory else { continue }
                scanEvent(eventPath, titles: [name], root: root, locations: locations, configuration: configuration, into: &draft)
            }
        }
    }

    /// Scans one dated event folder; returns its non-junk file count
    /// (subevents included) so a parent is not called empty when only its
    /// subevents hold media.
    @discardableResult
    private func scanEvent(
        _ eventPath: String,
        titles: [String],
        root: LayoutMigrationPlan.Root,
        locations: EventStorageLocations,
        configuration: AppConfiguration,
        into draft: inout Draft
    ) -> Int {
        var fileCount = 0
        var mediaCount = 0
        var byteCount: Int64 = 0
        var nestedMedia = 0
        func count(_ entries: [LayoutMigrationEntry]) {
            for entry in entries where entry.kind == .file {
                fileCount += 1
                byteCount += entry.size
                if !JunkPolicy.isJunkFile(entry.name) { mediaCount += 1 }
            }
        }

        for name in LayoutMigrationDisk.names(in: eventPath, fileManager: fileManager) {
            let path = (eventPath as NSString).appendingPathComponent(name)
            guard let entry = LayoutMigrationDisk.lstatEntry(path) else { continue }
            switch entry.kind {
            case .directory:
                if DriveEventDiscovery.parseEventFolder(name) != nil {
                    nestedMedia += scanEvent(path, titles: titles + [name], root: root, locations: locations, configuration: configuration, into: &draft)
                    continue
                }
                let contents = LayoutMigrationDisk.walk(path, fileManager: fileManager)
                count(contents)
                if name == EventStorageLocations.originalsFolderName || name == EventStorageLocations.editedFolderName {
                    continue
                }
                let cardCopy = (path as NSString).appendingPathComponent(EventStorageLocations.legacyCardCopyFolderName)
                if LayoutMigrationDisk.lstatEntry(cardCopy)?.kind == .directory {
                    planFolder(
                        deviceFolder: entry,
                        eventPath: eventPath,
                        titles: titles,
                        root: root,
                        locations: locations,
                        configuration: configuration,
                        into: &draft
                    )
                } else {
                    let files = contents.filter { $0.kind == .file }
                    draft.leftInPlace.append(.init(
                        path: path,
                        fileCount: files.count,
                        byteCount: files.reduce(0) { $0 + $1.size },
                        reason: "Event-level folder outside Originals/Edited — kept where it is (move it into Edited/ by hand if it holds edits)"
                    ))
                }
            case .file:
                count([entry])
                if !JunkPolicy.isJunkFile(name) {
                    draft.leftInPlace.append(.init(path: path, fileCount: 1, byteCount: entry.size, reason: "File directly in the event folder — kept where it is"))
                }
            case .symlink, .other:
                draft.refused.append(.init(path: path, reason: "Not a regular file or folder (\(entry.kind.rawValue)) — left untouched"))
            }
        }

        let components = DriveEventDiscovery.relativeComponents(
            of: URL(fileURLWithPath: eventPath),
            under: URL(fileURLWithPath: root.path)
        )
        let hasEvent = configuration.savedEvents.contains {
            DriveEventDiscovery.folderComponents(of: $0, locations: locations) == components
        }
        var reasons: [String] = []
        if mediaCount == 0 && nestedMedia == 0 {
            reasons.append(fileCount == 0 ? "empty" : "only Finder metadata (._*, .DS_Store) and empty skeleton folders")
        }
        if !hasEvent { reasons.append("no catalog event uses this folder") }
        if mediaCount == 0 && nestedMedia == 0 {
            // A skeleton with nothing but Finder metadata is the owner's to
            // review: its legacy camera folders are neither moved nor
            // removed (they stay fingerprinted, so a change is still seen).
            let untouched = draft.folders.filter { $0.eventFolderPath == eventPath }
            draft.folders.removeAll { $0.eventFolderPath == eventPath }
            for folder in untouched {
                draft.leftInPlace.append(.init(
                    path: folder.legacyDeviceFolderPath,
                    fileCount: folder.moves.count,
                    byteCount: folder.byteCount,
                    reason: "Legacy camera folder inside an odd event folder with no media — left for you to review"
                ))
            }
            if !untouched.isEmpty { reasons.append("its legacy camera folder(s) are left untouched") }
        }
        if !reasons.isEmpty {
            draft.oddFolders.append(.init(
                path: eventPath,
                fileCount: fileCount,
                mediaFileCount: mediaCount,
                byteCount: byteCount,
                hasCatalogEvent: hasEvent,
                reasons: reasons
            ))
        }
        return mediaCount + nestedMedia
    }

    private func planFolder(
        deviceFolder: LayoutMigrationEntry,
        eventPath: String,
        titles: [String],
        root: LayoutMigrationPlan.Root,
        locations: EventStorageLocations,
        configuration: AppConfiguration,
        into draft: inout Draft
    ) {
        let devicePath = deviceFolder.path
        let cardCopy = (devicePath as NSString).appendingPathComponent(EventStorageLocations.legacyCardCopyFolderName)
        let deviceID = DriveEventDiscovery.deviceID(forDeviceFolder: deviceFolder.name)
        let cameraFolder = LayoutMigrationPaths.cameraFolder(forLegacyDeviceFolder: deviceFolder.name)
        let originals = ((eventPath as NSString).appendingPathComponent(EventStorageLocations.originalsFolderName) as NSString)
            .appendingPathComponent(cameraFolder)
        draft.legacyCameraFolders.append(devicePath)
        draft.listings[devicePath] = LayoutMigrationDisk.listingDigest(of: devicePath, fileManager: fileManager)

        // Anything in the device folder beside Card Copy stays; the folder's
        // own `._Card Copy` twin is the filesystem's.
        for name in LayoutMigrationDisk.names(in: devicePath, fileManager: fileManager)
        where name != EventStorageLocations.legacyCardCopyFolderName && name != "._" + EventStorageLocations.legacyCardCopyFolderName {
            let path = (devicePath as NSString).appendingPathComponent(name)
            let contents = [LayoutMigrationDisk.lstatEntry(path)].compactMap { $0 } + LayoutMigrationDisk.walk(path, fileManager: fileManager)
            let files = contents.filter { $0.kind == .file }
            draft.leftInPlace.append(.init(
                path: path,
                fileCount: files.count,
                byteCount: files.reduce(0) { $0 + $1.size },
                reason: "In the device folder beside Card Copy — kept where it is, so \(deviceFolder.name)/ stays"
            ))
        }

        let destinationDevice = VolumeInfo.deviceNumber(for: URL(fileURLWithPath: eventPath))
        let entries = LayoutMigrationDisk.walk(cardCopy, fileManager: fileManager)
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var directories: [String] = []
        var moves: [LayoutMigrationPlan.Move] = []
        var mainIndex: [String: Int] = [:]
        var twins: [LayoutMigrationEntry] = []
        for entry in entries {
            let relative = String(entry.path.dropFirst(cardCopy.count + 1))
            switch entry.kind {
            case .directory:
                directories.append(relative)
                continue
            case .symlink, .other:
                draft.refused.append(.init(path: entry.path, reason: "Not a regular file (\(entry.kind.rawValue)) — left in Card Copy"))
                continue
            case .file:
                break
            }
            guard destinationDevice != nil, entry.device == destinationDevice else {
                draft.refused.append(.init(path: entry.path, reason: "On a different volume than its event folder — the migration only renames within one volume"))
                continue
            }
            if entry.name.hasPrefix("._"), entry.name.count > 2 {
                let sibling = ((entry.path as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(String(entry.name.dropFirst(2)))
                if byPath[sibling] != nil {
                    twins.append(entry)
                    continue
                }
            }
            mainIndex[entry.path] = moves.count
            moves.append(.init(
                source: entry.path,
                destination: (originals as NSString).appendingPathComponent(relative),
                byteCount: entry.size,
                inode: entry.inode,
                modifiedAt: entry.modifiedAt,
                kind: Self.kind(of: entry.name),
                catalogKnown: false,
                renamed: false,
                companionOf: nil
            ))
        }
        // Twins of files follow their file; twins of folders move to the
        // twin of the folder's new location. Shortest names first, so the
        // twin of a twin (`._._NAME`, left by copying `._` files onto a
        // drive without native xattrs) chains onto `._NAME`'s new name.
        for twin in twins.sorted(by: { $0.name.count == $1.name.count ? $0.path < $1.path : $0.name.count < $1.name.count }) {
            let sibling = ((twin.path as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(String(twin.name.dropFirst(2)))
            let relative = String(twin.path.dropFirst(cardCopy.count + 1))
            if let main = mainIndex[sibling] {
                mainIndex[twin.path] = moves.count
                moves.append(.init(
                    source: twin.path,
                    destination: LayoutMigrationDisk.appleDoubleTwin(of: moves[main].destination),
                    byteCount: twin.size,
                    inode: twin.inode,
                    modifiedAt: twin.modifiedAt,
                    kind: .appleDouble,
                    catalogKnown: false,
                    renamed: false,
                    companionOf: main
                ))
            } else if byPath[sibling]?.kind == .directory {
                moves.append(.init(
                    source: twin.path,
                    destination: (originals as NSString).appendingPathComponent(relative),
                    byteCount: twin.size,
                    inode: twin.inode,
                    modifiedAt: twin.modifiedAt,
                    kind: .folderAppleDouble,
                    catalogKnown: false,
                    renamed: false,
                    companionOf: nil
                ))
            } else {
                // The twin of a refused entry: it stays with it.
                draft.refused.append(.init(path: twin.path, reason: "AppleDouble twin of an entry that stays — left with it"))
            }
        }

        let eventComponents = DriveEventDiscovery.relativeComponents(
            of: URL(fileURLWithPath: eventPath),
            under: URL(fileURLWithPath: root.path)
        )
        let event = configuration.savedEvents.first {
            DriveEventDiscovery.folderComponents(of: $0, locations: locations) == eventComponents
        }
        draft.folders.append(.init(
            id: String(format: "F%04d", draft.folders.count + 1),
            policy: root.policy,
            eventFolderPath: eventPath,
            eventTitle: titles.map { DriveEventDiscovery.parseEventFolder($0)?.name ?? $0 }.joined(separator: " / "),
            eventID: event?.id,
            legacyDeviceFolderPath: devicePath,
            legacyFilesRootPath: cardCopy,
            originalsPath: originals,
            cameraFolder: cameraFolder,
            deviceID: deviceID,
            moves: moves,
            byteCount: moves.reduce(0) { $0 + $1.byteCount },
            legacyDirectories: directories
        ))
    }

    static func kind(of name: String) -> LayoutMigrationPlan.FileKind {
        if name == ".DS_Store" { return .finderMetadata }
        if name.hasPrefix("._") { return .appleDouble }
        let ext = (name as NSString).pathExtension.lowercased()
        if OrganizeFileClassifier.rawExtensions.contains(ext)
            || OrganizeFileClassifier.photoExtensions.contains(ext)
            || OrganizeFileClassifier.videoExtensions.contains(ext)
            || ["wav", "mp3", "m4a", "aac"].contains(ext) {
            return .media
        }
        if OrganizeFileClassifier.companionExtensions.contains(ext) || ext == "dat" { return .sidecar }
        return .other
    }

    // MARK: - Collisions

    /// Claims every destination once, case-insensitively, across all
    /// folders. A taken name — by a file already on disk or by another
    /// planned move — renames the whole group (file + sidecars sharing its
    /// base name) to the lowest free `NAME (N).EXT`, the same rule as
    /// Apply's Keep Both. AppleDouble twins follow their file's new name.
    private func resolveCollisions(_ draft: inout Draft) {
        var claimed: Set<String> = []
        func taken(_ path: String) -> Bool {
            claimed.contains(path.lowercased()) || LayoutMigrationDisk.exists(path)
        }
        for folderIndex in draft.folders.indices {
            var folder = draft.folders[folderIndex]
            let mainIndices = folder.moves.indices.filter {
                folder.moves[$0].companionOf == nil && folder.moves[$0].kind != .folderAppleDouble
            }
            var order: [String] = []
            var groups: [String: [Int]] = [:]
            for index in mainIndices {
                let key = ApplyCollisionCheck.groupKey(folder.moves[index].source)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(index)
            }
            for key in order {
                let members = groups[key] ?? []
                let collided = members.filter { index in
                    let destination = folder.moves[index].destination
                    return taken(destination) || taken(LayoutMigrationDisk.appleDoubleTwin(of: destination))
                }
                if collided.isEmpty {
                    for index in members { claimed.insert(folder.moves[index].destination.lowercased()) }
                    continue
                }
                let driveMoves = members.map {
                    DriveMove(sourcePath: folder.moves[$0].source, destinationPath: folder.moves[$0].destination, byteCount: folder.moves[$0].byteCount)
                }
                guard let renamed = KeepBothNaming.renamedMoves(for: driveMoves, exists: { taken($0) }) else {
                    draft.blockers.append("No free “(N)” name for \(folder.moves[members[0]].source).")
                    continue
                }
                let collidedSet = Set(collided)
                for (index, move) in zip(members, renamed) {
                    let planned = folder.moves[index].destination
                    let existing = LayoutMigrationDisk.lstatEntry(planned)
                    let reason: LayoutMigrationPlan.Conflict.Reason
                    if !collidedSet.contains(index) {
                        reason = .travelsWithConflict
                    } else if existing != nil {
                        reason = .destinationExists
                    } else {
                        reason = .claimedByAnotherFile
                    }
                    var identical: Bool?
                    if reason == .destinationExists, let existing, existing.kind == .file, existing.size == folder.moves[index].byteCount {
                        identical = ApplyCollisionCheck.classify(
                            sourcePath: folder.moves[index].source,
                            destinationPath: planned
                        )?.kind == .identicalCopy
                    }
                    draft.conflicts.append(.init(
                        source: folder.moves[index].source,
                        plannedDestination: planned,
                        resolvedDestination: move.destinationPath,
                        reason: reason,
                        existingByteCount: existing?.kind == .file ? existing?.size : nil,
                        identicalContent: identical
                    ))
                    folder.moves[index].destination = move.destinationPath
                    folder.moves[index].renamed = true
                    claimed.insert(move.destinationPath.lowercased())
                }
            }
            // Twins follow their file; a folder twin whose place is taken stays.
            var dropped: Set<Int> = []
            for index in folder.moves.indices {
                if let main = folder.moves[index].companionOf {
                    folder.moves[index].destination = LayoutMigrationDisk.appleDoubleTwin(of: folder.moves[main].destination)
                    folder.moves[index].renamed = folder.moves[main].renamed
                    if taken(folder.moves[index].destination) {
                        draft.blockers.append("The AppleDouble twin destination \(folder.moves[index].destination) is already taken.")
                    }
                    claimed.insert(folder.moves[index].destination.lowercased())
                } else if folder.moves[index].kind == .folderAppleDouble {
                    if taken(folder.moves[index].destination) {
                        draft.refused.append(.init(path: folder.moves[index].source, reason: "Folder twin already present at \(folder.moves[index].destination) — left in place"))
                        dropped.insert(index)
                    } else {
                        claimed.insert(folder.moves[index].destination.lowercased())
                    }
                }
            }
            if !dropped.isEmpty {
                // Re-number companion links after dropping folder twins
                // (they are never a companion target).
                var remap: [Int: Int] = [:]
                var kept: [LayoutMigrationPlan.Move] = []
                for index in folder.moves.indices where !dropped.contains(index) {
                    remap[index] = kept.count
                    kept.append(folder.moves[index])
                }
                for index in kept.indices {
                    if let main = kept[index].companionOf { kept[index].companionOf = remap[main] }
                }
                folder.moves = kept
                folder.byteCount = kept.reduce(0) { $0 + $1.byteCount }
            }
            draft.folders[folderIndex] = folder
        }
    }

    // MARK: - Catalog

    private func catalogChanges(
        snapshot: LayoutMigrationCatalog.Snapshot,
        configuration: AppConfiguration,
        locations: EventStorageLocations,
        moveBySource: [String: (folder: Int, move: Int)],
        draft: inout Draft
    ) -> LayoutMigrationPlan.CatalogChanges {
        let eventsByID = Dictionary(configuration.savedEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var standardizedRoots: [String: String] = [:]
        func standardizedRoot(_ path: String) -> String {
            if let cached = standardizedRoots[path] { return cached }
            let built = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
            standardizedRoots[path] = built
            return built
        }
        func key(root: String, relative: String) -> String {
            EventStorageLocations.joinedPathKey(rootPath: root, relativePath: relative)
                ?? EventStorageLocations.pathKey(root + "/" + relative)
        }
        func renamedRelative(_ relative: String, to destination: String) -> String {
            let folder = (relative as NSString).deletingLastPathComponent
            let name = (destination as NSString).lastPathComponent
            return folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)
        }

        var rewrites: [LayoutMigrationPlan.AssignmentRewrite] = []
        var finalIDs: [String: Int] = [:]
        for assignment in configuration.photoEventAssignments {
            let oldID = CatalogStore.eventAssetID(assignment)
            guard let event = eventsByID[assignment.eventID],
                  (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else {
                finalIDs[oldID, default: 0] += 1
                continue
            }
            let sourceRoot = standardizedRoot(assignment.sourceRootPath)
            var rewritten: PhotoEventAssignment?
            var destination: String?
            if let hit = moveBySource[key(root: sourceRoot, relative: assignment.relativePath)] {
                // Adopted from the drive: the source root is the legacy folder.
                let folder = draft.folders[hit.folder]
                let move = folder.moves[hit.move]
                draft.folders[hit.folder].moves[hit.move].catalogKnown = true
                guard let newRoot = Self.mapPrefix(sourceRoot, from: folder.legacyFilesRootPath, to: folder.originalsPath) else {
                    draft.blockers.append("Assignment \(oldID) has a source root above Card Copy (\(sourceRoot)); it cannot be rewritten safely.")
                    finalIDs[oldID, default: 0] += 1
                    continue
                }
                var updated = assignment
                updated.sourceRootPath = newRoot
                updated.relativePath = move.renamed ? renamedRelative(assignment.relativePath, to: move.destination) : assignment.relativePath
                guard key(root: newRoot, relative: updated.relativePath) == move.destination.lowercased() else {
                    draft.blockers.append("Assignment \(oldID) would not point at \(move.destination) after the rewrite.")
                    finalIDs[oldID, default: 0] += 1
                    continue
                }
                rewritten = updated
                destination = move.destination
            } else {
                let policy = locations.resolvedPolicy(for: event)
                let other: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
                for candidate in [policy, other] {
                    let legacyRoot = locations.legacyCardCopyRoot(for: event, deviceID: assignment.deviceID, policy: candidate).path
                    guard let hit = moveBySource[key(root: legacyRoot, relative: assignment.relativePath)] else { continue }
                    let move = draft.folders[hit.folder].moves[hit.move]
                    draft.folders[hit.folder].moves[hit.move].catalogKnown = true
                    let newRoot = locations.originalsRoot(for: event, deviceID: assignment.deviceID, policy: candidate).path
                    var updated = assignment
                    if move.renamed {
                        updated.relativePath = renamedRelative(assignment.relativePath, to: move.destination)
                    }
                    guard key(root: newRoot, relative: updated.relativePath) == move.destination.lowercased() else {
                        draft.blockers.append("Assignment \(oldID) would not resolve to \(move.destination) in the new layout (its device id \(assignment.deviceID ?? "none") names another camera folder).")
                        break
                    }
                    if move.renamed {
                        rewritten = updated
                        destination = move.destination
                    }
                    break
                }
            }
            if let rewritten, let destination {
                let newID = CatalogStore.eventAssetID(rewritten)
                finalIDs[newID, default: 0] += 1
                if newID != oldID || rewritten != assignment {
                    rewrites.append(.init(
                        oldID: oldID,
                        newID: newID,
                        eventID: assignment.eventID,
                        oldSourceRootPath: assignment.sourceRootPath,
                        newSourceRootPath: rewritten.sourceRootPath,
                        oldRelativePath: assignment.relativePath,
                        newRelativePath: rewritten.relativePath,
                        destination: destination
                    ))
                }
            } else {
                finalIDs[oldID, default: 0] += 1
            }
        }
        let duplicateIDs = finalIDs.filter { $0.value > 1 }.keys.sorted()
        if !duplicateIDs.isEmpty {
            draft.blockers.append("\(duplicateIDs.count) assignment id(s) would collide after the rewrite, e.g. \(duplicateIDs[0]).")
        }

        // Face photos: re-key rows whose path is a moved file; follow a
        // renamed file's identity for rows at stale paths.
        var movedByFileKey: [String: [LayoutMigrationPlan.Move]] = [:]
        for folder in draft.folders {
            for move in folder.moves where move.companionOf == nil && move.kind != .folderAppleDouble {
                let key = FaceIndexStore.fileKey(
                    fileName: (move.source as NSString).lastPathComponent,
                    byteCount: move.byteCount,
                    modifiedAt: Date(timeIntervalSinceReferenceDate: move.modifiedAt)
                )
                movedByFileKey[key, default: []].append(move)
            }
        }
        var facePhotoRewrites: [LayoutMigrationPlan.FacePhotoRewrite] = []
        var identityRenames: [LayoutMigrationPlan.FaceIdentityRename] = []
        var affected = 0
        let existingPhotoKeys = Set(snapshot.facePhotos.map(\.pathKey))
        var movingAway: Set<String> = []
        for photo in snapshot.facePhotos {
            if let hit = moveBySource[photo.pathKey] {
                let move = draft.folders[hit.folder].moves[hit.move]
                facePhotoRewrites.append(.init(
                    oldPathKey: photo.pathKey,
                    newPathKey: EventStorageLocations.pathKey(move.destination),
                    newPath: move.destination,
                    newFileName: (move.destination as NSString).lastPathComponent,
                    faceCount: photo.faceCount,
                    confirmedFaceCount: photo.confirmedFaceCount
                ))
                movingAway.insert(photo.pathKey)
                affected += photo.confirmedFaceCount
            } else if let moves = movedByFileKey[photo.fileKey] {
                affected += photo.confirmedFaceCount
                if moves.count == 1, let move = moves.first, move.renamed {
                    identityRenames.append(.init(
                        pathKey: photo.pathKey,
                        oldFileName: photo.fileName,
                        newFileName: (move.destination as NSString).lastPathComponent
                    ))
                }
            }
        }
        for rewrite in facePhotoRewrites where existingPhotoKeys.contains(rewrite.newPathKey) && !movingAway.contains(rewrite.newPathKey) {
            draft.blockers.append("A face photo row already exists for \(rewrite.newPath); re-keying \(rewrite.oldPathKey) onto it would merge two photos.")
        }

        // Rotations are keyed by file identity: only a rename needs a copy.
        var orientationCopies: [LayoutMigrationPlan.OrientationCopy] = []
        for folder in draft.folders {
            for move in folder.moves where move.renamed && move.companionOf == nil {
                let date = Date(timeIntervalSinceReferenceDate: move.modifiedAt)
                let oldKey = FaceIndexStore.fileKey(fileName: (move.source as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
                let newKey = FaceIndexStore.fileKey(fileName: (move.destination as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
                if let turns = configuration.displayOrientations[oldKey], configuration.displayOrientations[newKey] == nil {
                    orientationCopies.append(.init(oldKey: oldKey, newKey: newKey, quarterTurns: turns))
                }
            }
        }

        var splitRewrites: [LayoutMigrationPlan.BurstSplitRewrite] = []
        for split in configuration.burstSplits {
            let mapped = split.memberPathKeys.map { key -> String in
                guard let hit = moveBySource[key] else { return key }
                return EventStorageLocations.pathKey(draft.folders[hit.folder].moves[hit.move].destination)
            }
            if mapped != split.memberPathKeys {
                splitRewrites.append(.init(id: split.id, oldMemberPathKeys: split.memberPathKeys, newMemberPathKeys: mapped))
            }
        }

        return .init(
            assignmentRewrites: rewrites,
            facePhotoRewrites: facePhotoRewrites,
            faceIdentityRenames: identityRenames,
            orientationCopies: orientationCopies,
            burstSplitRewrites: splitRewrites,
            tableCounts: snapshot.tableCounts,
            confirmedFaces: snapshot.confirmedFaces,
            confirmedFacesAffected: affected,
            markerKey: LayoutMigrationCatalog.markerKey
        )
    }

    /// `path` with `prefix` replaced by `replacement`, when `path` is
    /// `prefix` itself or lies below it.
    static func mapPrefix(_ path: String, from prefix: String, to replacement: String) -> String? {
        if path.lowercased() == prefix.lowercased() { return replacement }
        guard path.lowercased().hasPrefix(prefix.lowercased() + "/") else { return nil }
        return replacement + String(path.dropFirst(prefix.count))
    }

    /// Assignments whose file is not on the source, either drive layout,
    /// or a planned move. Reported, never deleted.
    private func missingRows(
        configuration: AppConfiguration,
        locations: EventStorageLocations,
        moveBySource: [String: (folder: Int, move: Int)],
        draft: Draft
    ) -> [LayoutMigrationPlan.MissingRow] {
        let eventsByID = Dictionary(configuration.savedEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mounted = VolumeInfo.mountedVolumePaths(fileManager: fileManager)
        var rows: [LayoutMigrationPlan.MissingRow] = []
        for assignment in configuration.photoEventAssignments {
            guard let event = eventsByID[assignment.eventID] else { continue }
            let id = CatalogStore.eventAssetID(assignment)
            let title = locations.displayName(for: event)
            let candidates: [URL] = [
                locations.sourceURL(for: assignment),
                locations.driveURL(for: assignment, event: event, policy: .buffer),
                locations.driveURL(for: assignment, event: event, policy: .archiveOnly),
                locations.legacyDriveURL(for: assignment, event: event, policy: .buffer),
                locations.legacyDriveURL(for: assignment, event: event, policy: .archiveOnly),
            ].compactMap { $0 }
            guard let expected = candidates.first else {
                rows.append(.init(eventAssetID: id, eventTitle: title, expectedPath: assignment.relativePath, reason: "unsafe relative path"))
                continue
            }
            if candidates.contains(where: { moveBySource[$0.path.lowercased()] != nil }) { continue }
            if candidates.contains(where: { LayoutMigrationDisk.lstatEntry($0.path)?.kind == .file }) { continue }
            let offline = candidates.filter { !VolumeInfo.isAvailable($0, mountedVolumes: mounted) }
            let reason: String
            if offline.contains(where: { $0.path == expected.path }) {
                reason = "not on the drive; its source volume is not mounted (it may still be there, or on the NAS)"
            } else {
                reason = "not on the drive or at its source (it may be on the NAS only)"
            }
            rows.append(.init(eventAssetID: id, eventTitle: title, expectedPath: expected.path, reason: reason))
        }
        return rows
    }

    // MARK: - Stores outside the catalog

    private func storeChanges(
        inputs: Inputs,
        locations: EventStorageLocations,
        roots: [LayoutMigrationPlan.Root],
        draft: Draft,
        blockers: inout [String]
    ) -> LayoutMigrationPlan.StoreChanges {
        let sources = Set(draft.folders.flatMap { $0.moves.map(\.source) })
        let capturePath = Self.captureDateCacheURL(supportFolder: inputs.supportFolder)
        var captureKeys = 0
        if let data = try? Data(contentsOf: capturePath),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["entries"] as? [String: Any] {
            captureKeys = entries.keys.count { sources.contains($0) }
        }

        let driveRoots = roots.filter(\.scanned).map(\.path)
        var manifests: [LayoutMigrationPlan.TrashManifestRewrite] = []
        for trashRoot in locations.trashRoots() {
            for batch in LayoutMigrationDisk.names(in: trashRoot.path, fileManager: fileManager) {
                let manifestURL = trashRoot.appendingPathComponent(batch, isDirectory: true)
                    .appendingPathComponent(MediaTrashService.manifestFileName)
                guard let manifest = try? MediaTrashService.readManifest(manifestURL) else { continue }
                let entries = manifest.entries.compactMap { entry -> LayoutMigrationPlan.PathRewrite? in
                    LayoutMigrationPaths.currentPath(forLegacy: entry.originalAbsolutePath, driveRoots: driveRoots)
                        .map { .init(old: entry.originalAbsolutePath, new: $0) }
                }
                if !entries.isEmpty {
                    manifests.append(.init(manifestPath: manifestURL.path, entries: entries))
                }
            }
        }

        let journals = Self.moveJournalFolder(supportFolder: inputs.supportFolder)
        let journalCount = LayoutMigrationDisk.names(in: journals.path, fileManager: fileManager).count { $0.hasSuffix(".json") }

        for name in ["transfer-queue.json", "pending-transfers.json"]
        where fileManager.fileExists(atPath: inputs.supportFolder.appendingPathComponent(name).path) {
            blockers.append("\(name) exists: a transfer is queued or pending. Finish or clear it in Camera Toolkit first — its paths may name the legacy layout.")
        }
        let configured = inputs.configuration.configuredLocations.filter { location in
            let path = URL(fileURLWithPath: NSString(string: location.path).expandingTildeInPath).standardizedFileURL.path
            return draft.folders.contains { path == $0.legacyFilesRootPath || path.hasPrefix($0.legacyFilesRootPath + "/") || path == $0.legacyDeviceFolderPath }
        }
        for location in configured {
            blockers.append("The configured location “\(location.name)” points inside a legacy Card Copy folder (\(location.path)); change it first.")
        }

        return .init(
            captureDatePath: capturePath.path,
            captureDateKeys: captureKeys,
            trashManifests: manifests,
            moveJournalFolderPath: journals.path,
            moveJournalsSuperseded: journalCount
        )
    }

    // MARK: - Summary

    static func summarized(_ plan: LayoutMigrationPlan) -> LayoutMigrationPlan {
        var plan = plan
        let moves = plan.allMoves
        var perEvent: [String: LayoutMigrationPlan.EventSummary] = [:]
        for folder in plan.folders {
            var summary = perEvent[folder.eventFolderPath] ?? .init(
                eventFolderPath: folder.eventFolderPath,
                title: folder.eventTitle,
                policy: folder.policy,
                cameras: [],
                files: 0,
                byteCount: 0
            )
            summary.cameras.append(folder.cameraFolder)
            summary.files += folder.moves.count
            summary.byteCount += folder.byteCount
            perEvent[folder.eventFolderPath] = summary
        }
        plan.summary = .init(
            events: perEvent.count,
            folders: plan.folders.count,
            files: moves.count,
            byteCount: moves.reduce(0) { $0 + $1.byteCount },
            catalogKnownFiles: moves.count(where: \.catalogKnown),
            unknownFilesMoved: moves.count { !$0.catalogKnown && ($0.kind == .media || $0.kind == .sidecar || $0.kind == .other) },
            appleDoubleFiles: moves.count { $0.kind == .appleDouble || $0.kind == .folderAppleDouble },
            conflicts: plan.conflicts.count,
            renamedFiles: moves.count(where: \.renamed),
            leftInPlace: plan.leftInPlace.count,
            leftInPlaceFiles: plan.leftInPlace.reduce(0) { $0 + $1.fileCount },
            missingRows: plan.missingRows.count,
            refused: plan.refused.count,
            oddFolders: plan.oddFolders.count,
            assignmentRewrites: plan.catalog.assignmentRewrites.count,
            facePhotoRewrites: plan.catalog.facePhotoRewrites.count,
            faceIdentityRenames: plan.catalog.faceIdentityRenames.count,
            confirmedFaces: plan.catalog.confirmedFaces,
            confirmedFacesAffected: plan.catalog.confirmedFacesAffected,
            burstSplitRewrites: plan.catalog.burstSplitRewrites.count,
            orientationCopies: plan.catalog.orientationCopies.count,
            trashEntriesRewritten: plan.stores.trashManifests.reduce(0) { $0 + $1.entries.count },
            captureDateKeys: plan.stores.captureDateKeys,
            moveJournalsSuperseded: plan.stores.moveJournalsSuperseded,
            perEvent: perEvent.values.sorted { $0.eventFolderPath < $1.eventFolderPath }
        )
        return plan
    }
}
