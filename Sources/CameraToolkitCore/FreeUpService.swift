import Foundation
import Darwin

public struct FreeUpService {
    public static let confirmationToken = "DELETE"

    private let checkService: LocalCheckService
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        checkService: LocalCheckService = LocalCheckService(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.checkService = checkService
        self.fileManager = fileManager
        self.now = now
    }

    public func freeUp(
        bufferRoot: URL,
        archiveRoot: URL,
        trashRoot: URL,
        excludes: [String] = DefaultExcludes.all,
        apply: Bool
    ) throws -> FreeUpReport {
        let check = try checkService.check(source: bufferRoot, destination: archiveRoot, excludes: excludes)
        var report = FreeUpReport(
            scannedAt: now(),
            safe: check.match.sorted(),
            notOnArchive: check.sourceOnly.sorted(),
            differ: check.differ.sorted(),
            errors: check.errors.sorted()
        )

        guard apply else {
            return report
        }

        if report.safe.isEmpty {
            report.junkRemoved = try sweepJunk(root: bufferRoot, skipping: trashRoot)
            try pruneEmptyDirectories(root: bufferRoot)
            return report
        }

        try assertTrashPath(trashRoot)
        let batch = batchName(for: now())
        let batchRoot = trashRoot.appendingPathComponent(batch, isDirectory: true)
        try fileManager.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        try assertSameVolume(bufferRoot, batchRoot)
        report.trashBatch = batch

        for relativePath in report.safe {
            do {
                try PathSafety.validateRelativePath(relativePath)
                let source = bufferRoot.appendingPathComponent(relativePath)
                let destination = batchRoot.appendingPathComponent(relativePath)
                let size = try fileSize(source)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: destination)
                report.moved.append(relativePath)
                report.freedBytes += size
            } catch {
                report.moveFailures[relativePath] = String(describing: error)
            }
        }

        report.junkRemoved = try sweepJunk(root: bufferRoot, skipping: trashRoot)
        try pruneEmptyDirectories(root: bufferRoot)
        return report
    }

    public func emptyTrash(trashRoot: URL, confirm: String, olderThanDays: Double = 0) throws -> (deletedBatches: [String], freedBytes: Int64) {
        guard confirm == Self.confirmationToken else {
            throw ToolkitError.confirmationRequired(expected: Self.confirmationToken, received: confirm)
        }
        try assertTrashPath(trashRoot)

        guard fileManager.fileExists(atPath: trashRoot.path) else {
            return ([], 0)
        }

        let cutoff = now().addingTimeInterval(-olderThanDays * 86_400)
        var deleted: [String] = []
        var freed: Int64 = 0

        for batch in try listTrash(trashRoot: trashRoot) {
            if olderThanDays > 0, batch.modifiedAt > cutoff {
                continue
            }
            try fileManager.removeItem(at: batch.url)
            deleted.append(batch.name)
            freed += batch.bytes
        }

        return (deleted, freed)
    }

    public func restoreTrashBatch(trashRoot: URL, batch: String, bufferRoot: URL) throws -> (restored: Int, skipped: [String]) {
        let batchRoot = trashRoot.appendingPathComponent(batch, isDirectory: true)
        try FileScanner().assertDirectory(batchRoot)

        let files = try FileScanner().scan(root: batchRoot, excludes: [], hashing: false)
        var restored = 0
        var skipped: [String] = []

        for file in files {
            let source = batchRoot.appendingPathComponent(file.path)
            let destination = bufferRoot.appendingPathComponent(file.path)
            if fileManager.fileExists(atPath: destination.path) {
                skipped.append(file.path)
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            restored += 1
        }

        try pruneEmptyDirectories(root: batchRoot)
        try? fileManager.removeItem(at: batchRoot)
        return (restored, skipped.sorted())
    }

    public func listTrash(trashRoot: URL) throws -> [TrashBatch] {
        guard fileManager.fileExists(atPath: trashRoot.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        var batches: [TrashBatch] = []

        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { continue }
            let files = try FileScanner().scan(root: entry, excludes: [], hashing: false)
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            batches.append(TrashBatch(name: entry.lastPathComponent, url: entry, files: files.count, bytes: bytes, modifiedAt: values.contentModificationDate ?? .distantPast))
        }

        return batches.sorted { $0.name < $1.name }
    }

    private func assertTrashPath(_ trashRoot: URL) throws {
        let components = trashRoot.standardizedFileURL.pathComponents
        guard components.contains("_Trash") else {
            throw ToolkitError.trashPathRequired(trashRoot.path)
        }
    }

    private func assertSameVolume(_ a: URL, _ b: URL) throws {
        let aDevice = try deviceIdentifier(for: a)
        let bDevice = try deviceIdentifier(for: b)
        guard aDevice == bDevice else {
            throw ToolkitError.crossVolumeQuarantine(a.path, b.path)
        }
    }

    private func deviceIdentifier(for url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let number = attributes[.systemNumber] as? NSNumber {
            return number.uint64Value
        }
        return 0
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sweepJunk(root: URL, skipping skipSubtree: URL) throws -> Int {
        let skipPath = skipSubtree.standardizedFileURL.path
        return try sweepJunkRecursive(root: root, skipPath: skipPath)
    }

    private func sweepJunkRecursive(root: URL, skipPath: String) throws -> Int {
        let rootPath = root.standardizedFileURL.path
        if rootPath == skipPath || rootPath.hasPrefix(skipPath + "/") {
            return 0
        }

        var removed = 0
        let children = try directoryEntryNames(at: root)

        for name in children {
            let child = root.appendingPathComponent(name)
            var isDirectory = ObjCBool(false)
            fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                removed += try sweepJunkRecursive(root: child, skipPath: skipPath)
            } else if JunkPolicy.isJunkFile(name) {
                try? fileManager.removeItem(atPath: child.path)
                removed += 1
            }
        }

        return removed
    }

    private func directoryEntryNames(at url: URL) throws -> [String] {
        guard let directory = opendir(url.path) else {
            throw ToolkitError.pathNotFound(url.path)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    private func pruneEmptyDirectories(root: URL) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: nil) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                directories.append(url)
            }
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if directory.standardizedFileURL == root.standardizedFileURL { continue }
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func batchName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}

public struct TrashBatch: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var url: URL
    public var files: Int
    public var bytes: Int64
    public var modifiedAt: Date
}
