import Foundation

/// One album as pairing sees it: its name and where its assets are.
public struct ImmichAlbumContents: Equatable, Sendable {
    public var album: ImmichAlbum
    /// The server paths of the album's assets.
    public var originalPaths: [String]

    public init(album: ImmichAlbum, originalPaths: [String]) {
        self.album = album
        self.originalPaths = originalPaths
    }
}

/// An album paired with an event, and what made the match clear.
public struct ImmichAlbumPair: Equatable, Sendable {
    public enum Basis: String, Equatable, Sendable {
        case name
        case contents
        case nameAndContents
    }

    public var album: ImmichAlbum
    public var eventID: UUID
    public var basis: Basis
    /// Album assets that are this event's files.
    public var matchedAssets: Int

    public init(album: ImmichAlbum, eventID: UUID, basis: Basis, matchedAssets: Int) {
        self.album = album
        self.eventID = eventID
        self.basis = basis
        self.matchedAssets = matchedAssets
    }
}

/// Why an album was left unpaired.
public enum ImmichPairingReason: Equatable, Sendable {
    case noMatch
    /// Most of its photos are from no single event.
    case mixed(topShare: Double)
    /// Its name fits more than one event, and its photos do not settle it.
    case tie
    /// Its name fits one event and its photos another.
    case nameAndContentsDisagree
    /// The event it fits also fits another album.
    case eventMatchesSeveralAlbums
    case privateEvent
    /// The event is set to No album.
    case eventOptedOut
    /// The event already has an album.
    case eventAlreadyPaired

    public var text: String {
        switch self {
        case .noMatch: "No event has this name or these photos"
        case .mixed(let share): "Photos from several events (at most \(Int((share * 100).rounded()))% from one)"
        case .tie: "Its name fits more than one event"
        case .nameAndContentsDisagree: "Its name fits one event, its photos another"
        case .eventMatchesSeveralAlbums: "Its event matches more than one album"
        case .privateEvent: "Its event is private; turn on Allow album to pair it"
        case .eventOptedOut: "Its event is set to No album"
        case .eventAlreadyPaired: "Its event already has an album"
        }
    }
}

public struct ImmichUnpairedAlbum: Equatable, Sendable {
    public var album: ImmichAlbum
    public var eventID: UUID?
    public var reason: ImmichPairingReason

    public init(album: ImmichAlbum, eventID: UUID? = nil, reason: ImmichPairingReason) {
        self.album = album
        self.eventID = eventID
        self.reason = reason
    }
}

public struct ImmichPairingResult: Equatable, Sendable {
    public var pairs: [ImmichAlbumPair] = []
    public var unpaired: [ImmichUnpairedAlbum] = []
    /// Albums already paired before this run, left as they were.
    public var alreadyPaired = 0

    public init() {}
}

/// Pairs existing Immich albums with events when the match is clear, and
/// says why for every album it leaves alone. It decides only; it writes
/// nothing to Immich.
public enum ImmichAlbumPairing {
    /// Share of an album's assets that must be one event's files.
    public static let minimumShare = 0.8
    /// And at least this many of them.
    public static let minimumAssets = 5

