import Foundation

/// One camera folder of a NAS event folder: `Originals/<folderName>`, with
/// the files under it that no assignment covers yet.
public struct DiscoveredNASCameraFolder: Hashable, Sendable {
    /// The camera folder's name on the NAS.
    public var folderName: String
    public var deviceID: String
    /// Paths relative to `Originals/<folderName>`, subfolders kept.
    public var files: [FileRecord]

    public init(folderName: String, deviceID: String, files: [FileRecord]) {
        self.folderName = folderName
        self.deviceID = deviceID
        self.files = files
    }
}

/// A dated event folder in the NAS mirror whose `Originals` hold files no
/// catalog assignment covers — typically media that only ever reached the
/// NAS, so no drive discovery could find it.
public struct DiscoveredNASEvent: Identifiable, Hashable, Sendable {
    public var id: String { relativeFolderPath }
    /// `<year>/<event folder>[/<subevent folder>…]` under the NAS root.
    public var relativeFolderPath: String
    /// The event folder names root-first, year excluded: one per event in
    /// the chain this folder nests in, itself last.
    public var folderNames: [String]
    public var name: String
    public var dateString: String
    public var cameras: [DiscoveredNASCameraFolder]
    /// The saved event already at this folder, when exactly one is.
    public var matchingEventID: UUID?

    public init(
        relativeFolderPath: String,
        folderNames: [String],
        name: String,
        dateString: String,
        cameras: [DiscoveredNASCameraFolder],
        matchingEventID: UUID?
    ) {
        self.relativeFolderPath = relativeFolderPath
        self.folderNames = folderNames
        self.name = name
        self.dateString = dateString
        self.cameras = cameras
        self.matchingEventID = matchingEventID
    }

    /// "Parent / Child" from the folder names, without their dates.
    public var displayName: String {
        folderNames.map { DriveEventDiscovery.parseEventFolder($0)?.name ?? $0 }.joined(separator: " / ")
    }

    public var fileCount: Int { cameras.reduce(0) { $0 + $1.files.count } }
    public var byteCount: Int64 { cameras.reduce(Int64(0)) { $0 + $1.files.reduce(Int64(0)) { $0 + $1.size } } }
}

/// Something discovery or adoption left alone, and why.
public struct NASDiscoveryProblem: Codable, Hashable, Sendable {
    /// Relative to the NAS root.
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct NASEventDiscoveryResult: Sendable {
    public var events: [DiscoveredNASEvent]
    public var problems: [NASDiscoveryProblem]

    public init(events: [DiscoveredNASEvent] = [], problems: [NASDiscoveryProblem] = []) {
        self.events = events
        self.problems = problems
    }
}

public struct NASAdoptionSummary: Sendable {
    public var createdEvents = 0
    public var addedAssignments = 0
    /// Files an assignment already covered when the write happened.
    public var alreadyCovered = 0
    /// Every event that gained assignments or was created, ancestors included.
    public var touchedEventIDs: Set<UUID> = []
    public var problems: [NASDiscoveryProblem] = []

    public init() {}
}

/// Finds event folders in the NAS mirror (`EventStorageLocations.nasRoot`,
/// `<year>/<event>[/<subevent>…]/Originals/<Camera>/<subpath>`) holding
/// files no catalog assignment covers, and adopts them as NAS-only files.
///
/// Read-only on the NAS: one `DirectoryListing` (`getattrlistbulk`) per
/// folder, never a stat per file and never a file opened. Adoption writes
/// catalog rows only, in the shape an adopted drive photo has after Take
/// Off Drive: `sourceRootPath` is the event's own drive `Originals/<Camera>`
/// folder, so the file counts as a drive-adopted file that is on no drive
/// (never as a separate source Free Up Source could remove), and its NAS
/// copy is the mirror path the presence sweep already probes.
public enum NASEventDiscovery {
    public typealias Lister = (String) throws -> [DirectoryListingEntry]

    /// Hidden entries (`._*`, `.DS_Store`, `.Camera Toolkit`, `.zfs`, Sync to
    /// NAS temporaries), Trash folders and anything that is not a regular
    /// file or folder are never media.
    static func isSkipped(_ entry: DirectoryListingEntry) -> Bool {
        entry.name.hasPrefix(".") || NASSyncPlanner.isJunk(entry.name) || entry.name == "_Trash"
            || (entry.kind != .file && entry.kind != .directory)
    }

