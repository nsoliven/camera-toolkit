import Darwin
import Foundation

/// One entry of a directory listing, with the facts a listing call returns
/// in bulk: kind, size, modification time, and file id.
public struct DirectoryListingEntry: Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symlink, other }

    public var name: String
    public var kind: Kind
    public var size: Int64
    /// `timeIntervalSinceReferenceDate` of the modification time.
    public var modifiedAt: Double
    /// The file id the filesystem reports. Not stable over SMB — never an
    /// identity on a network share, only a hint.
    public var fileID: UInt64
    /// Whether this user may read the entry, as the listing reports it
    /// (`ATTR_CMN_USERACCESS`). True when the filesystem does not say.
    public var isReadable: Bool

    public init(name: String, kind: Kind, size: Int64, modifiedAt: Double, fileID: UInt64, isReadable: Bool = true) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileID = fileID
        self.isReadable = isReadable
    }
}

/// Lists a folder with `getattrlistbulk`: one call per batch of entries
/// returns every entry's name, type, size, and modification time, so a
/// network share answers a folder listing instead of one stat round trip
/// per file. Falls back to `readdir` + `lstat` on a filesystem that does not
/// support it. Hidden entries — `._` AppleDouble files included — are
/// returned; `FileManager` would hide them.
public enum DirectoryListing {
    /// Test seam: a listing that fails (for an unreadable folder) or answers
    /// from memory. Nil uses the filesystem.
    nonisolated(unsafe) static var override: ((String) throws -> [DirectoryListingEntry])?

    public static func list(_ path: String) throws -> [DirectoryListingEntry] {
        if let override { return try override(path) }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(errno, "list", path) }
        defer { close(descriptor) }
        do {
            return try bulk(descriptor: descriptor)
        } catch let error as BulkUnsupported {
            _ = error
            return try readdirFallback(path)
        }
    }

    struct BulkUnsupported: Error {}

    static func bulk(descriptor: Int32) throws -> [DirectoryListingEntry] {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_USERACCESS) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [DirectoryListingEntry] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == ENOTSUP || code == EINVAL { throw BulkUnsupported() }
                throw posix(code, "list", "folder")
            }
            if count == 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry.advanced(by: MemoryLayout<UInt32>.size)
                // attribute_set_t: which attributes were actually returned.
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field = field.advanced(by: MemoryLayout<attribute_set_t>.size)
                // ATTR_CMN_NAME: an attrreference_t relative to itself.
                let nameReference = field
                let nameOffset = Int(nameReference.loadUnaligned(as: Int32.self))
                let nameLength = Int(nameReference.advanced(by: 4).loadUnaligned(as: UInt32.self))
                let nameStart = nameReference.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
                let name = String(
                    decoding: UnsafeRawBufferPointer(start: nameStart, count: max(nameLength - 1, 0)),
                    as: UTF8.self
                )
                field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                let objectType = field.loadUnaligned(as: fsobj_type_t.self)
                field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
                let modified = field.loadUnaligned(as: timespec.self)
                field = field.advanced(by: MemoryLayout<timespec>.size)
                // ATTR_CMN_USERACCESS packs before ATTR_CMN_FILEID (bit order).
                let access = field.loadUnaligned(as: UInt32.self)
                let accessReturned = returned.commonattr & attrgroup_t(ATTR_CMN_USERACCESS) != 0
                field = field.advanced(by: MemoryLayout<UInt32>.size)
                let fileID = field.loadUnaligned(as: UInt64.self)
                field = field.advanced(by: MemoryLayout<UInt64>.size)
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    size = field.loadUnaligned(as: off_t.self)
                }
                let kind: DirectoryListingEntry.Kind
                switch Int(objectType) {
                case Int(VREG.rawValue): kind = .file
                case Int(VDIR.rawValue): kind = .directory
                case Int(VLNK.rawValue): kind = .symlink
                default: kind = .other
                }
                if name != "." && name != ".." {
                    let seconds = TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1e9
                    entries.append(DirectoryListingEntry(
                        name: name,
                        kind: kind,
                        size: kind == .file ? size : 0,
                        modifiedAt: Date(timeIntervalSince1970: seconds).timeIntervalSinceReferenceDate,
                        fileID: fileID,
                        isReadable: !accessReturned || access & UInt32(R_OK) != 0
                    ))
                }
                entry = entry.advanced(by: length)
            }
        }
        return entries.sorted { $0.name < $1.name }
    }

    static func readdirFallback(_ path: String) throws -> [DirectoryListingEntry] {
        guard let directory = opendir(path) else { throw posix(errno, "list", path) }
        defer { closedir(directory) }
        var entries: [DirectoryListingEntry] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            let child = (path as NSString).appendingPathComponent(name)
            guard lstat(child, &info) == 0 else { continue }
            let kind: DirectoryListingEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            entries.append(DirectoryListingEntry(
                name: name,
                kind: kind,
                size: kind == .file ? Int64(info.st_size) : 0,
                modifiedAt: Date(timeIntervalSince1970: seconds).timeIntervalSinceReferenceDate,
                fileID: UInt64(info.st_ino),
                isReadable: access(child, R_OK) == 0
            ))
        }
        return entries.sorted { $0.name < $1.name }
    }

    static func posix(_ code: Int32, _ operation: String, _ path: String) -> ToolkitError {
        .commandFailed("Could not \(operation) \(path): \(String(cString: strerror(code)))")
    }
}
