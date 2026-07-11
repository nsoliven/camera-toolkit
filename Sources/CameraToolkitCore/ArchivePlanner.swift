import Foundation

public struct ArchivePlanner {
    private let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    public func planCopy(
        source: URL,
        destination: URL,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> CopyPlan {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Hashing source"))
        }
        let destinationFiles: [FileRecord]

        if FileManager.default.fileExists(atPath: destination.path) {
            destinationFiles = try scanner.scan(root: destination, excludes: excludes, hashing: true) { update in
                progress?(update.withPhase("Hashing destination"))
            }
        } else {
            destinationFiles = []
            progress?(
                FileOperationProgress(
                    phase: "Destination missing",
                    processedFiles: sourceFiles.count,
                    totalFiles: sourceFiles.count,
                    processedBytes: sourceFiles.reduce(0) { $0 + $1.size },
                    totalBytes: sourceFiles.reduce(0) { $0 + $1.size }
                )
            )
        }

        let destinationByPath = Dictionary(uniqueKeysWithValues: destinationFiles.map { ($0.path, $0) })
        var plan = CopyPlan()

        for file in sourceFiles {
            guard let existing = destinationByPath[file.path] else {
                plan.new.append(file)
                continue
            }

            if existing.sha256 == file.sha256 {
                plan.existing.append(file)
            } else {
                plan.conflicts.append(file)
            }
        }

        return plan
    }
}

public struct LocalCheckService {
    private let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    public func check(
        source: URL,
        destination: URL,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> CheckReport {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Checking source"))
        }
        let destinationFiles: [FileRecord]
        if FileManager.default.fileExists(atPath: destination.path) {
            destinationFiles = try scanner.scan(root: destination, excludes: excludes, hashing: true) { update in
                progress?(update.withPhase("Checking destination"))
            }
        } else {
            destinationFiles = []
        }

        let sourceByPath = Dictionary(uniqueKeysWithValues: sourceFiles.map { ($0.path, $0) })
        let destinationByPath = Dictionary(uniqueKeysWithValues: destinationFiles.map { ($0.path, $0) })
        var report = CheckReport()

        for sourceFile in sourceFiles {
            guard let destinationFile = destinationByPath[sourceFile.path] else {
                report.sourceOnly.append(sourceFile.path)
                continue
            }

            if sourceFile.sha256 == destinationFile.sha256 {
                report.match.append(sourceFile.path)
            } else {
                report.differ.append(sourceFile.path)
            }
        }

        for destinationFile in destinationFiles where sourceByPath[destinationFile.path] == nil {
            report.destinationOnly.append(destinationFile.path)
        }

        report.match.sort()
        report.sourceOnly.sort()
        report.destinationOnly.sort()
        report.differ.sort()
        return report
    }
}
