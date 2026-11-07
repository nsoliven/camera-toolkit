import Compression
import Foundation
import GRDB

/// A Photomator edit file (`.photo-edit`) read without changing it: a ZIP
/// (usually stored, uncompressed) holding `metadata.info` — a SQLite
/// database with the edit settings — and QuickLook renders of the edited
/// photo (`QuickLook/Thumbnail.webp`, `QuickLook/Icon.webp`).
///
/// Everything here only reads. The settings database is opened read-only
/// from a temporary copy, never from inside the archive or beside it.
public struct PhotoEditArchive: Sendable {
    public enum ReadError: Error, Equatable, LocalizedError {
        case tooLarge(Int64)
        case notAZip
        case unsupported(String)
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let size): "The edit file is \(size) bytes — too large to be a Photomator edit."
            case .notAZip: "The edit file is not a ZIP archive."
            case .unsupported(let detail): "The edit file uses a ZIP feature this reader does not handle (\(detail))."
            case .missing(let name): "The edit file has no \(name)."
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public var name: String
        /// 0 stored, 8 deflated.
        public var method: UInt16
        public var compressedSize: Int
        public var size: Int
        public var localHeaderOffset: Int
    }

    public static let extensionName = "photo-edit"
    public static let metadataName = "metadata.info"
    public static let thumbnailName = "QuickLook/Thumbnail.webp"
    public static let iconName = "QuickLook/Icon.webp"
    /// Real edit files are a few hundred kilobytes.
    public static let sizeLimit: Int64 = 64 * 1_024 * 1_024

    public let data: Data
    public let entries: [Entry]

    public static func isPhotoEdit(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == extensionName
    }

    public init(contentsOf url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.sizeLimit else { throw ReadError.tooLarge(size) }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        entries = try Self.centralDirectory(data)
    }

    public func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The bytes of `name`, inflated when the archive deflated it.
    public func contents(of name: String) throws -> Data {
        guard let entry = entry(name) else { throw ReadError.missing(name) }
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, Self.u32(data, local) == 0x0403_4b50 else { throw ReadError.notAZip }
        let start = local + 30 + Int(Self.u16(data, local + 26)) + Int(Self.u16(data, local + 28))
        guard start + entry.compressedSize <= data.count else { throw ReadError.notAZip }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            return try Self.inflate(raw, size: entry.size)
        default:
            throw ReadError.unsupported("compression method \(entry.method)")
        }
    }

    // MARK: - ZIP

    static func centralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ReadError.notAZip }
        // The end record sits in the last 64 KiB + 22 bytes (its comment is
        // at most 64 KiB).
        let floor = max(0, data.count - 22 - 65_535)
        var end: Int?
        var position = data.count - 22
        while position >= floor {
            if u32(data, position) == 0x0605_4b50 { end = position; break }
            position -= 1
        }
        guard let end else { throw ReadError.notAZip }
        let count = Int(u16(data, end + 10))
        let offset = Int(u32(data, end + 16))
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw ReadError.unsupported("ZIP64") }
        var entries: [Entry] = []
        var cursor = offset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x0201_4b50 else { throw ReadError.notAZip }
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            guard cursor + 46 + nameLength <= data.count else { throw ReadError.notAZip }
            let name = String(decoding: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: u16(data, cursor + 10),
                compressedSize: Int(u32(data, cursor + 20)),
                size: Int(u32(data, cursor + 24)),
                localHeaderOffset: Int(u32(data, cursor + 42))
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard size <= Int(sizeLimit) else { throw ReadError.tooLarge(Int64(size)) }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { target in
            raw.withUnsafeBytes { source in
                compression_decode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ReadError.unsupported("a damaged deflate stream") }
        return output
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }
}

// MARK: - Edit settings

/// One edit setting, flattened to a readable path and value:
/// `layer_info.color-adjustments.exposure` = `0.35`.
public struct PhotoEditSetting: Equatable, Sendable {
    public var key: String
    public var value: String
}

/// A setting that differs between two versions of an edit; nil on a side
/// means the version does not have it.
public struct PhotoEditDifference: Equatable, Sendable {
    public var key: String
    public var drive: String?
    public var nas: String?
}

public enum PhotoEditSettings {
    /// Values longer than this are shown shortened with their length.
    static let valueLimit = 120
    /// A version with more settings than this is cut off (a damaged file).
    static let settingLimit = 20_000

