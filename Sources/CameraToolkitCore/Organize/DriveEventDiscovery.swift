import Foundation

public struct DiscoveredDriveEvent: Identifiable, Hashable, Sendable {
    public var id: String { cardCopyPath }
    public var eventFolderPath: String
    /// On-disk path of the parent event folder, when this folder nests inside
    /// another dated event folder. Adoption turns it into `parentEventID`.
    public var parentEventFolderPath: String?
    public var name: String
    public var dateString: String
    public var deviceID: String
    public var cardCopyPath: String
    /// Files not yet covered by any event assignment, relative to `cardCopyPath`.
    public var files: [FileRecord]
    public var policy: EventStoragePolicy
    public var matchingEventID: UUID?

    public var byteCount: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }
}

/// Finds event folders already on the working drive
/// (`<yyyy>/<yyyy-MM-dd Name>/<Camera>/Card Copy`) that the configuration does
/// not know about yet, so a drive organized by hand can join the catalog.
/// A dated folder inside an event folder is a subevent root — it can hold
/// device folders of its own and deeper subevents.
public enum DriveEventDiscovery {
    public static func deviceID(forDeviceFolder name: String) -> String {
        switch name.lowercased() {
        case "sony a7v", "sony-a7v": "sony-a7v"
        case "dji osmo 360", "osmo-360": "osmo-360"
        case "dji mini 2", "dji-mini-2": "dji-mini-2"
        case "dji nano", "dji-nano": "dji-nano"
        case "dji action 6", "action-6": "action-6"
        case "iphone": "iphone"
        case "camera": "generic-camera"
        default: name
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

        var covered: Set<String> = []
        for assignment in configuration.photoEventAssignments {
            guard let event = events[assignment.eventID] else { continue }
            for candidatePolicy in EventStoragePolicy.allCases {
                if let url = locations.driveURL(for: assignment, event: event, policy: candidatePolicy) {
                    covered.insert(EventStorageLocations.pathKey(url.path))
                }
            }
            if let source = locations.sourceURL(for: assignment) {
                covered.insert(EventStorageLocations.pathKey(source.path))
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
    /// and recurse; anything else is treated as a camera/device folder that
    /// may hold a `Card Copy`.
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
            let cardCopy = subdirectory.appendingPathComponent("Card Copy", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: cardCopy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let files = try FileScanner(fileManager: fileManager).scan(root: cardCopy).filter { file in
                !covered.contains(EventStorageLocations.pathKey(cardCopy.appendingPathComponent(file.path).path))
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
                deviceID: deviceID(forDeviceFolder: subdirectory.lastPathComponent),
                cardCopyPath: cardCopy.standardizedFileURL.path,
                files: files,
                policy: policy,
                matchingEventID: matching?.id
            ))
        }
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
                    sourceRootPath: folder.cardCopyPath,
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

    static func parseEventFolder(_ name: String) -> (date: String, name: String)? {
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

    private static func directories(in url: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
