import Foundation

public enum EmbeddedJPEGPreviewPreference: Equatable, Sendable {
    case thumbnail
    case fullSize
}

/// Reads JPEG previews already embedded in TIFF-based camera RAW files.
///
/// Sony ARW files contain multiple JPEG representations. Reading the TIFF IFD
/// pointers lets Camera Toolkit fetch only the preview bytes instead of loading
/// or decoding the full RAW payload.
public struct EmbeddedJPEGPreviewExtractor: Sendable {
    private enum ByteOrder {
        case littleEndian
        case bigEndian
    }

    private struct Candidate: Hashable {
        var offset: UInt64
        var length: Int
    }

    public init() {}

    public func jpegData(
        from url: URL,
        preference: EmbeddedJPEGPreviewPreference = .thumbnail
    ) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 8 else { return nil }
        let header = try read(handle, offset: 0, count: 8)

        let order: ByteOrder
        switch (header[0], header[1]) {
        case (0x49, 0x49): order = .littleEndian
        case (0x4d, 0x4d): order = .bigEndian
        default: return nil
        }
        guard uint16(header, at: 2, order: order) == 42 else { return nil }

        let firstIFD = UInt64(uint32(header, at: 4, order: order))
        var pendingIFDs = firstIFD == 0 ? [] : [firstIFD]
        var visitedIFDs: Set<UInt64> = []
        var candidates: [Candidate] = []

        while let ifdOffset = pendingIFDs.popLast(), visitedIFDs.count < 32 {
            guard visitedIFDs.insert(ifdOffset).inserted,
                  ifdOffset + 2 <= fileSize else { continue }

            let countData = try read(handle, offset: ifdOffset, count: 2)
            let entryCount = Int(uint16(countData, at: 0, order: order))
            guard entryCount <= 4_096 else { continue }

            let tableByteCount = entryCount * 12 + 4
            guard ifdOffset + 2 + UInt64(tableByteCount) <= fileSize else { continue }
            let table = try read(handle, offset: ifdOffset + 2, count: tableByteCount)

            var jpegOffset: UInt64?
            var jpegLength: Int?
            for index in 0..<entryCount {
                let base = index * 12
                let tag = uint16(table, at: base, order: order)
                let type = uint16(table, at: base + 2, order: order)
                let valueCount = uint32(table, at: base + 4, order: order)
                let valueOrOffset = uint32(table, at: base + 8, order: order)

                switch tag {
                case 0x0201:
                    jpegOffset = scalarValue(
                        type: type,
                        count: valueCount,
                        inlineData: table,
                        inlineOffset: base + 8,
                        valueOrOffset: valueOrOffset,
                        order: order
                    ).map(UInt64.init)
                case 0x0202:
                    jpegLength = scalarValue(
                        type: type,
                        count: valueCount,
                        inlineData: table,
                        inlineOffset: base + 8,
                        valueOrOffset: valueOrOffset,
                        order: order
                    ).flatMap(Int.init(exactly:))
                case 0x014a:
                    let offsets = try ifdOffsets(
                        handle: handle,
                        fileSize: fileSize,
                        type: type,
                        count: valueCount,
                        inlineData: table,
                        inlineOffset: base + 8,
                        valueOrOffset: valueOrOffset,
                        order: order
                    )
                    pendingIFDs.append(contentsOf: offsets)
                default:
                    break
                }
            }

            if let jpegOffset, let jpegLength,
               jpegLength > 0,
               jpegLength <= 64 * 1_024 * 1_024,
               jpegOffset + UInt64(jpegLength) <= fileSize {
                candidates.append(Candidate(offset: jpegOffset, length: jpegLength))
            }

            let nextOffsetIndex = entryCount * 12
            let nextIFD = UInt64(uint32(table, at: nextOffsetIndex, order: order))
            if nextIFD != 0 { pendingIFDs.append(nextIFD) }
        }

        let validCandidates = Array(Set(candidates))
        let chosen: Candidate?
        switch preference {
        case .thumbnail:
            let useful = validCandidates.filter { $0.length >= 64 * 1_024 }
            chosen = useful.min { $0.length < $1.length }
                ?? validCandidates.max { $0.length < $1.length }
        case .fullSize:
            chosen = validCandidates.max { $0.length < $1.length }
        }

        guard let chosen else { return nil }
        let data = try read(handle, offset: chosen.offset, count: chosen.length)
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else { return nil }
        return data
    }

    private func ifdOffsets(
        handle: FileHandle,
        fileSize: UInt64,
        type: UInt16,
        count: UInt32,
        inlineData: Data,
        inlineOffset: Int,
        valueOrOffset: UInt32,
        order: ByteOrder
    ) throws -> [UInt64] {
        guard type == 4 || type == 13, count > 0, count <= 64 else { return [] }
        let byteCount = Int(count) * 4
        let data: Data
        if byteCount <= 4 {
            data = inlineData.subdata(in: inlineOffset..<(inlineOffset + byteCount))
        } else {
            let offset = UInt64(valueOrOffset)
            guard offset + UInt64(byteCount) <= fileSize else { return [] }
            data = try read(handle, offset: offset, count: byteCount)
        }
        return stride(from: 0, to: byteCount, by: 4).map {
            UInt64(uint32(data, at: $0, order: order))
        }.filter { $0 != 0 }
    }

    private func scalarValue(
        type: UInt16,
        count: UInt32,
        inlineData: Data,
        inlineOffset: Int,
        valueOrOffset: UInt32,
        order: ByteOrder
    ) -> UInt32? {
        guard count == 1 else { return nil }
        switch type {
        case 3:
            return UInt32(uint16(inlineData, at: inlineOffset, order: order))
        case 4, 13:
            return valueOrOffset
        default:
            return nil
        }
    }

    private func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private func uint16(_ data: Data, at offset: Int, order: ByteOrder) -> UInt16 {
        let a = UInt16(data[offset])
        let b = UInt16(data[offset + 1])
        switch order {
        case .littleEndian: return a | (b << 8)
        case .bigEndian: return (a << 8) | b
        }
    }

    private func uint32(_ data: Data, at offset: Int, order: ByteOrder) -> UInt32 {
        let a = UInt32(data[offset])
        let b = UInt32(data[offset + 1])
        let c = UInt32(data[offset + 2])
        let d = UInt32(data[offset + 3])
        switch order {
        case .littleEndian: return a | (b << 8) | (c << 16) | (d << 24)
        case .bigEndian: return (a << 24) | (b << 16) | (c << 8) | d
        }
    }
}
