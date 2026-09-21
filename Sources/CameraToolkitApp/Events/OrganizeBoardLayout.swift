import CameraToolkitCore
import Foundation

/// How a board draws its stacks: the classic tile grid or a denser
/// file-list of rows.
enum OrganizeBoardMode: String, CaseIterable, Identifiable, Sendable {
    case tiles
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiles: "Tiles"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .tiles: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

/// What the board's collapsible sections group by.
enum OrganizeBoardGrouping: String, CaseIterable, Identifiable, Sendable {
    case day
    case folder
    case kind
    case event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .folder: "Folder"
        case .kind: "Kind"
        case .event: "Event"
        }
    }

    var symbol: String {
        switch self {
        case .day: "calendar"
        case .folder: "folder"
        case .kind: "square.stack.3d.up"
        case .event: "rectangle.stack"
        }
    }
}

/// Stack order inside a group (and, for day/folder groups, the group order).
enum OrganizeBoardOrder: String, CaseIterable, Identifiable, Sendable {
    case oldestFirst
    case newestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldestFirst: "Oldest First"
        case .newestFirst: "Newest First"
        }
    }
}

/// Which event bucket a stack lands in when grouping by event.
struct OrganizeEventBucket: Equatable, Sendable {
    var key: String
    var title: String
    var date: Date

    static let unsorted = OrganizeEventBucket(key: "unsorted", title: "Not Sorted Yet", date: .distantPast)
    static let mixed = OrganizeEventBucket(key: "mixed", title: "Mixed Events", date: .distantPast)
}

/// One collapsible section of a board.
struct OrganizeBoardGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var symbol: String?
    var stacks: [OrganizeStack]

    var frameCount: Int { stacks.reduce(0) { $0 + $1.items.count } }
    var byteCount: Int64 { stacks.reduce(Int64(0)) { $0 + $1.byteCount } }
    var subtitle: String {
        "\(stacks.count) item\(stacks.count == 1 ? "" : "s") · \(frameCount) frame\(frameCount == 1 ? "" : "s") · \(byteCount.formattedBytes)"
    }
}

