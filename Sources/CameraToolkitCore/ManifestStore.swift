import Foundation

public struct Manifest: Codable, Equatable, Sendable {
    public static let fileName = "camtk-manifest.json"

    public var version: Int
    public var batchID: String
    public var deviceID: String
    public var source: String
    public var createdAt: Date
    public var files: [FileRecord]

    public init(
        version: Int = 1,
        batchID: String,
        deviceID: String,
        source: String,
        createdAt: Date = Date(),
        files: [FileRecord] = []
    ) {
        self.version = version
        self.batchID = batchID
        self.deviceID = deviceID
        self.source = source
        self.createdAt = createdAt
        self.files = files
    }

    public var fileCount: Int { files.count }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ManifestVerificationReport: Codable, Equatable, Sendable {
    public var ok: Bool { missing.isEmpty && mismatched.isEmpty }
    public var verified: Int
    public var missing: [String]
    public var mismatched: [String]
    public var total: Int
}

public struct ManifestStore {
    private let scanner: FileScanner
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func build(root: URL, batchID: String, deviceID: String, source: String, excludes: [String] = DefaultExcludes.all) throws -> Manifest {
        let manifestExcludes = excludes + [Manifest.fileName]
        let files = try scanner.scan(root: root, excludes: manifestExcludes, hashing: true)
        return Manifest(batchID: batchID, deviceID: deviceID, source: source, files: files)
    }

    public func write(_ manifest: Manifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    public func read(from url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Manifest.self, from: data)
    }

    public func verify(root: URL, manifest: Manifest) throws -> ManifestVerificationReport {
        var verified = 0
        var missing: [String] = []
        var mismatched: [String] = []

        for file in manifest.files {
            let url = try PathSafety.safeAppend(root: root, relativePath: file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(file.path)
                continue
            }

            let digest = try FileScanner.sha256(url)
            if digest == file.sha256 {
                verified += 1
            } else {
                mismatched.append(file.path)
            }
        }

        return ManifestVerificationReport(
            verified: verified,
            missing: missing.sorted(),
            mismatched: mismatched.sorted(),
            total: manifest.files.count
        )
    }
}
