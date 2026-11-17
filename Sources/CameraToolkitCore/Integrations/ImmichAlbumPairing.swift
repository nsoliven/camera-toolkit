import Foundation

/// One album as pairing sees it: its name, where its assets are, and when
/// they were taken.
public struct ImmichAlbumContents: Equatable, Sendable {
    public var album: ImmichAlbum
    /// The server paths of the album's assets.
    public var originalPaths: [String]
    /// The capture times of the album's assets that have one.
    public var captureDates: [Date]

    public init(album: ImmichAlbum, originalPaths: [String], captureDates: [Date] = []) {
        self.album = album
        self.originalPaths = originalPaths
        self.captureDates = captureDates
    }
}

/// An album paired with an event, and what made the match clear. The same
/// value describes an "also in" link (`ImmichPairingResult.links`): an album
/// the event is in besides its own, never filled by the app.
public struct ImmichAlbumPair: Equatable, Sendable {
    public enum Basis: String, Equatable, Sendable {
        case name
        case contents
        case nameAndContents
        /// Its name fits several events; its photos' dates fit one.
        case nameAndDates
        /// A phone album: its photos' dates overlap the event's and its name
        /// shares a word with the event's.
        case dates
        /// Camera photos from several events; linked to each of them.
        case severalEvents

        public var text: String {
            switch self {
            case .name: "name"
            case .contents: "photos"
            case .nameAndContents: "name and photos"
            case .nameAndDates: "name and dates"
            case .dates: "dates"
            case .severalEvents: "several events"
            }
        }
    }

    public var album: ImmichAlbum
    public var eventID: UUID
    public var basis: Basis
    /// Album assets that are this event's files.
    public var matchedAssets: Int
    /// The album already holds most of the event (an event album), so checks
    /// keep it filled. Otherwise it is a picks album: linked, not filled.
    public var fills: Bool
    /// The album's photos' dates with outliers trimmed, for a match by dates.
    public var dateSpan: ClosedRange<Date>?