enum OrganizeBoardPlan {
    /// Builds the board's collapsible groups. `eventBucket` is only consulted
    /// for `.event` grouping; nil buckets collect under "Not Sorted Yet".
    static func groups(
        for stacks: [OrganizeStack],
        grouping: OrganizeBoardGrouping,
        order: OrganizeBoardOrder,
        rootPath: String? = nil,
        eventBucket: (OrganizeStack) -> OrganizeEventBucket? = { _ in nil }
    ) -> [OrganizeBoardGroup] {
        let ascending = order == .oldestFirst
        let sortStacks: ([OrganizeStack]) -> [OrganizeStack] = { stacks in
            stacks.sorted { lhs, rhs in
                if lhs.captureDate != rhs.captureDate {
                    return ascending ? lhs.captureDate < rhs.captureDate : lhs.captureDate > rhs.captureDate
                }
                return lhs.id < rhs.id
            }
        }

        switch grouping {
        case .day:
            let days = OrganizeStacker.days(for: stacks)
            let ordered = ascending ? days : days.reversed()
            return ordered.map { day in
                OrganizeBoardGroup(
                    id: "day|\(day.id)",
                    title: day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
                    symbol: "calendar",
                    stacks: ascending ? day.stacks : day.stacks.reversed()
                )
            }

        case .folder:
            var byFolder: [String: [OrganizeStack]] = [:]
            for stack in stacks {
                let title = OrganizeFolderLabel.title(
                    forFolderPath: stack.coverItem.primary.folderPath,
                    rootPath: rootPath
                )
                byFolder[title, default: []].append(stack)
            }
            let titles = byFolder.keys.sorted {
                $0.localizedStandardCompare($1) == (ascending ? .orderedAscending : .orderedDescending)
            }
            return titles.map { title in
                OrganizeBoardGroup(
                    id: "folder|\(title)",
                    title: title,
                    symbol: "folder",
                    stacks: sortStacks(byFolder[title] ?? [])
                )
            }

        case .kind:
            let buckets: [(key: String, title: String, symbol: String, match: (OrganizeStack) -> Bool)] = [
                ("burst", "Bursts", "square.stack.3d.down.right.fill", { $0.isBurst }),
                ("video", "Videos", "video.fill", { !$0.isBurst && $0.kind == .video }),
                ("photo", "Photos", "photo", { !$0.isBurst && ($0.kind == .raw || $0.kind == .photo) }),
                ("other", "Other Files", "doc", { !$0.isBurst && $0.kind == .other })
            ]
            return buckets.compactMap { bucket in
                let members = sortStacks(stacks.filter(bucket.match))
                guard !members.isEmpty else { return nil }
                return OrganizeBoardGroup(
                    id: "kind|\(bucket.key)",
                    title: bucket.title,
                    symbol: bucket.symbol,
                    stacks: members
                )
            }

        case .event:
            var unsorted: [OrganizeStack] = []
            var mixed: [OrganizeStack] = []
            var byKey: [String: (bucket: OrganizeEventBucket, stacks: [OrganizeStack])] = [:]
            for stack in stacks {
                switch eventBucket(stack) {
                case .none:
                    unsorted.append(stack)
                case .some(let bucket) where bucket.key == OrganizeEventBucket.mixed.key:
                    mixed.append(stack)
                case .some(let bucket):
                    byKey[bucket.key, default: (bucket, [])].stacks.append(stack)
                }
            }
            var groups: [OrganizeBoardGroup] = []
            if !unsorted.isEmpty {
                groups.append(OrganizeBoardGroup(
                    id: "event|\(OrganizeEventBucket.unsorted.key)",
                    title: OrganizeEventBucket.unsorted.title,
                    symbol: "questionmark.folder",
                    stacks: sortStacks(unsorted)
                ))
            }
            if !mixed.isEmpty {
                groups.append(OrganizeBoardGroup(
                    id: "event|\(OrganizeEventBucket.mixed.key)",
                    title: OrganizeEventBucket.mixed.title,
                    symbol: "square.split.2x1",
                    stacks: sortStacks(mixed)
                ))
            }
            let eventGroups = byKey.values.sorted { lhs, rhs in
                if lhs.bucket.date != rhs.bucket.date {
                    return ascending ? lhs.bucket.date < rhs.bucket.date : lhs.bucket.date > rhs.bucket.date
                }
                return lhs.bucket.title.localizedStandardCompare(rhs.bucket.title) == .orderedAscending
            }
            groups.append(contentsOf: eventGroups.map { entry in
                OrganizeBoardGroup(
                    id: "event|\(entry.bucket.key)",
                    title: entry.bucket.title,
                    symbol: "rectangle.stack",
                    stacks: sortStacks(entry.stacks)
                )
            })
            return groups
        }
    }
}

/// Short, readable path labels for source → destination diagrams. A path
/// like `/Volumes/A7V/DCIM/Transfer 1` renders as `A7V ▸ DCIM ▸ Transfer 1`;
/// paths under the home folder start with `~`. These are display strings —
/// all move/copy logic keeps working on the full paths.
enum OrganizeRouteLabel {
    static func breadcrumb(for path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        var components = standardized.split(separator: "/").map(String.init)
        if components.first == "Volumes", components.count > 1 {
            components = Array(components.dropFirst())
        } else {
            let home = NSHomeDirectory()
            if standardized.hasPrefix(home + "/") {
                let rest = standardized.dropFirst(home.count + 1).split(separator: "/").map(String.init)
                components = ["~"] + rest
            }
        }
        return components.isEmpty ? standardized : components.joined(separator: " ▸ ")
    }

    /// `path` relative to `root`, as a breadcrumb — e.g. the "Sony A7V ▸ Card
    /// Copy" tail of a file's destination inside an event folder. Empty when
    /// the path is the root itself; the full breadcrumb when outside it.
    static func subpath(of path: String, under root: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        guard standardizedPath != standardizedRoot else { return "" }
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else { return breadcrumb(for: path) }
        return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
            .split(separator: "/")
            .joined(separator: " ▸ ")
    }
}
