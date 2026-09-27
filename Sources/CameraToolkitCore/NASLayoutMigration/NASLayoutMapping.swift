import Foundation

/// The reviewed input of a NAS layout migration: which legacy archive event
/// folder becomes which mirror event folder. The planner never guesses an
/// event's name or date — every folder it touches is listed here.
///
/// ```json
/// {
///   "format": "camera-toolkit-nas-layout-mapping",
///   "version": 1,
///   "legacyRoot": "/Volumes/Share/Media/Camera/Originals",
///   "mirrorRoot": "/Volumes/Share/Media/Camera",
///   "events": [
///     { "source": "2026/2026-07-01 Trip", "destination": "2026/2026-07-01 Trip",
///       "eventID": "…optional catalog event id…" }
///   ],
///   "cameraNames": { "Custom-Cam": "Custom Cam" }
/// }
/// ```
///
/// `source` is relative to `legacyRoot` (default: the library root's
/// `Originals`), `destination` to `mirrorRoot` (default: the configured NAS
/// mirror root). A subevent is its own entry; its source folder inside a
/// mapped parent is then left to that entry.
///
/// **Per-file mode** (`files` set, `events` empty): a reviewed CSV names
/// every file — `library/<source> → mirrorRoot/<destination>`, or no
/// destination for a file that stays. `source` is then relative to the
/// library root itself (`legacyRoot` defaults to it). `eventRenames` renames
/// catalog events first so the app computes the new NAS folders, and
/// `boundaries` names datasets or shares below the library that a rename
/// cannot cross.
public struct NASLayoutMapping: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-nas-layout-mapping"
    public static let currentVersion = 1

    public struct Event: Codable, Equatable, Hashable, Sendable {
        public var source: String
        public var destination: String
        /// Optional: the catalog event these files belong to. Its
        /// assignments say which subfolder under `Originals/<Camera>` each
        /// file had on the drive — the path the legacy archive flattened
        /// away — so those files (and their same-named sidecars) land where
        /// presence looks for them. Without it every file lands flat.
        public var eventID: UUID?

        public init(source: String, destination: String, eventID: UUID? = nil) {
            self.source = source
            self.destination = destination
            self.eventID = eventID
        }
    }

    /// One row of a per-file mapping.
    public struct FileEntry: Codable, Equatable, Hashable, Sendable {
        /// Relative to the library root.
        public var source: String
        /// The size the reviewed inventory saw; a different size on the NAS
        /// is a blocker (the CSV is stale).
        public var byteCount: Int64
        /// Relative to the mirror root; nil leaves the file where it is.
        public var destination: String?

        public init(source: String, byteCount: Int64, destination: String?) {
            self.source = source
            self.byteCount = byteCount
            self.destination = destination
        }
    }

    /// A catalog event renamed before its files move, so the app's
    /// `<yyyy-MM-dd> <name>` folder is the one the files land in.
    public struct EventRename: Codable, Equatable, Hashable, Sendable {
        /// The event's id, or its exact current name.
        public var event: String
        public var name: String

        public init(event: String, name: String) {
            self.event = event
            self.name = name
        }
    }

    public var format: String
    public var version: Int
    public var legacyRoot: String?
    public var mirrorRoot: String?
    public var events: [Event]
    /// Extra camera-folder spellings → names, checked before the built-in
    /// table. Keys match case- and separator-insensitively.
    public var cameraNames: [String: String]?
    /// Per-file mode: every file of the reviewed CSV.
    public var files: [FileEntry]?
    /// SHA-256 of the CSV the files came from.
    public var fileMappingDigest: String?
    public var eventRenames: [EventRename]?
    /// Library-relative folders that are their own dataset or share: no
    /// rename may cross into or out of one.
    public var boundaries: [String]?

    public var isFileMode: Bool { files != nil }

    public init(
        legacyRoot: String? = nil,
        mirrorRoot: String? = nil,
        events: [Event],
        cameraNames: [String: String]? = nil,
        files: [FileEntry]? = nil,
        fileMappingDigest: String? = nil,
        eventRenames: [EventRename]? = nil,
        boundaries: [String]? = nil
    ) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.legacyRoot = legacyRoot
        self.mirrorRoot = mirrorRoot
        self.events = events
        self.cameraNames = cameraNames
        self.files = files
        self.fileMappingDigest = fileMappingDigest
        self.eventRenames = eventRenames
        self.boundaries = boundaries
    }

    /// A per-file mapping from a reviewed CSV: a header row, then
    /// `current_path, bytes, class, proposed_path[, note]` — paths relative
    /// to the library (`current_path`) and the mirror root
    /// (`proposed_path`); an empty proposed path means "leave in place".
    public static func readFileMapping(
        csv url: URL,
        legacyRoot: String? = nil,
        mirrorRoot: String? = nil,
        eventRenames: [EventRename] = [],
        boundaries: [String] = []
    ) throws -> NASLayoutMapping {
        let data = try Data(contentsOf: url)
        let rows = try CSVRows.parse(String(decoding: data, as: UTF8.self))
        guard let header = rows.first, header.count >= 4, header[0].lowercased().hasPrefix("current_path"),
              header[1].lowercased().hasPrefix("bytes"), header[3].lowercased().hasPrefix("proposed_path") else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) does not start with the header current_path, bytes, class, proposed_path.")
        }
        var files: [FileEntry] = []
        files.reserveCapacity(rows.count)
        for (index, row) in rows.dropFirst().enumerated() {
            if row.count == 1, row[0].isEmpty { continue }
            guard row.count >= 4, let bytes = Int64(row[1]) else {
                throw ToolkitError.commandFailed("\(url.lastPathComponent) row \(index + 2) is not current_path, bytes, class, proposed_path.")
            }
            let destination = row[3].trimmingCharacters(in: .whitespaces).isEmpty ? nil : row[3]
            files.append(FileEntry(source: row[0], byteCount: bytes, destination: destination))
        }
        return NASLayoutMapping(
            legacyRoot: legacyRoot,
            mirrorRoot: mirrorRoot,
            events: [],
            files: files,
            fileMappingDigest: LayoutMigrationHash.sha256(data),
            eventRenames: eventRenames.isEmpty ? nil : eventRenames,
            boundaries: boundaries.isEmpty ? nil : boundaries
        )
    }

    public static func read(_ url: URL) throws -> NASLayoutMapping {
        let data = try Data(contentsOf: url)
        let mapping = try JSONDecoder().decode(NASLayoutMapping.self, from: data)
        guard mapping.format == formatName else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not a NAS layout mapping (format must be \(formatName)).")
        }
        guard mapping.version == currentVersion else {
            throw ToolkitError.commandFailed("The mapping is version \(mapping.version); this build reads version \(currentVersion).")
        }
        return mapping
    }

    /// Problems that make the mapping unusable, each naming its entry.
    public func problems() -> [String] {
        var problems: [String] = []
        var sources = Set<String>()
        var destinations = Set<String>()
        for (index, event) in events.enumerated() {
            let label = "events[\(index)]"
            for (field, value) in [("source", event.source), ("destination", event.destination)] {
                if !EventStorageLocations.isLexicallyClean(value) || (try? PathSafety.validateRelativePath(value)) == nil {
                    problems.append("\(label).\(field) \"\(value)\" is not a clean relative path.")
                }
            }
            if !sources.insert(event.source.lowercased()).inserted {
                problems.append("\(label).source \"\(event.source)\" is listed twice.")
            }
            if !destinations.insert(event.destination.lowercased()).inserted {
                problems.append("\(label).destination \"\(event.destination)\" is listed twice.")
            }
        }
        if let files {
            if !events.isEmpty { problems.append("A per-file mapping cannot also list events.") }
            problems += Self.fileProblems(files)
        }
        for (index, rename) in (eventRenames ?? []).enumerated() {
            let validation = EventNamePolicy.validate(rename.name)
            if !validation.isValid || validation.normalizedName != rename.name {
                problems.append("eventRenames[\(index)] \"\(rename.name)\" is not a valid event name\(validation.errorMessage.map { ": \($0)" } ?? ".")")
            }
        }
        for boundary in boundaries ?? [] where !EventStorageLocations.isLexicallyClean(boundary) {
            problems.append("The boundary \"\(boundary)\" is not a clean relative path.")
        }
        return problems
    }

    /// Row-level problems of a per-file mapping: unclean paths, a source or
    /// a destination listed twice (compared case-insensitively, as SMB
    /// does), a destination that is some row's source or runs through one,
    /// and a destination inside a top-level folder that holds sources (the
    /// legacy tree) — each would make one rename depend on another.
    /// Messages are capped; the count is always given.
    static func fileProblems(_ files: [FileEntry]) -> [String] {
        var problems: [String] = []
        var extra = 0
        func add(_ message: String) {
            if problems.count < 40 { problems.append(message) } else { extra += 1 }
        }
        var sources = Set<String>()
        var destinations: [String: String] = [:]
        for file in files {
            if !EventStorageLocations.isLexicallyClean(file.source) || (try? PathSafety.validateRelativePath(file.source)) == nil {
                add("\"\(file.source)\" is not a clean relative path.")
            }
            if !sources.insert(file.source.lowercased()).inserted {
                add("\"\(file.source)\" is listed twice.")
            }
            guard let destination = file.destination else { continue }
            if !EventStorageLocations.isLexicallyClean(destination) || (try? PathSafety.validateRelativePath(destination)) == nil {
                add("\(file.source): the destination \"\(destination)\" is not a clean relative path.")
            }
            if let other = destinations.updateValue(file.source, forKey: destination.lowercased()) {
                add("\(file.source) and \(other) both go to \(destination) (names compare case-insensitively on SMB).")
            }
        }
        let areas = Set(files.compactMap { $0.source.contains("/") ? $0.source.split(separator: "/").first.map { $0.lowercased() } : nil })
        for file in files {
            guard let destination = file.destination else { continue }
            let lower = destination.lowercased()
            let parts = lower.split(separator: "/").map(String.init)
            if sources.contains(lower) {
                add("\(file.source): the destination \(destination) is another row's source; renames would depend on their order.")
            }
            if parts.count > 1, (1..<parts.count).contains(where: { sources.contains(parts[..<$0].joined(separator: "/")) }) {
                add("\(file.source): the destination \(destination) runs through a source file.")
            }
            if let first = parts.first, areas.contains(first) {
                add("\(file.source): the destination \(destination) lies inside the legacy tree (\(first)/ holds sources).")
            }
        }
        if extra > 0 { problems.append("… and \(extra) more problem(s) in the file mapping.") }
        return problems
    }
}

