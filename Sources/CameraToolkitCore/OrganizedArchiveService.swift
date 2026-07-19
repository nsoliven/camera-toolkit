import Foundation

public enum OrganizedMediaFolder: String, Codable, CaseIterable, Sendable {
    case raw = "RAW"
    case jpeg = "JPEG"
    case photos = "Photos"
    case video = "Video"
    case audio = "Audio"
    case support = "Camera Support"
}

public struct OrganizedArchiveMapping: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { destinationPath }
    public var sourcePath: String
    public var destinationPath: String
    public var size: Int64
    public var modifiedAt: Date
    public var sha256: String

    public init(
        sourcePath: String,
        destinationPath: String,
        size: Int64,
        modifiedAt: Date,
        sha256: String
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

public struct OrganizedArchivePlan: Codable, Equatable, Sendable {
    public var new: [OrganizedArchiveMapping]
    public var existing: [OrganizedArchiveMapping]
    public var conflicts: [OrganizedArchiveMapping]
    public var folders: [String]

    public init(
        new: [OrganizedArchiveMapping] = [],
        existing: [OrganizedArchiveMapping] = [],
        conflicts: [OrganizedArchiveMapping] = [],
        folders: [String] = []
    ) {
        self.new = new
        self.existing = existing
        self.conflicts = conflicts
        self.folders = folders
    }

    public var totalFiles: Int { new.count + existing.count + conflicts.count }
    public var isVerified: Bool {
        totalFiles > 0
            && new.isEmpty
            && conflicts.isEmpty
            && existing.allSatisfy { !$0.sha256.isEmpty }
    }
}

public struct OrganizedArchiveResult: Codable, Equatable, Sendable {
    public var copied: [String]
    public var skippedIdentical: [String]
    public var conflicts: [String]
    public var manifestPath: String?

    public init(
        copied: [String] = [],
        skippedIdentical: [String] = [],
        conflicts: [String] = [],
        manifestPath: String? = nil
    ) {
        self.copied = copied
        self.skippedIdentical = skippedIdentical
        self.conflicts = conflicts
        self.manifestPath = manifestPath
    }
}

public struct OrganizedArchiveLayout: Sendable {
    public let eventDate: String
    public let eventName: String
    public let deviceID: String

    public init(eventDate: String, eventName: String, deviceID: String) {
        self.eventDate = Self.safeDate(eventDate)
        self.eventName = EventNamePolicy.folderName(for: eventName, fallback: "Import")
        self.deviceID = deviceID
    }

    public init(configuration: AppConfiguration) {
        self.init(
            eventDate: configuration.archiveEventDate,
            eventName: configuration.eventName,
            deviceID: configuration.selectedDeviceID
        )
    }

    public var year: String { String(eventDate.prefix(4)) }
    public var eventFolder: String { "\(eventDate) \(eventName)" }

    public var deviceFolder: String {
        switch deviceID {
        case "sony-a7v": "Sony A7V"
        case "osmo-360": "DJI Osmo 360"
        case "dji-mini-2": "DJI Mini 2"
        case "action-6": "DJI Action 6"
        case "iphone": "iPhone"
        default: Self.pathComponent(deviceID, fallback: "Camera")
        }
    }

    public func destinationRelativePath(for sourcePath: String) throws -> String {
        try PathSafety.validateRelativePath(sourcePath)
        let fileName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let folder = mediaFolder(for: sourcePath).rawValue
        return ["Originals", year, eventFolder, deviceFolder, folder, fileName]
            .joined(separator: "/")
    }

    public func mediaFolder(for path: String) -> OrganizedMediaFolder {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let sonyRAW = Set(["arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw"])
        let photos = Set(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"])
        let video = Set(["mp4", "mov", "m4v", "mts", "m2ts", "mxf", "avi", "insv", "lrv", "osv"])
        let audio = Set(["wav", "mp3", "m4a", "aac"])

        if ext == "xmp" { return deviceID == "osmo-360" ? .photos : .raw }
        if sonyRAW.contains(ext) { return deviceID == "osmo-360" ? .photos : .raw }
        if ext == "dng" { return deviceID == "osmo-360" ? .photos : .raw }
        if photos.contains(ext) { return deviceID == "osmo-360" ? .photos : .jpeg }
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        return .support
    }

    public func requiredFolders(for sourcePaths: [String]) -> [String] {
        var folders: Set<String> = [
            ["Originals", year, eventFolder, deviceFolder].joined(separator: "/"),
            ["Edited", year, eventFolder, "Masters"].joined(separator: "/"),
            ["Edited", year, eventFolder, "Web"].joined(separator: "/"),
            ["Edited", year, eventFolder, "Social"].joined(separator: "/"),
            "System/Manifests",
            "System/Import History"
        ]
        for path in sourcePaths {
            let media = mediaFolder(for: path).rawValue
            folders.insert(["Originals", year, eventFolder, deviceFolder, media].joined(separator: "/"))
        }
        return folders.sorted()
    }

    private static func safeDate(_ value: String) -> String {
        let prefix = String(value.prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: prefix) == nil ? formatter.string(from: Date()) : prefix
    }

    private static func pathComponent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-'"))
        let sanitized = String(source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return sanitized.isEmpty ? fallback : sanitized
    }
}

public struct OrganizedArchivePlanner {
    private let scanner: FileScanner
    private let fileManager: FileManager

    public init(scanner: FileScanner = FileScanner(), fileManager: FileManager = .default) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func plan(
        source: URL,
        libraryRoot: URL,
        layout: OrganizedArchiveLayout,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> OrganizedArchivePlan {
        let files = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Hashing workspace"))
        }
        return try plan(source: source, sourceFiles: files, libraryRoot: libraryRoot, layout: layout, progress: progress)
    }

    public func plan(
        source: URL,
        sourceFiles files: [FileRecord],
        libraryRoot: URL,
        layout: OrganizedArchiveLayout,
        progress: FileOperationProgressHandler? = nil
    ) throws -> OrganizedArchivePlan {
        var plan = OrganizedArchivePlan(folders: layout.requiredFolders(for: files.map(\.path)))
        let totalFiles = files.count

        for (index, file) in files.enumerated() {
            let relativeDestination = try layout.destinationRelativePath(for: file.path)
            let sourceHash = try file.sha256 ?? FileScanner.sha256(source.appendingPathComponent(file.path))
            let mapping = OrganizedArchiveMapping(
                sourcePath: file.path,
                destinationPath: relativeDestination,
                size: file.size,
                modifiedAt: file.modifiedAt,
                sha256: sourceHash
            )
            let destination = libraryRoot.appendingPathComponent(relativeDestination)
            if fileManager.fileExists(atPath: destination.path) {
                if try FileScanner.sha256(destination) == mapping.sha256 {
                    plan.existing.append(mapping)
                } else {
                    plan.conflicts.append(mapping)
                }
            } else {
                plan.new.append(mapping)
            }
            progress?(
                FileOperationProgress(
                    phase: "Comparing NAS destination",
                    currentPath: relativeDestination,
                    processedFiles: index + 1,
                    totalFiles: totalFiles
                )
            )
        }
        return plan
    }

    /// Builds a destination preview without reading the contents of each RAW.
    /// Empty hashes intentionally mark same-size destination files as present,
    /// not verified. Copy and archive operations still perform SHA-256 checks.
    public func planMetadata(
        sourceFiles files: [FileRecord],
        libraryRoot: URL,
        layout: OrganizedArchiveLayout,
        progress: FileOperationProgressHandler? = nil
    ) throws -> OrganizedArchivePlan {
        var plan = OrganizedArchivePlan(folders: layout.requiredFolders(for: files.map(\.path)))
        let totalFiles = files.count

        for (index, file) in files.enumerated() {
            let relativeDestination = try layout.destinationRelativePath(for: file.path)
            let mapping = OrganizedArchiveMapping(
                sourcePath: file.path,
                destinationPath: relativeDestination,
                size: file.size,
                modifiedAt: file.modifiedAt,
                sha256: ""
            )
            let destination = libraryRoot.appendingPathComponent(relativeDestination)
            if fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true, Int64(values.fileSize ?? -1) == file.size {
                    plan.existing.append(mapping)
                } else {
                    plan.conflicts.append(mapping)
                }
            } else {
                plan.new.append(mapping)
            }
            progress?(
                FileOperationProgress(
                    phase: "Reading destination metadata",
                    currentPath: relativeDestination,
                    processedFiles: index + 1,
                    totalFiles: totalFiles
                )
            )
        }
        return plan
    }
}

public struct OrganizedArchiveService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func archive(
        source: URL,
        libraryRoot: URL,
        plan: OrganizedArchivePlan,
        progress: FileOperationProgressHandler? = nil
    ) throws -> OrganizedArchiveResult {
        var result = OrganizedArchiveResult(
            skippedIdentical: plan.existing.map(\.destinationPath),
            conflicts: plan.conflicts.map(\.destinationPath)
        )
        for folder in plan.folders {
            try PathSafety.validateRelativePath(folder)
            try fileManager.createDirectory(
                at: libraryRoot.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let totalBytes = plan.new.reduce(Int64(0)) { $0 + $1.size }
        let startedAt = Date()
        var processedBytes: Int64 = 0
        var processedFiles = 0
        var limiter = FileOperationProgressLimiter()

        for mapping in plan.new.sorted(by: { $0.destinationPath < $1.destinationPath }) {
            try PathSafety.validateRelativePath(mapping.sourcePath)
            try PathSafety.validateRelativePath(mapping.destinationPath)
            let sourceURL = source.appendingPathComponent(mapping.sourcePath)
            let destinationURL = libraryRoot.appendingPathComponent(mapping.destinationPath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                if try FileScanner.sha256(destinationURL) == mapping.sha256 {
                    result.skippedIdentical.append(mapping.destinationPath)
                } else {
                    result.conflicts.append(mapping.destinationPath)
                }
                processedFiles += 1
                continue
            }

            let temporaryURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).cttmp-\(UUID().uuidString)")
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw ToolkitError.commandFailed("Could not create temporary archive file at \(temporaryURL.path)")
            }
            do {
                try StreamingFileIO.copyBytes(from: sourceURL, to: temporaryURL) { copied in
                    processedBytes += Int64(copied)
                    if limiter.shouldEmit() {
                        progress?(
                            FileOperationProgress(
                                phase: "Copying to NAS",
                                currentPath: mapping.destinationPath,
                                processedFiles: processedFiles,
                                totalFiles: plan.new.count,
                                processedBytes: processedBytes,
                                totalBytes: totalBytes,
                                bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                            )
                        )
                    }
                }
                guard try FileScanner.sha256(temporaryURL) == mapping.sha256 else {
                    throw ToolkitError.commandFailed("Verification failed for \(mapping.destinationPath)")
                }
                try fileManager.setAttributes([.modificationDate: mapping.modifiedAt], ofItemAtPath: temporaryURL.path)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                result.copied.append(mapping.destinationPath)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
            processedFiles += 1
            progress?(
                FileOperationProgress(
                    phase: "Verified on NAS",
                    currentPath: mapping.destinationPath,
                    processedFiles: processedFiles,
                    totalFiles: plan.new.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                )
            )
        }

        result.copied.sort()
        result.skippedIdentical = Array(Set(result.skippedIdentical)).sorted()
        result.conflicts = Array(Set(result.conflicts)).sorted()
        result.manifestPath = try writeManifest(result: result, plan: plan, libraryRoot: libraryRoot)
        return result
    }

    private func writeManifest(
        result: OrganizedArchiveResult,
        plan: OrganizedArchivePlan,
        libraryRoot: URL
    ) throws -> String {
        struct Manifest: Codable {
            var archivedAt: Date
            var copied: [String]
            var alreadyVerified: [String]
            var conflicts: [String]
            var files: [OrganizedArchiveMapping]
        }
        let folder = libraryRoot.appendingPathComponent("System/Manifests", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = folder.appendingPathComponent("Import_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).json")
        let manifest = Manifest(
            archivedAt: Date(),
            copied: result.copied,
            alreadyVerified: result.skippedIdentical,
            conflicts: result.conflicts,
            files: (plan.new + plan.existing + plan.conflicts).sorted { $0.destinationPath < $1.destinationPath }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url.path
    }

    private static func rate(bytes: Int64, since date: Date) -> Double {
        Double(bytes) / max(Date().timeIntervalSince(date), 0.001)
    }
}
