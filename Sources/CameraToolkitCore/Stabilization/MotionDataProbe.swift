import Foundation

/// Where a clip's gyro data comes from, as far as its tracks say.
public enum MotionDataSource: String, Sendable, Equatable {
    /// Sony's real-time metadata track (`rtmd`): gyro, accelerometer and
    /// lens data (A7-series, FX-series).
    case sony
    /// DJI's metadata track (`djmd`, or the older `dbgi`): Osmo Action,
    /// Osmo Nano, Avata.
    case dji
    /// GoPro's `gpmd` telemetry.
    case gopro
    /// The `camm` camera-motion track some phones and 360 cameras write.
    case camm

    public var displayName: String {
        switch self {
        case .sony: "Sony"
        case .dji: "DJI"
        case .gopro: "GoPro"
        case .camm: "camera"
        }
    }
}

/// The answer to "can this clip be stabilized from its own motion data".
public enum MotionDataAvailability: Equatable, Sendable {
    case present(MotionDataSource)
    case absent
    /// The file could not be read (offline, not an MP4/MOV, too big a
    /// header): the stabilizer may still find something.
    case unknown(String)

    public var isPresent: Bool {
        if case .present = self { return true }
        return false
    }

    /// The panel's line when the toggle has to stay off.
    public var problem: String? {
        switch self {
        case .present: nil
        case .absent: "No motion data in this file"
        case .unknown(let reason): reason
        }
    }
}

/// A cheap probe: reads only the movie header (`moov`, by seeking over the
/// media) and looks for a metadata track Gyroflow reads. It never decodes
/// video and never writes.
public enum MotionDataProbe {
    /// A header bigger than this is not read (a real one is a few MB).
    public static let maximumHeaderBytes: UInt64 = 64 * 1024 * 1024

    static let sampleEntryTypes: [String: MotionDataSource] = [
        "rtmd": .sony,
        "djmd": .dji,
        "dbgi": .dji,
        "gpmd": .gopro,
        "camm": .camm,
    ]

    public static func probe(_ url: URL) -> MotionDataAvailability {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unknown("This file can’t be read right now")
        }
        defer { try? handle.close() }
        guard let moov = readTopLevelBox("moov", from: handle) else {
            return .unknown("Not an MP4 or MOV movie this app can look inside")
        }
        let types = sampleEntryTypes(inMovie: moov)
        for type in ["rtmd", "djmd", "dbgi", "gpmd", "camm"] where types.contains(type) {
            return .present(sampleEntryTypes[type]!)
        }
        return .absent
    }

    /// The four-character sample entry types of every track in `moov`.
    public static func sampleEntryTypes(inMovie moov: Data) -> Set<String> {
        var found: Set<String> = []
        walk(moov, path: []) { path, type, payload in
            guard type == "stsd", payload.count >= 8 else { return }
            var offset = payload.startIndex + 8 // version/flags, entry count
            while offset + 8 <= payload.endIndex {
                let size = Int(readUInt32(payload, at: offset))
                let entryType = fourCC(payload, at: offset + 4)
                found.insert(entryType)
                guard size >= 8 else { break }
                offset += size
            }
        }
        return found
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf"]

    private static func walk(_ data: Data, path: [String], visit: ([String], String, Data) -> Void) {
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            var size = UInt64(readUInt32(data, at: offset))
            let type = fourCC(data, at: offset + 4)
            var header = 8
            if size == 1, offset + 16 <= data.endIndex {
                size = readUInt64(data, at: offset + 8)
                header = 16
            } else if size == 0 {
                size = UInt64(data.endIndex - offset)
            }
            guard size >= UInt64(header), offset + Int(size) <= data.endIndex else { break }
            let payload = data[(offset + header)..<(offset + Int(size))]
            visit(path, type, payload)
            if containers.contains(type) {
                walk(Data(payload), path: path + [type], visit: visit)
            }
            offset += Int(size)
        }
    }

    /// Seeks box by box through the top level until `type`, then reads it.
    static func readTopLevelBox(_ type: String, from handle: FileHandle) -> Data? {
        var offset: UInt64 = 0
        let end = (try? handle.seekToEnd()) ?? 0
        for _ in 0..<64 {
            guard offset + 8 <= end else { return nil }
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            var size = UInt64(readUInt32(header, at: header.startIndex))
            let boxType = fourCC(header, at: header.startIndex + 4)
            var headerSize: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = readUInt64(header, at: header.startIndex + 8)
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize else { return nil }
            if boxType == type {
                guard size - headerSize <= maximumHeaderBytes else { return nil }
                try? handle.seek(toOffset: offset + headerSize)
                return try? handle.read(upToCount: Int(size - headerSize))
            }
            offset += size
        }
        return nil
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }
}
