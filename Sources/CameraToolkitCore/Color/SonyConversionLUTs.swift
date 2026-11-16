import Foundation

/// Sony's own S-Log3 → Rec.709 conversion, fetched from Sony when the user
/// asks. Nothing of Sony's is in the repository: the archive comes from
/// Sony's site over HTTPS, is checked to be a zip of `.cube` files, and the
/// LUTs are imported as conversion LUTs for S-Log3 / S-Gamut3.Cine.
///
/// Sony's "Sony Collection" on its cinematography LUT page offers
/// `Slog3-S-Gamut3.Cine_To_s709_V200` — s709 is the Rec.709 look Sony's
/// current cameras (VENICE, FX, Alpha) use, and the one an A7V's own clip
/// metadata names (`SL3SG3Ctos709.cube`).
public enum SonyConversionLUTs {
    /// The page Sony lists the LUT downloads on.
    public static let sourcePage = URL(string: "https://sony-cinematography.com/resources/luts/")!
    /// The archive the page links for "Slog3-S-Gamut3.Cine To s709 V200",
    /// on the content host that page serves its downloads from.
    public static let s709Archive = URL(string: "https://77snszqv.media.zestyio.com/Slog3-S-Gamut3.Cine_To_s709_V200.zip")!
    /// The archive is about 230 KB; anything far bigger is not it.
    public static let maximumArchiveBytes = 20 * 1_024 * 1_024

    public struct ImportResult: Equatable, Sendable {
        public var imported: [ImportedLUT]
        /// The s709 LUT among them, the one to make the default.
        public var s709: ImportedLUT?
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notHTTPS
        case badResponse(Int)
        case tooLarge
        case notAZip
        case extractFailed(String)
        case noCubes

        public var errorDescription: String? {
            switch self {
            case .notHTTPS: "Only an HTTPS address from Sony is used."
            case .badResponse(let code): "Sony's server answered \(code). Try again later, or download the LUTs from Sony's page and import them."
            case .tooLarge: "The download is far larger than Sony's LUT archive. It was not opened."
            case .notAZip: "The download is not a zip archive. It was not opened."
            case .extractFailed(let reason): "The archive could not be opened: \(reason)"
            case .noCubes: "The archive holds no .cube LUTs."
            }
        }
    }

    /// Downloads the s709 archive and imports its LUTs.
    public static func download(
        from url: URL = s709Archive,
        into library: LUTLibrary,
        session: URLSession = .shared,
        scratch: URL = FileManager.default.temporaryDirectory
    ) async throws -> ImportResult {
        guard url.scheme?.lowercased() == "https" else { throw Failure.notHTTPS }
        let (downloaded, response) = try await session.download(from: url)
        let folder = scratch.appendingPathComponent("SonyLUTs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The folder is this call's own scratch space.
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("archive.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }
        return try importArchive(at: zip, into: library, scratch: folder)
    }

    /// Checks `zip` is a small zip archive, extracts it with `ditto` into
    /// scratch space, and imports every `.cube` in it as an S-Log3 /
    /// S-Gamut3.Cine conversion LUT. Links, AppleDouble files and the
    /// `__MACOSX` folder are skipped.
    public static func importArchive(at zip: URL, into library: LUTLibrary, scratch: URL) throws -> ImportResult {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumArchiveBytes else { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: zip)
        let magic = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw Failure.notAZip }

        let extracted = scratch.appendingPathComponent("extracted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, extracted.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.extractFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var cubes: [URL] = []
        for entry in LayoutMigrationDisk.walk(extracted.path, fileManager: .default) where entry.kind == .file {
            let name = entry.name
            guard name.lowercased().hasSuffix(".cube"), !name.hasPrefix("._"),
                  !entry.path.contains("/__MACOSX/") else { continue }
            cubes.append(URL(fileURLWithPath: entry.path))
        }
        guard !cubes.isEmpty else { throw Failure.noCubes }
        var result = ImportResult(imported: [], s709: nil)
        for cube in cubes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let entry = try library.importLUT(from: cube, role: .conversion(.sLog3SGamut3Cine))
            if entry.role != .conversion(.sLog3SGamut3Cine) {
                try library.setRole(id: entry.id, to: .conversion(.sLog3SGamut3Cine))
            }
            result.imported.append(entry)
            if result.s709 == nil, cube.lastPathComponent.lowercased().contains("s709") { result.s709 = entry }
        }
        if result.s709 == nil, result.imported.count == 1 { result.s709 = result.imported.first }
        return result
    }
}
