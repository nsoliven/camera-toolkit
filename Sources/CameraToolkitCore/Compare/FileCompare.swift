import CryptoKit
import Foundation

/// One side of a comparison, read from its own real location: never a
/// cached copy, never the other side's file.
public struct ComparedFile: Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var size: Int64
    public var modified: Date?
    /// SHA-256 computed now, from this file's own bytes.
    public var sha256: String?
    /// Why the file could not be read, when it could not.
    public var problem: String?

    public var shortHash: String? { sha256.map { String($0.prefix(12)) } }
}

/// Two copies of one file — the drive's and the NAS's — and whether they
/// are byte-for-byte the same.
public struct FileComparison: Equatable, Sendable {
    public var drive: ComparedFile
    public var nas: ComparedFile
    /// For `.photo-edit` files: the edit settings that differ.
    public var settingDifferences: [PhotoEditDifference]?
    /// Why the edit settings could not be compared.
    public var settingsProblem: String?

    public var identical: Bool {
        guard let left = drive.sha256, let right = nas.sha256 else { return false }
        return left == right && drive.size == nas.size
    }

    /// Which side was saved later, when both dates are known.
    public var newer: Side? {
        // Identical copies have no newer side, and a second's difference is
        // a filesystem's rounding, not a later save.
        guard !identical, let left = drive.modified, let right = nas.modified, abs(left.timeIntervalSince(right)) >= 1 else { return nil }
        return left > right ? .drive : .nas
    }

    public enum Side: String, Sendable {
        case drive
        case nas
    }
}

public enum PhotoEditCompare {
    /// The first 12 hex digits of a SHA-256 — enough to tell versions apart
    /// at a glance.
    public static func shortHash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

public enum FileCompare {
    static let chunkSize = 1 << 20

    /// Size, date and a fresh SHA-256 of the file at `path`, streamed in
    /// bounded chunks. Only reads.
    public static func inspect(_ path: String, isCancelled: () -> Bool = { false }) -> ComparedFile {
        let url = URL(fileURLWithPath: path)
        var file = ComparedFile(path: path, exists: false, size: 0)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            file.problem = FileManager.default.fileExists(atPath: path) ? "Not a regular file." : "Not found at this location."
            return file
        }
        file.exists = true
        file.size = Int64(values.fileSize ?? 0)
        file.modified = values.contentModificationDate
        do {
            file.sha256 = try sha256(of: url, isCancelled: isCancelled)
        } catch {
            file.problem = "Could not read it: \(error.localizedDescription)"
        }
        return file
    }

    public static func sha256(of url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Both copies, each from its own path, and — for an edit file whose
    /// copies differ — the edit settings that changed.
    public static func compare(drivePath: String, nasPath: String, isCancelled: () -> Bool = { false }) -> FileComparison {
        var comparison = FileComparison(drive: inspect(drivePath, isCancelled: isCancelled), nas: inspect(nasPath, isCancelled: isCancelled))
        if PhotoEditArchive.isPhotoEdit(drivePath), comparison.drive.exists, comparison.nas.exists, !comparison.identical {
            do {
                comparison.settingDifferences = PhotoEditSettings.differences(
                    drive: try PhotoEditSettings.read(PhotoEditArchive(contentsOf: URL(fileURLWithPath: drivePath))),
                    nas: try PhotoEditSettings.read(PhotoEditArchive(contentsOf: URL(fileURLWithPath: nasPath)))
                )
            } catch {
                comparison.settingsProblem = error.localizedDescription
            }
        }
        return comparison
    }
}