    public init(album: ImmichAlbum, eventID: UUID, basis: Basis, matchedAssets: Int, fills: Bool = false, dateSpan: ClosedRange<Date>? = nil) {
        self.album = album
        self.eventID = eventID
        self.basis = basis
        self.matchedAssets = matchedAssets
        self.fills = fills
        self.dateSpan = dateSpan
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
    /// Someone else's album shared with the key's user.
    case sharedWithYou
    /// The key's user could not be read, so whose album it is is unknown.
    case ownerUnknown
    /// The album holds nothing.
    case empty
    /// A phone album whose photos (outliers trimmed) span too long to be
    /// one event's, like Favorites or Screenshots.
    case longSpan(days: Int)
    /// A phone album whose name and dates fit more than one event.
    case datesFitSeveralEvents
    /// A phone album no event fits by name word and dates.
    case noDateMatch
    /// A phone album with too few dated photos to place it.
    case tooFewDates

    public var text: String {
        switch self {
        case .noMatch: "No event has this name or these photos"
        case .mixed(let share): "Photos from several events (at most \(Int((share * 100).rounded()))% from one)"
        case .tie: "Its name fits more than one event"
        case .nameAndContentsDisagree: "Its name fits one event, its photos another"
        case .eventMatchesSeveralAlbums: "Its event matches more than one album"
        case .privateEvent: "Its event is private; use Allow Album and Pair to pair it"
        case .eventOptedOut: "Its event is set to No album"
        case .eventAlreadyPaired: "Its event already has an album"
        case .sharedWithYou: "Shared with you, not your album; not paired"
        case .ownerUnknown: "Could not confirm it is your album (the key needs user.read); not paired"
        case .empty: "The album is empty"
        case .longSpan(let days): "Its photos span \(days) days, too long for one event"
        case .datesFitSeveralEvents: "Its name and dates fit more than one event"
        case .noDateMatch: "No event with a word of its name around its dates"
        case .tooFewDates: "Too few dated photos to place it"
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
    /// Each event's own album (at most one per event and per album).
    public var pairs: [ImmichAlbumPair] = []
    /// "Also in" links: albums an event is in besides its own. Never filled.
    public var links: [ImmichAlbumPair] = []
    public var unpaired: [ImmichUnpairedAlbum] = []
    /// Pairs and links that wait on Allow album for their private event.
    /// They are listed in `unpaired` too (reason `.privateEvent`) when the
    /// album has nothing else.
    public var privatePairs: [ImmichAlbumPair] = []
    public var privateLinks: [ImmichAlbumPair] = []
    /// Albums already paired or linked before this run, left as they were.
    public var alreadyPaired = 0

    public init() {}

    /// Albums that would pair or link once their private events allow an album.
    public var privateAlbumIDs: Set<String> { Set((privatePairs + privateLinks).map(\.album.id)) }
    /// The private events those albums belong to.
    public var privateEventIDs: Set<UUID> { Set((privatePairs + privateLinks).map(\.eventID)) }
}

/// Pairs existing Immich albums with events when the match is clear, links
/// albums that span several events to each of them, and says why for every
/// album it leaves alone. It decides only; it writes nothing to Immich.
///
/// The rules, in order, for each album the user owns that is not paired or
/// linked yet:
/// 1. Today's rules: at least `minimumAssets` photos and `minimumShare` of
///    the album from one event, or a name that is exactly one event's. A
///    name that fits several events is settled by the album's dates.
/// 2. Several events: every event with at least `linkMinimumAssets` of the
///    album's camera photos and either `linkMinimumShare` of the album's
///    matched photos or `linkMinimumEventShare` of the event's own photos
///    gets an "also in" link (besides the event of rule 1, if any).
/// 3. Phone albums (at most `phoneAlbumLibraryShare` camera photos): the
///    densest window holding `spanShare` of the photos' capture dates
///    (`robustSpan`) must span at most `phoneAlbumMaximumSpan`, overlap an
///    event's photo dates within `dateTolerance`, and share a word with the
///    event's name (`nameWords`). The best overlap wins; a tie is left
///    alone. A match by dates is always an "also in" link, never the
///    event's own album, so it never takes the album an event would get.
///
/// An event gets one album of its own: a second match for an event that
/// already has one, or several matches for the same event, become links.
/// A phone album is never filled, whatever made it match.
public enum ImmichAlbumPairing {
    /// Share of an album's assets that must be one event's files.
    public static let minimumShare = 0.8
    /// And at least this many of them.
    public static let minimumAssets = 5
    /// Share of the event's photos and videos an album must already hold to
    /// be kept filled with the whole event.
    public static let eventAlbumShare = 0.8

    /// A several-events album is linked to an event with at least this many
    /// of its camera photos…
    public static let linkMinimumAssets = 5
    /// …that are at least this share of the album's matched photos…
    public static let linkMinimumShare = 0.05
    /// …or at least this share of the event's own photos.
    public static let linkMinimumEventShare = 0.25

    /// An album with at most this share of camera-library assets (and at
    /// most one when it is small) is a phone album, placed by its dates.
    public static let phoneAlbumLibraryShare = 0.05
    /// A phone album's dates (`robustSpan`) must span at most this long.
    public static let phoneAlbumMaximumSpan: TimeInterval = 21 * 86_400
    /// An album's or event's dates are the shortest window holding this
    /// share of its photos, so stray imports and late exports drop out.
    public static let spanShare = 0.8
    /// How far apart an album's and an event's dates may be and still fit.
    public static let dateTolerance: TimeInterval = 86_400
    /// A phone album needs at least this many dated photos.
    public static let minimumDatedAssets = 3

    /// Words that never make a name match on their own.
    public static let stopWords: Set<String> = [
        "a", "an", "and", "at", "by", "de", "for", "in", "my", "of", "on", "our", "the", "to", "w", "with",
        "trip", "day", "days", "weekend", "vacation", "holiday", "part", "pt",
        // Words of the albums Immich and phones make on their own.
        "favorites", "favourites", "recents", "recent", "screenshots", "screenshot", "selfies", "videos", "video",
        "live", "photos", "photo", "raw", "portrait", "portraits", "bursts", "panoramas", "imports", "hidden", "edits"
    ]

    /// - Parameters:
    ///   - currentUserID: the key's user; albums owned by anyone else
    ///     (shared with the user) are never paired.
    ///   - linkedAlbumIDs: albums that already have an "also in" link (or one
    ///     the user removed or moved an event off); they are left alone like
    ///     paired albums.
    ///   - assetDates: Immich's capture dates of the library's files, by
    ///     `NASSyncStore.pathKey` of the library-relative path; the best
    ///     source for an event's dates.
    ///   - captureDates: the capture-date cache's dates by event asset ID
    ///     (`captureDates(assignments:cache:)`); used when Immich has none.
    public static func pair(
        albums: [ImmichAlbumContents],
        events: [SavedCameraEvent],
        files: [ImmichCatalogFile],
        library: ImmichLibrary,
        locations: EventStorageLocations,
        currentUserID: String? = nil,
        linkedAlbumIDs: Set<String> = [],
        assetDates: [String: Date] = [:],
        captureDates: [String: Date] = [:]
    ) -> ImmichPairingResult {
        let media = OrganizeFileClassifier.rawExtensions.union(OrganizeFileClassifier.photoExtensions).union(OrganizeFileClassifier.videoExtensions)
        var eventMediaCount: [UUID: Int] = [:]
        for file in files {
            guard let eventID = file.eventID, media.contains((file.relativePath as NSString).pathExtension.lowercased()) else { continue }
            eventMediaCount[eventID, default: 0] += 1
        }
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
        let handledAlbumIDs = Set(events.compactMap(\.immichAlbumID)).union(linkedAlbumIDs)
        let spans = eventDateSpans(events: events, files: files, media: media, assetDates: assetDates, captureDates: captureDates)
        let eventWords = Dictionary(events.map { ($0.id, nameWords($0.name)) }) { first, _ in first }

        var result = ImmichPairingResult()
        var mains: [Match] = []
        var links: [Match] = []
        var reasons: [String: ImmichPairingReason] = [:]
        var albumOrder: [ImmichAlbum] = []
        for contents in albums {
            let album = contents.album
            if handledAlbumIDs.contains(album.id) {
                result.alreadyPaired += 1
                continue
            }
            // Fails closed: without the key's user, no album with an owner pairs.
            if let owner = album.ownerID {
                guard let currentUserID else {
                    result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .ownerUnknown))
                    continue
                }
                if owner != currentUserID {
                    result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .sharedWithYou))
                    continue
                }
            }
            if contents.originalPaths.isEmpty, (album.assetCount ?? 0) == 0 {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: .empty))
                continue
            }
            albumOrder.append(album)
            let nameMatches = eventsByNameKey[NASSyncStore.pathKey(album.name.trimmingCharacters(in: .whitespacesAndNewlines))] ?? []
            var counts: [UUID: Int] = [:]
            var libraryAssets = 0
            for path in contents.originalPaths {
                guard let relative = paths.relativePath(forOriginalPath: path) else { continue }
                libraryAssets += 1
                guard let eventID = eventByPathKey[NASSyncStore.pathKey(relative)] else { continue }
                counts[eventID, default: 0] += 1
            }
            // The album's own count: a shared album lists only the user's
            // assets, so the listing alone would overstate the share.
            let total = max(album.assetCount ?? 0, contents.originalPaths.count, 1)
            let top = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.uuidString > $1.key.uuidString) }
            let contentMatch = top.flatMap { top -> UUID? in
                top.value >= minimumAssets && Double(top.value) / Double(total) >= minimumShare ? top.key : nil
            }
            let albumSpan = robustSpan(contents.captureDates)
            let isPhoneAlbum = libraryAssets <= max(1, Int(Double(contents.originalPaths.count) * phoneAlbumLibraryShare))

            // 1. Today's rules, with a name tie settled by dates.
            var main: (UUID, ImmichAlbumPair.Basis)?
            var failure: ImmichPairingReason?
            if let contentMatch {
                if nameMatches.isEmpty {
                    main = (contentMatch, .contents)
                } else if nameMatches.contains(contentMatch) {
                    main = (contentMatch, .nameAndContents)
                } else {
                    reasons[album.id] = .nameAndContentsDisagree
                    continue
                }
            } else if nameMatches.count == 1, let only = nameMatches.first {
                main = (only, .name)
            } else if nameMatches.count > 1 {
                if contents.captureDates.count >= minimumDatedAssets, let albumSpan,
                   case .match(let eventID) = bestByDates(span: albumSpan, candidates: nameMatches, spans: spans) {
                    main = (eventID, .nameAndDates)
                } else {
                    failure = .tie
                }
            }

            // 2. Camera photos from several events.
            let matchedTotal = counts.values.reduce(0, +)
            let linked = counts.filter { eventID, count in
                guard eventID != main?.0, count >= linkMinimumAssets else { return false }
                let albumShare = Double(count) / Double(max(matchedTotal, 1))
                let eventShare = Double(count) / Double(max(eventMediaCount[eventID] ?? 0, 1))
                return albumShare >= linkMinimumShare || eventShare >= linkMinimumEventShare
            }
            for (eventID, count) in linked.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key.uuidString < $1.key.uuidString) }) {
                links.append(Match(album: album, eventID: eventID, basis: .severalEvents, matched: count, isStrong: true, span: nil, isPhoneAlbum: isPhoneAlbum))
            }

            // 3. A phone album, by its dates and a word of its name.
            var datedLink = false
            if main == nil, linked.isEmpty {
                if isPhoneAlbum {
                    switch phoneMatch(contents: contents, span: albumSpan, events: events, words: eventWords, spans: spans) {
                    case .success(let eventID):
                        // Always a link: dates alone never take the event's own album.
                        links.append(Match(album: album, eventID: eventID, basis: .dates, matched: counts[eventID] ?? 0, isStrong: false, span: albumSpan, isPhoneAlbum: true))
                        datedLink = true
                    case .failure(let reason):
                        // A name tie stays the reason: dates were the extra try.
                        failure = failure == .tie ? .tie : reason
                    }
                } else if failure == nil {
                    failure = top.map { $0.value >= minimumAssets ? .mixed(topShare: Double($0.value) / Double(total)) : .noMatch } ?? .noMatch
                }
            }

            if let (eventID, basis) = main {
                mains.append(Match(album: album, eventID: eventID, basis: basis, matched: counts[eventID] ?? 0, isStrong: true, span: basis == .nameAndDates ? albumSpan : nil, isPhoneAlbum: isPhoneAlbum))
            } else if linked.isEmpty, !datedLink {
                reasons[album.id] = failure ?? .noMatch
            }
        }

        // Each event's own album: one strong match wins (weaker ones become
        // links); several strong matches, or a second album for an event
        // that has one, become links.
        var finalPairs: [Match] = []
        var finalLinks = links
        for (eventID, matches) in Dictionary(grouping: mains, by: \.eventID) {
            let ordered = matches.sorted { $0.album.name.localizedStandardCompare($1.album.name) == .orderedAscending }
            guard let event = eventsByID[eventID], event.immichAlbumID == nil else {
                finalLinks += ordered
                continue
            }
            let strong = ordered.filter(\.isStrong)
            let winner: Match? = strong.count == 1 ? strong[0] : (strong.isEmpty && ordered.count == 1 ? ordered[0] : nil)
            for match in ordered {
                if let winner, match.album.id == winner.album.id { finalPairs.append(match) } else { finalLinks.append(match) }
            }
        }

        // The event's own rules: No album blocks it, private waits on Allow album.
        var placedAlbums: Set<String> = []
        var blocked: [String: (UUID, ImmichPairingReason)] = [:]
        func admit(_ match: Match) -> Bool {
            guard let event = eventsByID[match.eventID] else { return false }
            if event.immichAlbumPolicy == ImmichAlbumPolicy.none {
                blocked[match.album.id] = blocked[match.album.id] ?? (match.eventID, .eventOptedOut)
                return false
            }
            return true
        }
        func isPrivate(_ eventID: UUID) -> Bool {
            guard let event = eventsByID[eventID] else { return false }
            return locations.resolvedPolicy(for: event) == .archiveOnly && !event.sendsToImmich
        }
        for match in finalPairs where admit(match) {
            let eventTotal = eventMediaCount[match.eventID] ?? 0
            // A phone album is never filled, even when it holds a small
            // event's few camera photos.
            let isEventAlbum = !match.isPhoneAlbum && eventTotal > 0 && Double(match.matched) / Double(eventTotal) >= eventAlbumShare
            let pair = ImmichAlbumPair(album: match.album, eventID: match.eventID, basis: match.basis, matchedAssets: match.matched, fills: isEventAlbum, dateSpan: match.span)
            if isPrivate(match.eventID) {
                result.privatePairs.append(pair)
                if blocked[match.album.id] == nil { blocked[match.album.id] = (match.eventID, .privateEvent) }
            } else {
                result.pairs.append(pair)
                placedAlbums.insert(match.album.id)
            }
        }
        var seenLinks: Set<String> = []
        for match in finalLinks where admit(match) {
            guard seenLinks.insert("\(match.eventID.uuidString)|\(match.album.id)").inserted else { continue }
            let link = ImmichAlbumPair(album: match.album, eventID: match.eventID, basis: match.basis, matchedAssets: match.matched, dateSpan: match.span)
            if isPrivate(match.eventID) {
                result.privateLinks.append(link)
                if blocked[match.album.id] == nil { blocked[match.album.id] = (match.eventID, .privateEvent) }
            } else {
                result.links.append(link)
                placedAlbums.insert(match.album.id)
            }
        }
        for album in albumOrder where !placedAlbums.contains(album.id) {
            if let (eventID, reason) = blocked[album.id] {
                // Private wins over No album in the reason: it can be fixed here.
                let isPrivateToo = result.privateAlbumIDs.contains(album.id)
                result.unpaired.append(ImmichUnpairedAlbum(album: album, eventID: eventID, reason: isPrivateToo ? .privateEvent : reason))
            } else {
                result.unpaired.append(ImmichUnpairedAlbum(album: album, reason: reasons[album.id] ?? .noMatch))
            }
        }

        let byAlbumName: (ImmichAlbumPair, ImmichAlbumPair) -> Bool = {
            let order = $0.album.name.localizedStandardCompare($1.album.name)
            return order == .orderedSame ? $0.matchedAssets > $1.matchedAssets : order == .orderedAscending
        }
        result.pairs.sort(by: byAlbumName)
        result.links.sort(by: byAlbumName)
        result.privatePairs.sort(by: byAlbumName)
        result.privateLinks.sort(by: byAlbumName)
        result.unpaired.sort { $0.album.name.localizedStandardCompare($1.album.name) == .orderedAscending }
        return result
    }

    private struct Match {
        var album: ImmichAlbum
        var eventID: UUID
        var basis: ImmichAlbumPair.Basis
        var matched: Int
        /// Made by today's rules (name or photos), not by dates alone.
        var isStrong: Bool
        var span: ClosedRange<Date>?
        /// At most `phoneAlbumLibraryShare` of it is in the camera library.
        var isPhoneAlbum: Bool
    }

    // MARK: - Dates and names

    /// The shortest window holding `spanShare` of `dates` (at least one),
    /// or nil for none: a few stray dates (an import-day photo, exports
    /// months later) fall outside it.
    public static func robustSpan(_ dates: [Date]) -> ClosedRange<Date>? {
        guard !dates.isEmpty else { return nil }
        let sorted = dates.sorted()
        let keep = min(sorted.count, max(1, Int((Double(sorted.count) * spanShare).rounded(.up))))
        var best = 0
        var bestLength = TimeInterval.infinity
        for start in 0...(sorted.count - keep) {
            let length = sorted[start + keep - 1].timeIntervalSince(sorted[start])
            if length < bestLength { best = start; bestLength = length }
        }
        return sorted[best]...sorted[best + keep - 1]
    }

    /// The meaningful words of a name: case, accents, punctuation, emoji and
    /// digits (years, "24'") ignored, and `stopWords` and single letters left out.
    public static func nameWords(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: Set<String> = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 2, !stopWords.contains(current) { words.insert(current) }
                current = ""
            }
        }
        if current.count >= 2, !stopWords.contains(current) { words.insert(current) }
        return words
    }

    /// Each event's photo dates: for each of its own photos, Immich's
    /// capture date, else the capture-date cache's, else the file time
    /// (cameras set it at capture, but copies and exports can move it);
    /// its subevents' when it has none of its own; else its event day.
    /// The span is `robustSpan` of those dates.
    static func eventDateSpans(
        events: [SavedCameraEvent],
        files: [ImmichCatalogFile],
        media: Set<String>,
        assetDates: [String: Date] = [:],
        captureDates: [String: Date] = [:]
    ) -> [UUID: ClosedRange<Date>] {
        // Before 1990 is a missing or reset clock, not a capture time.
        let earliest = Date(timeIntervalSince1970: 631_152_000)
        var dates: [UUID: [Date]] = [:]
        for file in files {
            guard let eventID = file.eventID, media.contains((file.relativePath as NSString).pathExtension.lowercased()) else { continue }
            let date = assetDates[NASSyncStore.pathKey(file.relativePath)] ?? captureDates[file.eventAssetID] ?? file.modifiedAt
            guard date > earliest else { continue }
            dates[eventID, default: []].append(date)
        }
        var children: [UUID: [UUID]] = [:]
        for event in events { if let parent = event.parentEventID { children[parent, default: []].append(event.id) } }
        func descendantDates(_ id: UUID, depth: Int) -> [Date] {
            guard depth < 32 else { return [] }
            return (children[id] ?? []).flatMap { (dates[$0] ?? []) + descendantDates($0, depth: depth + 1) }
        }
        var spans: [UUID: ClosedRange<Date>] = [:]
        for event in events {
            let own = dates[event.id] ?? []
            let chosen = own.isEmpty ? descendantDates(event.id, depth: 0) : own
            spans[event.id] = robustSpan(chosen) ?? event.eventDate...event.eventDate.addingTimeInterval(86_399)
        }
        return spans
    }

    /// Immich's capture dates of the library's files, by
    /// `NASSyncStore.pathKey` of the path under the library's folder.
    public static func assetDates(assets: [ImmichLibraryAsset], library: ImmichLibrary) -> [String: Date] {
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        var result: [String: Date] = [:]
        for asset in assets where !asset.isTrashed {
            guard let date = asset.captureDate, let relative = paths.relativePath(forOriginalPath: asset.originalPath) else { continue }
            result[NASSyncStore.pathKey(relative)] = date
        }
        return result
    }

    /// The capture-date cache's dates of the catalog's files, by event asset
    /// ID (`CatalogStore.eventAssetID`). Files the cache does not hold, or
    /// that changed since, are left out.
    public static func captureDates(assignments: [PhotoEventAssignment], cache: CaptureDateCache) -> [String: Date] {
        var result: [String: Date] = [:]
        for assignment in assignments {
            let path = URL(fileURLWithPath: assignment.sourceRootPath, isDirectory: true).appendingPathComponent(assignment.relativePath).path
            guard let cached = cache.lookup(path: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt),
                  let date = cached?.date else { continue }
            result[CatalogStore.eventAssetID(assignment)] = date
        }
        return result
    }

    enum DateFit: Equatable {
        case match(UUID)
        case ambiguous
        case none
    }

    /// The candidate whose dates overlap `span` best (within
    /// `dateTolerance`): the longest overlap, then the closest fit. Equal
    /// fits are ambiguous.
    static func bestByDates(span: ClosedRange<Date>, candidates: Set<UUID>, spans: [UUID: ClosedRange<Date>]) -> DateFit {
        // A one-moment album still overlaps by an hour.
        let albumStart = span.lowerBound
        let albumEnd = max(span.upperBound, albumStart.addingTimeInterval(3_600))
        var scored: [(id: UUID, overlap: Double, fit: Double)] = []
        for id in candidates {
            guard let eventSpan = spans[id] else { continue }
            let start = eventSpan.lowerBound.addingTimeInterval(-dateTolerance)
            let end = eventSpan.upperBound.addingTimeInterval(dateTolerance)
            let overlap = min(albumEnd, end).timeIntervalSince(max(albumStart, start))
            guard overlap >= 0 else { continue }
            let union = max(albumEnd, end).timeIntervalSince(min(albumStart, start))
            scored.append((id, overlap, union > 0 ? overlap / union : 0))
        }
        scored.sort { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : ($0.fit != $1.fit ? $0.fit > $1.fit : $0.id.uuidString < $1.id.uuidString) }
        guard let best = scored.first else { return .none }
        if scored.count > 1 {
            let second = scored[1]
            if abs(best.overlap - second.overlap) < 3_600, abs(best.fit - second.fit) < 0.01 { return .ambiguous }
        }
        return .match(best.id)
    }

    private enum PhoneOutcome {
        case success(UUID)
        case failure(ImmichPairingReason)
    }

    private static func phoneMatch(
        contents: ImmichAlbumContents,
        span: ClosedRange<Date>?,
        events: [SavedCameraEvent],
        words: [UUID: Set<String>],
        spans: [UUID: ClosedRange<Date>]
    ) -> PhoneOutcome {
        guard contents.captureDates.count >= minimumDatedAssets, let span else { return .failure(.tooFewDates) }
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length <= phoneAlbumMaximumSpan else { return .failure(.longSpan(days: Int((length / 86_400).rounded()))) }
        let albumWords = nameWords(contents.album.name)
        guard !albumWords.isEmpty else { return .failure(.noDateMatch) }
        let candidates = Set(events.filter { !(words[$0.id] ?? []).isDisjoint(with: albumWords) }.map(\.id))
        switch bestByDates(span: span, candidates: candidates, spans: spans) {
        case .match(let id): return .success(id)
        case .ambiguous: return .failure(.datesFitSeveralEvents)
        case .none: return .failure(.noDateMatch)
        }
    }
}

