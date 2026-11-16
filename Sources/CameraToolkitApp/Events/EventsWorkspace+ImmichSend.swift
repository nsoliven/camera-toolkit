import CameraToolkitCore
import Foundation

/// "Send to Immich": Immich already reads the NAS, so sending means asking it
/// to scan now, waiting a little for the chosen events' files to show up, and
/// filling their albums at once instead of on the background schedule.
struct ImmichSendRequest: Identifiable {
    let id = UUID()
    var eventIDs: Set<UUID>
}

struct ImmichSendResult: Equatable, Identifiable {
    var id: UUID
    var eventName: String
    var inImmich: Int
    var albumName: String?
    var inAlbum: Int?
    /// Photos with no verified NAS copy: Immich cannot have them yet.
    var notOnNAS: Int
    /// On the NAS, not listed by Immich yet when the wait ended.
    var waiting: Int
}

struct ImmichSendState: Equatable {
    enum Phase: Equatable {
        case scanning(waiting: Int?)
        case adding(count: Int, album: String)
        case done
        case failed(String)
    }

    var phase: Phase
    var eventCount: Int
    var results: [ImmichSendResult] = []
    var addedToAlbums = 0

    var isFinished: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    var line: String {
        switch phase {
        case .scanning(nil): "Asking Immich to scan…"
        case .scanning(let waiting?): waiting == 0 ? "Scanning… all files found" : "Scanning… waiting for \(waiting.formatted()) file\(waiting == 1 ? "" : "s")"
        case .adding(let count, let album): "Adding \(count.formatted()) photo\(count == 1 ? "" : "s") to “\(album)”…"
        case .done: addedToAlbums > 0 ? "Done. Added \(addedToAlbums.formatted()) photo\(addedToAlbums == 1 ? "" : "s") to albums." : "Done."
        case .failed(let message): message
        }
    }
}

extension EventsWorkspace {
    /// How long Send waits for Immich's scan to list the files before it
    /// fills albums with what is there; the rest follows on the next check.
    nonisolated static let immichSendScanWait: TimeInterval = 90
    nonisolated static let immichSendPollInterval: UInt64 = 4

    func requestImmichSend(_ eventIDs: Set<UUID>) {
        guard immichIsConfigured else {
            model.statusMessage = "Choose your Immich library in Settings first."
            return
        }
        immichSend = nil
        immichSendRequest = ImmichSendRequest(eventIDs: eventIDs)
    }

    func sendToImmich(_ eventIDs: Set<UUID>) {
        guard !eventIDs.isEmpty, immichSend?.isFinished ?? true else { return }
        immichFollowUp?.cancel()
        immichSend = ImmichSendState(phase: .scanning(waiting: nil), eventCount: eventIDs.count)
        immichSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sync = try model.makeImmichSync()
                try await sync.requestScan()
                let deadline = Date().addingTimeInterval(Self.immichSendScanWait)
                var files = await model.immichCatalogFiles()
                while true {
                    let look = try await sync.check(files: files, events: eventIDs, fillsAlbums: false)
                    let waiting = look.report.count(.pendingScan)
                    immichSend?.phase = .scanning(waiting: waiting)
                    if waiting == 0 || Date() >= deadline { break }
                    try await Task.sleep(nanoseconds: Self.immichSendPollInterval * 1_000_000_000)
                    files = await model.immichCatalogFiles()
                }
                let outcome = try await sync.check(files: files, events: eventIDs, fillsAlbums: true) { [weak self] step in
                    guard case .adding(let count, let album) = step else { return }
                    Task { @MainActor in self?.immichSend?.phase = .adding(count: count, album: album) }
                }
                model.applyImmichAlbumOutcome(outcome)
                immichSend?.addedToAlbums = outcome.addedToAlbums
                immichSend?.results = await immichSendResults(eventIDs)
                immichSend?.phase = outcome.problems.isEmpty ? .done : .failed("Done with problems: " + outcome.problems.prefix(3).joined(separator: "; "))
                immichCheckLine = outcome.summary
                await reloadShownImmichStatusesForSend()
                // Anything Immich had not listed yet joins on the usual schedule.
                if outcome.report.count(.pendingScan) > 0 { followNASChangeInImmich() }
            } catch {
                guard !Task.isCancelled else { return }
                immichSend?.phase = .failed("Immich: \(error.localizedDescription)")
            }
        }
    }

    func cancelImmichSend() {
        immichSendTask?.cancel()
        immichSendTask = nil
        immichSend = nil
        immichSendRequest = nil
    }

    private func immichSendResults(_ eventIDs: Set<UUID>) async -> [ImmichSendResult] {
        let catalogURL = model.catalogURLForImmich
        let ids = Array(eventIDs)
        let statuses = await Task.detached(priority: .utility) { () -> [UUID: [ImmichCatalogStatus]] in
            let inspector = CatalogInspector(url: catalogURL)
            var result: [UUID: [ImmichCatalogStatus]] = [:]
            for id in ids {
                result[id] = Array(((try? inspector.immichStatuses(eventID: id)) ?? [:]).values)
            }
            return result
        }.value
        let targets = immichAlbumTargets
        return ids.compactMap { id -> ImmichSendResult? in
            guard let event = event(id) else { return nil }
            let summary = ImmichEventSummary(statuses: statuses[id] ?? [])
            let state = model.immichAlbumStates[id]
            return ImmichSendResult(
                id: id,
                eventName: event.name,
                inImmich: summary.inImmich,
                albumName: state?.albumName ?? targets[id]?.displayName,
                inAlbum: state?.inAlbum,
                notOnNAS: summary.notOnNAS,
                waiting: summary.pendingScan
            )
        }
        .sorted { $0.eventName.localizedStandardCompare($1.eventName) == .orderedAscending }
    }

    private func reloadShownImmichStatusesForSend() async {
        let catalogURL = model.catalogURLForImmich
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