/// Legacy NAS camera-folder names → the drive's camera names.
public enum NASCameraNames {
    /// `"Sony-A7V"` → `"sony a7v"`: lower case, `-`/`_` as spaces, single spaces.
    static func key(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Every spelling the legacy archive and the drive used.
    static let builtIn: [String: String] = [
        "sony a7v": "Sony A7V",
        "sony a7 v": "Sony A7V",
        "ilce 7m5": "Sony A7V",
        "dji osmo 360": "Osmo 360",
        "osmo 360": "Osmo 360",
        "osmo360": "Osmo 360",
        "dji nano": "Osmo Nano",
        "dji osmo nano": "Osmo Nano",
        "osmo nano": "Osmo Nano",
        "dji mini 2": "DJI Mini 2",
        "mini 2": "DJI Mini 2",
        "action 6": "Osmo Action 6",
        "dji action 6": "Osmo Action 6",
        "osmo action 6": "Osmo Action 6",
        "dji osmo action 6": "Osmo Action 6",
        "iphone": "iPhone",
    ]

    /// The camera folder name, and whether it was recognized. An unknown
    /// name is kept verbatim (and reported by the planner).
    public static func normalized(_ name: String, extra: [String: String]? = nil) -> (name: String, known: Bool) {
        let key = key(name)
        if let extra, let hit = extra.first(where: { Self.key($0.key) == key })?.value {
            return (hit, true)
        }
        if let hit = builtIn[key] { return (hit, true) }
        return (name, false)
    }

    /// The legacy archive's per-camera media folders, flattened into
    /// `Originals/<Camera>/`.
    public static let mediaFolders: Set<String> = ["raw", "jpeg", "jpg", "video", "camera support", "photos", "saved clips", "audio"]

    public static func isMediaFolder(_ name: String) -> Bool {
        mediaFolders.contains(name.lowercased())
    }
}


/// A minimal RFC 4180 reader: quoted fields may hold commas, quotes (`""`)
/// and line breaks; `\r\n` and `\n` both end a row.
enum CSVRows {
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending { pending = nil; return scalar }
            return iterator.next()
        }
        var atFieldStart = true
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case ",":
                row.append(field)
                field = ""
                atFieldStart = true
            case "\r":
                continue
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                atFieldStart = true
            default:
                field.unicodeScalars.append(scalar)
                atFieldStart = false
            }
        }
        if quoted { throw ToolkitError.commandFailed("The CSV ends inside a quoted field.") }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