extension ImmichAlbumPairing {
    /// Every album on the account with its assets' paths and dates. Reads only.
    public static func readAlbums(client: ImmichClient, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [ImmichAlbumContents] {
        let albums = try await client.albums()
        var contents: [ImmichAlbumContents] = []
        for (index, album) in albums.enumerated() {
            progress(index + 1, albums.count)
            let assets = try await client.albumAssets(albumID: album.id)
            contents.append(ImmichAlbumContents(album: album, originalPaths: assets.map(\.originalPath), captureDates: assets.compactMap(\.captureDate)))
        }
        return contents
    }
}

extension SavedCameraEvent {
    /// Pairs the event with an existing album. The policy and name are kept
    /// in step so a build without pairing fills the same album by name.
    ///
    /// - Parameters:
    ///   - fills: checks add the whole event to it; false links a picks album.
    ///   - automatic: it came from "Make an album for every event".
    public mutating func pairImmichAlbum(_ album: ImmichAlbum, fills: Bool = true, automatic: Bool = false, shared: Bool = false) {
        immichAlbumID = album.id
        immichAlbumPolicy = .custom
        immichAlbumName = album.name
        immichAlbumFill = fills && !shared
        immichAlbumAutomatic = automatic ? true : nil
        immichAlbumShared = shared ? true : nil
    }