    public static func discover(
        configuration: AppConfiguration,
        list: Lister = DirectoryListing.list,
        isCancelled: () -> Bool = { false }
    ) -> NASEventDiscoveryResult {
        let locations = EventStorageLocations(configuration: configuration)
        let root = locations.nasRoot.path
        guard nasRootIsUsable(locations) else { return NASEventDiscoveryResult() }
        let covered = coveredMirrorKeys(configuration: configuration, locations: locations, folderKeys: nil)
        let folders = eventsByFolderKey(configuration.savedEvents, locations: locations)
        var result = NASEventDiscoveryResult()

        func listed(_ relative: String) -> [DirectoryListingEntry]? {
            do {
                return try list(relative.isEmpty ? root : root + "/" + relative)
            } catch {
                result.problems.append(NASDiscoveryProblem(path: relative, reason: "could not be listed: \(error.localizedDescription)"))
                return nil
            }
        }

        /// Every regular file under a camera folder, relative to it; nil
        /// when any folder of it could not be listed — a partial camera
        /// folder is never offered.
        func cameraFiles(_ cameraRelative: String) -> [(path: String, entry: DirectoryListingEntry)]? {
            var files: [(String, DirectoryListingEntry)] = []
            var pending = [""]
            while let sub = pending.popLast() {
                if isCancelled() { return nil }
                guard let entries = listed(sub.isEmpty ? cameraRelative : cameraRelative + "/" + sub) else { return nil }
                for entry in entries where !isSkipped(entry) {
                    let path = sub.isEmpty ? entry.name : sub + "/" + entry.name
                    if entry.kind == .directory {
                        pending.append(path)
                    } else if entry.isReadable {
                        files.append((path, entry))
                    } else {
                        result.problems.append(NASDiscoveryProblem(path: cameraRelative + "/" + path, reason: "this user cannot read it"))
                    }
                }
            }
            return files
        }

        func walk(_ relative: String, names: [String]) {
            if isCancelled() { return }
            guard let parsed = DriveEventDiscovery.parseEventFolder(names[names.count - 1]),
                  let entries = listed(relative) else { return }
            var cameras: [DiscoveredNASCameraFolder] = []
            for entry in entries where entry.kind == .directory && !isSkipped(entry) {
                if DriveEventDiscovery.parseEventFolder(entry.name) != nil {
                    walk(relative + "/" + entry.name, names: names + [entry.name])
                    continue
                }
                // `Edited/` holds edit tags, not cameras; any other folder
                // is outside the layout and left alone.
                guard entry.name == EventStorageLocations.originalsFolderName,
                      let cameraEntries = listed(relative + "/" + entry.name) else { continue }
                for camera in cameraEntries where camera.kind == .directory && !isSkipped(camera) {
                    let cameraRelative = relative + "/" + entry.name + "/" + camera.name
                    let deviceID = DriveEventDiscovery.deviceID(forDeviceFolder: camera.name)
                    // The app must name this folder exactly so, or an
                    // assignment would point beside the files.
                    guard NASSyncStore.pathKey(cameraFolderName(deviceID: deviceID)) == NASSyncStore.pathKey(camera.name) else {
                        result.problems.append(NASDiscoveryProblem(
                            path: cameraRelative,
                            reason: "the app names this camera’s folder “\(cameraFolderName(deviceID: deviceID))”"
                        ))
                        continue
                    }
                    guard let files = cameraFiles(cameraRelative) else { continue }
                    var uncovered: [FileRecord] = []
                    for (path, file) in files {
                        guard !covered.contains(NASSyncStore.pathKey(cameraRelative + "/" + path)) else { continue }
                        guard (try? PathSafety.validateRelativePath(path)) != nil,
                              NASSyncStore.pathKey(PortablePath.sanitize(relativePath: path)) == NASSyncStore.pathKey(path) else {
                            result.problems.append(NASDiscoveryProblem(path: cameraRelative + "/" + path, reason: "its name cannot be stored as is"))
                            continue
                        }
                        uncovered.append(FileRecord(
                            path: path,
                            size: file.size,
                            modifiedAt: Date(timeIntervalSinceReferenceDate: file.modifiedAt)
                        ))
                    }
                    guard !uncovered.isEmpty else { continue }
                    uncovered.sort { $0.path < $1.path }
                    cameras.append(DiscoveredNASCameraFolder(folderName: camera.name, deviceID: deviceID, files: uncovered))
                }
            }
            guard !cameras.isEmpty else { return }
            let matches = folders[NASSyncStore.pathKey(relative)] ?? []
            result.events.append(DiscoveredNASEvent(
                relativeFolderPath: relative,
                folderNames: names,
                name: parsed.name,
                dateString: parsed.date,
                cameras: cameras,
                matchingEventID: matches.count == 1 ? matches[0] : nil
            ))
        }

        guard let years = listed("") else { return result }
        for year in years where year.kind == .directory && year.name.count == 4 && year.name.allSatisfy(\.isNumber) {
            guard let events = listed(year.name) else { continue }
            for folder in events where folder.kind == .directory && !isSkipped(folder) {
                walk(year.name + "/" + folder.name, names: [folder.name])
            }
        }
        result.events.sort { $0.relativeFolderPath < $1.relativeFolderPath }
        return result
    }

