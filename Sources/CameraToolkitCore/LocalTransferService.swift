import Foundation

public struct LocalCopyResult: Codable, Equatable, Sendable {
    public var copied: [String]
    public var skippedIdentical: [String]
    public var conflicts: [String]

    public init(copied: [String] = [], skippedIdentical: [String] = [], conflicts: [String] = []) {
        self.copied = copied
        self.skippedIdentical = skippedIdentical
        self.conflicts = conflicts
    }
}

public struct LocalTransferService {
    private let scanner: FileScanner
    private let fileManager: FileManager

    public init(scanner: FileScanner = FileScanner(), fileManager: FileManager = .default) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func copyImmutable(source: URL, destination: URL, excludes: [String] = DefaultExcludes.all) throws -> LocalCopyResult {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var result = LocalCopyResult()

        for sourceFile in sourceFiles {
            try PathSafety.validateRelativePath(sourceFile.path)
            let sourceURL = source.appendingPathComponent(sourceFile.path)
            let destinationURL = destination.appendingPathComponent(sourceFile.path)

            if fileManager.fileExists(atPath: destinationURL.path) {
                let destinationHash = try FileScanner.sha256(destinationURL)
                if destinationHash == sourceFile.sha256 {
                    result.skippedIdentical.append(sourceFile.path)
                } else {
                    result.conflicts.append(sourceFile.path)
                }
                continue
            }

            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            result.copied.append(sourceFile.path)
        }

        result.copied.sort()
        result.skippedIdentical.sort()
        result.conflicts.sort()
        return result
    }
}
