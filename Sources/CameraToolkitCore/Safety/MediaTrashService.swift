import Foundation

/// Extra context recorded in a trash batch's manifest so the app can point
/// back at where each file lived when it was moved aside.
public struct TrashContext: Sendable {
    /// Name of the unsorted location the files were browsed under.
    public var locationName: String?
    /// Camera that produced the files, when the location knows it.
    public var deviceID: String?
    /// Event each file was sorted into at that moment, keyed by lower-cased
    /// standardized path (see `EventStorageLocations.pathKey`).
    public var eventIDsByPathKey: [String: UUID]

    public init(locationName: String? = nil, deviceID: String? = nil, eventIDsByPathKey: [String: UUID] = [:]) {
        self.locationName = locationName
        self.deviceID = deviceID
        self.eventIDsByPathKey = eventIDsByPathKey
    }
}

/// One file's durable "where it lived" record inside a batch manifest.
public struct MediaTrashEntry: Codable, Hashable, Sendable {
    /// Path inside the batch folder, relative to the volume or source root.
    public var trashedRelativePath: String
    /// Absolute path the file occupied at the moment it was trashed.
    public var originalAbsolutePath: String
    public var originalLocationName: String?
    public var eventID: UUID?
    public var deviceID: String?
    public var size: Int64

    public init(
        trashedRelativePath: String,
        originalAbsolutePath: String,
        originalLocationName: String? = nil,
        eventID: UUID? = nil,
        deviceID: String? = nil,
        size: Int64
    ) {
        self.trashedRelativePath = trashedRelativePath
        self.originalAbsolutePath = originalAbsolutePath
        self.originalLocationName = originalLocationName
        self.eventID = eventID
        self.deviceID = deviceID
        self.size = size
    }
}

/// `manifest.json` written inside every batch folder before the first rename,
/// so an interrupted run still records every intended origin.
public struct MediaTrashManifest: Codable, Sendable {
    public var version: Int
    public var batchID: String
    public var createdAt: Date
    public var entries: [MediaTrashEntry]

    public init(version: Int, batchID: String, createdAt: Date, entries: [MediaTrashEntry]) {
        self.version = version
        self.batchID = batchID
        self.createdAt = createdAt
        self.entries = entries
    }
}

/// A file `trash` left in place, with the reason.
/// Where a trash confirmation should say files will go, grouped by volume.
public struct MediaTrashDestinationPreview: Hashable, Sendable {
    public var volumeLabel: String
    public var trashFolderPath: String
    public var fileCount: Int
    public var byteCount: Int64

