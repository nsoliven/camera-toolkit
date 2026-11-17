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
    /// Graded copies (`ImmichGradedAlbumSwap`): in the album in their
    /// original's place, on the NAS but not listed yet, still on the drive.
    var gradedInAlbum = 0
    var gradedWaiting = 0
    var gradedOnDrive = 0
    /// Gone from the NAS, offline or trashed in Immich, or excluded by the
    /// library: the flat original keeps its album place.
    var gradedMissing = 0
}

struct ImmichSendState: Equatable {
    enum Phase: Equatable {
        /// Graded copies of log clips being rendered first (`ImmichSendGrading`).
        case rendering(count: Int, detail: String?)
        case scanning(waiting: Int?)
        case adding(count: Int, album: String)
        case stacking
        case done
        case failed(String)
    }

    var phase: Phase
    var eventCount: Int
    var results: [ImmichSendResult] = []
    var addedToAlbums = 0
    var stacksMade = 0
    var renderedCopies = 0
    var renderFailures = 0
    var gradedSwapped = 0
    var originalsRemoved = 0

    var isFinished: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    var line: String {
        switch phase {
        case .rendering(let count, let detail):
            "Rendering \(count.formatted()) graded cop\(count == 1 ? "y" : "ies")…" + (detail.map { " \($0)" } ?? "")
        case .scanning(nil): "Asking Immich to scan…"
        case .scanning(let waiting?): waiting == 0 ? "Scanning… all files found" : "Scanning… waiting for \(waiting.formatted()) file\(waiting == 1 ? "" : "s")"
        case .adding(let count, let album): "Adding \(count.formatted()) photo\(count == 1 ? "" : "s") to “\(album)”…"
        case .stacking: "Stacking bursts and edits…"
        case .done:
            [
                "Done.",
                addedToAlbums > 0 ? "Added \(addedToAlbums.formatted()) photo\(addedToAlbums == 1 ? "" : "s") to albums." : nil,
                stacksMade > 0 ? "Made \(stacksMade.formatted()) stack\(stacksMade == 1 ? "" : "s")." : nil,
                renderedCopies > 0 ? "Rendered \(renderedCopies.formatted()) graded cop\(renderedCopies == 1 ? "y" : "ies")." : nil,
                renderFailures > 0 ? "\(renderFailures.formatted()) could not be rendered (see Jobs)." : nil,
                gradedSwapped > 0 ? "\(gradedSwapped.formatted()) graded cop\(gradedSwapped == 1 ? "y is" : "ies are") in albums in place of the flat original\(gradedSwapped == 1 ? "" : "s")." : nil,
                originalsRemoved > 0 ? "Took \(originalsRemoved.formatted()) flat original\(originalsRemoved == 1 ? "" : "s") out of albums (still in Immich)." : nil
            ].compactMap { $0 }.joined(separator: " ")
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
                    let waiting = look.report.count(.pendingScan) + look.graded.waitingForScan.count
                    immichSend?.phase = .scanning(waiting: waiting)
                    if waiting == 0 || Date() >= deadline { break }
                    try await Task.sleep(nanoseconds: Self.immichSendPollInterval * 1_000_000_000)
                    files = await model.immichCatalogFiles()
                }
                let outcome = try await sync.check(files: files, events: eventIDs, fillsAlbums: true) { [weak self] step in
                    let phase: ImmichSendState.Phase? = switch step {
                    case .adding(let count, let album): .adding(count: count, album: album)
                    case .stacking: .stacking
                    default: nil
                    }
                    guard let phase else { return }
                    Task { @MainActor in self?.immichSend?.phase = phase }
                }
                model.applyImmichAlbumOutcome(outcome)
                immichSend?.addedToAlbums = outcome.addedToAlbums
                immichSend?.stacksMade = outcome.stacks?.created.count ?? 0
                immichSend?.gradedSwapped = outcome.graded.swaps.count
                immichSend?.originalsRemoved = outcome.graded.removedOriginals
                immichSend?.results = await immichSendResults(eventIDs, graded: outcome.graded)
                immichSend?.phase = outcome.problems.isEmpty ? .done : .failed("Done with problems: " + outcome.problems.prefix(3).joined(separator: "; "))
                immichCheckLine = outcome.summary
                await reloadShownImmichStatusesForSend()
                // Anything Immich had not listed yet joins on the usual schedule.
                if outcome.waitsForScan { followNASChangeInImmich() }
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
        grading.immichSendAsk = nil
    }

    private func immichSendResults(_ eventIDs: Set<UUID>, graded: ImmichGradedSwapReport = ImmichGradedSwapReport()) async -> [ImmichSendResult] {
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
                waiting: summary.pendingScan,
                gradedInAlbum: graded.swapsByEvent[id] ?? 0,
                gradedWaiting: graded.waitingByEvent[id] ?? 0,
                gradedOnDrive: graded.notOnNASByEvent[id] ?? 0,
                gradedMissing: (graded.unavailableByEvent[id] ?? 0) + (graded.excludedByEvent[id] ?? 0)
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
