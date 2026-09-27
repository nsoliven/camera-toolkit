import Foundation
import GRDB

/// Builds a `NASLayoutMigrationPlan` from a reviewed mapping. Read-only: it
/// lists folders (`DirectoryListing` — one bulk listing per folder, never a
/// stat per file), reads the catalog through a read-only connection, and
/// writes nothing.
///
/// For each mapped event folder, under the legacy archive layout
/// `<event>/<camera>/RAW|JPEG|Video|Camera Support|Photos|Saved Clips|Audio/<files>`:
/// - the media folders flatten into `<new event>/Originals/<Camera>/`, with
///   any subfolders below them kept;
/// - `<camera>` is normalized ("Sony-A7V" → "Sony A7V", "DJI Osmo 360" →
///   "Osmo 360", …); an unknown name is kept verbatim and reported;
/// - other subfolders of a camera folder are kept under
///   `Originals/<Camera>/<subfolder>/`; an event's own `Originals/` and
///   `Edited/` keep their inner paths; loose files keep their names;
/// - a taken destination renames the file's whole base-name group to
///   `NAME (N).EXT`, sidecars included;
/// - an unmapped dated subfolder, `.DS_Store`, and orphan `._` files stay;
/// - a folder that cannot be listed is reported and skipped — the rest of
///   the event is still planned.
public struct NASLayoutMigrationPlanner {
    public struct Inputs {
        public var mapping: NASLayoutMapping
        public var configuration: AppConfiguration
        public var supportFolder: URL
        public var configurationURL: URL
        public var catalogURL: URL?

        public init(mapping: NASLayoutMapping, configuration: AppConfiguration, supportFolder: URL, configurationURL: URL, catalogURL: URL?) {
            self.mapping = mapping
            self.configuration = configuration
            self.supportFolder = supportFolder
            self.configurationURL = configurationURL
            self.catalogURL = catalogURL
        }
    }

    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// One file found under a mapped event folder, before collisions.
    private struct Candidate {
        var source: String
        var destination: String
        var entry: DirectoryListingEntry
        var kind: NASLayoutMigrationPlan.FileKind
        /// Files sharing it (same source camera folder, same destination
        /// folder, same base name) are renamed together.
        var groupKey: String
        var sourceFolder: String
        /// `<camera>/<media folder>/<name>` (lower case) for a file directly
        /// in a legacy media folder — what the flattening kept of its path.
        var legacyKey: String?
        /// The source camera folder, for re-deriving the group key.
        var cameraSource: String?
    }

    private struct Walker {
        var listed = 0
        var unreadable: [NASLayoutMigrationPlan.Issue] = []
        var refused: [NASLayoutMigrationPlan.Issue] = []
        var leftInPlace: [NASLayoutMigrationPlan.LeftInPlace] = []
        var directories: [String] = []
        var listingLines: [String] = []
        var eventRoot = ""
        /// `._NAME` files whose `NAME` sits beside them, by full path.
        var twins: [String: DirectoryListingEntry] = [:]

        mutating func list(_ path: String) -> [DirectoryListingEntry]? {
            listed += 1
            do {
                let entries = try DirectoryListing.list(path)
                let relative = path == eventRoot ? "" : String(path.dropFirst(eventRoot.count + 1))
                for entry in entries {
                    listingLines.append("\(relative)/\(entry.name)\t\(entry.kind.rawValue)\t\(entry.size)\t\(entry.modifiedAt)")
                }
                return entries
            } catch {
                unreadable.append(.init(path: path, reason: error.localizedDescription))
                return nil
            }
        }
    }