    /// Adds the discovered files to their events as NAS-only files. Saved
    /// events are matched by their full mirror folder path (NFC, case
    /// folded); a missing event — and any missing ancestor — is created
    /// from its folder name with the on-disk parent linkage. Coverage is
    /// checked again against `configuration` as it is now, so a file
    /// assigned since discovery ran is not added twice. A folder or file
    /// the app would not resolve back to the same NAS path is skipped and
    /// reported. Writes only `configuration`.
    @discardableResult
    public static func adopt(
        _ discovered: [DiscoveredNASEvent],
        into configuration: inout AppConfiguration
    ) -> NASAdoptionSummary {
        var summary = NASAdoptionSummary()
        guard !discovered.isEmpty else { return summary }
        var scratch = configuration
        var locations = EventStorageLocations(configuration: scratch)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        var folders = eventsByFolderKey(scratch.savedEvents, locations: locations)
        var created: Set<UUID> = []
        let targetKeys = Set(discovered.map { NASSyncStore.pathKey($0.relativeFolderPath) })
        var covered = coveredMirrorKeys(configuration: scratch, locations: locations, folderKeys: targetKeys)
        // An asset id names its event, so only the target events' rows can collide.
        let targetEventIDs = Set(targetKeys.flatMap { folders[$0] ?? [] })
        var existingIDs = Set(scratch.photoEventAssignments.lazy
            .filter { targetEventIDs.contains($0.eventID) }
            .map(CatalogStore.eventAssetID))

        /// The event at `<year>/<names…>`, created with its ancestors when
        /// missing. Nil when two saved events claim the folder, or when the
        /// app would not put a new event at exactly this folder.
        func ensureEvent(year: String, names: [String]) -> UUID? {
            let relative = ([year] + names).joined(separator: "/")
            let key = NASSyncStore.pathKey(relative)
            if let matches = folders[key] {
                if matches.count == 1 { return matches[0] }
                summary.problems.append(NASDiscoveryProblem(path: relative, reason: "\(matches.count) events use this folder"))
                return nil
            }
            guard let parsed = DriveEventDiscovery.parseEventFolder(names[names.count - 1]),
                  let date = formatter.date(from: parsed.date) else { return nil }
            var parentID: UUID?
            if names.count > 1 {
                guard let parent = ensureEvent(year: year, names: Array(names.dropLast())) else { return nil }
                parentID = parent
            }
            let event = SavedCameraEvent(name: parsed.name, eventDate: date, storagePolicy: nil, parentEventID: parentID)
            locations.events = scratch.savedEvents + [event]
            guard NASSyncStore.pathKey(locations.layout(for: event, deviceID: nil).mirrorEventFolderPath) == key else {
                locations.events = scratch.savedEvents
                summary.problems.append(NASDiscoveryProblem(
                    path: relative,
                    reason: "an event made from this folder name would use \(locations.layout(for: event, deviceID: nil).mirrorEventFolderPath)"
                ))
                return nil
            }
            scratch.savedEvents.append(event)
            folders[key] = [event.id]
            created.insert(event.id)
            return event.id
        }

        // Parents first, so a subevent links to the event its parent
        // folder became.
        for folder in discovered.sorted(by: { $0.folderNames.count < $1.folderNames.count }) {
            let year = String(folder.relativeFolderPath.prefix { $0 != "/" })
            guard let eventID = ensureEvent(year: year, names: folder.folderNames),
                  let event = scratch.savedEvents.first(where: { $0.id == eventID }) else { continue }
            let policy = locations.resolvedPolicy(for: event)
            for camera in folder.cameras {
                let layout = locations.layout(for: event, deviceID: camera.deviceID)
                let expectedRoot = NASSyncStore.pathKey(folder.relativeFolderPath + "/" + EventStorageLocations.originalsFolderName + "/" + camera.folderName)
                guard NASSyncStore.pathKey(layout.mirrorOriginalsPath) == expectedRoot else {
                    summary.problems.append(NASDiscoveryProblem(
                        path: folder.relativeFolderPath + "/" + EventStorageLocations.originalsFolderName + "/" + camera.folderName,
                        reason: "the event keeps this camera’s files in \(layout.mirrorOriginalsPath)"
                    ))
                    continue
                }
                let driveRoot = locations.originalsRoot(for: event, deviceID: camera.deviceID, policy: policy).path
                for file in camera.files {
                    guard let mirror = try? layout.mirrorRelativePath(for: file.path),
                          NASSyncStore.pathKey(mirror) == expectedRoot + "/" + NASSyncStore.pathKey(file.path) else {
                        summary.problems.append(NASDiscoveryProblem(path: folder.relativeFolderPath + "/" + file.path, reason: "its path does not resolve back to itself"))
                        continue
                    }
                    let key = NASSyncStore.pathKey(mirror)
                    let assignment = PhotoEventAssignment(
                        sourceRootPath: driveRoot,
                        relativePath: file.path,
                        fileSize: file.size,
                        modifiedAt: file.modifiedAt,
                        eventID: eventID,
                        deviceID: camera.deviceID
                    )
                    let id = CatalogStore.eventAssetID(assignment)
                    guard !covered.contains(key), !existingIDs.contains(id) else {
                        summary.alreadyCovered += 1
                        continue
                    }
                    scratch.photoEventAssignments.append(assignment)
                    covered.insert(key)
                    existingIDs.insert(id)
                    summary.addedAssignments += 1
                    summary.touchedEventIDs.insert(eventID)
                }
            }
        }

        // An event made only for a folder whose files were all skipped is
        // dropped again, unless a kept event nests in it.
        let byID = EventHierarchy.index(scratch.savedEvents)
        var keep: Set<UUID> = []
        for id in summary.touchedEventIDs {
            keep.insert(id)
            if let event = byID[id] {
                keep.formUnion(EventHierarchy.ancestors(of: event, byID: byID).map(\.id))
            }
        }
        let dropped = created.subtracting(keep)
        scratch.savedEvents.removeAll { dropped.contains($0.id) }
        summary.createdEvents = created.count - dropped.count
        summary.touchedEventIDs.formUnion(keep)
        configuration = scratch
        return summary
    }