    /// The settings of an edit, read from a temporary copy of its
    /// `metadata.info` opened read-only. Each table row becomes
    /// `table.<key>` (its `key`/`name` column when it has one, else its
    /// row id) with one setting per other column; a JSON or property-list
    /// value opens into its fields.
    public static func read(_ archive: PhotoEditArchive) throws -> [PhotoEditSetting] {
        let database = try archive.contents(of: PhotoEditArchive.metadataName)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photo-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(PhotoEditArchive.metadataName)
        try database.write(to: copy)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            var settings: [PhotoEditSetting] = []
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            for table in tables {
                let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted))").compactMap { $0["name"] as String? }
                let keyColumn = columns.first { ["key", "name", "identifier", "id"].contains($0.lowercased()) }
                for row in try Row.fetchAll(db, sql: "SELECT rowid AS _rowid_, * FROM \(quoted)") {
                    let rowKey: String = keyColumn.flatMap { row[$0].map { "\($0)" } } ?? "\(row["_rowid_"] as Int64? ?? 0)"
                    let valueColumns = columns.filter { $0 != keyColumn }
                    for column in valueColumns {
                        let base = valueColumns.count == 1 ? "\(table).\(rowKey)" : "\(table).\(rowKey).\(column)"
                        flatten(row[column] as DatabaseValue, key: base, into: &settings)
                        guard settings.count < settingLimit else { return settings }
                    }
                }
            }
            return settings
        }
    }

    /// The settings that differ between the drive's and the NAS's version,
    /// in key order.
    public static func differences(drive: [PhotoEditSetting], nas: [PhotoEditSetting]) -> [PhotoEditDifference] {
        let left = Dictionary(drive.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let right = Dictionary(nas.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        return Set(left.keys).union(right.keys).sorted().compactMap { key in
            left[key] == right[key] ? nil : PhotoEditDifference(key: key, drive: left[key], nas: right[key])
        }
    }

    static func flatten(_ value: DatabaseValue, key: String, into settings: inout [PhotoEditSetting]) {
        switch value.storage {
        case .null:
            settings.append(PhotoEditSetting(key: key, value: "—"))
        case .int64(let number):
            settings.append(PhotoEditSetting(key: key, value: "\(number)"))
        case .double(let number):
            settings.append(PhotoEditSetting(key: key, value: format(number)))
        case .string(let text):
            if let object = structured(Data(text.utf8)) {
                flatten(object, key: key, into: &settings)
            } else {
                settings.append(PhotoEditSetting(key: key, value: shorten(text)))
            }
        case .blob(let data):
            if let object = structured(data) {
                flatten(object, key: key, into: &settings)
            } else if let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") {
                settings.append(PhotoEditSetting(key: key, value: shorten(text)))
            } else {
                settings.append(PhotoEditSetting(key: key, value: "\(data.count) bytes · \(PhotoEditCompare.shortHash(data))"))
            }
        }
    }

    static func flatten(_ object: Any, key: String, into settings: inout [PhotoEditSetting]) {
        guard settings.count < settingLimit else { return }
        switch object {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { settings.append(PhotoEditSetting(key: key, value: "{}")) }
            for name in dictionary.keys.sorted() {
                flatten(dictionary[name] as Any, key: "\(key).\(name)", into: &settings)
            }
        case let array as [Any]:
            if array.isEmpty { settings.append(PhotoEditSetting(key: key, value: "[]")) }
            for (index, element) in array.enumerated() {
                flatten(element, key: "\(key)[\(index)]", into: &settings)
            }
        case let number as NSNumber:
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            settings.append(PhotoEditSetting(key: key, value: isBool ? (number.boolValue ? "true" : "false") : format(number.doubleValue)))
        case let text as String:
            settings.append(PhotoEditSetting(key: key, value: shorten(text)))
        case let data as Data:
            if let nested = structured(data) {
                flatten(nested, key: key, into: &settings)
            } else {
                settings.append(PhotoEditSetting(key: key, value: "\(data.count) bytes · \(PhotoEditCompare.shortHash(data))"))
            }
        case let date as Date:
            settings.append(PhotoEditSetting(key: key, value: date.ISO8601Format()))
        default:
            settings.append(PhotoEditSetting(key: key, value: shorten("\(object)")))
        }
    }

    /// A JSON or property-list document, when `data` is one.
    static func structured(_ data: Data) -> Any? {
        guard let first = data.first else { return nil }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           object is [String: Any] || object is [Any] {
            return object
        }
        if data.starts(with: Data("bplist".utf8)) || data.starts(with: Data("<?xml".utf8)),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           object is [String: Any] || object is [Any] {
            return object
        }
        return nil
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        if value == value.rounded(), abs(value) < 1e15 { return "\(Int64(value))" }
        return String(format: "%.4g", value)
    }

    static func shorten(_ text: String) -> String {
        text.count > valueLimit ? "\(text.prefix(valueLimit))… (\(text.count) characters)" : text
    }
}
