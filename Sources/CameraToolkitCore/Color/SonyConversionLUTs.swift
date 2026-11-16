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
    /// SHA-256 of that archive (235,873 bytes, one 33-point
    /// `Slog3-S-Gamut3.Cine_To_s709_V200.cube`), checked before anything is
    /// extracted. If Sony republishes the file this stops matching and the
    /// user is pointed to Sony's page to download and import it by hand.
    public static let s709SHA256 = "6d86a4032342e43c0d105326748f433583789039b3c9e1336d6bb3cc4d68df7d"
    /// The archive is about 230 KB; anything far bigger is not it. Checked
    /// while the bytes arrive, so a wrong file is never downloaded whole.
    public static let maximumArchiveBytes = 20 * 1_024 * 1_024
    /// What the archive may unpack to at most (the real one is ~1 MB).
    public static let maximumExtractedBytes: Int64 = 64 * 1_024 * 1_024
    public static let maximumEntries = 64

    public struct ImportResult: Equatable, Sendable {
        public var imported: [ImportedLUT]
        /// The s709 LUT among them, the one to make the default.
        public var s709: ImportedLUT?
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notHTTPS
        case insecureRedirect
        case badResponse(Int)
        case tooLarge
        case notAZip
        case checksumMismatch
        case unpacksTooLarge
        case extractFailed(String)
        case noCubes

        public var errorDescription: String? {
            switch self {
            case .notHTTPS: "Only an HTTPS address from Sony is used."
            case .insecureRedirect: "The download was redirected away from HTTPS, so it was stopped. Download the LUTs from Sony's page and import them instead."
            case .badResponse(let code): "Sony's server answered \(code). Try again later, or download the LUTs from Sony's page and import them."
            case .tooLarge: "The download is far larger than Sony's LUT archive. It was stopped and not opened."
            case .notAZip: "The download is not a zip archive. It was not opened."
            case .checksumMismatch: "The file from Sony's server is not the s709 archive this version of Camera Toolkit knows (Sony may have updated it). It was not opened. Download it from Sony's LUT page and import the .cube in Settings › Color."
            case .unpacksTooLarge: "The archive would unpack to far more than Sony's LUTs. It was not opened."
            case .extractFailed(let reason): "The archive could not be opened: \(reason)"
            case .noCubes: "The archive holds no .cube LUTs."
            }
        }
    }

    /// Downloads the s709 archive — HTTPS only, redirects included, size
    /// capped while it arrives — checks it against `s709SHA256`, and imports
    /// its LUTs.
    public static func download(
        from url: URL = s709Archive,
        expectedSHA256: String? = s709SHA256,
        into library: LUTLibrary,
        session: URLSession = .shared,
        scratch: URL = FileManager.default.temporaryDirectory,
        maximumBytes: Int = maximumArchiveBytes
    ) async throws -> ImportResult {
        guard url.scheme?.lowercased() == "https" else { throw Failure.notHTTPS }
        let folder = scratch.appendingPathComponent("SonyLUTs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The folder is this call's own scratch space.
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("archive.zip")
        try await fetch(url, to: zip, session: session, maximumBytes: maximumBytes)
        return try importArchive(at: zip, into: library, scratch: folder, expectedSHA256: expectedSHA256)
    }

    /// Refuses any redirect that leaves HTTPS.
    final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var refused = false
        var refusedRedirect: Bool { lock.withLock { refused } }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if request.url?.scheme?.lowercased() == "https" {
                completionHandler(request)
            } else {
                lock.withLock { refused = true }
                completionHandler(nil)
                task.cancel()
            }
        }
    }

    /// Streams `url` into `file`, stopping as soon as it passes the cap.
    static func fetch(_ url: URL, to file: URL, session: URLSession, maximumBytes: Int = maximumArchiveBytes) async throws {
        let guardDelegate = HTTPSOnlyRedirects()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(from: url, delegate: guardDelegate)
        } catch {
            if guardDelegate.refusedRedirect { throw Failure.insecureRedirect }
            throw error
        }
        if guardDelegate.refusedRedirect || response.url?.scheme?.lowercased() != "https" { throw Failure.insecureRedirect }
        if let http = response as? HTTPURLResponse {
            if (300..<400).contains(http.statusCode) { throw Failure.insecureRedirect }
            guard (200..<300).contains(http.statusCode) else { throw Failure.badResponse(http.statusCode) }
        }
        if response.expectedContentLength > Int64(maximumBytes) { throw Failure.tooLarge }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var total = 0
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            if total > maximumBytes { throw Failure.tooLarge }
            if buffer.count >= 64 * 1_024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// Entry count and total unpacked size from a zip's central directory,
    /// read without extracting anything. ZIP64 archives (which Sony's is
    /// not) are refused.
    static func centralDirectoryTotals(_ data: Data) throws -> (entries: Int, bytes: Int64) {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24 }
        guard data.count >= 22 else { throw Failure.notAZip }
        var eocd: Int?
        var o = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while o >= floor {
            if u32(o) == 0x0605_4B50 { eocd = o; break }
            o -= 1
        }
        guard let end = eocd else { throw Failure.notAZip }
        let count = u16(end + 10)
        let directoryOffset = Int(u32(end + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF, count <= maximumEntries else { throw Failure.unpacksTooLarge }
        var cursor = directoryOffset
        var total: Int64 = 0
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(cursor) == 0x0201_4B50 else { throw Failure.notAZip }
            let size = u32(cursor + 24)
            guard size != 0xFFFF_FFFF else { throw Failure.unpacksTooLarge }
            total += Int64(size)
            cursor += 46 + u16(cursor + 28) + u16(cursor + 30) + u16(cursor + 32)
        }
        return (count, total)
    }

    /// Checks `zip` is a small zip archive, extracts it with `ditto` into
    /// scratch space, and imports every `.cube` in it as an S-Log3 /
    /// S-Gamut3.Cine conversion LUT. Links, AppleDouble files and the
    /// `__MACOSX` folder are skipped.
    public static func importArchive(
        at zip: URL, into library: LUTLibrary, scratch: URL, expectedSHA256: String? = nil,
        extractedLimit: Int64 = maximumExtractedBytes
    ) throws -> ImportResult {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumArchiveBytes else { throw Failure.tooLarge }
        let data = try Data(contentsOf: zip)
        guard data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else { throw Failure.notAZip }
        if let expectedSHA256, LayoutMigrationHash.sha256(data) != expectedSHA256.lowercased() {
            throw Failure.checksumMismatch
        }
        let totals = try centralDirectoryTotals(data)
        guard totals.bytes <= extractedLimit else { throw Failure.unpacksTooLarge }

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
        let entries = LayoutMigrationDisk.walk(extracted.path, fileManager: .default)
        // What actually came out, in case the directory under-reported it.
        let unpacked = entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + ((try? URL(fileURLWithPath: $1.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
        guard unpacked <= extractedLimit else { throw Failure.unpacksTooLarge }
        for entry in entries where entry.kind == .file {
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
