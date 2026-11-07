import CameraToolkitCore
import Foundation

/// A file row of a Sync to NAS job, opened for comparing: its drive copy
/// and its NAS copy.
struct CompareRequest: Identifiable {
    enum Mode {
        /// The copies differ; the owner may choose which to keep.
        case conflict
        /// The copies should be identical; only look.
        case viewOnly
    }

    let id = UUID()
    var pair: ConflictPair
    var mode: Mode
    var fileName: String
}

extension DashboardModel {
    /// The catalog's folder: where resolution journals are kept.
    var catalogFolderURL: URL {
        URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath)).deletingLastPathComponent()
    }

    var conflictJournalFolder: URL {
        catalogFolderURL.appendingPathComponent("Conflict Resolutions", isDirectory: true)
    }

    /// The drive and NAS copies behind a Sync to NAS file row: the NAS copy
    /// sits at the row's path under the NAS mirror root; the drive copy is
    /// the Buffer (or private staging) file that mirrors to that path.
    /// Nil when no drive copy can be found (the drive is not connected).
    func comparePair(for item: JobHistoryItem) -> ConflictPair? {
        let locations = EventStorageLocations(configuration: configuration)
        for root in [locations.bufferRoot, locations.privateStagingRoot] {
            let candidate = root.appendingPathComponent(item.relativePath).path
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if let mirrored = locations.mirrorRelativePath(forDrivePath: candidate), mirrored != item.relativePath { continue }
            return ConflictPair(drivePath: candidate, nasRoot: locations.nasRoot.path, relativePath: item.relativePath)
        }
        return nil
    }

    private func conflictResolver() throws -> ConflictResolver {
        let locations = EventStorageLocations(configuration: configuration)
        let catalog = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath))
        return ConflictResolver(
            store: try NASSyncStore(catalogURL: catalog),
            removedFilesRoot: locations.removedFilesRoot,
            journalFolder: conflictJournalFolder
        )
    }

    /// Resolves one conflict as a job behind the job gate. `completion`
    /// gets the finished resolution, or nil when it refused or failed (the
    /// job's note says why).
    func resolveConflict(
        _ pair: ConflictPair,
        choice: ConflictChoice,
        expectedDrive: String,
        expectedNAS: String,
        fileName: String,
        completion: @escaping @MainActor (ConflictResolution?) -> Void
    ) {
        let resolver: ConflictResolver
        do {
            resolver = try conflictResolver()
        } catch {
            statusMessage = "Could not open the sync records: \(error.localizedDescription). Nothing was changed."
            completion(nil)
            return
        }
        let title: String = switch choice {
        case .keepDrive: "Kept the drive version of \(fileName)"
        case .keepNAS: "Kept the NAS version of \(fileName)"
        case .keepBoth: "Kept both versions of \(fileName)"
        }
        let started = runBackgroundJob(
            action: .resolveConflict,
            runningNote: "Resolving \(fileName): re-hashing both copies",
            logTitle: title,
            logDetail: Self.resolutionDetail(choice),
            sourcePath: pair.drivePath,
            destinationPath: pair.nasPath,
            operation: { _ in
                try resolver.resolve(pair, choice: choice, expectedDrive: expectedDrive, expectedNAS: expectedNAS)
            },
            completion: { [weak self] resolution in
                completion(resolution)
                self?.onConflictResolved?(resolution, title)
                return resolution.steps.joined(separator: " ")
            }
        )
        if started == nil { completion(nil) }
    }

    /// Undoes a resolution as a job; `completion` gets the undone journal.
    func undoConflictResolution(_ resolution: ConflictResolution, completion: @escaping @MainActor (ConflictResolution?) -> Void = { _ in }) {
        guard let resolver = try? conflictResolver() else { completion(nil); return }
        let name = (resolution.pair.relativePath as NSString).lastPathComponent
        let started = runBackgroundJob(
            action: .resolveConflict,
            runningNote: "Undoing the resolution of \(name)",
            logTitle: "Undid the resolution of \(name)",
            logDetail: "Whatever the resolution put in place moved aside (NAS _Stale Copies, drive _Trash) and the original versions returned to their paths. Nothing was deleted.",
            operation: { _ in try resolver.undo(resolution) },
            completion: { undone in
                completion(undone)
                return undone.steps.last ?? "Undone."
            }
        )
        if started == nil { completion(nil) }
    }

    static func resolutionDetail(_ choice: ConflictChoice) -> String {
        switch choice {
        case .keepDrive:
            "Both copies were re-hashed first. The NAS version moved to .Camera Toolkit/_Stale Copies on the NAS; the drive version was copied to the NAS through an exclusive temporary and verified by SHA-256 before it took the name."
        case .keepNAS:
            "Both copies were re-hashed first. The drive version moved to the drive's _Trash (with a manifest); the NAS version was copied to the drive and verified by SHA-256 before it took the name."
        case .keepBoth:
            "Both copies were re-hashed first. The NAS version was renamed with \"(NAS <date>)\" on the NAS and copied to the drive under that name; the drive version was copied to the NAS under the original name. Every copy was verified by SHA-256."
        }
    }
}