    public func plan(_ inputs: Inputs) throws -> NASLayoutMigrationPlan {
        let mapping = inputs.mapping
        let locations = EventStorageLocations(configuration: inputs.configuration)
        let legacyRoot = URL(fileURLWithPath: NSString(string: mapping.legacyRoot
            ?? locations.libraryRoot.appendingPathComponent(CameraLibraryFolder.originals.rawValue).path).expandingTildeInPath)
            .standardizedFileURL.path
        let mirrorRoot = URL(fileURLWithPath: NSString(string: mapping.mirrorRoot ?? locations.nasRoot.path).expandingTildeInPath)
            .standardizedFileURL.path
        var blockers = mapping.problems()
        let legacyEntry = LayoutMigrationDisk.lstatEntry(legacyRoot)
        let mirrorEntry = LayoutMigrationDisk.lstatEntry(mirrorRoot)
        if legacyEntry?.kind != .directory { blockers.append("The legacy archive root \(legacyRoot) is not reachable.") }
        if mirrorEntry?.kind != .directory { blockers.append("The mirror root \(mirrorRoot) is not reachable.") }
        if let legacyEntry, let mirrorEntry, legacyEntry.device != mirrorEntry.device {
            blockers.append("The legacy root and the mirror root are on different volumes; the migration only renames on one share.")
        }

        let mappedSources = Set(mapping.events.map { (legacyRoot + "/" + $0.source).lowercased() })
        var notes: [String] = []
        // The catalog, read once up front: its assignments can say where
        // flattened files belong.
        var snapshot: NASLayoutMigrationCatalog.Snapshot?
        if let catalogURL = inputs.catalogURL, FileManager.default.fileExists(atPath: catalogURL.path) {
            snapshot = try NASLayoutMigrationCatalog.snapshot(catalogURL: catalogURL)
        }
        var events: [NASLayoutMigrationPlan.Event] = []
        var conflicts: [NASLayoutMigrationPlan.Conflict] = []
        var unknownCameras: [NASLayoutMigrationPlan.UnknownCamera] = []
        var walker = Walker()
        var listings: [String: String] = [:]
        // Destination-folder listings, for "is that name taken on the NAS".
        var destinationListings: [String: Set<String>] = [:]
        var claimed: [String: String] = [:]

        func destinationTaken(_ path: String) -> Bool {
            let folder = (path as NSString).deletingLastPathComponent
            if destinationListings[folder] == nil {
                if LayoutMigrationDisk.lstatEntry(folder)?.kind == .directory {
                    walker.listed += 1
                    destinationListings[folder] = Set(((try? DirectoryListing.list(folder)) ?? []).map { $0.name.lowercased() })
                } else {
                    destinationListings[folder] = []
                }
            }
            return destinationListings[folder]?.contains((path as NSString).lastPathComponent.lowercased()) == true
        }

        for (index, mapped) in mapping.events.enumerated() {
            let eventID = String(format: "E%04d", index + 1)
            let sourcePath = legacyRoot + "/" + mapped.source
            let destinationPath = mirrorRoot + "/" + mapped.destination
            guard LayoutMigrationDisk.lstatEntry(sourcePath)?.kind == .directory else {
                blockers.append("\(mapped.source): the legacy event folder \(sourcePath) does not exist.")
                continue
            }
            if destinationPath.lowercased().hasPrefix(sourcePath.lowercased() + "/") {
                blockers.append("\(mapped.source): the destination \(mapped.destination) is inside the source folder.")
                continue
            }
            walker.eventRoot = sourcePath
            walker.listingLines = []
            walker.directories = []
            var candidates: [Candidate] = []
            var cameras: [String: NASLayoutMigrationPlan.CameraFolder] = [:]
            var keptSubfolders: [String] = []

            /// Every file below `folder`, each to `destinationFolder` plus
            /// its path below `folder`.
            func collect(_ folder: String, into destinationFolder: String, groupRoot: String, legacyKeyPrefix: String? = nil) {
                walker.directories.append(folder)
                guard let entries = walker.list(folder) else { return }
                let files = Set(entries.filter { $0.kind == .file }.map(\.name))
                for entry in entries {
                    let path = folder + "/" + entry.name
                    if entry.name == ".DS_Store" {
                        walker.leftInPlace.append(.init(path: path, reason: "Finder metadata; stays (reproducible)"))
                        continue
                    }
                    if entry.name.hasPrefix("._") {
                        if files.contains(String(entry.name.dropFirst(2))) {
                            // Travels with its file; added after the file.
                            walker.twins[path] = entry
                        } else {
                            walker.leftInPlace.append(.init(path: path, reason: "AppleDouble file without its file; stays"))
                        }
                        continue
                    }
                    switch entry.kind {
                    case .directory:
                        collect(path, into: destinationFolder + "/" + entry.name, groupRoot: groupRoot)
                    case .file:
                        let base = KeepBothNaming.split(entry.name).base.lowercased()
                        candidates.append(Candidate(
                            source: path,
                            destination: destinationFolder + "/" + entry.name,
                            entry: entry,
                            kind: Self.kind(of: entry.name),
                            groupKey: groupRoot + "\u{0}" + destinationFolder.lowercased() + "\u{0}" + base,
                            sourceFolder: folder,
                            legacyKey: legacyKeyPrefix.map { ($0 + "/" + entry.name).lowercased() },
                            cameraSource: groupRoot
                        ))
                    case .symlink, .other:
                        walker.refused.append(.init(path: path, reason: entry.kind == .symlink ? "Symlinks are never followed or moved." : "Not a regular file."))
                    }
                }
            }

            /// A legacy camera folder: media folders flatten, other
            /// subfolders are kept, loose files move up.
            func collectCamera(_ folder: String, name: String) {
                let normalized = NASCameraNames.normalized(name, extra: mapping.cameraNames)
                if !normalized.known {
                    unknownCameras.append(.init(path: folder, name: name))
                }
                let cameraDestination = destinationPath + "/" + EventStorageLocations.originalsFolderName + "/" + normalized.name
                let before = candidates.count
                walker.directories.append(folder)
                guard let entries = walker.list(folder) else { return }
                let files = Set(entries.filter { $0.kind == .file }.map(\.name))
                for entry in entries {
                    let path = folder + "/" + entry.name
                    if entry.name == ".DS_Store" {
                        walker.leftInPlace.append(.init(path: path, reason: "Finder metadata; stays (reproducible)"))
                        continue
                    }
                    if entry.name.hasPrefix("._") {
                        if files.contains(String(entry.name.dropFirst(2))) {
                            walker.twins[path] = entry
                        } else {
                            walker.leftInPlace.append(.init(path: path, reason: "AppleDouble file without its file; stays"))
                        }
                        continue
                    }
                    switch entry.kind {
                    case .directory where NASCameraNames.isMediaFolder(entry.name):
                        collect(path, into: cameraDestination, groupRoot: folder.lowercased(), legacyKeyPrefix: normalized.name + "/" + entry.name)
                    case .directory:
                        keptSubfolders.append(path)
                        collect(path, into: cameraDestination + "/" + entry.name, groupRoot: folder.lowercased())
                    case .file:
                        let base = KeepBothNaming.split(entry.name).base.lowercased()
                        candidates.append(Candidate(
                            source: path,
                            destination: cameraDestination + "/" + entry.name,
                            entry: entry,
                            kind: Self.kind(of: entry.name),
                            groupKey: folder.lowercased() + "\u{0}" + cameraDestination.lowercased() + "\u{0}" + base,
                            sourceFolder: folder
                        ))
                    case .symlink, .other:
                        walker.refused.append(.init(path: path, reason: "Not a regular file."))
                    }
                }
                let key = folder.lowercased()
                cameras[key] = .init(
                    sourceFolder: String(folder.dropFirst(sourcePath.count + 1)),
                    camera: normalized.name,
                    known: normalized.known,
                    files: candidates.count - before
                )
            }

            walker.directories.append(sourcePath)
            if let top = walker.list(sourcePath) {
                let topFiles = Set(top.filter { $0.kind == .file }.map(\.name))
                for entry in top {
                    let path = sourcePath + "/" + entry.name
                    if entry.name == ".DS_Store" {
                        walker.leftInPlace.append(.init(path: path, reason: "Finder metadata; stays (reproducible)"))
                        continue
                    }
                    if entry.name.hasPrefix("._") {
                        if topFiles.contains(String(entry.name.dropFirst(2))) {
                            walker.twins[path] = entry
                        } else {
                            walker.leftInPlace.append(.init(path: path, reason: "AppleDouble file without its file; stays"))
                        }
                        continue
                    }
                    switch entry.kind {
                    case .directory where mappedSources.contains(path.lowercased()):
                        // A subevent with its own mapping entry.
                        continue
                    case .directory where entry.name == EventStorageLocations.originalsFolderName:
                        // Already the mirror layout: camera names are still
                        // normalized, inner paths kept.
                        walker.directories.append(path)
                        for camera in walker.list(path) ?? [] {
                            let cameraPath = path + "/" + camera.name
                            if camera.kind == .directory, !camera.name.hasPrefix(".") {
                                let normalized = NASCameraNames.normalized(camera.name, extra: mapping.cameraNames)
                                if !normalized.known { unknownCameras.append(.init(path: cameraPath, name: camera.name)) }
                                collect(
                                    cameraPath,
                                    into: destinationPath + "/" + EventStorageLocations.originalsFolderName + "/" + normalized.name,
                                    groupRoot: cameraPath.lowercased()
                                )
                            } else if camera.kind == .file, camera.name != ".DS_Store", !camera.name.hasPrefix("._") {
                                candidates.append(Candidate(
                                    source: cameraPath,
                                    destination: destinationPath + "/" + EventStorageLocations.originalsFolderName + "/" + camera.name,
                                    entry: camera,
                                    kind: Self.kind(of: camera.name),
                                    groupKey: path.lowercased() + "\u{0}" + KeepBothNaming.split(camera.name).base.lowercased(),
                                    sourceFolder: path
                                ))
                            }
                        }
                    case .directory where entry.name == EventStorageLocations.editedFolderName:
                        collect(path, into: destinationPath + "/" + EventStorageLocations.editedFolderName, groupRoot: path.lowercased())
                    case .directory where DriveEventDiscovery.parseEventFolder(entry.name) != nil:
                        walker.leftInPlace.append(.init(path: path, reason: "A dated subfolder that the mapping does not list; add it as its own entry to migrate it"))
                    case .directory:
                        collectCamera(path, name: entry.name)
                    case .file:
                        candidates.append(Candidate(
                            source: path,
                            destination: destinationPath + "/" + entry.name,
                            entry: entry,
                            kind: Self.kind(of: entry.name),
                            groupKey: sourcePath.lowercased() + "\u{0}" + KeepBothNaming.split(entry.name).base.lowercased(),
                            sourceFolder: sourcePath
                        ))
                    case .symlink, .other:
                        walker.refused.append(.init(path: path, reason: "Not a regular file."))
                    }
                }
            }
            listings[sourcePath] = LayoutMigrationHash.sha256(walker.listingLines.sorted().joined(separator: "\n"))

            // Known subfolders: the catalog event the entry names says where
            // each file sat under Originals/<Camera> on the drive.
            var knownFiles = 0
            var ambiguous = 0
            if let eventUUID = mapped.eventID {
                if let snapshot, let catalogEvent = snapshot.base.state.savedEvents.first(where: { $0.id == eventUUID }) {
                    var known: [String: String?] = [:]
                    for assignment in snapshot.base.state.photoEventAssignments where assignment.eventID == eventUUID {
                        let layout = OrganizedArchiveLayout(
                            eventDate: "2000-01-01",
                            eventName: "E",
                            deviceID: assignment.deviceID ?? inputs.configuration.selectedDeviceID
                        )
                        let name = (assignment.relativePath as NSString).lastPathComponent
                        let key = "\(layout.cameraFolder)/\(layout.mediaFolder(for: assignment.relativePath).rawValue)/\(name)".lowercased()
                        known[key] = known[key] == nil ? .some(assignment.relativePath) : .some(nil)
                    }
                    ambiguous = known.values.count { $0 == nil }
                    // Two legacy files for one known name (two camera folders
                    // that normalize alike) are just as ambiguous.
                    var matches: [String: Int] = [:]
                    for candidate in candidates { if let key = candidate.legacyKey { matches[key, default: 0] += 1 } }
                    for (key, count) in matches where count > 1 && known[key] != nil {
                        if known[key] != .some(nil) { ambiguous += 1 }
                        known[key] = .some(nil)
                    }
                    // camera source + base → the subfolder its known file took.
                    var subfolderByBase: [String: Set<String>] = [:]
                    for i in candidates.indices {
                        guard let key = candidates[i].legacyKey, let hit = known[key], let relative = hit,
                              relative.contains("/") else { continue }
                        let camera = (candidates[i].destination as NSString).deletingLastPathComponent
                        candidates[i].destination = camera + "/" + relative
                        knownFiles += 1
                        let base = KeepBothNaming.split(candidates[i].entry.name).base.lowercased()
                        subfolderByBase[(candidates[i].cameraSource ?? "") + "\u{0}" + base, default: []]
                            .insert((relative as NSString).deletingLastPathComponent)
                    }
                    // Unknown files of the same base (sidecars the catalog
                    // does not list) follow when the subfolder is unambiguous.
                    for i in candidates.indices {
                        guard let key = candidates[i].legacyKey, known[key] == nil else { continue }
                        let base = KeepBothNaming.split(candidates[i].entry.name).base.lowercased()
                        guard let folders = subfolderByBase[(candidates[i].cameraSource ?? "") + "\u{0}" + base], folders.count == 1,
                              let sub = folders.first else { continue }
                        let camera = (candidates[i].destination as NSString).deletingLastPathComponent
                        candidates[i].destination = camera + "/" + sub + "/" + candidates[i].entry.name
                        knownFiles += 1
                    }
                    for i in candidates.indices where candidates[i].legacyKey != nil {
                        let folder = (candidates[i].destination as NSString).deletingLastPathComponent
                        candidates[i].groupKey = (candidates[i].cameraSource ?? "") + "\u{0}" + folder.lowercased() + "\u{0}"
                            + KeepBothNaming.split(candidates[i].entry.name).base.lowercased()
                    }
                    let expected = EventStorageLocations(configuration: {
                        var configuration = inputs.configuration
                        configuration.savedEvents = snapshot.base.state.savedEvents
                        return configuration
                    }()).layout(for: catalogEvent, deviceID: nil).mirrorEventFolderPath
                    if expected.lowercased() != mapped.destination.lowercased() {
                        notes.append("\(mapped.source): the catalog event \"\(catalogEvent.name)\" expects its NAS folder at \(expected), but the mapping puts it at \(mapped.destination); presence will not find these files until the two agree.")
                    }
                } else {
                    blockers.append("\(mapped.source): the catalog has no event \(eventUUID.uuidString).")
                }
            }

            // Files already where they belong (an in-place mapping) do not move.
            candidates.removeAll { $0.source == $0.destination }
            for candidate in candidates where candidate.source.lowercased() == candidate.destination.lowercased() {
                walker.leftInPlace.append(.init(path: candidate.source, reason: "Differs from its destination only by letter case; stays"))
            }
            candidates.removeAll { $0.source.lowercased() == $0.destination.lowercased() }
            candidates.sort { $0.source < $1.source }

            // Groups; a group whose members would land on one name is split
            // by source folder.
            var order: [String] = []
            var groups: [String: [Int]] = [:]
            for (i, candidate) in candidates.enumerated() {
                if groups[candidate.groupKey] == nil { order.append(candidate.groupKey) }
                groups[candidate.groupKey, default: []].append(i)
            }
            var splitOrder: [String] = []
            var splitGroups: [String: [Int]] = [:]
            for key in order {
                let members = groups[key] ?? []
                let names = members.map { candidates[$0].destination.lowercased() }
                if Set(names).count == names.count {
                    splitOrder.append(key)
                    splitGroups[key] = members
                } else {
                    for member in members {
                        let subKey = key + "\u{0}" + candidates[member].sourceFolder.lowercased()
                        if splitGroups[subKey] == nil { splitOrder.append(subKey) }
                        splitGroups[subKey, default: []].append(member)
                    }
                }
            }

            var resolved = candidates.map(\.destination)
            var renamed = Array(repeating: false, count: candidates.count)
            var colliding: [String] = []
            for key in splitOrder {
                let members = splitGroups[key] ?? []
                let taken = members.contains { member in
                    let destination = candidates[member].destination
                    return claimed[destination.lowercased()] != nil || destinationTaken(destination)
                        || destinationTaken(LayoutMigrationDisk.appleDoubleTwin(of: destination))
                }
                if taken {
                    colliding.append(key)
                } else {
                    for member in members { claimed[candidates[member].destination.lowercased()] = key }
                }
            }
            for key in colliding {
                let members = splitGroups[key] ?? []
                var chosen: Int?
                for number in 2...999 {
                    let names = members.map { member -> String in
                        let destination = candidates[member].destination
                        return ((destination as NSString).deletingLastPathComponent as NSString)
                            .appendingPathComponent(KeepBothNaming.suffixed((destination as NSString).lastPathComponent, number))
                    }
                    let free = names.allSatisfy { name in
                        claimed[name.lowercased()] == nil && !destinationTaken(name)
                            && !destinationTaken(LayoutMigrationDisk.appleDoubleTwin(of: name))
                    }
                    if free {
                        chosen = number
                        for (offset, member) in members.enumerated() {
                            resolved[member] = names[offset]
                            renamed[member] = true
                            claimed[names[offset].lowercased()] = key
                        }
                        break
                    }
                }
                guard chosen != nil else {
                    blockers.append("No free (N) name for \(candidates[members[0]].source).")
                    continue
                }
                for member in members {
                    let destination = candidates[member].destination
                    let onDisk = destinationTaken(destination)
                    let byClaim = claimed[destination.lowercased()].map { $0 != key } ?? false
                    conflicts.append(.init(
                        source: candidates[member].source,
                        plannedDestination: destination,
                        resolvedDestination: resolved[member],
                        reason: onDisk ? .destinationExists : (byClaim ? .claimedByAnotherFile : .travelsWithConflict),
                        existingByteCount: nil
                    ))
                }
            }

            var moves: [NASLayoutMigrationPlan.Move] = []
            for (i, candidate) in candidates.enumerated() {
                moves.append(.init(
                    source: candidate.source,
                    destination: resolved[i],
                    byteCount: candidate.entry.size,
                    modifiedAt: candidate.entry.modifiedAt,
                    kind: candidate.kind,
                    renamed: renamed[i],
                    companionOf: nil
                ))
            }
            // AppleDouble twins follow their file.
            for i in moves.indices {
                let twinPath = LayoutMigrationDisk.appleDoubleTwin(of: moves[i].source)
                guard let twin = walker.twins[twinPath] else { continue }
                moves.append(.init(
                    source: twinPath,
                    destination: LayoutMigrationDisk.appleDoubleTwin(of: moves[i].destination),
                    byteCount: twin.size,
                    modifiedAt: twin.modifiedAt,
                    kind: .appleDouble,
                    renamed: moves[i].renamed,
                    companionOf: i
                ))
            }

            events.append(.init(
                id: eventID,
                source: mapped.source,
                destination: mapped.destination,
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                cameras: cameras.values.sorted { $0.sourceFolder < $1.sourceFolder },
                moves: moves,
                sourceDirectories: Array(Set(walker.directories)).sorted {
                    let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
                    return a == b ? $0 > $1 : a > b
                },
                keptSubfolders: keptSubfolders.map { String($0.dropFirst(sourcePath.count + 1)) },
                knownSubfolderFiles: knownFiles,
                ambiguousKnownNames: ambiguous,
                byteCount: moves.reduce(0) { $0 + $1.byteCount }
            ))
        }

        // The catalog: rows that name a moved NAS path.
        var catalog = NASLayoutMigrationPlan.CatalogChanges(
            facePhotoRewrites: [], orientationCopies: [], burstSplitRewrites: [], syncRecordRewrites: [],
            tableCounts: [:], confirmedFaces: 0, markerKey: NASLayoutMigrationExecutor.markerKey
        )
        var catalogDigest: String?
        if let snapshot {
            let moves = events.flatMap(\.moves)
            var moveBySource: [String: NASLayoutMigrationPlan.Move] = [:]
            for move in moves where move.companionOf == nil { moveBySource[move.source.lowercased()] = move }
            catalogDigest = snapshot.digest
            catalog.tableCounts = snapshot.base.tableCounts
            catalog.confirmedFaces = snapshot.base.confirmedFaces
            let existingKeys = Set(snapshot.base.facePhotos.map(\.pathKey))
            var movingAway = Set<String>()
            for photo in snapshot.base.facePhotos {
                guard let move = moveBySource[photo.pathKey] else { continue }
                let newKey = EventStorageLocations.pathKey(move.destination)
                catalog.facePhotoRewrites.append(.init(
                    oldPathKey: photo.pathKey,
                    newPathKey: newKey,
                    newPath: move.destination,
                    newFileName: (move.destination as NSString).lastPathComponent,
                    confirmedFaceCount: photo.confirmedFaceCount
                ))
                movingAway.insert(photo.pathKey)
            }
            for rewrite in catalog.facePhotoRewrites where existingKeys.contains(rewrite.newPathKey) && !movingAway.contains(rewrite.newPathKey) {
                blockers.append("A face photo row already exists for \(rewrite.newPath); re-keying \(rewrite.oldPathKey) onto it would merge two photos.")
            }
            for move in moves where move.renamed && move.companionOf == nil {
                let date = Date(timeIntervalSinceReferenceDate: move.modifiedAt)
                let oldKey = FaceIndexStore.fileKey(fileName: (move.source as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
                let newKey = FaceIndexStore.fileKey(fileName: (move.destination as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
                if let turns = snapshot.base.state.displayOrientations[oldKey], snapshot.base.state.displayOrientations[newKey] == nil {
                    catalog.orientationCopies.append(.init(oldKey: oldKey, newKey: newKey, quarterTurns: turns))
                }
            }
            for split in snapshot.base.state.burstSplits {
                let mapped = split.memberPathKeys.map { key in moveBySource[key].map { EventStorageLocations.pathKey($0.destination) } ?? key }
                if mapped != split.memberPathKeys {
                    catalog.burstSplitRewrites.append(.init(id: split.id, oldMemberPathKeys: split.memberPathKeys, newMemberPathKeys: mapped))
                }
            }
            for row in snapshot.syncRecords {
                guard let move = moveBySource[(row.nasRoot + "/" + row.relativePath).lowercased()] else { continue }
                guard move.destination.hasPrefix(row.nasRoot + "/") else {
                    blockers.append("A Sync to NAS record for \(row.relativePath) would move outside its NAS root \(row.nasRoot).")
                    continue
                }
                catalog.syncRecordRewrites.append(.init(
                    nasRoot: row.nasRoot,
                    oldPathKey: row.pathKey,
                    newRelativePath: String(move.destination.dropFirst(row.nasRoot.count + 1))
                ))
            }
            // Assignments adopted from a NAS folder would need their ids
            // re-derived; the app never adopts from the NAS, so refuse.
            let prefixes = events.map { $0.sourcePath.lowercased() + "/" }
            let pointing = snapshot.base.state.photoEventAssignments.filter { assignment in
                let key = EventStorageLocations.pathKey((assignment.sourceRootPath as NSString).appendingPathComponent(assignment.relativePath))
                return prefixes.contains { key.hasPrefix($0) }
            }
            if !pointing.isEmpty {
                blockers.append("\(pointing.count) catalog assignment(s) point into the legacy NAS event folders; this migration does not rewrite assignments.")
            }
        }

        let allMoves = events.flatMap(\.moves)
        let summary = NASLayoutMigrationPlan.Summary(
            events: events.count,
            files: allMoves.count,
            byteCount: allMoves.reduce(0) { $0 + $1.byteCount },
            appleDoubleFiles: allMoves.count { $0.kind == .appleDouble },
            conflicts: conflicts.count,
            renamedFiles: allMoves.count { $0.renamed },
            unknownCameras: unknownCameras.count,
            keptSubfolders: events.reduce(0) { $0 + $1.keptSubfolders.count },
            knownSubfolderFiles: events.reduce(0) { $0 + $1.knownSubfolderFiles },
            leftInPlace: walker.leftInPlace.count,
            unreadable: walker.unreadable.count,
            refused: walker.refused.count,
            facePhotoRewrites: catalog.facePhotoRewrites.count,
            syncRecordRewrites: catalog.syncRecordRewrites.count,
            foldersListed: walker.listed
        )
        return NASLayoutMigrationPlan(
            format: NASLayoutMigrationPlan.formatName,
            version: NASLayoutMigrationPlan.currentVersion,
            id: UUID(),
            // Whole seconds: exactly representable, so a plan read back
            // encodes to the same bytes it was written as.
            createdAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)),
            supportFolderPath: inputs.supportFolder.standardizedFileURL.path,
            configurationPath: inputs.configurationURL.standardizedFileURL.path,
            catalogPath: inputs.catalogURL.map { $0.standardizedFileURL.path },
            legacyRoot: legacyRoot,
            mirrorRoot: mirrorRoot,
            mappingDigest: LayoutMigrationHash.sha256(try LayoutMigrationPlan.encoder().encode(mapping)),
            mapping: {
                var resolved = mapping
                resolved.legacyRoot = legacyRoot
                resolved.mirrorRoot = mirrorRoot
                return resolved
            }(),
            events: events,
            conflicts: conflicts,
            unknownCameras: unknownCameras,
            leftInPlace: walker.leftInPlace,
            unreadable: walker.unreadable,
            refused: walker.refused,
            blockers: blockers,
            notes: notes,
            catalog: catalog,
            fingerprint: .init(folderListings: listings, catalogDigest: catalogDigest),
            summary: summary
        )
    }

    static func kind(of name: String) -> NASLayoutMigrationPlan.FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        let media: Set<String> = ["arw", "cr2", "cr3", "nef", "dng", "raf", "rw2", "orf", "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
                                  "mp4", "mov", "m4v", "mts", "insv", "osv", "insp", "wav", "m4a", "mp3"]
        let sidecar: Set<String> = ["xmp", "lrf", "lrv", "thm", "xml", "srt", "photo-edit", "aae"]
        if media.contains(ext) { return .media }
        if sidecar.contains(ext) { return .sidecar }
        return .other
    }

}

/// The catalog rows a NAS layout migration reads: the Buffer migration's
/// snapshot plus Sync to NAS records.
enum NASLayoutMigrationCatalog {
    struct SyncRow: Sendable {
        var nasRoot: String
        var pathKey: String
        var relativePath: String
    }