    /// The camera folder name the app uses for `deviceID` under `Originals`.
    static func cameraFolderName(deviceID: String) -> String {
        OrganizedArchiveLayout(eventDate: "", eventName: "", deviceID: deviceID, parentEventFolders: [], year: "").cameraFolder
    }

    /// A NAS root that is mounted, is a folder, and is not one of the drive
    /// roots (or nested with one) — otherwise drive discovery owns the files.
    static func nasRootIsUsable(_ locations: EventStorageLocations) -> Bool {
        let root = locations.nasRoot.path
        guard VolumeInfo.isAvailable(locations.nasRoot),
              LayoutMigrationDisk.lstatEntry(root)?.kind == .directory else { return false }
        for drive in [locations.bufferRoot.path, locations.privateStagingRoot.path] {
            if drive == root || drive.hasPrefix(root + "/") || root.hasPrefix(drive + "/") { return false }
        }
        return true
    }

    /// Mirror folder key (`NASSyncStore.pathKey`) → the saved events whose
    /// NAS event folder it is.
    static func eventsByFolderKey(_ events: [SavedCameraEvent], locations: EventStorageLocations) -> [String: [UUID]] {
        var result: [String: [UUID]] = [:]
        for event in events {
            result[NASSyncStore.pathKey(locations.layout(for: event, deviceID: nil).mirrorEventFolderPath), default: []].append(event.id)
        }
        return result
    }

