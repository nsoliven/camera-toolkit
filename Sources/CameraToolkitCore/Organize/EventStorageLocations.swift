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
    /// The NAS library root. The legacy archive layout lives under it at
    /// `Originals/<year>/<event>/<device>/RAW|JPEG|…` (`legacyArchiveURL`).
    public var libraryRoot: URL
    /// The NAS mirror root: every drive file's archive copy sits at the same
    /// `<year>/<event>/…` relative path under it (`archiveURL`,
    /// `nasMirrorURL(forDrivePath:)`). Private events mirror here too —
    /// "Private · NAS only" keeps them out of the shared Buffer and Immich,
    /// not out of the NAS.
    public var nasRoot: URL
    public var fallbackDeviceID: String
    /// Paths the Trash roots are derived from — every configured location
    /// plus the Buffer, private staging, and library roots.
    private let trashSourcePaths: [String]
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
        let mirror = configuration.archiveLayoutRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        nasRoot = URL(
            fileURLWithPath: NSString(
                string: mirror.isEmpty
                    ? AppConfiguration.derivedArchiveLayoutRoot(cameraLibraryRootPath: configuration.cameraLibraryRootPath)
                    : mirror
            ).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        fallbackDeviceID = configuration.selectedDeviceID
        var sourcePaths = configuration.configuredLocations.map(\.path)
        sourcePaths.append(configuration.bufferPath)
        sourcePaths.append(configuration.privateStagingPath)
        sourcePaths.append(configuration.cameraLibraryRootPath)
        trashSourcePaths = sourcePaths
        events = configuration.savedEvents
        eventsByID = EventHierarchy.index(configuration.savedEvents)
    }

    /// Every `_Trash` root the Trash browser and Empty Trash cover: the
    /// configured removed-files folder plus `.Camera Toolkit/_Trash` on the
    /// volume of each configured location. Listing, browsing, and emptying
    /// share this scope — a file outside these roots is never touched.
    public func trashRoots() -> [URL] {
        var roots = [removedFilesRoot]
        var seen = Set(roots.map { Self.pathKey($0.path) })
        for path in trashSourcePaths {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            guard let volume = VolumeInfo.volumeRoot(for: url) else { continue }
            let root = volume
                .appendingPathComponent(Self.toolkitFolderName, isDirectory: true)
                .appendingPathComponent(MediaTrashService.trashFolderName, isDirectory: true)
            if seen.insert(Self.pathKey(root.path)).inserted {
                roots.append(root)
            }
        }
        return roots
    }

    /// `/Volumes/Drive/.Camera Toolkit` for a Buffer on an external drive,
    /// otherwise a hidden sibling of the Buffer folder.
    public static func defaultToolkitFolder(forBuffer buffer: URL) -> URL {
        if let volume = VolumeInfo.volumeRoot(for: buffer) {
            return volume.appendingPathComponent(toolkitFolderName, isDirectory: true)
        }
        return buffer.deletingLastPathComponent().appendingPathComponent(toolkitFolderName, isDirectory: true)
    }

    /// One formatter for every `yyyy-MM-dd` event folder name in the app.
    /// The presence sweep and drive discovery used to mint one per call —
    /// several per file — and formatter construction dominated the sweep.
    /// `en_US_POSIX` + Gregorian keep the names byte-identical everywhere.
    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func eventDateString(_ date: Date) -> String {
        eventDateFormatter.string(from: date)
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

    /// `Originals`: everything a camera wrote, one folder per camera.
    public static let originalsFolderName = "Originals"
    /// `Edited`: the owner's edits; each first-level folder is an edit tag.
    public static let editedFolderName = "Edited"
    /// The per-device folder of the legacy layout
    /// (`<event>/<device>/Card Copy`) that `Originals/<Camera>` replaced.
    /// Only discovery, presence fallback, and the layout migration read it.
    public static let legacyCardCopyFolderName = "Card Copy"

    /// Folder names inside an event folder that belong to the event itself,
    /// never to a camera or a subevent.
    public static let reservedEventFolderNames: Set<String> = [originalsFolderName, editedFolderName]

    /// `<event folder>/Originals/<Camera>` — where one camera's files for
    /// the event live on the policy's drive.
    public func originalsRoot(for event: SavedCameraEvent, deviceID: String?, policy: EventStoragePolicy) -> URL {
        let layout = layout(for: event, deviceID: deviceID)
        return eventFolder(for: event, policy: policy)
            .appendingPathComponent(Self.originalsFolderName, isDirectory: true)
            .appendingPathComponent(layout.cameraFolder, isDirectory: true)
    }

    /// `<event folder>/Edited` on the policy's drive.
    public func editedRoot(for event: SavedCameraEvent, policy: EventStoragePolicy) -> URL {
        eventFolder(for: event, policy: policy)
            .appendingPathComponent(Self.editedFolderName, isDirectory: true)
    }

    /// `<event folder>/<device folder>/Card Copy` — the legacy layout's
    /// root for one camera. Read during the transition only: a drive that
    /// has not been migrated yet still keeps its files there.
    public func legacyCardCopyRoot(for event: SavedCameraEvent, deviceID: String?, policy: EventStoragePolicy) -> URL {
        let layout = layout(for: event, deviceID: deviceID)
        return eventFolder(for: event, policy: policy)
            .appendingPathComponent(layout.deviceFolder, isDirectory: true)
            .appendingPathComponent(Self.legacyCardCopyFolderName, isDirectory: true)
    }

    public func sourceURL(for assignment: PhotoEventAssignment) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return URL(fileURLWithPath: NSString(string: assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(assignment.relativePath)
            .standardizedFileURL
    }

    public func driveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent, policy: EventStoragePolicy) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return originalsRoot(for: event, deviceID: assignment.deviceID, policy: policy)
            .appendingPathComponent(assignment.relativePath)
            .standardizedFileURL
    }

    /// Where the legacy layout kept this assignment's drive copy.
    public func legacyDriveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent, policy: EventStoragePolicy) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return legacyCardCopyRoot(for: event, deviceID: assignment.deviceID, policy: policy)
            .appendingPathComponent(assignment.relativePath)
            .standardizedFileURL
    }

    /// The path the event board trusts before any place is probed: the
    /// policy's `Originals/<Camera>` root joined with the assignment's
    /// relative path. Unlike `driveURL` this never calls `standardizedFileURL`,
    /// which resolves symlinked ancestors through the filesystem — the
    /// root was standardized once at init and `relativePath` is already
    /// validated, so the join is pure string work. A file that actually
    /// lives somewhere else is corrected by the presence sweep.
    public func impliedDrivePath(for assignment: PhotoEventAssignment, event: SavedCameraEvent, policy: EventStoragePolicy) -> String? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return originalsRoot(for: event, deviceID: assignment.deviceID, policy: policy)
            .appendingPathComponent(assignment.relativePath)
            .path
    }

    /// `<NAS root>/<year>/<parent…>/<event>` — the same event folder path
    /// the drive uses, for every storage policy.
    public func nasEventFolder(for event: SavedCameraEvent) -> URL {
        nasRoot.appendingPathComponent(layout(for: event, deviceID: nil).mirrorEventFolderPath, isDirectory: true)
    }

    /// `<NAS event folder>/Originals/<Camera>`.
    public func nasOriginalsRoot(for event: SavedCameraEvent, deviceID: String?) -> URL {
        nasRoot.appendingPathComponent(layout(for: event, deviceID: deviceID).mirrorOriginalsPath, isDirectory: true)
    }

    /// `<NAS event folder>/Edited`.
    public func nasEditedRoot(for event: SavedCameraEvent) -> URL {
        nasEventFolder(for: event).appendingPathComponent(Self.editedFolderName, isDirectory: true)
    }

    /// The legacy archive's event folder,
    /// `<library>/Originals/<year>/<parent…>/<event>`.
    public func legacyArchiveEventFolder(for event: SavedCameraEvent) -> URL {
        libraryRoot
            .appendingPathComponent(CameraLibraryFolder.originals.rawValue, isDirectory: true)
            .appendingPathComponent(layout(for: event, deviceID: nil).mirrorEventFolderPath, isDirectory: true)
    }

    /// The assignment's NAS copy in the mirror layout: the drive's
    /// `Originals/<Camera>/<relative path>` under the NAS root.
    public func archiveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent) -> URL? {
        guard let relative = try? layout(for: event, deviceID: assignment.deviceID)
            .mirrorRelativePath(for: assignment.relativePath) else { return nil }
        return nasRoot.appendingPathComponent(relative).standardizedFileURL
    }

    /// Where the legacy archive layout kept the assignment's NAS copy
    /// (flattened into `RAW`/`JPEG`/`Video`/…). Read as a fallback so events
    /// archived before the mirror layout still show as on the NAS.
    public func legacyArchiveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent) -> URL? {
        guard let relative = try? layout(for: event, deviceID: assignment.deviceID)
            .legacyArchiveRelativePath(for: assignment.relativePath) else { return nil }
        return libraryRoot.appendingPathComponent(relative).standardizedFileURL
    }

    /// The path of a drive file relative to the drive root it sits under —
    /// the Buffer or private staging — which is also its path under the NAS
    /// mirror root, with any component SMB cannot store rewritten by
    /// `PortablePath` (as `OrganizedArchiveLayout.mirrorRelativePath`
    /// does). Nil for a path under neither root or one that is not
    /// lexically clean.
    public func mirrorRelativePath(forDrivePath path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        // The longer root first, in case one drive root nests inside the other.
        for root in [bufferRoot.path, privateStagingRoot.path].sorted(by: { $0.count > $1.count })
            where standardized.hasPrefix(root + "/") {
            let relative = String(standardized.dropFirst(root.count + 1))
            guard Self.isLexicallyClean(relative), (try? PathSafety.validateRelativePath(relative)) != nil else { return nil }
            return PortablePath.sanitize(relativePath: relative)
        }
        return nil
    }

    /// A path under the NAS root, relative to it; nil for any other path.
    public func nasRelativePath(_ path: String) -> String? {
        let root = nasRoot.path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(root) ? String(standardized.dropFirst(root.count)) : nil
    }

    /// The NAS mirror copy of a drive file.
    public func nasMirrorURL(forDrivePath path: String) -> URL? {
        mirrorRelativePath(forDrivePath: path).map { nasRoot.appendingPathComponent($0).standardizedFileURL }
    }

    /// Lower-cased standardized absolute path used to match files to
    /// assignments on case-insensitive camera drives. On current macOS
    /// `standardizedFileURL` is lexical — it collapses `.`, `..`, and `//`
    /// without resolving symlinks — but `URL(fileURLWithPath:)` still
    /// stats an existing path to guess directory-ness, so repeating it
    /// per file is not free. Hot loops use `OrganizeFile.pathKey`, which
    /// computes this once per file, or `joinedPathKey` under a
    /// pre-standardized root.
    public static func pathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    /// `relativePath` joins cleanly under a standardized root: no `//`, `.`,
    /// or `..` segments for standardization to collapse and no leading or
    /// trailing slash to trim. `validateRelativePath` already rejects `..`;
    /// this is the stronger check a string join needs before it can stand
    /// in for realpath.
    public static func isLexicallyClean(_ relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.hasPrefix("./")
            && !relativePath.contains("//")
            && !relativePath.contains("/./")
            && !relativePath.hasSuffix("/.")
            && !relativePath.hasSuffix("/")
            && relativePath != "."
            && relativePath != ".."
            && !relativePath.hasPrefix("../")
            && !relativePath.hasSuffix("/..")
            && !relativePath.contains("/../")
    }

    /// `pathKey(rootPath + "/" + relativePath)` without paying realpath's
    /// filesystem walk again: `rootPath` was already standardized, so for a
    /// clean relative path the resolved key is the lowercased join. Returns
    /// nil when `relativePath` still needs realpath — the caller falls back
    /// to `pathKey` on the joined string.
    public static func joinedPathKey(rootPath: String, relativePath: String) -> String? {
        guard isLexicallyClean(relativePath) else { return nil }
        return (rootPath + "/" + relativePath).lowercased()
    }
}

/// Builds event assignments for files picked in an unsorted folder.
///
/// Each file is identified by its own folder plus file name, so its copy in
/// the event's `Originals/<Camera>` folder stays flat. When a file name repeats inside
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
