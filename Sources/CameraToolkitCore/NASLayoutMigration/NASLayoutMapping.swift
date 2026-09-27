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

    public var format: String
    public var version: Int
    public var legacyRoot: String?
    public var mirrorRoot: String?
    public var events: [Event]
    /// Extra camera-folder spellings → names, checked before the built-in
    /// table. Keys match case- and separator-insensitively.
    public var cameraNames: [String: String]?

    public init(
        legacyRoot: String? = nil,
        mirrorRoot: String? = nil,
        events: [Event],
        cameraNames: [String: String]? = nil
    ) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.legacyRoot = legacyRoot
        self.mirrorRoot = mirrorRoot
        self.events = events
        self.cameraNames = cameraNames
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
