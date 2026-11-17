import CameraToolkitCore
import Foundation

/// Immich albums: pairing existing albums with events, each event's album
/// choice, and the state the last check left. Pairing reads the account and
/// writes only the app's own settings; filling albums happens in checks.
extension DashboardModel {
    var immichLibraryIsChosen: Bool {
        !configuration.immichLibraryID.isEmpty
            && !configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var catalogURLForImmich: URL {
        URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath))
    }

    /// The key from the field being typed, else the Keychain. Sent only as a
    /// request header.
    func makeImmichClient() throws -> ImmichClient {
        var apiKey = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            apiKey = (try secretStore.read(account: Self.immichAPIKeyAccount))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !apiKey.isEmpty else {
            throw ToolkitError.commandFailed("Save an Immich API key in Settings first.")
        }
        return try ImmichClient(serverURL: configuration.immichServerURL, apiKey: apiKey)
    }

    func makeImmichSync() throws -> ImmichLibrarySync {
        ImmichLibrarySync(
            client: try makeImmichClient(),
            libraryID: configuration.immichLibraryID,
            catalogURL: catalogURLForImmich,
            carriesAlbumsAcrossRenames: configuration.immichCarriesAlbumsAcrossRenames,
            stacksBurstsAndEdits: configuration.immichStacksBurstsAndEdits,
            reservedAlbumIDs: immichReservedAlbumIDs,
            stackableEventIDs: ImmichStackGrouping.stackableEventIDs(
                events: configuration.savedEvents,
                locations: EventStorageLocations(configuration: configuration)
            ),
            logFolder: immichLogFolder
        )
    }

    /// Albums an album found by name may not resolve to: other events' own
    /// albums. "Also in" albums are not reserved: they are never filled as
    /// links, and an event whose name matches one should use it rather than
    /// get a duplicate made in Immich.
    var immichReservedAlbumIDs: Set<String> {
        Set(configuration.savedEvents.compactMap(\.immichAlbumID))
    }

    /// Every album addition and stack change, as JSON lines to undo from.
    var immichLogFolder: URL {
        catalogURLForImmich.deletingLastPathComponent().appendingPathComponent("Immich Logs", isDirectory: true)
    }

    /// Every catalog file with its NAS path and album, off the main actor.
    func immichCatalogFiles() async -> [ImmichCatalogFile] {
        let assignments = configuration.photoEventAssignments
        let events = configuration.savedEvents
        let albumsForEveryEvent = configuration.immichAlbumsForEveryEvent
        let locations = EventStorageLocations(configuration: configuration)
        let catalogURL = catalogURLForImmich
        return await Task.detached(priority: .utility) { () -> [ImmichCatalogFile] in
            let verified = NASSyncStore.existingRecords(catalogURL: catalogURL, nasRoot: locations.nasRoot.path)
                .filter { $0.value.state == .verified }
            return ImmichCatalogFile.build(
                assignments: assignments,
                events: events,
                locations: locations,
                verifiedPathKeys: Set(verified.keys),
                albumsForEveryEvent: albumsForEveryEvent
            )
        }.value
    }

    /// Reads every album on the account and pairs each with an event when the
    /// match is clear, and links albums of several events (and phone albums
    /// of an event that has its own) as "also in". Writes nothing to Immich.
    /// - Parameter allowsFilling: false links every pair without filling it
    ///   (choosing a library); Pair Albums keeps event albums filled.
    func pairImmichAlbums(allowsFilling: Bool = true) {
        guard immichLibraryIsChosen else {
            immichPairingNote = "Choose your Immich library first."
            return
        }
        guard !immichIsPairing else { return }
        immichIsPairing = true
        immichPairingNote = "Reading your Immich albums…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { immichIsPairing = false }
            do {
                let client = try makeImmichClient()
                let library = try await client.library(id: configuration.immichLibraryID)
                immichLibrary = library
                let contents = try await ImmichAlbumPairing.readAlbums(client: client) { [weak self] index, total in
                    Task { @MainActor in self?.immichPairingNote = "Reading album \(index) of \(total)…" }
                }
                immichAlbums = contents.map(\.album).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let files = await immichCatalogFiles()
                let events = configuration.savedEvents
                let locations = EventStorageLocations(configuration: configuration)
                // Fails closed: without the key's user, nothing with an owner pairs.
                let me = try? await client.currentUserID()
                immichCurrentUserID = me
                // Links to albums Immich no longer has go; the rest (and the
                // ones the user removed) are left alone.
                let catalogURL = catalogURLForImmich
                let accountIDs = Set(contents.map(\.album.id))
                let linked = await Task.detached(priority: .utility) { () -> Set<String> in
                    try? ImmichEventAlbumStore(catalogURL: catalogURL).removeLinks(toAlbumsNotIn: accountIDs)
                    return ImmichEventAlbumStore.handledAlbumIDs(catalogURL: catalogURL)
                }.value
                // Event dates: Immich's own capture dates, else the capture-date cache.
                immichPairingNote = "Reading the library's photo dates…"
                let assetDates = ImmichAlbumPairing.assetDates(assets: (try? await client.libraryAssets(libraryID: library.id)) ?? [], library: library)
                let assignments = configuration.photoEventAssignments
                let cacheURL = LayoutMigrationPlanner.captureDateCacheURL(supportFolder: configurationStore.url.deletingLastPathComponent())
                let captureDates = await Task.detached(priority: .utility) {
                    ImmichAlbumPairing.captureDates(assignments: assignments, cache: CaptureDateCache(url: cacheURL))
                }.value
                var result = ImmichAlbumPairing.pair(
                    albums: contents, events: events, files: files, library: library, locations: locations,
                    currentUserID: me, linkedAlbumIDs: linked, assetDates: assetDates, captureDates: captureDates
                )
                if !allowsFilling {
                    for index in result.privatePairs.indices { result.privatePairs[index].fills = false }
                }
                await applyImmichPairs(result.pairs, links: result.links, allowsFilling: allowsFilling)
                immichPairing = result
                let picks = result.pairs.count { !(allowsFilling && $0.fills) }
                immichPairingNote = Self.immichPairingSummary(result, picks: picks)
                loadImmichAlbumStates()
            } catch {
                immichPairingNote = "Pairing failed: \(error.localizedDescription)"
            }
        }
    }

    static func immichPairingSummary(_ result: ImmichPairingResult, picks: Int) -> String {
        var parts = ["Paired \(result.pairs.count) album\(result.pairs.count == 1 ? "" : "s") (\(picks) picks, linked only)"]
        let linkedAlbums = Set(result.links.map(\.album.id)).count
        if linkedAlbums > 0 {
            parts.append("linked \(linkedAlbums) more as also in (\(result.links.count) event link\(result.links.count == 1 ? "" : "s"))")
        }
        parts.append("\(result.unpaired.count) not paired")
        return parts.joined(separator: "; ") + ". Nothing was changed in Immich."
    }

    /// Writes pairs to the events and links to the catalog. A pair whose
    /// event got an album in the meantime becomes a link.
    /// Returns once the links are in the catalog, so a reload right after
    /// reads them.
    private func applyImmichPairs(_ pairs: [ImmichAlbumPair], links: [ImmichAlbumPair], allowsFilling: Bool, allowingEvents allowed: Set<UUID> = []) async {
        let byEvent = Dictionary(pairs.map { ($0.eventID, $0) }) { first, _ in first }
        var demoted: [ImmichAlbumPair] = []
        if !byEvent.isEmpty || !allowed.isEmpty {
            let current = Dictionary(configuration.savedEvents.map { ($0.id, $0) }) { first, _ in first }
            demoted = pairs.filter { current[$0.eventID]?.immichAlbumID != nil }
            // Event albums are kept filled; picks albums are only linked.
            updateConfiguration { configuration in
                for index in configuration.savedEvents.indices {
                    let id = configuration.savedEvents[index].id
                    if allowed.contains(id) { configuration.savedEvents[index].immichUploadEnabled = true }
                    if let pair = byEvent[id], configuration.savedEvents[index].immichAlbumID == nil {
                        configuration.savedEvents[index].pairImmichAlbum(pair.album, fills: allowsFilling && pair.fills)
                    }
                }
            }
        }
        let rows = (links + demoted).map(ImmichEventAlbumLink.init)
        guard !rows.isEmpty else { return }
        for row in rows where !(immichAlbumLinks[row.eventID] ?? []).contains(where: { $0.albumID == row.albumID }) {
            immichAlbumLinks[row.eventID, default: []].append(row)
        }
        let catalogURL = catalogURLForImmich
        await Task.detached(priority: .utility) { try? ImmichEventAlbumStore(catalogURL: catalogURL).addLinks(rows) }.value
    }

    /// Albums of private events the last pairing found, by album.
    var immichPrivateAlbumCount: Int { immichPairing?.privateAlbumIDs.count ?? 0 }

    /// "Allow album and pair": turns on Allow album for exactly the private
    /// events the last pairing found albums for, and pairs those albums.
    @discardableResult
    func allowAlbumAndPairPrivateEvents() -> Task<Void, Never>? {
        guard var result = immichPairing, !result.privateAlbumIDs.isEmpty else { return nil }
        let eventIDs = result.privateEventIDs
        let albumIDs = result.privateAlbumIDs
        let pairs = result.privatePairs
        let links = result.privateLinks
        // The events change now; the links reach the catalog right after.
        let write = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await applyImmichPairs(pairs, links: links, allowsFilling: true, allowingEvents: eventIDs)
        }
        result.pairs += pairs
        result.links += links
        result.privatePairs = []
        result.privateLinks = []
        result.unpaired.removeAll { albumIDs.contains($0.album.id) && $0.reason == .privateEvent }
        immichPairing = result
        immichPairingNote = "Allowed an album for \(eventIDs.count) private event\(eventIDs.count == 1 ? "" : "s") and paired \(albumIDs.count) album\(albumIDs.count == 1 ? "" : "s"). Nothing was changed in Immich."
        statusMessage = immichPairingNote
        return write
    }

    /// Removes one "also in" link; pairing never makes it again. The album
    /// stays in Immich as it is.
    @discardableResult
    func removeImmichAlbumLink(eventID: UUID, albumID: String) -> Task<Void, Never> {
        let removed = immichAlbumLinks[eventID]?.first { $0.albumID == albumID }
        let name = removed?.albumName ?? ""
        immichAlbumLinks[eventID]?.removeAll { $0.albumID == albumID }
        if immichAlbumLinks[eventID]?.isEmpty == true { immichAlbumLinks[eventID] = nil }
        statusMessage = "Removed the link to “\(name)”. The album stays in Immich as it is."
        let catalogURL = catalogURLForImmich
        return Task { @MainActor [weak self] () -> Void in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try ImmichEventAlbumStore(catalogURL: catalogURL).dismissLink(eventID: eventID, albumID: albumID, albumName: name)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self, let failure else { return }
            // Not saved: show the link again and say so.
            if let removed, !(immichAlbumLinks[eventID] ?? []).contains(where: { $0.albumID == albumID }) {
                immichAlbumLinks[eventID, default: []].append(removed)
            }
            statusMessage = "Could not remove the link to “\(name)”: \(failure)"
        }
    }

    /// The event no longer uses `albumID` as its own album (another album
    /// was picked, a new one asked for, or none): the catalog forgets the
    /// album's last state and remembers the move, so Pair Albums does not
    /// pair the album with the event again.
    @discardableResult
    func forgetImmichAlbum(_ albumID: String?, name: String?, for eventID: UUID) -> Task<Void, Never> {
        let catalogURL = catalogURLForImmich
        return Task.detached(priority: .utility) {
            guard let store = try? ImmichEventAlbumStore(catalogURL: catalogURL) else { return }
            try? store.remove(eventIDs: [eventID])
            if let albumID { try? store.dismissLink(eventID: eventID, albumID: albumID, albumName: name ?? "") }
        }
    }

    /// The account's albums for the Album menus, when none are loaded yet.
    func loadImmichAlbumsIfNeeded() {
        guard immichLibraryIsChosen, immichAlbums.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, let client = try? makeImmichClient(), let albums = try? await client.albums() else { return }
            immichAlbums = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if immichCurrentUserID == nil { immichCurrentUserID = try? await client.currentUserID() }
        }
    }

    /// Someone else's album, or one whose owner cannot be confirmed.
    func immichAlbumIsShared(_ album: ImmichAlbum) -> Bool {
        guard let owner = album.ownerID else { return false }
        return owner != immichCurrentUserID
    }

    func loadImmichAlbumStates() {
        let catalogURL = catalogURLForImmich
        Task { @MainActor [weak self] in
            let (states, records, links, stackedEvents) = await Task.detached(priority: .utility) {
                ((try? ImmichEventAlbumStore(catalogURL: catalogURL).all()) ?? [:],
                 (try? ImmichStackStore(catalogURL: catalogURL).records()) ?? [:],
                 ImmichEventAlbumStore.existingLinks(catalogURL: catalogURL),
                 ImmichStackEventStore.existing(catalogURL: catalogURL))
            }.value
            if self?.immichStackedEventIDs != stackedEvents { self?.immichStackedEventIDs = stackedEvents }
            let linksByEvent = Dictionary(grouping: links, by: \.eventID)
            if self?.immichAlbumLinks != linksByEvent { self?.immichAlbumLinks = linksByEvent }
            let live = records.values.filter { !$0.stackID.isEmpty && $0.removedInImmich != true }
            let counts = live.reduce(into: [UUID: Int]()) { $0[$1.eventID, default: 0] += 1 }
            let keys = Set(live.map(\.key))
            let unstacked = Set(records.values.filter { $0.removedInImmich == true }.map(\.key))
            if self?.immichUnstackedKeys != unstacked { self?.immichUnstackedKeys = unstacked }
            if self?.immichAlbumStates != states { self?.immichAlbumStates = states }
            if self?.immichStackCounts != counts { self?.immichStackCounts = counts }
            if self?.immichStackedKeys != keys { self?.immichStackedKeys = keys }
        }
    }

    // MARK: - Key

    /// Says whether a key is saved, and whether an earlier build left one
    /// under another Keychain service. Reads names only, never the secret.
    func refreshImmichKeyStatus() {
        let services = KeychainSecretStore.otherServices(holding: Self.immichAPIKeyAccount, excluding: "")
        immichKeyIsSaved = services.contains(Self.keychainService)
        // Only entries an earlier Camera Toolkit build wrote (a bundle ID
        // ending in .CameraToolkit), never another app's.
        immichEarlierKeyServices = services.filter { $0 != Self.keychainService && $0.hasSuffix(".CameraToolkit") }
    }

    /// Copies the key an earlier build saved into this build's Keychain
    /// entry, on the user's click. macOS asks before the old entry is read.
    /// The old entry is left where it is.
    func moveEarlierImmichKey() {
        guard let service = immichEarlierKeyServices.first else { return }
        do {
            guard let key = try KeychainSecretStore(service: service).read(account: Self.immichAPIKeyAccount),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                immichConnectionStatus = "The earlier key is empty."
                return
            }
            try secretStore.save(key, account: Self.immichAPIKeyAccount)
            immichConnectionStatus = "Moved the earlier API key into this app's Keychain entry. Press Test Connection."
        } catch {
            immichConnectionStatus = "Could not move the earlier key: \(error.localizedDescription)"
        }
        refreshImmichKeyStatus()
    }

    // MARK: - View in Immich

    /// Where View in Immich goes for an event: always its folder in Immich's
    /// folder view (Show Album opens its albums), else the server's home
    /// page when the library's folder is not known yet. Nil when no server
    /// is set.
    func immichWebURL(for event: SavedCameraEvent) -> URL? {
        let library = immichLibrary ?? immichLibraries.first { $0.id == configuration.immichLibraryID }
        return Self.immichFolderURL(
            server: configuration.immichServerURL,
            importRoot: library?.importPaths.first,
            eventFolder: EventStorageLocations(configuration: configuration).nasEventFolderRelativePath(for: event)
        )
    }

    /// An event folder's page in Immich's folder view, else the server's home.
    static func immichFolderURL(server: String, importRoot: String?, eventFolder: String) -> URL? {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return nil }
        if let root = importRoot, !root.isEmpty {
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            if let url = ImmichClient.webURL(serverURL: server, folder: "\(trimmed)/\(eventFolder)") { return url }
        }
        return ImmichClient.webURL(serverURL: server)
    }

    /// The albums Show Album lists for an event: its own album first, then
    /// its "also in" albums by name. Empty when it has none, or no server.
    func immichAlbumChoices(for event: SavedCameraEvent) -> [ImmichAlbumChoice] {
        let state = immichAlbumStates[event.id]
        let mainID = state?.albumID ?? event.immichAlbumID
        let mainName = state?.albumName ?? event.immichAlbumName ?? event.name
        let currentNames = Dictionary(immichAlbums.map { ($0.id, $0.name) }) { first, _ in first }
        return Self.immichAlbumChoices(
            server: configuration.immichServerURL,
            main: mainID.map { ($0, mainName) },
            links: immichAlbumLinks[event.id] ?? [],
            currentNames: currentNames
        )
    }

    static func immichAlbumChoices(
        server: String,
        main: (id: String, name: String)?,
        links: [ImmichEventAlbumLink],
        currentNames: [String: String] = [:]
    ) -> [ImmichAlbumChoice] {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return [] }
        var choices: [ImmichAlbumChoice] = []
        if let main, let url = ImmichClient.webURL(serverURL: server, albumID: main.id) {
            choices.append(ImmichAlbumChoice(albumID: main.id, name: currentNames[main.id] ?? main.name, isMain: true, url: url))
        }
        var seen = Set(choices.map(\.albumID))
        let also = links.compactMap { link -> ImmichAlbumChoice? in
            guard seen.insert(link.albumID).inserted, let url = ImmichClient.webURL(serverURL: server, albumID: link.albumID) else { return nil }
            return ImmichAlbumChoice(albumID: link.albumID, name: currentNames[link.albumID] ?? link.albumName, isMain: false, url: url)
        }
        return choices + also.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var immichServerIsSet: Bool {
        !configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - One event's album

    /// Links an album the user picked. It is filled only when it already
    /// holds most of the event (checked right after), or when the user turns
    /// filling on; someone else's album is never filled.
    func pairEvent(_ eventID: UUID, withImmichAlbum album: ImmichAlbum) {
        let shared = immichAlbumIsShared(album)
        if let previous = event(eventID), let old = previous.immichAlbumID, old != album.id {
            forgetImmichAlbum(old, name: previous.immichAlbumName, for: eventID)
        }
        updateConfiguration { configuration in
            // One album belongs to one event: a previous holder lets go.
            for index in configuration.savedEvents.indices where configuration.savedEvents[index].immichAlbumID == album.id {
                configuration.savedEvents[index].unpairImmichAlbum()
            }
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].pairImmichAlbum(album, fills: false, shared: shared)
        }
        immichAlbumStates[eventID] = nil
        statusMessage = shared
            ? "Linked to “\(album.name)”, which is shared with you. The app never adds to someone else's album."
            : "Linked to “\(album.name)” as a picks album. Checking whether it already holds this event…"
        guard !shared else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let client = try makeImmichClient()
                let library: ImmichLibrary
                if let known = immichLibrary { library = known } else { library = try await client.library(id: configuration.immichLibraryID) }
                let inAlbum = try await client.albumAssets(albumID: album.id)
                let files = await immichCatalogFiles().filter { $0.eventID == eventID }
                let paths = ImmichLibraryPaths(importPaths: library.importPaths)
                let mine = Set(files.map { NASSyncStore.pathKey($0.relativePath) })
                let matched = inAlbum.count { asset in
                    paths.relativePath(forOriginalPath: asset.originalPath).map { mine.contains(NASSyncStore.pathKey($0)) } ?? false
                }
                let media = OrganizeFileClassifier.rawExtensions.union(OrganizeFileClassifier.photoExtensions).union(OrganizeFileClassifier.videoExtensions)
                let eventMedia = files.count { media.contains(($0.relativePath as NSString).pathExtension.lowercased()) }
                guard event(eventID)?.immichAlbumID == album.id else { return }
                if SavedCameraEvent.immichAlbumHoldsWholeEvent(matched: matched, eventMediaCount: eventMedia) {
                    setImmichAlbumFill(for: eventID, fills: true)
                } else {
                    statusMessage = "Linked to “\(album.name)” as a picks album (\(matched) of \(eventMedia) photos). Turn on Keep This Album Filled to add the whole event."
                }
            } catch {
                statusMessage = "Linked to “\(album.name)” as a picks album; could not check it: \(error.localizedDescription)"
            }
        }
    }

    private func event(_ id: UUID) -> SavedCameraEvent? {
        configuration.savedEvents.first { $0.id == id }
    }

    /// Clears the app's memory that these stacks were unstacked in Immich,
    /// so the next check makes them again.
    func stackAgainInImmich(groupKeys: Set<String>) {
        guard !groupKeys.isEmpty else { return }
        let catalogURL = catalogURLForImmich
        Task { @MainActor [weak self] in
            await Task.detached(priority: .utility) { try? ImmichStackStore(catalogURL: catalogURL).remove(keys: groupKeys) }.value
            self?.loadImmichAlbumStates()
            self?.statusMessage = groupKeys.count == 1
                ? "This burst is stacked again on the next Immich check."
                : "\(groupKeys.count) bursts are stacked again on the next Immich check."
        }
    }

    /// Whether checks keep a paired album filled with the whole event.
    func setImmichAlbumFill(for eventID: UUID, fills: Bool) {
        if fills, event(eventID)?.immichAlbumShared == true {
            statusMessage = "This album is shared with you; the app never adds to someone else's album."
            return
        }
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].immichAlbumFill = fills
            configuration.savedEvents[index].immichAlbumAutomatic = nil
        }
        statusMessage = fills
            ? "The album is kept filled with this event's photos from the next check. Nothing is removed from it."
            : "The album stays linked; checks no longer add photos to it."
    }

    @discardableResult
    func useNewImmichAlbum(for eventID: UUID) -> Task<Void, Never> {
        let previous = event(eventID)
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].useNewImmichAlbumNamedAfterEvent()
        }
        immichAlbumStates[eventID] = nil
        statusMessage = "A new album named after the event is made on the next check."
        // The stored state would still offer the old album in Show Album.
        return forgetImmichAlbum(previous?.immichAlbumID, name: previous?.immichAlbumName, for: eventID)
    }

    func unpairImmichAlbum(for eventID: UUID) {
        let previous = event(eventID)
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].unpairImmichAlbum()
        }
        immichAlbumStates[eventID] = nil
        forgetImmichAlbum(previous?.immichAlbumID, name: previous?.immichAlbumName, for: eventID)
        statusMessage = "No album for this event. The album stays in Immich as it is."
    }

    /// What a check learned about albums: an album made or found by name is
    /// paired by ID from now on, a renamed album's name is updated, and the
    /// per-event counts are kept.
    func applyImmichAlbumOutcome(_ outcome: ImmichLibrarySyncOutcome) {
        let resolved = outcome.resolvedAlbums
        let needsUpdate = configuration.savedEvents.contains { event in
            guard let album = resolved[event.id] else { return false }
            return event.immichAlbumID != album.id || event.immichAlbumName != album.name
        }
        if needsUpdate {
            updateConfiguration { configuration in
                for index in configuration.savedEvents.indices {
                    guard let album = resolved[configuration.savedEvents[index].id] else { continue }
                    let event = configuration.savedEvents[index]
                    if event.immichAlbumID == nil {
                        // An album made by name is paired by ID from now on. One
                        // the every-event switch made is marked, so turning the
                        // switch off stops filling it.
                        configuration.savedEvents[index].pairImmichAlbum(album, fills: true, automatic: event.immichAlbumPolicy == nil)
                    } else if event.immichAlbumName != album.name {
                        configuration.savedEvents[index].immichAlbumName = album.name
                    }
                }
            }
        }
        for (eventID, state) in outcome.albumStates where immichAlbumStates[eventID] != state {
            immichAlbumStates[eventID] = state
        }
        if let library = outcome.library { immichLibrary = library }
        for (key, state) in outcome.graded.states where immichGradedCopyStates[key] != state {
            immichGradedCopyStates[key] = state
        }
        if let created = outcome.stacks?.created, !created.isEmpty { loadImmichAlbumStates() }
    }
}

/// One album Show Album can open: the event's own album or an "also in" one.
struct ImmichAlbumChoice: Identifiable, Equatable {
    var id: String { albumID }
    var albumID: String
    var name: String
    /// The event's own album (the one that may be kept filled).
    var isMain: Bool
    var url: URL
}

extension DashboardModel {
    /// A render job's copies: kept for the Jobs window, and in the job's
    /// history so a later session shows them too.
    func noteRenderedCopies(_ copies: [JobGradedCopy], jobID: UUID) {
        guard !copies.isEmpty else { return }
        renderedCopiesByJob[jobID] = copies
        jobHistoryRecorders[jobID]?.noteGradedCopies(copies)
    }
}
