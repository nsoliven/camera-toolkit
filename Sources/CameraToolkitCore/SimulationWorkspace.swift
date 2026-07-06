import Foundation

public struct SimulationSummary: Codable, Equatable, Sendable {
    public var root: String
    public var sourcePath: String
    public var archivePath: String
    public var bufferPath: String
    public var manifestOK: Bool
    public var copiedCount: Int
    public var quarantinedCount: Int
    public var leftUnsafeCount: Int

    public init(
        root: String,
        sourcePath: String,
        archivePath: String,
        bufferPath: String,
        manifestOK: Bool,
        copiedCount: Int,
        quarantinedCount: Int,
        leftUnsafeCount: Int
    ) {
        self.root = root
        self.sourcePath = sourcePath
        self.archivePath = archivePath
        self.bufferPath = bufferPath
        self.manifestOK = manifestOK
        self.copiedCount = copiedCount
        self.quarantinedCount = quarantinedCount
        self.leftUnsafeCount = leftUnsafeCount
    }
}

public struct SimulationWorkspace {
    public let root: URL

    public var sourceCard: URL { root.appendingPathComponent("Fake Card", isDirectory: true) }
    public var archive: URL { root.appendingPathComponent("Archive", isDirectory: true) }
    public var buffer: URL { root.appendingPathComponent("Buffer", isDirectory: true) }
    public var trash: URL { buffer.appendingPathComponent("_Trash", isDirectory: true) }
    public var manifestURL: URL { archive.appendingPathComponent(Manifest.fileName) }

    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func resetAndSeed() throws {
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }

        try write(sourceCard.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"), bytes: Data(repeating: 0xA1, count: 44_200))
        try write(sourceCard.appendingPathComponent("DCIM/100MSDCF/DSC00002.ARW"), bytes: Data(repeating: 0xA2, count: 45_100))
        try write(sourceCard.appendingPathComponent("DCIM/100MSDCF/DSC00003.JPG"), bytes: Data(repeating: 0xB3, count: 8_200))
        try write(sourceCard.appendingPathComponent("M4ROOT/CLIP/C0001.MP4"), bytes: Data(repeating: 0xC1, count: 280_000))
        try write(sourceCard.appendingPathComponent("M4ROOT/CLIP/C0001M01.XML"), bytes: Data("<xml/>".utf8))
        try write(sourceCard.appendingPathComponent("DCIM/.DS_Store"), bytes: Data("junk".utf8))
        try write(sourceCard.appendingPathComponent("DCIM/100MSDCF/._DSC00001.ARW"), bytes: Data("appledouble".utf8))

        try write(archive.appendingPathComponent("DCIM/100MSDCF/DSC00003.JPG"), bytes: Data(repeating: 0xB3, count: 8_200))

        try write(buffer.appendingPathComponent("DCIM/100MSDCF/DSC00003.JPG"), bytes: Data(repeating: 0xB3, count: 8_200))
        try write(buffer.appendingPathComponent("BufferOnly/UNSYNCED.ARW"), bytes: Data("not on archive".utf8))
    }

    public func previewImport() throws -> CopyPlan {
        try ArchivePlanner().planCopy(source: sourceCard, destination: archive)
    }

    public func runImport() throws -> (copy: LocalCopyResult, check: CheckReport, manifest: ManifestVerificationReport) {
        let copy = try LocalTransferService().copyImmutable(source: sourceCard, destination: archive)
        if !copy.conflicts.isEmpty {
            throw ToolkitError.commandFailed("Simulation import found immutable conflicts: \(copy.conflicts.joined(separator: ", "))")
        }

        let check = try LocalCheckService().check(source: sourceCard, destination: archive)
        if !check.ok {
            throw ToolkitError.commandFailed("Simulation import failed verification")
        }

        let store = ManifestStore()
        let manifest = try store.build(root: archive, batchID: "simulation-batch", deviceID: "sony-a7v", source: sourceCard.path)
        try store.write(manifest, to: manifestURL)
        let manifestReport = try store.verify(root: archive, manifest: manifest)
        return (copy, check, manifestReport)
    }

    public func runFreeUp() throws -> FreeUpReport {
        try FreeUpService().freeUp(bufferRoot: buffer, archiveRoot: archive, trashRoot: trash, apply: true)
    }

    public func runFullSimulation() throws -> SimulationSummary {
        try resetAndSeed()
        _ = try previewImport()
        let importResult = try runImport()
        let freeUpReport = try runFreeUp()

        return SimulationSummary(
            root: root.path,
            sourcePath: sourceCard.path,
            archivePath: archive.path,
            bufferPath: buffer.path,
            manifestOK: importResult.manifest.ok,
            copiedCount: importResult.copy.copied.count,
            quarantinedCount: freeUpReport.moved.count,
            leftUnsafeCount: freeUpReport.notOnArchive.count + freeUpReport.differ.count + freeUpReport.errors.count
        )
    }

    private func write(_ url: URL, bytes: Data) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
}
