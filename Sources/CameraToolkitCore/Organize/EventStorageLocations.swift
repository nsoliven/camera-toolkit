import Darwin
import Foundation

public enum VolumeInfo {
    /// `/Volumes/<name>` for paths on external or network volumes.
    public static func volumeRoot(for url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
    }

    public static func mountedVolumePaths(fileManager: FileManager = .default) -> Set<String> {
        Set((fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardizedFileURL.path })
    }

    /// False only when the path lives under an unmounted `/Volumes/<name>`.
    public static func isAvailable(_ url: URL, mountedVolumes: Set<String>? = nil) -> Bool {
        guard let root = volumeRoot(for: url) else { return true }
        let mounted = mountedVolumes ?? mountedVolumePaths()
        return mounted.contains(root.standardizedFileURL.path)
    }

    /// The device number of the path, or of its nearest existing ancestor.
    public static func deviceNumber(for url: URL) -> UInt64? {
        var candidate = url.standardizedFileURL
        while true {
            var info = stat()
            let result = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return lstat(path, &info)
            }
            if result == 0 {
                return UInt64(bitPattern: Int64(info.st_dev))
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    /// True when both paths are on the same mounted filesystem, which makes a
    /// move an instant rename instead of a copy.
    public static func isSameVolume(_ lhs: URL, _ rhs: URL, mountedVolumes: Set<String>? = nil) -> Bool {
        let mounted = mountedVolumes ?? mountedVolumePaths()
        guard isAvailable(lhs, mountedVolumes: mounted), isAvailable(rhs, mountedVolumes: mounted) else { return false }
        if volumeRoot(for: lhs)?.path != volumeRoot(for: rhs)?.path { return false }
        guard let a = deviceNumber(for: lhs), let b = deviceNumber(for: rhs) else { return false }
        return a == b
    }
}

/// Resolves every place an event's originals can live: the card or unsorted
/// folder they came from, the shared Buffer, the hidden private staging
/// folder, and the NAS library.
public struct EventStorageLocations: Sendable {
    public var bufferRoot: URL
    public var privateStagingRoot: URL
    public var removedFilesRoot: URL
    public var libraryRoot: URL
    public var fallbackDeviceID: String
    /// Known events, so subevent paths resolve through their parent chain.
    public var events: [SavedCameraEvent] {
        didSet { eventsByID = EventHierarchy.index(events) }
    }
    /// Shared event index for the hierarchy lookups below, built once per
    /// event list instead of once per ancestor/policy/name call.
    private var eventsByID: [UUID: SavedCameraEvent]

    public static let toolkitFolderName = ".Camera Toolkit"

    public init(configuration: AppConfiguration) {
        let buffer = URL(fileURLWithPath: NSString(string: configuration.bufferPath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        let toolkitFolder = Self.defaultToolkitFolder(forBuffer: buffer)
        let staging = configuration.privateStagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        bufferRoot = buffer
        privateStagingRoot = staging.isEmpty
            ? toolkitFolder.appendingPathComponent("Private", isDirectory: true)
            : URL(fileURLWithPath: NSString(string: staging).expandingTildeInPath, isDirectory: true).standardizedFileURL
        removedFilesRoot = toolkitFolder.appendingPathComponent("_Trash", isDirectory: true)
        libraryRoot = URL(
            fileURLWithPath: NSString(string: configuration.cameraLibraryRootPath).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        fallbackDeviceID = configuration.selectedDeviceID
        events = configuration.savedEvents
        eventsByID = EventHierarchy.index(configuration.savedEvents)
    }

    /// `/Volumes/Drive/.Camera Toolkit` for a Buffer on an external drive,
    /// otherwise a hidden sibling of the Buffer folder.
    public static func defaultToolkitFolder(forBuffer buffer: URL) -> URL {
        if let volume = VolumeInfo.volumeRoot(for: buffer) {
            return volume.appendingPathComponent(toolkitFolderName, isDirectory: true)
        }
        return buffer.deletingLastPathComponent().appendingPathComponent(toolkitFolderName, isDirectory: true)
    }

    public static func eventDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Ancestors of `event`, root first. Unknown or looping parent links end
    /// the chain, so such an event resolves like a top-level one.
    public func ancestors(of event: SavedCameraEvent) -> [SavedCameraEvent] {
        EventHierarchy.ancestors(of: event, byID: eventsByID)
    }

    /// The event's effective storage policy: its own, else the nearest
    /// ancestor's, else `.buffer`.
    public func resolvedPolicy(for event: SavedCameraEvent) -> EventStoragePolicy {
        EventHierarchy.resolvedPolicy(of: event, byID: eventsByID)
    }

    /// "Parent / Child" breadcrumb for titles, menus, and plan summaries.
    public func displayName(for event: SavedCameraEvent) -> String {
        EventHierarchy.displayName(of: event, byID: eventsByID)
    }

    public func layout(for event: SavedCameraEvent, deviceID: String?) -> OrganizedArchiveLayout {
        let ancestors = ancestors(of: event)
        return OrganizedArchiveLayout(
            eventDate: Self.eventDateString(event.eventDate),
            eventName: event.name,
            deviceID: deviceID ?? fallbackDeviceID,
            parentEventFolders: ancestors.map {
                OrganizedArchiveLayout.eventFolderName(date: Self.eventDateString($0.eventDate), name: $0.name)
            },
            year: String(Self.eventDateString((ancestors.first ?? event).eventDate).prefix(4))
        )
    }

    public func driveRoot(for policy: EventStoragePolicy) -> URL {
        switch policy {
        case .buffer: bufferRoot
        case .archiveOnly: privateStagingRoot
        }
    }

    /// `<root>/<year>/<parent event folder>/…/<event folder>` — a subevent's
    /// folder nests inside its parent's, under the root ancestor's year.
    public func eventFolder(for event: SavedCameraEvent, policy: EventStoragePolicy) -> URL {
        let layout = layout(for: event, deviceID: nil)
        var url = driveRoot(for: policy)
            .appendingPathComponent(layout.year, isDirectory: true)
        for folder in layout.parentEventFolders {
            url.appendPathComponent(folder, isDirectory: true)
        }
        return url.appendingPathComponent(layout.eventFolder, isDirectory: true)
    }

    public func cardCopyRoot(for event: SavedCameraEvent, deviceID: String?, policy: EventStoragePolicy) -> URL {
        let layout = layout(for: event, deviceID: deviceID)
        return eventFolder(for: event, policy: policy)
            .appendingPathComponent(layout.deviceFolder, isDirectory: true)
            .appendingPathComponent("Card Copy", isDirectory: true)
    }

    public func sourceURL(for assignment: PhotoEventAssignment) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return URL(fileURLWithPath: NSString(string: assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(assignment.relativePath)
            .standardizedFileURL
    }

    public func driveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent, policy: EventStoragePolicy) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return cardCopyRoot(for: event, deviceID: assignment.deviceID, policy: policy)
            .appendingPathComponent(assignment.relativePath)
            .standardizedFileURL
    }

    public func archiveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent) -> URL? {
        guard let relative = try? layout(for: event, deviceID: assignment.deviceID)
            .destinationRelativePath(for: assignment.relativePath) else { return nil }
        return libraryRoot.appendingPathComponent(relative).standardizedFileURL
    }

    /// Lower-cased standardized absolute path used to match files to
    /// assignments on case-insensitive camera drives. Standardization resolves
    /// symlinked ancestors (`/var` → `/private/var`), so there is no cheaper
    /// string-only equivalent — hot loops use `OrganizeFile.pathKey`, which
    /// computes this once per file.
    public static func pathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }
}

/// Builds event assignments for files picked in an unsorted folder.
///
/// Each file is identified by its own folder plus file name, so its copy in
/// the event's `Card Copy` folder stays flat. When a file name repeats inside
/// the scanned folder or the event, the identity falls back to the path under
/// the scanned root, which keeps both copies apart.
public enum OrganizeAssignmentBuilder {
    public static func assignments(
        for files: [OrganizeFile],
        scanRootPath: String,
        duplicateNames: Set<String>,
        existingEventAssignments: [PhotoEventAssignment],
        eventID: UUID,
        deviceID: String?
    ) -> [PhotoEventAssignment] {
        let root = URL(fileURLWithPath: scanRootPath, isDirectory: true).standardizedFileURL.path
        var batchNames: [String: Int] = [:]
        for file in files {
            batchNames[file.name.lowercased(), default: 0] += 1
        }
        var eventNames: [String: Set<String>] = [:]
        for assignment in existingEventAssignments {
            let key = assignment.relativePath.lowercased()
            eventNames[key, default: []].insert(EventStorageLocations.pathKey(
                (assignment.sourceRootPath as NSString).appendingPathComponent(assignment.relativePath)
            ))
        }

        return files.map { file in
            let lowered = file.name.lowercased()
            let ownKey = file.pathKey
            let collidesInEvent = eventNames[lowered].map { !$0.subtracting([ownKey]).isEmpty } ?? false
            let needsLongIdentity = duplicateNames.contains(lowered) || (batchNames[lowered] ?? 0) > 1 || collidesInEvent
            let sourceRoot: String
            let relativePath: String
            if needsLongIdentity, file.path.hasPrefix(root + "/") {
                sourceRoot = root
                relativePath = String(file.path.dropFirst(root.count + 1))
            } else {
                sourceRoot = file.folderPath
                relativePath = file.name
            }
            return PhotoEventAssignment(
                sourceRootPath: sourceRoot,
                relativePath: relativePath,
                fileSize: file.size,
                modifiedAt: file.modifiedAt,
                eventID: eventID,
                deviceID: deviceID
            )
        }
    }
}
