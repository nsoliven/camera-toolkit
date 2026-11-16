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
            carriesAlbumsAcrossRenames: configuration.immichCarriesAlbumsAcrossRenames
        )
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
    func pairImmichAlbums() {
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
                let albums = try await client.albums()
                immichAlbums = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                var contents: [ImmichAlbumContents] = []
                for (index, album) in albums.enumerated() {
                    immichPairingNote = "Reading album \(index + 1) of \(albums.count)…"
                    let assets = try await client.albumAssets(albumID: album.id)
                    contents.append(ImmichAlbumContents(album: album, originalPaths: assets.map(\.originalPath)))
                }
                let files = await immichCatalogFiles()
                let events = configuration.savedEvents
                let locations = EventStorageLocations(configuration: configuration)
                let result = ImmichAlbumPairing.pair(albums: contents, events: events, files: files, library: library, locations: locations)
                let pairs = Dictionary(result.pairs.map { ($0.eventID, $0.album) }) { first, _ in first }
                if !pairs.isEmpty {
                    updateConfiguration { configuration in
                        for index in configuration.savedEvents.indices {
                            if let album = pairs[configuration.savedEvents[index].id] {
                                configuration.savedEvents[index].pairImmichAlbum(album)
                            }
                        }
                    }
                }
                immichPairing = result
                immichPairingNote = "Paired \(result.pairs.count) album\(result.pairs.count == 1 ? "" : "s"); \(result.unpaired.count) not paired. Nothing was changed in Immich."
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
            guard let self, let albums = try? await makeImmichClient().albums() else { return }
            immichAlbums = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func loadImmichAlbumStates() {
        let catalogURL = catalogURLForImmich
        Task { @MainActor [weak self] in
            let states = await Task.detached(priority: .utility) {
                (try? ImmichEventAlbumStore(catalogURL: catalogURL).all()) ?? [:]
            }.value
            if self?.immichAlbumStates != states { self?.immichAlbumStates = states }
        }
    }

    // MARK: - One event's album

    func pairEvent(_ eventID: UUID, withImmichAlbum album: ImmichAlbum) {
        updateConfiguration { configuration in
            // One album fills one event: a previous holder lets go.
            for index in configuration.savedEvents.indices where configuration.savedEvents[index].immichAlbumID == album.id {
                configuration.savedEvents[index].unpairImmichAlbum()
            }
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].pairImmichAlbum(album)
        }
        immichAlbumStates[eventID] = nil
        statusMessage = "Paired with “\(album.name)”. New photos are added on the next check; nothing is removed from it."
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
                    if event.immichAlbumID != album.id || event.immichAlbumName != album.name {
                        configuration.savedEvents[index].pairImmichAlbum(album)
                    }
                }
            }
        }
        for (eventID, state) in outcome.albumStates where immichAlbumStates[eventID] != state {
            immichAlbumStates[eventID] = state
        }
    }
}
