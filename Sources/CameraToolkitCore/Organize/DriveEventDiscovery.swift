import Foundation

/// Which on-disk layout a discovered camera folder uses.
public enum DriveFolderLayout: String, Codable, Hashable, Sendable {
    /// `<event>/Originals/<Camera>/…`
    case originals
    /// `<event>/<device>/Card Copy/…` — the layout `Originals` replaced.
    /// Still discovered so an unmigrated drive is found and offered for
    /// the layout migration.
    case legacyCardCopy
}

public struct DiscoveredDriveEvent: Identifiable, Hashable, Sendable {
    public var id: String { filesRootPath }
    public var eventFolderPath: String
    /// On-disk path of the parent event folder, when this folder nests inside
    /// another dated event folder. Adoption turns it into `parentEventID`.
    public var parentEventFolderPath: String?
    public var name: String
    public var dateString: String
    public var deviceID: String
    /// The camera's files root: `<event>/Originals/<Camera>`, or the legacy
    /// `<event>/<device>/Card Copy`.
    public var filesRootPath: String
    public var layout: DriveFolderLayout
    /// Files not yet covered by any event assignment, relative to `filesRootPath`.
    public var files: [FileRecord]
    public var policy: EventStoragePolicy
    public var matchingEventID: UUID?

    public var byteCount: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }
}

/// One camera folder on the drive, whatever its assignments: used to tell
/// the owner how much of a drive still sits in the legacy layout.
public struct DriveCameraFolder: Hashable, Sendable {
    public var eventFolderPath: String
    /// `<event>/<device>` for the legacy layout, `<event>/Originals/<Camera>` otherwise.
    public var cameraFolderPath: String
    public var filesRootPath: String
    public var layout: DriveFolderLayout
    public var deviceID: String
}

/// Finds event folders already on the working drive that the configuration
/// does not know about yet, so a drive organized by hand can join the
/// catalog. Both layouts are read during the transition:
/// `<yyyy>/<yyyy-MM-dd Name>/Originals/<Camera>/…` and the legacy
/// `<yyyy>/<yyyy-MM-dd Name>/<Camera>/Card Copy/…`.
/// A dated folder inside an event folder is a subevent root — it can hold
/// camera folders of its own and deeper subevents. `Edited` is the owner's
/// and is never read as a camera.
public enum DriveEventDiscovery {
    /// The device id a camera folder names. Accepts the current display
    /// names ("Osmo 360", "Osmo Nano"), the legacy device folders
    /// ("DJI Osmo 360", "DJI Nano"), and the ids themselves.
    public static func deviceID(forDeviceFolder name: String) -> String {
        let lowered = name.lowercased()
        if let known = CameraCatalog.deviceNames.first(where: { $0.value.lowercased() == lowered })?.key {
            return known
        }
        switch lowered {
        case "sony a7v", "sony-a7v": return "sony-a7v"
        case "dji osmo 360", "osmo-360": return "osmo-360"
        case "dji mini 2", "dji-mini-2": return "dji-mini-2"
        case "dji nano", "dji-nano": return "dji-nano"
        case "dji action 6", "action-6": return "action-6"
        case "iphone": return "iphone"
        case "camera": return "generic-camera"
        default: return name
        }
    }

