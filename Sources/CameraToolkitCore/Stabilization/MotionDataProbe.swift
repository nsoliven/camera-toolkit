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
        guard let types = sampleEntryTypes(inMovie: moov) else {
            return .unknown("This movie's header is damaged")
        }
        for type in ["rtmd", "djmd", "dbgi", "gpmd", "camm"] where types.contains(type) {
            return .present(sampleEntryTypes[type]!)
        }
        return .absent
    }

    /// The four-character sample entry types of every track in `moov`, or
    /// nil when a box size does not fit (a damaged or crafted header).
    public static func sampleEntryTypes(inMovie moov: Data) -> Set<String>? {
        var found: Set<String> = []
        var malformed = false
        walk(moov, malformed: &malformed) { type, payload in
            guard type == "stsd" else { return true }
            guard payload.count >= 8 else { return false }
            var offset = payload.startIndex + 8 // version/flags, entry count
            while payload.endIndex - offset >= 8 {
                let size = Int(readUInt32(payload, at: offset))
                found.insert(fourCC(payload, at: offset + 4))
                guard size >= 8, size <= payload.endIndex - offset else { return false }
                offset += size
            }
            return true
        }
        return malformed ? nil : found
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf"]

    /// Visits every box, descending into containers. Sizes are checked
    /// before any arithmetic: a size that does not fit what is left marks
    /// the header malformed and stops. `visit` answers false for a payload
    /// it could not read.
    private static func walk(_ data: Data, depth: Int = 0, malformed: inout Bool, visit: (String, Data) -> Bool) {
        guard depth < 16 else { malformed = true; return }
        var offset = data.startIndex
        while data.endIndex - offset >= 8 {
            let remaining = UInt64(data.endIndex - offset)
            var size = UInt64(readUInt32(data, at: offset))
            let type = fourCC(data, at: offset + 4)
            var header: UInt64 = 8
            if size == 1 {
                guard remaining >= 16 else { malformed = true; return }
                size = readUInt64(data, at: offset + 8)
                header = 16
            } else if size == 0 {
                size = remaining
            }
            guard size >= header, size <= remaining else { malformed = true; return }
            let payload = data[(offset + Int(header))..<(offset + Int(size))]
            if !visit(type, payload) { malformed = true; return }
            if containers.contains(type) {
                walk(Data(payload), depth: depth + 1, malformed: &malformed, visit: visit)
                if malformed { return }
            }
            offset += Int(size)
        }
    }

    /// Seeks box by box through the top level until `type`, then reads it.
    /// Nil when it is not there, too big, or a size does not add up.
    static func readTopLevelBox(_ type: String, from handle: FileHandle) -> Data? {
        var offset: UInt64 = 0
        let end = (try? handle.seekToEnd()) ?? 0
        for _ in 0..<64 {
            guard end >= 8, offset <= end - 8 else { return nil }
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            var size = UInt64(readUInt32(header, at: header.startIndex))
            let boxType = fourCC(header, at: header.startIndex + 4)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = readUInt64(header, at: header.startIndex + 8)
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, size <= end - offset else { return nil }
            if boxType == type {
                guard size - headerSize <= maximumHeaderBytes else { return nil }
                try? handle.seek(toOffset: offset + headerSize)
                return try? handle.read(upToCount: Int(size - headerSize))
            }
            let (next, overflow) = offset.addingReportingOverflow(size)
            guard !overflow else { return nil }
            offset = next
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
