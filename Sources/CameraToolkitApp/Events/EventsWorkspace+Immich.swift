import CameraToolkitCore
import Foundation

/// External-library mode: Immich reads the NAS itself. After the NAS changes
/// the app asks for a scan, then compares paths until the scan has caught up.
/// All of it is network reads off the job gate, so Immich being slow or away
/// never holds up a file job.
extension EventsWorkspace {
    /// Seconds to wait before each look at the library. Scans run on the
    /// server and take a while on a large library; the looks stop as soon as
    /// nothing is waiting.
    nonisolated static let immichFollowUpDelays: [UInt64] = [15, 60, 300, 900]
    /// The Check button answers at once, then looks again shortly.
    nonisolated static let immichManualDelays: [UInt64] = [0, 30, 120]

    var immichIsConfigured: Bool {
        !model.configuration.immichLibraryID.isEmpty
            && !model.configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The NAS changed: remember its renames and have Immich catch up.
    func followNASChangeInImmich(moves: [NASRename] = []) {
        guard immichIsConfigured else { return }
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        immichScanOwed = true
        immichFollowUp?.cancel()
        immichFollowUp = Task { [weak self] in
            if !moves.isEmpty {
                // Detached so a newer follow-up cannot cancel the write.
                await Task.detached(priority: .utility) {
                    try? ImmichPathMoveStore(catalogURL: catalogURL).record(moves)
                }.value
            }
            await self?.runImmichChecks(reportsToStatusLine: false)
        }
    }

    /// The Check button: scan and compare now, and say how it went.
    func checkImmichNow() {
        guard immichIsConfigured else {
            model.statusMessage = "Choose your Immich library in Settings first."
            return
        }
        immichScanOwed = true
        immichFollowUp?.cancel()
        immichFollowUp = Task { [weak self] in
            await self?.runImmichChecks(reportsToStatusLine: true)
        }
    }

    private func runImmichChecks(reportsToStatusLine: Bool) async {
        guard !Task.isCancelled else { return }
        let sync: ImmichLibrarySync
        do {
            sync = try makeImmichSync()
        } catch {
            immichCheckLine = error.localizedDescription
            if reportsToStatusLine { model.statusMessage = "Immich: \(error.localizedDescription)" }
            return
        }
        immichIsChecking = true
        defer { immichIsChecking = false }
        do {
            if immichScanOwed {
                try await sync.requestScan()
                immichScanOwed = false
            }
            for delay in reportsToStatusLine ? Self.immichManualDelays : Self.immichFollowUpDelays {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                let outcome = try await checkImmichOnce(sync)
                immichCheckLine = outcome.summary
                await reloadShownImmichStatuses()
                if reportsToStatusLine { model.statusMessage = "Immich: \(outcome.summary)." }
                if outcome.report.count(.pendingScan) == 0 { break }
            }
        } catch {
            // A newer follow-up took over.
            guard !Task.isCancelled else { return }
            immichCheckLine = "Immich check failed: \(error.localizedDescription)"
            if reportsToStatusLine { model.statusMessage = immichCheckLine }
        }
    }

    private func makeImmichSync() throws -> ImmichLibrarySync {
        let configuration = model.configuration
        var apiKey = model.immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            apiKey = (try model.secretStore.read(account: DashboardModel.immichAPIKeyAccount))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !apiKey.isEmpty else {
            throw ToolkitError.commandFailed("Save an Immich API key in Settings first.")
        }
        return ImmichLibrarySync(
            client: try ImmichClient(serverURL: configuration.immichServerURL, apiKey: apiKey),
            libraryID: configuration.immichLibraryID,
            catalogURL: URL(fileURLWithPath: DashboardModel.expandedPath(configuration.catalogDatabasePath)),
            carriesAlbumsAcrossRenames: configuration.immichCarriesAlbumsAcrossRenames
        )
    }

    private func checkImmichOnce(_ sync: ImmichLibrarySync) async throws -> ImmichLibrarySyncOutcome {
        let assignments = model.configuration.photoEventAssignments
        let events = model.configuration.savedEvents
        let locations = self.locations
        let catalogURL = sync.catalogURL
        let files = await Task.detached(priority: .utility) { () -> [ImmichCatalogFile] in
            let verified = NASSyncStore.existingRecords(catalogURL: catalogURL, nasRoot: locations.nasRoot.path)
                .filter { $0.value.state == .verified }
            return ImmichCatalogFile.build(
                assignments: assignments,
                events: events,
                locations: locations,
                verifiedPathKeys: Set(verified.keys)
            )
        }.value
        return try await sync.check(files: files)
    }

    /// Boards already open read the new answer without a full refresh.
    private func reloadShownImmichStatuses() async {
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let families = eventImmichStatuses.keys.map { ($0, eventFamily($0).map(\.id)) }
        let loaded = await Task.detached(priority: .utility) { () -> [UUID: [String: ImmichCatalogStatus]] in
            let inspector = CatalogInspector(url: catalogURL)
            var result: [UUID: [String: ImmichCatalogStatus]] = [:]
            for (eventID, members) in families {
                var statuses: [String: ImmichCatalogStatus] = [:]
                for member in members {
                    statuses.merge((try? inspector.immichStatuses(eventID: member)) ?? [:]) { current, _ in current }
                }
                result[eventID] = statuses
            }
            return result
        }.value
        for (eventID, statuses) in loaded where eventImmichStatuses[eventID] != statuses {
            eventImmichStatuses[eventID] = statuses
        }
    }
}