    public static func discover(
        driveRoot: URL,
        policy: EventStoragePolicy,
        configuration: AppConfiguration,
        fileManager: FileManager = .default
    ) throws -> [DiscoveredDriveEvent] {
        guard fileManager.fileExists(atPath: driveRoot.path) else { return [] }
        let locations = EventStorageLocations(configuration: configuration)
        var events: [UUID: SavedCameraEvent] = [:]
        for event in configuration.savedEvents where events[event.id] == nil {
            events[event.id] = event
        }

        // The covered set needs every candidate path's `pathKey`, but the
        // roots only depend on (event, device, policy): rebuilding them per
        // assignment minted date formatters by the thousand, so they are
        // memoized and each file contributes a join + standardize — the
        // same work `driveURL`/`sourceURL` do.
        var driveRoots: [String: [URL]] = [:]
        var sourceRoots: [String: URL] = [:]
        var validRelative: [String: Bool] = [:]
        /// Both layouts' roots: an assignment covers its file in either.
        func driveCandidateRoots(_ policy: EventStoragePolicy, _ event: SavedCameraEvent, _ deviceID: String?) -> [URL] {
            let key = "\(event.id)\u{0}\(policy.rawValue)\u{0}\(deviceID ?? "")"
            if let cached = driveRoots[key] { return cached }
            let roots = [
                locations.originalsRoot(for: event, deviceID: deviceID, policy: policy),
                locations.legacyCardCopyRoot(for: event, deviceID: deviceID, policy: policy),
            ]
            driveRoots[key] = roots
            return roots
        }
        func isValidRelative(_ path: String) -> Bool {
            if let cached = validRelative[path] { return cached }
            let valid = (try? PathSafety.validateRelativePath(path)) != nil
            validRelative[path] = valid
            return valid
        }

        var covered: Set<String> = []
        for assignment in configuration.photoEventAssignments {
            guard let event = events[assignment.eventID] else { continue }
            autoreleasepool {
                for candidatePolicy in EventStoragePolicy.allCases {
                    guard isValidRelative(assignment.relativePath) else { continue }
                    for root in driveCandidateRoots(candidatePolicy, event, assignment.deviceID) {
                        let url = root
                            .appendingPathComponent(assignment.relativePath)
                            .standardizedFileURL
                        covered.insert(EventStorageLocations.pathKey(url.path))
                    }
                }
                if isValidRelative(assignment.relativePath) {
                    let sourceRoot: URL
                    if let cached = sourceRoots[assignment.sourceRootPath] {
                        sourceRoot = cached
                    } else {
                        sourceRoot = URL(
                            fileURLWithPath: NSString(string: assignment.sourceRootPath).expandingTildeInPath,
                            isDirectory: true
                        )
                        sourceRoots[assignment.sourceRootPath] = sourceRoot
                    }
                    let source = sourceRoot
                        .appendingPathComponent(assignment.relativePath)
                        .standardizedFileURL
                    covered.insert(EventStorageLocations.pathKey(source.path))
                }
            }
        }

        var discovered: [DiscoveredDriveEvent] = []
        for year in try directories(in: driveRoot, fileManager: fileManager)
        where year.lastPathComponent.count == 4 && year.lastPathComponent.allSatisfy(\.isNumber) {
            for eventFolder in try directories(in: year, fileManager: fileManager) {
                try scanEventFolder(
                    eventFolder,
                    parentEventFolderPath: nil,
                    driveRoot: driveRoot,
                    policy: policy,
                    locations: locations,
                    configuration: configuration,
                    covered: covered,
                    fileManager: fileManager,
                    into: &discovered
                )
            }
        }
        return discovered.sorted { $0.dateString == $1.dateString ? $0.name < $1.name : $0.dateString < $1.dateString }
    }

