import Foundation

public struct DiscoveredDriveEvent: Identifiable, Hashable, Sendable {
    public var id: String { cardCopyPath }
    public var eventFolderPath: String
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
        let events = Dictionary(uniqueKeysWithValues: configuration.savedEvents.map { ($0.id, $0) })

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
                guard let parsed = parseEventFolder(eventFolder.lastPathComponent) else { continue }
                for deviceFolder in try directories(in: eventFolder, fileManager: fileManager) {
                    let cardCopy = deviceFolder.appendingPathComponent("Card Copy", isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: cardCopy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        continue
                    }
                    let files = try FileScanner(fileManager: fileManager).scan(root: cardCopy).filter { file in
                        !covered.contains(EventStorageLocations.pathKey(cardCopy.appendingPathComponent(file.path).path))
                    }
                    guard !files.isEmpty else { continue }
                    let matching = configuration.savedEvents.first {
                        $0.name.localizedCaseInsensitiveCompare(parsed.name) == .orderedSame
                            && EventStorageLocations.eventDateString($0.eventDate) == parsed.date
                    }
                    discovered.append(DiscoveredDriveEvent(
                        eventFolderPath: eventFolder.standardizedFileURL.path,
                        name: parsed.name,
                        dateString: parsed.date,
                        deviceID: deviceID(forDeviceFolder: deviceFolder.lastPathComponent),
                        cardCopyPath: cardCopy.standardizedFileURL.path,
                        files: files,
                        policy: policy,
                        matchingEventID: matching?.id
                    ))
                }
            }
        }
        return discovered.sorted { $0.dateString == $1.dateString ? $0.name < $1.name : $0.dateString < $1.dateString }
    }

    /// Adds discovered folders as events. Their files stay exactly where they
    /// are; each assignment points at the drive copy itself.
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

        var created = 0
        var added = 0
        for folder in discovered {
            let eventID: UUID
            if let existing = folder.matchingEventID ?? configuration.savedEvents.first(where: {
                $0.name.localizedCaseInsensitiveCompare(folder.name) == .orderedSame
                    && EventStorageLocations.eventDateString($0.eventDate) == folder.dateString
            })?.id {
                eventID = existing
            } else {
                guard let date = formatter.date(from: folder.dateString) else { continue }
                let event = SavedCameraEvent(
                    name: folder.name,
                    eventDate: date,
                    storagePolicy: folder.policy == .buffer ? nil : folder.policy
                )
                configuration.savedEvents.append(event)
                eventID = event.id
                created += 1
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