    /// `NASSyncStore.pathKey` of every NAS mirror path an assignment owns:
    /// its mirror copy, and its source when that is itself under the NAS
    /// root. `folderKeys` limits the work to events whose mirror folder is
    /// one of them (nil: every event).
    static func coveredMirrorKeys(
        configuration: AppConfiguration,
        locations: EventStorageLocations,
        folderKeys: Set<String>?
    ) -> Set<String> {
        var layouts: [String: OrganizedArchiveLayout] = [:]
        var eventsByID: [UUID: SavedCameraEvent] = [:]
        for event in configuration.savedEvents where eventsByID[event.id] == nil {
            eventsByID[event.id] = event
        }
        var inScope: [UUID: Bool] = [:]
        let nasPrefix = locations.nasRoot.path + "/"
        var covered: Set<String> = []
        for assignment in configuration.photoEventAssignments {
            if assignment.sourceRootPath.hasPrefix(nasPrefix) || assignment.sourceRootPath == locations.nasRoot.path,
               let source = locations.sourceURL(for: assignment), let relative = locations.nasRelativePath(source.path) {
                covered.insert(NASSyncStore.pathKey(relative))
            }
            guard let event = eventsByID[assignment.eventID] else { continue }
            if let folderKeys {
                let scoped = inScope[event.id] ?? {
                    let value = folderKeys.contains(NASSyncStore.pathKey(locations.layout(for: event, deviceID: nil).mirrorEventFolderPath))
                    inScope[event.id] = value
                    return value
                }()
                guard scoped else { continue }
            }
            let layoutKey = "\(event.id)\u{0}\(assignment.deviceID ?? "")"
            let layout: OrganizedArchiveLayout
            if let cached = layouts[layoutKey] {
                layout = cached
            } else {
                layout = locations.layout(for: event, deviceID: assignment.deviceID)
                layouts[layoutKey] = layout
            }
            if let mirror = try? layout.mirrorRelativePath(for: assignment.relativePath) {
                covered.insert(NASSyncStore.pathKey(mirror))
            }
        }
        return covered
    }
}

/// What the Add to Events job settled on before the catalog write: the
/// folders as a fresh listing found them, and the backup taken first.
public struct NASAdoptionPlan: Sendable {
    public var events: [DiscoveredNASEvent]
    public var problems: [NASDiscoveryProblem]
    public var backup: CatalogBackupManifest?
}

extension NASEventDiscovery {
    /// The off-main half of Add to Events. Refuses while NAS renames are
    /// queued — until they land, an event's old NAS folder still looks
    /// unowned and would be adopted a second time. Then lists the chosen
    /// folders again (the sidebar's answer may be stale) and takes a
    /// verified catalog backup before anything is written; a backup that
    /// fails stops the adoption.
    public static func prepareAdoption(
        folderIDs: Set<String>,
        configuration: AppConfiguration,
        pendingNASRenames: Int,
        backup: () throws -> CatalogBackupResult,
        list: Lister = DirectoryListing.list,
        isCancelled: () -> Bool = { false }
    ) throws -> NASAdoptionPlan {
        guard pendingNASRenames == 0 else {
            throw ToolkitError.commandFailed(
                "\(pendingNASRenames) NAS rename\(pendingNASRenames == 1 ? " is" : "s are") still waiting. Nothing was added; try again once they have run."
            )
        }
        let fresh = discover(configuration: configuration, list: list, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let events = fresh.events.filter { folderIDs.contains($0.id) }
        guard !events.isEmpty else { return NASAdoptionPlan(events: [], problems: fresh.problems, backup: nil) }
        let result = try backup()
        return NASAdoptionPlan(events: events, problems: fresh.problems, backup: result.manifest)
    }
}
