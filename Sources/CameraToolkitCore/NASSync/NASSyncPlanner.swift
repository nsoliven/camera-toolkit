import Foundation

/// One drive file Sync to NAS copies: its absolute drive path and the path
/// under the drive root — which is also its path under the NAS mirror root.
public struct NASSyncItem: Codable, Equatable, Hashable, Sendable {
    public var sourcePath: String
    public var relativePath: String
    public var byteCount: Int64
    /// `timeIntervalSinceReferenceDate`.
    public var modifiedAt: Double
    public var eventID: UUID?

    public init(sourcePath: String, relativePath: String, byteCount: Int64, modifiedAt: Double, eventID: UUID?) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.eventID = eventID
    }
}

/// One file or folder a sync could not handle, and why.
public struct NASSyncIssue: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct NASSyncPlan: Sendable {
    public var items: [NASSyncItem]
    /// Entries inside an event folder that are not `Originals/`, `Edited/`,
    /// or a known subevent's folder — a drive still in the legacy
    /// `Card Copy` layout, stray files. Never synced; the layout migration
    /// or the owner decides.
    public var outsideLayout: [String]
    /// `._` AppleDouble files and `.DS_Store`: reproducible, never synced.
    public var skippedJunk: Int
    /// Symlinks and special files, never followed or copied.
    public var refused: [NASSyncIssue]
    /// Folders that could not be listed.
    public var unreadable: [NASSyncIssue]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

/// Lists what one-way Buffer → NAS sync would copy for a set of events:
/// every file under each event's `Originals/` and `Edited/` on the drive the
/// event's policy points at (and the other drive, for copies left there).
/// Read-only; lists folders, never stats files one by one.
public enum NASSyncPlanner {
    /// Our own in-flight temporary files, never source material.
    public static let temporaryMarker = ".ctsync-"

    public static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.contains(temporaryMarker)
    }

    public static func plan(events: [SavedCameraEvent], locations: EventStorageLocations) -> NASSyncPlan {
        var plan = NASSyncPlan(items: [], outsideLayout: [], skippedJunk: 0, refused: [], unreadable: [])
        var seen = Set<String>()
        // Folder paths of every event in the set, so a subevent's folder
        // inside its parent's is not reported as outside the layout.
        var eventFolders = Set<String>()
        for event in events {
            for policy in EventStoragePolicy.allCases {
                eventFolders.insert(locations.eventFolder(for: event, policy: policy).standardizedFileURL.path)
            }
        }
        for event in events {
            let policy = locations.resolvedPolicy(for: event)
            let other: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
            for drivePolicy in [policy, other] {
                let driveRoot = locations.driveRoot(for: drivePolicy).standardizedFileURL.path
                let folder = locations.eventFolder(for: event, policy: drivePolicy).standardizedFileURL.path
                guard LayoutMigrationDisk.lstatEntry(folder)?.kind == .directory else { continue }
                let children: [DirectoryListingEntry]
                do {
                    children = try DirectoryListing.list(folder)
                } catch {
                    plan.unreadable.append(NASSyncIssue(path: folder, reason: error.localizedDescription))
                    continue
                }
                for child in children {
                    let path = (folder as NSString).appendingPathComponent(child.name)
                    if isJunk(child.name) {
                        plan.skippedJunk += 1
                        continue
                    }
                    if child.kind == .directory, EventStorageLocations.reservedEventFolderNames.contains(child.name) {
                        walk(path, driveRoot: driveRoot, eventID: event.id, plan: &plan, seen: &seen)
                    } else if child.kind == .directory, eventFolders.contains(path) {
                        continue
                    } else {
                        plan.outsideLayout.append(path)
                    }
                }
            }
        }
        plan.items.sort { $0.relativePath < $1.relativePath }
        return plan
    }

    private static func walk(_ folder: String, driveRoot: String, eventID: UUID, plan: inout NASSyncPlan, seen: inout Set<String>) {
        let entries: [DirectoryListingEntry]
        do {
            entries = try DirectoryListing.list(folder)
        } catch {
            plan.unreadable.append(NASSyncIssue(path: folder, reason: error.localizedDescription))
            return
        }
        for entry in entries {
            let path = (folder as NSString).appendingPathComponent(entry.name)
            if isJunk(entry.name) {
                plan.skippedJunk += 1
                continue
            }
            switch entry.kind {
            case .directory:
                walk(path, driveRoot: driveRoot, eventID: eventID, plan: &plan, seen: &seen)
            case .file:
                guard path.hasPrefix(driveRoot + "/") else { continue }
                let relative = String(path.dropFirst(driveRoot.count + 1))
                guard EventStorageLocations.isLexicallyClean(relative), (try? PathSafety.validateRelativePath(relative)) != nil else {
                    plan.refused.append(NASSyncIssue(path: path, reason: "The path cannot be mirrored safely."))
                    continue
                }
                // The policy drive is walked first, so its copy wins over
                // one left on the other drive.
                guard seen.insert(NASSyncStore.pathKey(relative)).inserted else { continue }
                plan.items.append(NASSyncItem(
                    sourcePath: path,
                    relativePath: relative,
                    byteCount: entry.size,
                    modifiedAt: entry.modifiedAt,
                    eventID: eventID
                ))
            case .symlink, .other:
                plan.refused.append(NASSyncIssue(path: path, reason: entry.kind == .symlink ? "Symlinks are never followed." : "Not a regular file."))
            }
        }
    }
}
