import Foundation

/// What a board orders its stacks by. Every key reads only what an
/// `OrganizeStack` already carries in memory — no disk, catalog, or
/// network reads — so sorting an 11k-item board is one pass to build the
/// keys plus one sort.
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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureTime: "Capture Time"
        case .burstSize: "Burst Size"
        case .fileSize: "File Size"
        case .fileName: "File Name"
        case .fileKind: "File Kind"
        case .burstDuration: "Burst Duration"
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
        }
    }

    /// The direction a key starts in when picked: counts, sizes and
    /// durations lead with the largest, times and names with the first.
    public var defaultAscending: Bool {
        switch self {
        case .captureTime, .fileName, .fileKind: true
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
        }
    }

    /// The same key with the other direction.
    public var reversed: OrganizeStackSort {
        OrganizeStackSort(key: key, ascending: !ascending)
    }

    /// `stacks` in this order. Keys are read once per stack up front, so
    /// the comparisons themselves never re-walk a burst's frames.
    public func sorted(_ stacks: [OrganizeStack]) -> [OrganizeStack] {
        guard stacks.count > 1 else { return stacks }
        let rows = stacks.map { Row(stack: $0, key: key) }
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

        init(stack: OrganizeStack, key: OrganizeSortKey) {
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

        func compare(_ other: Value) -> ComparisonResult {
            switch (self, other) {
            case let (.date(lhs), .date(rhs)): Self.order(lhs, rhs)
            case let (.integer(lhs), .integer(rhs)): Self.order(lhs, rhs)
            case let (.double(lhs), .double(rhs)): Self.order(lhs, rhs)
            case let (.text(lhs), .text(rhs)): lhs.localizedStandardCompare(rhs)
            default: .orderedSame
            }
        }

        static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
            lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
        }
    }
}
