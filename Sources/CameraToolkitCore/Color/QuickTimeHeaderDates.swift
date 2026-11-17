import Foundation

/// The creation and modification times in a QuickTime or MP4 file's own
/// headers: the movie header (`mvhd`), each track header (`tkhd`) and each
/// media header (`mdhd`). AVAssetWriter always writes the time of the
/// render there and has no way to set it, so a graded copy has its headers
/// stamped with the original's capture time before it is checked and
/// renamed into place. Readers that look only at these headers (Finder,
/// older tools, some photo apps) then show the capture time too.
///
/// Stamping rewrites fixed-size fields in place and nothing else: no atom
/// changes size and no media data moves. It is only ever done to a file the
/// app is writing (a partial), never to an original.
public enum QuickTimeHeaderDates {
    /// Seconds from 1904-01-01 (QuickTime's epoch) to 1970-01-01.
    static let epochOffset: TimeInterval = 2_082_844_800

    struct Field {
        /// File offset of the creation time; the modification time follows it.
        var offset: UInt64
        /// 4 (version 0) or 8 (version 1) bytes each.
        var width: Int
        var atom: String
    }

    /// Every header date in the file, creation then modification, header by
    /// header (`mvhd`, then each track's `tkhd` and `mdhd`).
    public static func read(_ url: URL) throws -> [Date] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var dates: [Date] = []
        for field in try fields(handle) {
            try handle.seek(toOffset: field.offset)
            let bytes = try handle.read(upToCount: field.width * 2) ?? Data()
            guard bytes.count == field.width * 2 else { throw truncated(url) }
            for index in 0..<2 {
                let value = bytes.subdata(in: (index * field.width)..<((index + 1) * field.width)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                dates.append(Date(timeIntervalSince1970: TimeInterval(value) - epochOffset))
            }
        }
        return dates
    }

    /// Sets every header's creation and modification time to `date` (whole
    /// seconds). Returns how many headers were stamped; throws when the file
    /// has no movie header.
    @discardableResult
    public static func stamp(_ url: URL, date: Date) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let found = try fields(handle)
        guard found.contains(where: { $0.atom == "mvhd" }) else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) has no movie header to date.")
        }
        let seconds = max(0, (date.timeIntervalSince1970 + epochOffset).rounded(.down))
        for field in found {
            let value = UInt64(seconds)
            guard field.width == 8 || value <= UInt64(UInt32.max) else { continue }
            var bytes = Data()
            for _ in 0..<2 {
                for shift in stride(from: (field.width - 1) * 8, through: 0, by: -8) {
                    bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
                }
            }
            try handle.seek(toOffset: field.offset)
            try handle.write(contentsOf: bytes)
        }
        try handle.synchronize()
        return found.count
    }

    // MARK: Atoms

    private static func truncated(_ url: URL) -> Error {
        ToolkitError.commandFailed("\(url.lastPathComponent) ends inside a header.")
    }

    /// Walks the top level, then `moov` → `mvhd`, `trak` → `tkhd`,
    /// `trak` → `mdia` → `mdhd`. Media data is skipped, never read.
    static func fields(_ handle: FileHandle) throws -> [Field] {
        let end = try handle.seekToEnd()
        var result: [Field] = []
        for top in try children(handle, from: 0, to: end) where top.type == "moov" {
            for child in try children(handle, from: top.body, to: top.end) {
                switch child.type {
                case "mvhd":
                    if let field = try dateField(handle, atom: child) { result.append(field) }
                case "trak":
                    for part in try children(handle, from: child.body, to: child.end) {
                        if part.type == "tkhd", let field = try dateField(handle, atom: part) { result.append(field) }
                        guard part.type == "mdia" else { continue }
                        for media in try children(handle, from: part.body, to: part.end) where media.type == "mdhd" {
                            if let field = try dateField(handle, atom: media) { result.append(field) }
                        }
                    }
                default:
                    continue
                }
            }
        }
        return result
    }

    struct Atom {
        var type: String
        /// Where its contents start (after the size and type).
        var body: UInt64
        var end: UInt64
    }

    static func children(_ handle: FileHandle, from start: UInt64, to end: UInt64) throws -> [Atom] {
        var atoms: [Atom] = []
        var cursor = start
        while cursor + 8 <= end {
            try handle.seek(toOffset: cursor)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            var size = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            var body = cursor + 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else { break }
                size = large.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                body += 8
            } else if size == 0 {
                size = end - cursor
            }
            guard size >= body - cursor, cursor + size <= end else { break }
            atoms.append(Atom(type: type, body: body, end: cursor + size))
            cursor += size
        }
        return atoms
    }

    /// A full box: version (1 byte) and flags (3), then the two times.
    private static func dateField(_ handle: FileHandle, atom: Atom) throws -> Field? {
        try handle.seek(toOffset: atom.body)
        guard let version = try handle.read(upToCount: 1)?.first else { return nil }
        let width = version == 1 ? 8 : 4
        guard atom.body + 4 + UInt64(width * 2) <= atom.end else { return nil }
        return Field(offset: atom.body + 4, width: width, atom: atom.type)
    }
}
