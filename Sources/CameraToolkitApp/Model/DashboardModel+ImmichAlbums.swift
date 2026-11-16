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
            reservedAlbumIDs: Set(configuration.savedEvents.compactMap(\.immichAlbumID)),
            stackableEventIDs: ImmichStackGrouping.stackableEventIDs(
                events: configuration.savedEvents,
                locations: EventStorageLocations(configuration: configuration)
            ),
            logFolder: immichLogFolder
        )
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
    /// match is clear. Writes nothing to Immich.
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
                let result = ImmichAlbumPairing.pair(albums: contents, events: events, files: files, library: library, locations: locations, currentUserID: me)
                let pairs = Dictionary(result.pairs.map { ($0.eventID, $0) }) { first, _ in first }
                if !pairs.isEmpty {
                    // Event albums are kept filled; picks albums are only linked.
                    updateConfiguration { configuration in
                        for index in configuration.savedEvents.indices {
                            if let pair = pairs[configuration.savedEvents[index].id] {
                                configuration.savedEvents[index].pairImmichAlbum(pair.album, fills: allowsFilling && pair.fills)
                            }
                        }
                    }
                }
                immichPairing = result
                let picks = result.pairs.count { !(allowsFilling && $0.fills) }
                immichPairingNote = "Paired \(result.pairs.count) album\(result.pairs.count == 1 ? "" : "s") (\(picks) picks, linked only); \(result.unpaired.count) not paired. Nothing was changed in Immich."
                loadImmichAlbumStates()
            } catch {
                immichPairingNote = "Pairing failed: \(error.localizedDescription)"
            }
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
            let (states, records) = await Task.detached(priority: .utility) {
                ((try? ImmichEventAlbumStore(catalogURL: catalogURL).all()) ?? [:],
                 (try? ImmichStackStore(catalogURL: catalogURL).records()) ?? [:])
            }.value
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

    /// Where View in Immich goes for an event: its paired album, else its
    /// folder in Immich's folder view, else the server's home page. Nil when
    /// no server is set.
    func immichWebURL(for event: SavedCameraEvent) -> URL? {
        let server = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return nil }
        if let albumID = immichAlbumStates[event.id]?.albumID ?? event.immichAlbumID,
           let url = ImmichClient.webURL(serverURL: server, albumID: albumID) {
            return url
        }
        let library = immichLibrary ?? immichLibraries.first { $0.id == configuration.immichLibraryID }
        if let root = library?.importPaths.first {
            let folder = EventStorageLocations(configuration: configuration).nasEventFolderRelativePath(for: event)
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            if let url = ImmichClient.webURL(serverURL: server, folder: "\(trimmed)/\(folder)") { return url }
        }
        return ImmichClient.webURL(serverURL: server)
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

    func useNewImmichAlbum(for eventID: UUID) {
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].useNewImmichAlbumNamedAfterEvent()
        }
        immichAlbumStates[eventID] = nil
        statusMessage = "A new album named after the event is made on the next check."
    }

    func unpairImmichAlbum(for eventID: UUID) {
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].unpairImmichAlbum()
        }
        immichAlbumStates[eventID] = nil
        let catalogURL = catalogURLForImmich
        Task.detached(priority: .utility) { try? ImmichEventAlbumStore(catalogURL: catalogURL).remove(eventIDs: [eventID]) }
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
        if let created = outcome.stacks?.created, !created.isEmpty { loadImmichAlbumStates() }
    }
}