    public init(volumeLabel: String, trashFolderPath: String, fileCount: Int, byteCount: Int64) {
        self.volumeLabel = volumeLabel
        self.trashFolderPath = trashFolderPath
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public struct MediaTrashSkip: Hashable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// One logical trash batch. Files that lived on different volumes sit in
/// same-named batch folders under each volume's own `.Camera Toolkit/_Trash`,
/// so `segments` can span drives while staying one recoverable unit.
public struct MediaTrashBatch: Identifiable, Sendable {
    public struct Segment: Identifiable, Sendable {
        public var id: String { folder.path }
        /// The `<trashRoot>/<batch>` folder.
        public var folder: URL
        /// The manifest read from the folder; `nil` for `_Trash` batches
        /// written before manifests existed (Free Up / Take Off Drive).
        public var manifest: MediaTrashManifest?
        /// Actual files found in the folder, excluding `manifest.json`.
        public var fileCount: Int
        public var byteCount: Int64

        public init(folder: URL, manifest: MediaTrashManifest?, fileCount: Int, byteCount: Int64) {
            self.folder = folder
            self.manifest = manifest
            self.fileCount = fileCount
            self.byteCount = byteCount
        }

        public var entries: [MediaTrashEntry] { manifest?.entries ?? [] }
        public var hasManifest: Bool { manifest != nil }
    }

    public var id: String { name }
    /// Batch folder name, `yyyy-MM-dd_HHmmss`.
    public var name: String
    public var createdAt: Date
    public var segments: [Segment]
    /// Files `trash` could not move. Always empty for batches read back by
    /// `listBatches`.
    public var skipped: [MediaTrashSkip]

    public init(name: String, createdAt: Date, segments: [Segment], skipped: [MediaTrashSkip] = []) {
        self.name = name
        self.createdAt = createdAt
        self.segments = segments
        self.skipped = skipped
    }

    public var entries: [MediaTrashEntry] { segments.flatMap(\.entries) }
    public var fileCount: Int { segments.reduce(0) { $0 + $1.fileCount } }
    public var byteCount: Int64 { segments.reduce(0) { $0 + $1.byteCount } }
    public var folders: [URL] { segments.map(\.folder) }
}

public struct MediaTrashRestoreReport: Sendable {
    /// Original paths that received their file back.
    public var restored: [String] = []
    /// Original paths that already had a file; nothing was replaced and the
    /// trashed copy stays in the batch.
    public var conflicts: [String] = []
    /// Manifest entries whose trashed file is no longer in the batch.
    public var missing: [String] = []
    /// Path → reason for files that could not move back.
    public var failed: [String: String] = [:]
    public var restoredBytes: Int64 = 0

    public init() {}
}

/// Moves unsorted media into a drive-local `_Trash/<batch>` folder so the
/// files travel with their card, drive, or NAS share. Every batch carries a
/// `manifest.json` recording each file's absolute origin, which makes the
/// trash restorable even when the file lived on an external drive or a
/// network volume.
///
/// Safety rules match `DriveMoveService`/`VerifiedRemovalService`: every file
/// is validated before the first rename, moves are exclusive same-device
/// renames that never overwrite and never copy across volumes, and files that
/// cannot join their own volume's trash are reported as skipped instead.
public struct MediaTrashService {
    public static let manifestFileName = "manifest.json"
    public static let manifestVersion = 1
    public static let trashFolderName = "_Trash"

    private struct PlannedMove {
        var file: OrganizeFile
        var source: URL
        var trashRoot: URL
        /// Path inside the batch folder, relative to the volume or source root.
        var trashedRelativePath: String
        /// Set once the batch name is chosen.
        var destination: URL
    }

    private let fileManager: FileManager
    /// Trash root for files that do not live on a `/Volumes/<name>` path,
    /// normally `EventStorageLocations.removedFilesRoot`.
    private let removedFilesRoot: URL
    /// Volume-root lookup, injectable so tests can simulate mounted drives.
    private let volumeRoot: @Sendable (URL) -> URL?
    private let now: @Sendable () -> Date

    public init(
        removedFilesRoot: URL,
        fileManager: FileManager = .default,
        volumeRoot: @escaping @Sendable (URL) -> URL? = VolumeInfo.volumeRoot(for:),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.removedFilesRoot = removedFilesRoot.standardizedFileURL
        self.fileManager = fileManager
        self.volumeRoot = volumeRoot
        self.now = now
    }

    /// Groups files by the `_Trash` folder they would land in. Does not move
    /// anything — confirmation UI uses this to name the destination volume.
    public static func previewDestinations(
        files: [OrganizeFile],
        removedFilesRoot: URL,
        volumeRoot: @escaping @Sendable (URL) -> URL? = VolumeInfo.volumeRoot(for:)
    ) -> [MediaTrashDestinationPreview] {
        var seen: Set<String> = []
        var buckets: [String: (label: String, path: String, count: Int, bytes: Int64)] = [:]
        for file in files where seen.insert(file.pathKey).inserted {
            let source = file.url.standardizedFileURL
            let root: URL
            let label: String
            if let volume = volumeRoot(source) {
                root = volume
                    .appendingPathComponent(EventStorageLocations.toolkitFolderName, isDirectory: true)
                    .appendingPathComponent(Self.trashFolderName, isDirectory: true)
                label = volume.lastPathComponent
            } else {
                root = removedFilesRoot.standardizedFileURL
                label = "This Mac"
            }
            let key = root.path
            var bucket = buckets[key] ?? (label, key, 0, 0)
            bucket.count += 1
            bucket.bytes += file.size
            buckets[key] = bucket
        }
        return buckets.values
            .map { MediaTrashDestinationPreview(volumeLabel: $0.label, trashFolderPath: $0.path, fileCount: $0.count, byteCount: $0.bytes) }
            .sorted { $0.volumeLabel.localizedCaseInsensitiveCompare($1.volumeLabel) == .orderedAscending }
    }

    /// Moves each file into `<its volume>/.Camera Toolkit/_Trash/<batch>`,
    /// keeping the file's path relative to the volume (or `originRoot` for
    /// non-volume paths) so folder structure stays intact. The manifest is
    /// written before the first rename. Files that fail validation — missing,
    /// unsafe path, or a Trash folder on another device — are skipped and
    /// reported on the returned batch; nothing is ever copied then deleted.
    public func trash(
        files: [OrganizeFile],
        originRoot: URL?,
        context: TrashContext = TrashContext(),
        progress: FileOperationProgressHandler? = nil
    ) throws -> MediaTrashBatch {
        var seen: Set<String> = []
        let unique = files
            .filter { seen.insert($0.pathKey).inserted }
            .sorted { $0.path < $1.path }
        guard !unique.isEmpty else {
            throw ToolkitError.commandFailed("There are no files to move to Trash.")
        }

        var skipped: [MediaTrashSkip] = []
        var planned: [PlannedMove] = []
        // `lstat` once per Trash root: every file on a volume shares the same
        // `_Trash` folder, so the device check repeats identical syscalls.
        var trashDevices: [URL: UInt64?] = [:]
        for file in unique {
            let source = file.url.standardizedFileURL
            guard DriveMoveService.isRegularFile(source.path) else {
                skipped.append(MediaTrashSkip(path: source.path, reason: "The file is no longer at its original location."))
                continue
            }
            let trashRoot = self.trashRoot(for: source)
            guard trashRoot.standardizedFileURL.pathComponents.contains(Self.trashFolderName) else {
                skipped.append(MediaTrashSkip(path: source.path, reason: "The Trash folder is not a \(Self.trashFolderName) folder."))
                continue
            }
            // Renames only work on one device; `deviceNumber` walks up to the
            // nearest existing ancestor, so the not-yet-created batch folder
            // still resolves to its volume.
            let rootKey = trashRoot.standardizedFileURL
            let trashDevice: UInt64?
            if let cached = trashDevices[rootKey] {
                trashDevice = cached
            } else {
                trashDevice = VolumeInfo.deviceNumber(for: trashRoot)
                trashDevices[rootKey] = trashDevice
            }
            guard let sourceDevice = VolumeInfo.deviceNumber(for: source),
                  let trashDevice,
                  sourceDevice == trashDevice else {
                skipped.append(MediaTrashSkip(path: source.path, reason: "The drive's Trash folder is on a different device. Nothing was copied."))
                continue
            }
            do {
                let relative = try relativePath(for: source, originRoot: originRoot)
                planned.append(PlannedMove(
                    file: file,
                    source: source,
                    trashRoot: trashRoot,
                    trashedRelativePath: relative,
                    destination: source // resolved once the batch name is chosen
                ))
            } catch {
                skipped.append(MediaTrashSkip(path: source.path, reason: "Unsafe path."))
            }
        }

        let createdAt = now()
        let involvedRoots = Array(Set(planned.map { $0.trashRoot.standardizedFileURL }))
            .sorted { $0.path < $1.path }
        let batchName = uniqueBatchName(in: involvedRoots, createdAt: createdAt)

        // Pick collision-free destinations before anything moves; an existing
        // name gets " 2", " 3", … appended rather than ever being replaced.
        var claimed: Set<String> = []
        for index in planned.indices {
            let batchFolder = planned[index].trashRoot.appendingPathComponent(batchName, isDirectory: true)
            planned[index].destination = uniqueDestination(
                for: batchFolder.appendingPathComponent(planned[index].trashedRelativePath),
                claimed: &claimed
            )
        }

        // Write every batch's manifest before the first rename so a crash
        // mid-move still leaves a durable record of where files came from.
        var prepared: [(folder: URL, moves: [PlannedMove])] = []
        for root in involvedRoots {
            let moves = planned.filter { $0.trashRoot.standardizedFileURL == root }
            guard !moves.isEmpty else { continue }
            let folder = root.appendingPathComponent(batchName, isDirectory: true)
            let manifest = MediaTrashManifest(
                version: Self.manifestVersion,
                batchID: batchName,
                createdAt: createdAt,
                entries: moves.map { entry(for: $0, batchFolder: folder, context: context) }
            )
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.writeManifest(manifest, to: folder.appendingPathComponent(Self.manifestFileName))
                prepared.append((folder, moves))
            } catch {
                for move in moves {
                    skipped.append(MediaTrashSkip(path: move.source.path, reason: "Could not prepare the Trash folder: \(error.localizedDescription)"))
                }
            }
        }

        var movedEntries: [URL: [MediaTrashEntry]] = [:]
        var processedFiles = 0
        // Destination parents repeat for files that lived in one folder;
        // only mkdir each once. A failed mkdir is not remembered so a later
        // file retries it.
        var createdFolders: Set<String> = []
        for (folder, moves) in prepared {
            createdFolders.insert(folder.path)
            for move in moves {
                do {
                    let parent = move.destination.deletingLastPathComponent()
                    if !createdFolders.contains(parent.path) {
                        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                        createdFolders.insert(parent.path)
                    }
                    try DriveMoveService.renameExclusive(from: move.source.path, to: move.destination.path)
                    DriveMoveService.moveAppleDoubleIfNeeded(from: move.source.path, to: move.destination.path)
                    movedEntries[folder, default: []].append(entry(for: move, batchFolder: folder, context: context))
                } catch {
                    skipped.append(MediaTrashSkip(path: move.source.path, reason: error.localizedDescription))
                }
                processedFiles += 1
                progress?(FileOperationProgress(
                    phase: "Moving to Trash",
                    currentPath: move.source.lastPathComponent,
                    processedFiles: processedFiles,
                    totalFiles: planned.count,
                    processedBytes: 0,
                    totalBytes: 0
                ))
            }
        }

        // Narrow each manifest to what actually moved and drop batch folders
        // that ended up empty.
        var segments: [MediaTrashBatch.Segment] = []
        for (folder, _) in prepared {
            let moved = movedEntries[folder] ?? []
            guard !moved.isEmpty else {
                try? fileManager.removeItem(at: folder)
                continue
            }
            let manifest = MediaTrashManifest(
                version: Self.manifestVersion,
                batchID: batchName,
                createdAt: createdAt,
                entries: moved
            )
            try? Self.writeManifest(manifest, to: folder.appendingPathComponent(Self.manifestFileName))
            segments.append(segment(for: folder, manifest: manifest))
        }

        return MediaTrashBatch(name: batchName, createdAt: createdAt, segments: segments, skipped: skipped)
    }

    /// Reads every `_Trash` batch under the given roots, newest first.
    /// Manifest-less batches (written by Free Up or Take Off Drive) are
    /// included with `manifest == nil` so they still list and can be emptied.
    public func listBatches(under roots: [URL]) -> [MediaTrashBatch] {
        var batches: [String: MediaTrashBatch] = [:]
        for root in roots {
            let rootURL = root.standardizedFileURL
            guard rootURL.pathComponents.contains(Self.trashFolderName),
                  fileManager.fileExists(atPath: rootURL.path),
                  let folders = try? fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
                  ) else { continue }
            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let manifest = try? Self.readManifest(folder.appendingPathComponent(Self.manifestFileName))
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let name = folder.lastPathComponent
                var batch = batches[name] ?? MediaTrashBatch(
                    name: name,
                    createdAt: manifest?.createdAt ?? modified ?? .distantPast,
                    segments: []
                )
                batch.segments.append(segment(for: folder, manifest: manifest))
                if let created = manifest?.createdAt { batch.createdAt = created }
                batches[name] = batch
            }
        }
        return batches.values.sorted { $0.name > $1.name }
    }

    /// Moves every manifest entry back to its recorded original path.
    /// Existing files are never replaced — conflicts keep the trashed copy in
    /// the batch — and manifest-less batches report their files as unrestored
    /// rather than guessing a destination. A fully restored batch folder is
    /// removed; a partially restored one keeps a rewritten manifest of what
    /// remains.
    public func restore(batch: MediaTrashBatch, progress: FileOperationProgressHandler? = nil) -> MediaTrashRestoreReport {
        var report = MediaTrashRestoreReport()
        for segment in batch.segments {
            restore(segment: segment, into: &report, progress: progress)
        }
        return report
    }

    private func restore(
        segment: MediaTrashBatch.Segment,
        into report: inout MediaTrashRestoreReport,
        progress: FileOperationProgressHandler?
    ) {
        let folder = segment.folder.standardizedFileURL
        guard let manifest = segment.manifest else {
            let leftovers = scannedFiles(under: folder)
            for file in leftovers {
                report.failed[folder.appendingPathComponent(file.path).path] =
                    "This Trash batch has no manifest, so where it came from is not recorded."
            }
            return
        }
        guard fileManager.fileExists(atPath: folder.path) else {
            report.missing.append(contentsOf: manifest.entries.map(\.originalAbsolutePath))
            return
        }

        var remaining: [MediaTrashEntry] = []
        for (index, entry) in manifest.entries.enumerated() {
            do {
                try PathSafety.validateRelativePath(entry.trashedRelativePath)
                guard entry.originalAbsolutePath.hasPrefix("/"),
                      !entry.originalAbsolutePath.split(separator: "/").contains("..") else {
                    throw ToolkitError.unsafeRelativePath(entry.originalAbsolutePath)
                }
                let source = folder.appendingPathComponent(entry.trashedRelativePath).standardizedFileURL
                let destination = URL(fileURLWithPath: entry.originalAbsolutePath).standardizedFileURL
                guard source.path != destination.path else {
                    throw ToolkitError.commandFailed("Refusing to restore a file onto itself.")
                }
                guard DriveMoveService.isRegularFile(source.path) else {
                    report.missing.append(entry.originalAbsolutePath)
                    continue // nothing left to restore; drop the manifest entry
                }
                guard !DriveMoveService.exists(destination.path) else {
                    report.conflicts.append(entry.originalAbsolutePath)
                    remaining.append(entry)
                    continue
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DriveMoveService.renameExclusive(from: source.path, to: destination.path)
                DriveMoveService.moveAppleDoubleIfNeeded(from: source.path, to: destination.path)
                report.restored.append(entry.originalAbsolutePath)
                report.restoredBytes += entry.size
            } catch {
                report.failed[entry.originalAbsolutePath] = error.localizedDescription
                remaining.append(entry)
            }
            progress?(FileOperationProgress(
                phase: "Restoring from Trash",
                currentPath: (entry.originalAbsolutePath as NSString).lastPathComponent,
                processedFiles: index + 1,
                totalFiles: manifest.entries.count
            ))
        }

        // Update the bookkeeping: remaining entries get a rewritten manifest,
        // a fully restored manifest is removed, and an emptied batch folder
        // (only manifest/junk left) goes away entirely.
        let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
        if remaining.isEmpty {
            try? fileManager.removeItem(at: manifestURL)
        } else {
            let updated = MediaTrashManifest(
                version: manifest.version,
                batchID: manifest.batchID,
                createdAt: manifest.createdAt,
                entries: remaining
            )
            try? Self.writeManifest(updated, to: manifestURL)
        }
        pruneEmptyDirectories(under: folder)
        let left = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.isEmpty || left.allSatisfy({ JunkPolicy.isJunkFile($0) }) {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// The `_Trash` root a file belongs in: its own volume's
    /// `.Camera Toolkit/_Trash`, or the configured removed-files folder for
    /// paths that are not on a mounted volume.
    private func trashRoot(for source: URL) -> URL {
        if let volume = volumeRoot(source) {
            return volume
                .appendingPathComponent(EventStorageLocations.toolkitFolderName, isDirectory: true)
                .appendingPathComponent(Self.trashFolderName, isDirectory: true)
        }
        return removedFilesRoot
    }

    /// The file's path relative to its volume root, or to `originRoot` when
    /// the file is not on a mounted volume. Files outside `originRoot` fall
    /// back to just their name.
    private func relativePath(for source: URL, originRoot: URL?) throws -> String {
        let relative: String
        if let volume = volumeRoot(source) {
            relative = FileScanner.relativePath(for: source, under: volume)
        } else if let origin = originRoot?.standardizedFileURL,
                  source.path.hasPrefix(origin.path + "/") {
            relative = FileScanner.relativePath(for: source, under: origin)
        } else {
            relative = source.lastPathComponent
        }
        try PathSafety.validateRelativePath(relative)
        return relative
    }

    private func entry(for move: PlannedMove, batchFolder: URL, context: TrashContext) -> MediaTrashEntry {
        let key = move.file.pathKey
        return MediaTrashEntry(
            trashedRelativePath: FileScanner.relativePath(for: move.destination, under: batchFolder),
            originalAbsolutePath: move.source.path,
            originalLocationName: context.locationName,
            eventID: context.eventIDsByPathKey[key],
            deviceID: context.deviceID,
            size: move.file.size
        )
    }

    private func uniqueBatchName(in roots: [URL], createdAt: Date) -> String {
        let base = Self.batchName(createdAt)
        var name = base
        var suffix = 2
        while roots.contains(where: { DriveMoveService.exists($0.appendingPathComponent(name).path) }) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    private func uniqueDestination(for desired: URL, claimed: inout Set<String>) -> URL {
        var candidate = desired.standardizedFileURL
        var suffix = 2
        while true {
            let key = candidate.path.lowercased()
            if !claimed.contains(key), !DriveMoveService.exists(candidate.path) {
                claimed.insert(key)
                return candidate
            }
            let folder = candidate.deletingLastPathComponent()
            let `extension` = candidate.pathExtension
            let stem = candidate.deletingPathExtension().lastPathComponent
            let name = `extension`.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(`extension`)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
    }

    private func segment(for folder: URL, manifest: MediaTrashManifest?) -> MediaTrashBatch.Segment {
        let files = scannedFiles(under: folder)
        return MediaTrashBatch.Segment(
            folder: folder,
            manifest: manifest,
            fileCount: files.count,
            byteCount: files.reduce(Int64(0)) { $0 + $1.size }
        )
    }

    private func scannedFiles(under folder: URL) -> [FileRecord] {
        (try? FileScanner(fileManager: fileManager).scan(
            root: folder,
            excludes: [Self.manifestFileName],
            hashing: false
        )) ?? []
    }

    private func pruneEmptyDirectories(under root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }
        // Deepest first, and only ever remove folders that hold nothing at
        // all — files are never deleted here, not even Finder metadata.
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    static func batchName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    static func writeManifest(_ manifest: MediaTrashManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    static func readManifest(_ url: URL) throws -> MediaTrashManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MediaTrashManifest.self, from: Data(contentsOf: url))
    }
}
