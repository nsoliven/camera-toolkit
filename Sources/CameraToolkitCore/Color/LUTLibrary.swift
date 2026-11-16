import Foundation

/// One imported `.cube` LUT.
public struct ImportedLUT: Codable, Hashable, Identifiable, Sendable {
    /// The first 16 hex digits of the file's SHA-256: importing the same
    /// file twice gives the same id, and a grade that names it keeps
    /// meaning the same table.
    public var id: String
    public var name: String
    /// The copy's file name inside the library folder.
    public var fileName: String
    public var importedAt: Date
    /// 3D table size, or nil for a 1D-only LUT.
    public var cubeSize: Int?
    /// What it expects in: log (a conversion) or Rec.709 (a look).
    public var role: LUTRole

    public init(id: String, name: String, fileName: String, importedAt: Date, cubeSize: Int?, role: LUTRole? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.importedAt = importedAt
        self.cubeSize = cubeSize
        self.role = role ?? LUTRole.inferred(fromName: name + " " + fileName)
    }

    private enum CodingKeys: String, CodingKey { case id, name, fileName, importedAt, cubeSize, role, sourceName }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        fileName = try values.decode(String.self, forKey: .fileName)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        cubeSize = try values.decodeIfPresent(Int.self, forKey: .cubeSize)
        role = try values.decodeIfPresent(LUTRole.self, forKey: .role) ?? LUTRole.inferred(fromName: name)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(importedAt, forKey: .importedAt)
        try values.encodeIfPresent(cubeSize, forKey: .cubeSize)
        try values.encode(role, forKey: .role)
    }
}

/// The user's imported LUTs, kept under the app's Application Support
/// folder (never in the repository, never beside the media). Importing
/// copies the file in after it parses; the original stays where it was.
public final class LUTLibrary: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var parsed: [String: CubeLUT] = [:]

    public init(folder: URL) {
        self.folder = folder
    }

    /// `<Application Support>/CameraToolkit/LUTs`.
    public static func defaultFolder(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("CameraToolkit", isDirectory: true)
            .appendingPathComponent("LUTs", isDirectory: true)
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    public func list() -> [ImportedLUT] {
        lock.lock()
        defer { lock.unlock() }
        return readIndex()
    }

    public func entry(id: String) -> ImportedLUT? {
        list().first { $0.id == id }
    }

    /// Parses `url`, then copies it in. Returns the existing entry when the
    /// same file was imported before.
    @discardableResult
    public func importLUT(from url: URL, role: LUTRole? = nil, now: Date = Date()) throws -> ImportedLUT {
        let data = try Data(contentsOf: url)
        guard data.count <= CubeLUT.maximumFileBytes else { throw CubeLUTError.tooLarge }
        let lut = try CubeLUT.parse(data)
        let id = String(LayoutMigrationHash.sha256(data).prefix(16)).lowercased()
        lock.lock()
        defer { lock.unlock() }
        var index = readIndex()
        if let existing = index.first(where: { $0.id == id }) { return existing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = "\(id).cube"
        let destination = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .withoutOverwriting)
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        let name = (lut.title?.isEmpty == false ? lut.title! : baseName)
        // Whole seconds: the index stores ISO 8601 without fractions.
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        // The role: as asked, else guessed from the file's own name (Sony's
        // and DJI's conversion LUTs name their log input).
        let entry = ImportedLUT(
            id: id, name: name, fileName: fileName, importedAt: stamp, cubeSize: lut.cube?.size,
            role: role ?? LUTRole.inferred(fromName: url.lastPathComponent + " " + (lut.title ?? ""))
        )
        index.append(entry)
        try writeIndex(index)
        parsed[id] = lut
        return entry
    }

    public func rename(id: String, to name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var index = readIndex()
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        index[position].name = trimmed
        try writeIndex(index)
    }

    public func setRole(id: String, to role: LUTRole) throws {
        lock.lock()
        defer { lock.unlock() }
        var index = readIndex()
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        index[position].role = role
        try writeIndex(index)
    }

    /// Present LUTs and what each expects, for `GradeResolver`.
    public func roles() -> [String: LUTRole] {
        Dictionary(list().map { ($0.id, $0.role) }, uniquingKeysWith: { first, _ in first })
    }

    /// Takes the LUT off the list and moves its copy to the Trash. Grades
    /// that name it then draw without a look until it is imported again.
    public func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var index = readIndex()
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        let entry = index.remove(at: position)
        try writeIndex(index)
        parsed[id] = nil
        let file = folder.appendingPathComponent(entry.fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// The parsed table, read once and kept.
    public func lut(id: String) -> CubeLUT? {
        lock.lock()
        if let cached = parsed[id] {
            lock.unlock()
            return cached
        }
        let entry = readIndex().first { $0.id == id }
        lock.unlock()
        guard let entry, let lut = try? CubeLUT.parse(contentsOf: folder.appendingPathComponent(entry.fileName)) else { return nil }
        lock.lock()
        parsed[id] = lut
        lock.unlock()
        return lut
    }

    private func readIndex() -> [ImportedLUT] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImportedLUT].self, from: data)) ?? []
    }

    private func writeIndex(_ index: [ImportedLUT]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }
}