    /// Scans one dated event folder: dated subdirectories are subevent roots
    /// and recurse; `Originals/<Camera>` folders are the current layout;
    /// any other folder holding a `Card Copy` is a legacy camera folder.
    private static func scanEventFolder(
        _ eventFolder: URL,
        parentEventFolderPath: String?,
        driveRoot: URL,
        policy: EventStoragePolicy,
        locations: EventStorageLocations,
        configuration: AppConfiguration,
        covered: Set<String>,
        fileManager: FileManager,
        into discovered: inout [DiscoveredDriveEvent]
    ) throws {
        guard let parsed = parseEventFolder(eventFolder.lastPathComponent) else { return }
        let eventFolderPath = eventFolder.standardizedFileURL.path
        var found: [DriveCameraFolder] = []
        for subdirectory in try directories(in: eventFolder, fileManager: fileManager) {
            if parseEventFolder(subdirectory.lastPathComponent) != nil {
                try scanEventFolder(
                    subdirectory,
                    parentEventFolderPath: eventFolderPath,
                    driveRoot: driveRoot,
                    policy: policy,
                    locations: locations,
                    configuration: configuration,
                    covered: covered,
                    fileManager: fileManager,
                    into: &discovered
                )
                continue
            }
            found += try cameraFolders(in: subdirectory, eventFolderPath: eventFolderPath, fileManager: fileManager)
        }
        for folder in found {
            let root = URL(fileURLWithPath: folder.filesRootPath, isDirectory: true)
            let files = try FileScanner(fileManager: fileManager).scan(root: root).filter { file in
                autoreleasepool {
                    !covered.contains(EventStorageLocations.pathKey(root.appendingPathComponent(file.path).path))
                }
            }
            guard !files.isEmpty else { continue }
            let components = relativeComponents(of: eventFolder, under: driveRoot)
            let matching = configuration.savedEvents.first {
                folderComponents(of: $0, locations: locations) == components
            }
            discovered.append(DiscoveredDriveEvent(
                eventFolderPath: eventFolderPath,
                parentEventFolderPath: parentEventFolderPath,
                name: parsed.name,
                dateString: parsed.date,
                deviceID: folder.deviceID,
                filesRootPath: folder.filesRootPath,
                layout: folder.layout,
                files: files,
                policy: policy,
                matchingEventID: matching?.id
            ))
        }
    }