    /// No album, and nothing pairs it again on its own.
    public mutating func unpairImmichAlbum() {
        immichAlbumID = nil
        immichAlbumPolicy = ImmichAlbumPolicy.none
        immichAlbumFill = nil
        immichAlbumAutomatic = nil
        immichAlbumShared = nil
    }

    /// A new album named after the event, made on the next check.
    public mutating func useNewImmichAlbumNamedAfterEvent() {
        immichAlbumID = nil
        immichAlbumPolicy = .event
        immichAlbumFill = nil
        immichAlbumAutomatic = nil
        immichAlbumShared = nil
    }

    /// Checks add the event's photos to its album: always for an album the
    /// app will make, for a paired album only when it is an event album.
    public var fillsImmichAlbum: Bool { immichAlbumID == nil || (immichAlbumShared != true && (immichAlbumFill ?? true)) }

    /// Whether checks fill the paired album right now, as the Album menu's
    /// switch shows it: an automatic album only while the every-event
    /// switch is on.
    public func isFillingImmichAlbum(albumsForEveryEvent: Bool) -> Bool {
        fillsImmichAlbum && (immichAlbumAutomatic != true || albumsForEveryEvent)
    }

    /// The share of `eventMediaCount` an album holding `matched` of the
    /// event's photos covers, against the event-album rule.
    public static func immichAlbumHoldsWholeEvent(matched: Int, eventMediaCount: Int) -> Bool {
        eventMediaCount > 0 && Double(matched) / Double(eventMediaCount) >= ImmichAlbumPairing.eventAlbumShare
    }
}
