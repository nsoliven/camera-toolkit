import Foundation

/// One place an event's originals can live, reduced to the root folder the
/// app would look under: the Buffer, private staging, the NAS library, or a
/// card/unsorted source.
public struct EventStoragePlace: Hashable, Sendable {
    public enum Role: Int, Comparable, Sendable {
        case buffer
        case privateStaging
        case nas
        case card

        public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .buffer: "Buffer"
            case .privateStaging: "Private staging"
            case .nas: "NAS"
            case .card: "Card"
            }
        }

        /// What the owner does to bring this place back.
        var remedy: String {
            switch self {
            case .buffer: "plug in the Buffer"
            case .privateStaging: "plug in the private staging drive"
            case .nas: "connect to the NAS"
            case .card: "insert the card"
            }
        }
    }

    public var role: Role
    public var root: URL
    /// True for places the event's own policy points at — the ones worth
    /// naming when they are missing. The other drive is still checked (a
    /// file can sit on either), but it is not what the owner plugs in.
    public var isPrimary: Bool

    public init(role: Role, root: URL, isPrimary: Bool) {
        self.role = role
        self.root = root.standardizedFileURL
        self.isPrimary = isPrimary
    }

    /// `/Volumes/<name>` when the place lives on an external or network volume.
    public var volumeRoot: URL? { VolumeInfo.volumeRoot(for: root) }

    /// "Buffer (Buffer)" — the volume name the owner sees in Finder,
    /// plus which role it plays for this event.
    public var displayName: String {
        let name = volumeRoot?.lastPathComponent ?? root.lastPathComponent
        return "\(name) (\(role.label))"
    }
}

public enum EventPlaceState: Sendable, Equatable {
    /// The root answered and exists.
    case reachable
    /// The volume is up (or the path is local) but the root folder is not there.
    case missing
    /// The place's `/Volumes/<name>` is not in the mount table.
    case notMounted
    /// The volume is mounted but did not answer within the timeout — a hung
    /// SMB share, or a drive spinning up.
    case notResponding

    public var isOffline: Bool { self == .notMounted || self == .notResponding }
}

/// The cheap answer to "can this event's board load at all?", computed
/// before any per-file work: the mount table first, then one bounded stat
/// per place root, off the caller's thread.
public struct EventReachabilityReport: Sendable, Equatable {
    public var states: [EventStoragePlace: EventPlaceState]
    /// Mounted `/Volumes/<name>` paths that did not answer in time. The
    /// presence sweep treats them as unmounted so no per-file stat can hang
    /// behind them.
    public var unresponsiveVolumes: Set<String>

    public init(states: [EventStoragePlace: EventPlaceState], unresponsiveVolumes: Set<String>) {
        self.states = states
        self.unresponsiveVolumes = unresponsiveVolumes
    }

    public var anyReachable: Bool { states.values.contains(.reachable) }

    /// Every offline place, one per volume, primary places first, in role
    /// order. Places that are not the event's own policy drive are named
    /// only when no primary place is offline.
    public var offlinePlaces: [EventStoragePlace] {
        let offline = states.filter { $0.value.isOffline }.map(\.key)
        let primary = offline.filter(\.isPrimary)
        let named = primary.isEmpty ? offline : primary
        var seen = Set<String>()
        return named
            .sorted { ($0.role, $0.root.path) < ($1.role, $1.root.path) }
            .filter { seen.insert(($0.volumeRoot ?? $0.root).path).inserted }
    }

    /// Nothing the board could read is reachable and at least one place is
    /// offline: the board's terminal answer is "plug something in", not a
    /// spinner.
    public var isOffline: Bool { !anyReachable && !offlinePlaces.isEmpty }

    /// "Buffer (Buffer), Photos (NAS)".
    public var offlineList: String {
        offlinePlaces.map(\.displayName).formatted(.list(type: .and))
    }

    /// "Plug in the Buffer or connect to the NAS to see the photos."
    public var remedySentence: String {
        var remedies: [String] = []
        for place in offlinePlaces where !remedies.contains(place.role.remedy) {
            remedies.append(place.role.remedy)
        }
        guard !remedies.isEmpty else { return "" }
        let joined = remedies.formatted(.list(type: .or))
        return joined.prefix(1).uppercased() + joined.dropFirst() + " to see the photos."
    }
}

