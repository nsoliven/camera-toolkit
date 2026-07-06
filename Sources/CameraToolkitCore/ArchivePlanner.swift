import Foundation

public struct ArchivePlanner {
    private let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    public func planCopy(source: URL, destination: URL, excludes: [String] = DefaultExcludes.all) throws -> CopyPlan {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true)
        let destinationFiles: [FileRecord]

        if FileManager.default.fileExists(atPath: destination.path) {
            destinationFiles = try scanner.scan(root: destination, excludes: excludes, hashing: true)
        } else {
            destinationFiles = []
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

    public func check(source: URL, destination: URL, excludes: [String] = DefaultExcludes.all) throws -> CheckReport {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true)
        let destinationFiles = FileManager.default.fileExists(atPath: destination.path)
            ? try scanner.scan(root: destination, excludes: excludes, hashing: true)
            : []

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