    /// The camera folders one non-dated child of an event folder holds:
    /// every `<Camera>` inside `Originals`, or the child itself when it is a
    /// legacy device folder with a `Card Copy`. `Edited` holds none.
    static func cameraFolders(in subdirectory: URL, eventFolderPath: String, fileManager: FileManager) throws -> [DriveCameraFolder] {
        let name = subdirectory.lastPathComponent
        if name == EventStorageLocations.editedFolderName { return [] }
        if name == EventStorageLocations.originalsFolderName {
            return try directories(in: subdirectory, fileManager: fileManager).map { camera in
                DriveCameraFolder(
                    eventFolderPath: eventFolderPath,
                    cameraFolderPath: camera.standardizedFileURL.path,
                    filesRootPath: camera.standardizedFileURL.path,
                    layout: .originals,
                    deviceID: deviceID(forDeviceFolder: camera.lastPathComponent)
                )
            }
        }
        let cardCopy = subdirectory.appendingPathComponent(EventStorageLocations.legacyCardCopyFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cardCopy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        return [DriveCameraFolder(
            eventFolderPath: eventFolderPath,
            cameraFolderPath: subdirectory.standardizedFileURL.path,
            filesRootPath: cardCopy.standardizedFileURL.path,
            layout: .legacyCardCopy,
            deviceID: deviceID(forDeviceFolder: name)
        )]
    }

    /// Every camera folder under `driveRoot`'s dated event folders (and
    /// their subevents), in both layouts, whether or not the catalog covers
    /// its files. Nothing is read beyond directory listings.
    public static func cameraFolders(driveRoot: URL, fileManager: FileManager = .default) throws -> [DriveCameraFolder] {
        guard fileManager.fileExists(atPath: driveRoot.path) else { return [] }
        var result: [DriveCameraFolder] = []
        func walk(_ eventFolder: URL) throws {
            guard parseEventFolder(eventFolder.lastPathComponent) != nil else { return }
            let eventFolderPath = eventFolder.standardizedFileURL.path
            for subdirectory in try directories(in: eventFolder, fileManager: fileManager) {
                if parseEventFolder(subdirectory.lastPathComponent) != nil {
                    try walk(subdirectory)
                } else {
                    result += try cameraFolders(in: subdirectory, eventFolderPath: eventFolderPath, fileManager: fileManager)
                }
            }
        }
        for year in try directories(in: driveRoot, fileManager: fileManager)
        where year.lastPathComponent.count == 4 && year.lastPathComponent.allSatisfy(\.isNumber) {
            for eventFolder in try directories(in: year, fileManager: fileManager) {
                try walk(eventFolder)
            }
        }
        return result
    }

    /// `<year>/<parent event folder>/…/<event folder>` components of `url`
    /// relative to `root`. Independent of which drive the path sits on, so it
    /// can be compared against a saved event's expected layout.
    static func relativeComponents(of url: URL, under root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return [] }
        return String(path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
    }

    /// The `<year>/<…>/<event folder>` components `event` should occupy.
    static func folderComponents(of event: SavedCameraEvent, locations: EventStorageLocations) -> [String] {
        let layout = locations.layout(for: event, deviceID: nil)
        return [layout.year] + layout.parentEventFolders + [layout.eventFolder]
    }

    /// Adds discovered folders as events. Their files stay exactly where they
    /// are; each assignment points at the drive copy itself. Subevent folders
    /// get their `parentEventID` from the event occupying the parent folder,
    /// creating that event from the folder name when needed.
    @discardableResult
    public static func adopt(
        _ discovered: [DiscoveredDriveEvent],
        into configuration: inout AppConfiguration
    ) -> (createdEvents: Int, addedAssignments: Int) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        var locations = EventStorageLocations(configuration: configuration)

        var created = 0
        var added = 0
        /// The event occupying `folderPath` on `policy`'s drive — an existing
        /// event when the path matches, otherwise a freshly created one.
        /// Returns nil for a non-dated folder (e.g. a bare year folder).
        func ensureEventID(forFolderPath folderPath: String, policy: EventStoragePolicy) -> UUID? {
            guard let parsed = parseEventFolder(URL(fileURLWithPath: folderPath).lastPathComponent),
                  let date = formatter.date(from: parsed.date) else { return nil }
            locations.events = configuration.savedEvents
            let components = relativeComponents(
                of: URL(fileURLWithPath: folderPath),
                under: locations.driveRoot(for: policy)
            )
            if let existing = configuration.savedEvents.first(where: {
                folderComponents(of: $0, locations: locations) == components
            }) {
                return existing.id
            }
            var parentID: UUID?
            if components.count > 2 {
                let parentPath = URL(fileURLWithPath: folderPath).deletingLastPathComponent().path
                parentID = ensureEventID(forFolderPath: parentPath, policy: policy)
            }
            let event = SavedCameraEvent(
                name: parsed.name,
                eventDate: date,
                storagePolicy: policy == .buffer ? nil : policy,
                parentEventID: parentID
            )
            configuration.savedEvents.append(event)
            locations.events = configuration.savedEvents
            created += 1
            return event.id
        }

        for folder in discovered {
            let eventID: UUID
            locations.events = configuration.savedEvents
            let components = relativeComponents(
                of: URL(fileURLWithPath: folder.eventFolderPath),
                under: locations.driveRoot(for: folder.policy)
            )
            if let existing = folder.matchingEventID
                ?? configuration.savedEvents.first(where: {
                    folderComponents(of: $0, locations: locations) == components
                })?.id {
                eventID = existing
            } else if let createdID = ensureEventID(forFolderPath: folder.eventFolderPath, policy: folder.policy) {
                // `ensureEventID` walks the folder path upward, so a nested
                // folder also materializes any missing ancestor events.
                eventID = createdID
            } else {
                continue
            }
            for file in folder.files {
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: folder.filesRootPath,
                    relativePath: file.path,
                    fileSize: file.size,
                    modifiedAt: file.modifiedAt,
                    eventID: eventID,
                    deviceID: folder.deviceID
                ))
                added += 1
            }
        }
        return (created, added)
    }

    public static func parseEventFolder(_ name: String) -> (date: String, name: String)? {
        guard name.count > 11 else { return nil }
        let date = String(name.prefix(10))
        let separator = name[name.index(name.startIndex, offsetBy: 10)]
        let rest = String(name.dropFirst(11)).trimmingCharacters(in: .whitespaces)
        let parts = date.split(separator: "-")
        guard separator == " ", !rest.isEmpty, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return (date, rest)
    }

    static func directories(in url: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