public enum EventReachability {
    /// Answers whether one place root exists. Runs off the caller's thread
    /// and is abandoned (not awaited) after the timeout, so a hung share
    /// costs a parked worker thread, never the caller.
    public typealias ResponseProbe = @Sendable (URL) -> Bool

    public static let defaultTimeout: TimeInterval = 1.5

    /// The places an event family's files can live: each member's policy
    /// drive (primary), the other drive, the NAS library, and one entry per
    /// distinct source root the assignments came from.
    public static func places(
        members: [SavedCameraEvent],
        assignments: [PhotoEventAssignment],
        locations: EventStorageLocations
    ) -> [EventStoragePlace] {
        let policies = Set(members.map { locations.resolvedPolicy(for: $0) })
        var places: [EventStoragePlace] = [
            EventStoragePlace(role: .buffer, root: locations.bufferRoot, isPrimary: policies.contains(.buffer)),
            EventStoragePlace(role: .privateStaging, root: locations.privateStagingRoot, isPrimary: policies.contains(.archiveOnly)),
            EventStoragePlace(role: .nas, root: locations.nasRoot, isPrimary: true),
        ]
        var sourceRoots = Set<String>()
        for assignment in assignments {
            sourceRoots.insert(assignment.sourceRootPath)
        }
        // One source per volume is enough to answer "is that card in?";
        // local folders are each their own place.
        var seenVolumes = Set<String>()
        for path in sourceRoots.sorted() {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            let key = VolumeInfo.volumeRoot(for: url)?.path ?? url.standardizedFileURL.path
            guard seenVolumes.insert(key).inserted else { continue }
            places.append(EventStoragePlace(role: .card, root: url, isPrimary: true))
        }
        return places
    }

    /// Classifies every place. Unmounted `/Volumes/<name>` roots are
    /// answered from the mount table alone — nothing touches the path.
    /// Everything else gets one existence stat on a background queue,
    /// bounded by `timeout`; a volume that does not answer in time is
    /// reported as not responding.
    public static func check(
        places: [EventStoragePlace],
        mountedVolumes: Set<String>,
        timeout: TimeInterval = defaultTimeout,
        probe: ResponseProbe? = nil
    ) async -> EventReachabilityReport {
        let probe = probe ?? { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var states: [EventStoragePlace: EventPlaceState] = [:]
        var toProbe: [EventStoragePlace] = []
        for place in places {
            if let volume = place.volumeRoot, !mountedVolumes.contains(volume.standardizedFileURL.path) {
                states[place] = .notMounted
            } else {
                toProbe.append(place)
            }
        }
        let probed = await withTaskGroup(of: (EventStoragePlace, EventPlaceState).self) { group in
            for place in toProbe {
                group.addTask { (place, await bounded(place.root, timeout: timeout, probe: probe)) }
            }
            var results: [(EventStoragePlace, EventPlaceState)] = []
            for await result in group { results.append(result) }
            return results
        }
        var unresponsive = Set<String>()
        for (place, state) in probed {
            states[place] = state
            if state == .notResponding, let volume = place.volumeRoot {
                unresponsive.insert(volume.standardizedFileURL.path)
            }
        }
        return EventReachabilityReport(states: states, unresponsiveVolumes: unresponsive)
    }

    /// One probe raced against a deadline. The probe's thread is never
    /// joined: a stat stuck in the kernel on a dead share finishes (or
    /// doesn't) on its own while the caller has already moved on.
    static func bounded(_ url: URL, timeout: TimeInterval, probe: @escaping ResponseProbe) async -> EventPlaceState {
        await withCheckedContinuation { (continuation: CheckedContinuation<EventPlaceState, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(probe(url) ? .reachable : .missing)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(.notResponding)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EventPlaceState, Never>?

    init(_ continuation: CheckedContinuation<EventPlaceState, Never>) {
        self.continuation = continuation
    }

    func resume(_ state: EventPlaceState) {
        let pending: CheckedContinuation<EventPlaceState, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: state)
    }
}