    struct Snapshot: Sendable {
        var base: LayoutMigrationCatalog.Snapshot
        var syncRecords: [SyncRow]
        var digest: String
    }

    static func snapshot(catalogURL: URL) throws -> Snapshot {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try snapshot(database: $0) }
    }

    static func snapshot(database: Database) throws -> Snapshot {
        let base = try LayoutMigrationCatalog.snapshot(database: database)
        var rows: [SyncRow] = []
        if try database.tableExists(NASSyncStore.tableName) {
            rows = try Row.fetchAll(database, sql: "SELECT nas_root, path_key, relative_path FROM nas_sync_files ORDER BY nas_root, path_key").map {
                SyncRow(nasRoot: $0["nas_root"], pathKey: $0["path_key"], relativePath: $0["relative_path"])
            }
        }
        return Snapshot(base: base, syncRecords: rows, digest: try digest(database: database))
    }

    static func digest(database: Database) throws -> String {
        var text = try LayoutMigrationCatalog.digest(database: database)
        if try database.tableExists(NASSyncStore.tableName) {
            for row in try Row.fetchAll(database, sql: "SELECT nas_root, path_key, relative_path FROM nas_sync_files ORDER BY nas_root, path_key") {
                text += "\n" + (row["nas_root"] as String) + "\u{1F}" + (row["path_key"] as String) + "\u{1F}" + (row["relative_path"] as String)
            }
        }
        return LayoutMigrationHash.sha256(text)
    }
}