    public static func pair(
        albums: [ImmichAlbumContents],
        events: [SavedCameraEvent],
        files: [ImmichCatalogFile],
        library: ImmichLibrary,
        locations: EventStorageLocations
    ) -> ImmichPairingResult {
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        let eventsByID = Dictionary(events.map { ($0.id, $0) }) { first, _ in first }

        // Name keys: the event's name, its dated album title, and a custom name.
        var eventsByNameKey: [String: Set<UUID>] = [:]
        for event in events {
            var names = [event.name, ImmichAlbumNaming.datedTitle(for: event)]
            if event.immichAlbumPolicy == .custom, let custom = event.immichAlbumName, event.immichAlbumID == nil { names.append(custom) }
            for name in names {
                let key = NASSyncStore.pathKey(name.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !key.isEmpty else { continue }
                eventsByNameKey[key, default: []].insert(event.id)
            }
        }
        var eventByPathKey: [String: UUID] = [:]
        for file in files {
            if let eventID = file.eventID { eventByPathKey[NASSyncStore.pathKey(file.relativePath)] = eventID }
        }
        let pairedAlbumIDs = Set(events.compactMap(\.immichAlbumID))

        var result = ImmichPairingResult()
        var candidates: [(album: ImmichAlbum, eventID: UUID, basis: ImmichAlbumPair.Basis, matched: Int)] = []
        for contents in albums {
            let album = contents.album
            if pairedAlbumIDs.contains(album.id) {
                result.alreadyPaired += 1
                continue
            }
            let nameMatches = eventsByNameKey[NASSyncStore.pathKey(album.name.trimmingCharacters(in: .whitespacesAndNewlines))] ?? []
            var counts: [UUID: Int] = [:]
            for path in contents.originalPaths {
                guard let relative = paths.relativePath(forOriginalPath: path),
                      let eventID = eventByPathKey[NASSyncStore.pathKey(relative)] else { continue }
                counts[eventID, default: 0] += 1
            }
            let total = max(contents.originalPaths.count, 1)
            let top = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.uuidString > $1.key.uuidString) }
            let contentMatch = top.flatMap { top -> UUID? in
                top.value >= minimumAssets && Double(top.value) / Double(total) >= minimumShare ? top.key : nil
            }

            let chosen: (UUID, ImmichAlbumPair.Basis)
            if let contentMatch {
                if nameMatches.isEmpty {
                    chosen = (contentMatch, .contents)
                } else if nameMatches.contains(contentMatch) {
                    chosen = (contentMatch, .nameAndContents)
                } else {
                    result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .nameAndContentsDisagree))
                    continue
                }
            } else if nameMatches.count == 1, let only = nameMatches.first {
                chosen = (only, .name)
            } else if nameMatches.count > 1 {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .tie))
                continue
            } else if let top, top.value >= minimumAssets {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .mixed(topShare: Double(top.value) / Double(total))))
                continue
            } else {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .noMatch))
                continue
            }

            let (eventID, basis) = chosen
            guard let event = eventsByID[eventID] else { continue }
            if event.immichAlbumID != nil {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, eventID: eventID, reason: .eventAlreadyPaired))
            } else if locations.resolvedPolicy(for: event) == .archiveOnly, !event.sendsToImmich {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, eventID: eventID, reason: .privateEvent))
            } else if event.immichAlbumPolicy == ImmichAlbumPolicy.none {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, eventID: eventID, reason: .eventOptedOut))
            } else {
                candidates.append((album, eventID, basis, counts[eventID] ?? 0))
            }
        }

        let perEvent = Dictionary(grouping: candidates, by: \.eventID)
        for candidate in candidates {
            if (perEvent[candidate.eventID]?.count ?? 0) > 1 {
                result.unpaired.append(ImmichUnpairedAlbum(album: candidate.album, eventID: candidate.eventID, reason: .eventMatchesSeveralAlbums))
            } else {
                result.pairs.append(ImmichAlbumPair(album: candidate.album, eventID: candidate.eventID, basis: candidate.basis, matchedAssets: candidate.matched))
            }
        }
        result.pairs.sort { $0.album.name.localizedStandardCompare($1.album.name) == .orderedAscending }
        result.unpaired.sort { $0.album.name.localizedStandardCompare($1.album.name) == .orderedAscending }
        return result
    }
}

extension ImmichAlbumPairing {
    /// Every album on the account with its assets' paths. Reads only.
    public static func readAlbums(client: ImmichClient, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [ImmichAlbumContents] {
        let albums = try await client.albums()
        var contents: [ImmichAlbumContents] = []
        for (index, album) in albums.enumerated() {
            progress(index + 1, albums.count)
            let assets = try await client.albumAssets(albumID: album.id)
            contents.append(ImmichAlbumContents(album: album, originalPaths: assets.map(\.originalPath)))
        }
        return contents
    }
}

extension SavedCameraEvent {
    /// Pairs the event with an existing album. The policy and name are kept
    /// in step so a build without pairing fills the same album by name.
    public mutating func pairImmichAlbum(_ album: ImmichAlbum) {
        immichAlbumID = album.id
        immichAlbumPolicy = .custom
        immichAlbumName = album.name
    }

    /// No album, and nothing pairs it again on its own.
    public mutating func unpairImmichAlbum() {
        immichAlbumID = nil
        immichAlbumPolicy = ImmichAlbumPolicy.none
    }

    /// A new album named after the event, made on the next check.
    public mutating func useNewImmichAlbumNamedAfterEvent() {
        immichAlbumID = nil
        immichAlbumPolicy = .event
    }
}
