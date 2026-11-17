import AppKit
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

    /// Every event's Immich album, for the storage strip and the header chip.
    var immichAlbumTargets: [UUID: ImmichAlbumTarget] {
        ImmichAlbumNaming.targets(
            events: model.configuration.savedEvents,
            locations: locations,
            albumsForEveryEvent: model.configuration.immichAlbumsForEveryEvent
        )
    }

    /// The single post-copy hook: files landed on the NAS or were renamed
    /// there. It records the renames, asks Immich to scan, and the checks that
    /// follow fill event albums. Every path that puts files on the NAS calls
    /// it once its copies are verified; it does nothing until a library is
    /// chosen in Settings.
    func followNASChangeInImmich(moves: [NASRename] = []) {
        nasChangeFollowObserver?(moves)
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
                if !outcome.waitsForScan { break }
            }
        } catch {
            // A newer follow-up took over.
            guard !Task.isCancelled else { return }
            immichCheckLine = "Immich check failed: \(error.localizedDescription)"
            if reportsToStatusLine { model.statusMessage = immichCheckLine }
        }
    }

    private func makeImmichSync() throws -> ImmichLibrarySync {
        try model.makeImmichSync()
    }

    private func checkImmichOnce(_ sync: ImmichLibrarySync) async throws -> ImmichLibrarySyncOutcome {
        let outcome = try await sync.check(files: await model.immichCatalogFiles())
        model.applyImmichAlbumOutcome(outcome)
        return outcome
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

    /// Opens a frame's own Immich page when the last check matched it, else
    /// its event's page.
    func viewInImmich(_ item: OrganizeItem, boardEventID: UUID) {
        let server = model.configuration.immichServerURL
        if let assignment = assignment(for: item.primary),
           let assetID = eventImmichStatuses[boardEventID]?[CatalogStore.eventAssetID(assignment)]?.immichAssetID,
           let url = ImmichClient.webURL(serverURL: server, assetID: assetID) {
            NSWorkspace.shared.open(url)
            return
        }
        let event = assignment(for: item.primary).flatMap { event($0.eventID) } ?? event(boardEventID)
        if let event, let url = model.immichWebURL(for: event) { NSWorkspace.shared.open(url) }
    }

    /// The app made this burst one Immich stack: the same key the grouping
    /// gives it (event, kind, first frame).
    /// The burst's group key when someone unstacked the app's stack of it
    /// in Immich; nil otherwise.
    func immichUnstackedKey(for stack: OrganizeStack, eventID: UUID) -> String? {
        guard stack.isBurst, !model.immichUnstackedKeys.isEmpty, let first = stack.items.first?.primary else { return nil }
        let identity = BurstFrameIdentity.key(fileName: first.name, byteCount: first.size, modifiedAt: first.modifiedAt)
        let key = "\(eventID.uuidString)|burst|\(identity)"
        return model.immichUnstackedKeys.contains(key) ? key : nil
    }

    func isStackedInImmich(_ stack: OrganizeStack, eventID: UUID) -> Bool {
        guard stack.isBurst, !model.immichStackedKeys.isEmpty, let first = stack.items.first?.primary else { return false }
        let identity = BurstFrameIdentity.key(fileName: first.name, byteCount: first.size, modifiedAt: first.modifiedAt)
        return model.immichStackedKeys.contains("\(eventID.uuidString)|burst|\(identity)")
    }
}
