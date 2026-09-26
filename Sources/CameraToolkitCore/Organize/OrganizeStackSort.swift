import Foundation

/// What a board orders its stacks by. Every key reads only what an
/// `OrganizeStack` already carries in memory — no disk, catalog, or
/// network reads — so sorting an 11k-item board is one pass to build the
/// keys plus one sort. (Camera reads the board's resolved camera through
/// a lookup the caller passes — itself in-memory index work.)
public enum OrganizeSortKey: String, CaseIterable, Identifiable, Sendable {
    /// First frame's capture time — the boards' long-standing order.
    case captureTime
    /// Frames in the stack; a single photo or clip counts 1.
    case burstSize
    /// Bytes on disk, primaries plus companions (RAW+JPEG, XMP, …).
    case fileSize
    /// First frame's file name, Finder-style (numbers compare by value).
    case fileName
    /// RAW, then photo, then video, then other files.
    case fileKind
    /// Seconds from the first frame to the last.
    case burstDuration
    /// The camera that shot the first frame, by name; unknown cameras
    /// sort after every named one.
    case camera

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureTime: "Capture Time"
        case .burstSize: "Burst Size"
        case .fileSize: "File Size"
        case .fileName: "File Name"
        case .fileKind: "File Kind"
        case .burstDuration: "Burst Duration"
        case .camera: "Camera"
        }
    }

    public var symbol: String {
        switch self {
        case .captureTime: "clock"
        case .burstSize: "square.stack.3d.down.right"
        case .fileSize: "internaldrive"
        case .fileName: "textformat"
        case .fileKind: "photo.on.rectangle"
        case .burstDuration: "timer"
        case .camera: "camera"
        }
    }

    /// The direction a key starts in when picked: counts, sizes and
    /// durations lead with the largest, times and names with the first.
    public var defaultAscending: Bool {
        switch self {
        case .captureTime, .fileName, .fileKind, .camera: true
        case .burstSize, .fileSize, .burstDuration: false
        }
    }

    /// The direction choices as the menu words them.
    public func directionTitle(ascending: Bool) -> String {
        switch self {
        case .captureTime: ascending ? "Oldest First" : "Newest First"
        case .burstSize: ascending ? "Fewest Frames First" : "Most Frames First"
        case .fileSize: ascending ? "Smallest First" : "Largest First"
        case .fileName: ascending ? "A to Z" : "Z to A"
        case .fileKind: ascending ? "RAW, Photo, Video" : "Video, Photo, RAW"
        case .burstDuration: ascending ? "Shortest First" : "Longest First"
        case .camera: ascending ? "A to Z" : "Z to A"
        }
    }
}

/// A board's sort: a key and a direction. Ties always fall back to capture
/// time, then file name, then stack id — all ascending — so equal stacks
/// keep one stable order whichever direction the key runs.
public struct OrganizeStackSort: Equatable, Hashable, Sendable {
    public var key: OrganizeSortKey
    public var ascending: Bool

    public init(key: OrganizeSortKey = .captureTime, ascending: Bool? = nil) {
        self.key = key
        self.ascending = ascending ?? key.defaultAscending
    }

    public static let oldestFirst = OrganizeStackSort(key: .captureTime, ascending: true)
    public static let newestFirst = OrganizeStackSort(key: .captureTime, ascending: false)

    /// Short name for the Sort button — "Largest Bursts", "Newest First".
    public var summary: String {
        switch key {
        case .captureTime: ascending ? "Oldest First" : "Newest First"
        case .burstSize: ascending ? "Smallest Bursts" : "Largest Bursts"
        case .fileSize: ascending ? "Smallest Files" : "Largest Files"
        case .fileName: ascending ? "Name A–Z" : "Name Z–A"
        case .fileKind: ascending ? "Kind" : "Kind, Reversed"
        case .burstDuration: ascending ? "Shortest Bursts" : "Longest Bursts"
        case .camera: ascending ? "Camera A–Z" : "Camera Z–A"
        }
    }

    /// The same key with the other direction.
    public var reversed: OrganizeStackSort {
        OrganizeStackSort(key: key, ascending: !ascending)
    }

    /// `stacks` in this order. Keys are read once per stack up front, so
    /// the comparisons themselves never re-walk a burst's frames.
    ///
    /// `cameraName` is the board's resolved camera for a stack (nil when
    /// unknown), asked only by the Camera key; the default reads the
    /// first frame's own camera tags.
    public func sorted(
        _ stacks: [OrganizeStack],
        cameraName: (OrganizeStack) -> String? = { $0.items.first?.metadataCamera?.name }
    ) -> [OrganizeStack] {
        guard stacks.count > 1 else { return stacks }
        let rows = stacks.map { Row(stack: $0, key: key, cameraName: cameraName) }
        let ascending = ascending
        return rows.sorted { lhs, rhs in
            switch lhs.primary.compare(rhs.primary) {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame: return lhs.breaksTieBefore(rhs)
            }
        }.map(\.stack)
    }

    private struct Row {
        let stack: OrganizeStack
        let primary: Value
        let captureDate: Date
        let name: String

        init(stack: OrganizeStack, key: OrganizeSortKey, cameraName: (OrganizeStack) -> String?) {
            self.stack = stack
            captureDate = stack.captureDate
            name = stack.items.first?.primary.name ?? ""
            switch key {
            case .captureTime: primary = .date(captureDate)
            case .burstSize: primary = .integer(Int64(stack.items.count))
            case .fileSize: primary = .integer(stack.byteCount)
            case .fileName: primary = .text(name)
            case .fileKind: primary = .integer(Int64(Self.rank(stack.kind)))
            case .burstDuration: primary = .double(stack.endDate.timeIntervalSince(stack.captureDate))
            case .camera: primary = .camera(cameraName(stack))
            }
        }

        static func rank(_ kind: OrganizeMediaKind) -> Int {
            switch kind {
            case .raw: 0
            case .photo: 1
            case .video: 2
            case .other: 3
            }
        }

        func breaksTieBefore(_ other: Row) -> Bool {
            if captureDate != other.captureDate {
                return captureDate < other.captureDate
            }
            switch name.localizedStandardCompare(other.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return stack.id < other.stack.id
            }
        }
    }

    private enum Value {
        case date(Date)
        case integer(Int64)
        case double(Double)
        case text(String)
        /// A camera name; nil (unknown) is greater than every name.
        case camera(String?)

        func compare(_ other: Value) -> ComparisonResult {
            switch (self, other) {
            case let (.date(lhs), .date(rhs)): Self.order(lhs, rhs)
            case let (.integer(lhs), .integer(rhs)): Self.order(lhs, rhs)
            case let (.double(lhs), .double(rhs)): Self.order(lhs, rhs)
            case let (.text(lhs), .text(rhs)): lhs.localizedStandardCompare(rhs)
            case let (.camera(lhs?), .camera(rhs?)): lhs.localizedStandardCompare(rhs)
            case (.camera(.some), .camera(.none)): .orderedAscending
            case (.camera(.none), .camera(.some)): .orderedDescending
            default: .orderedSame
            }
        }

        static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
            lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
        }
    }
}
