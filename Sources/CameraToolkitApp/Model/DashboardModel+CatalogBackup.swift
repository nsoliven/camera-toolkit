import CameraToolkitCore
import Foundation

/// Automatic, verified catalog backups: at launch when the newest one is
/// over a day old, after a write-heavy session (debounced), and on demand.
/// The work runs in `CatalogBackupService` off the main actor.
extension DashboardModel {
    /// Quiet time after the last catalog write before an after-writes
    /// backup runs, so a face-review session or a bulk move backs up once.
    static let catalogBackupDebounce: Duration = .seconds(5 * 60)
    /// Minimum spacing between after-writes backups.
    static let catalogBackupMinimumInterval: TimeInterval = 60 * 60
    /// Delay before the launch check, keeping first paint free of it.
    static let launchCatalogBackupDelay: Duration = .seconds(20)

    /// The folder beside `config.json` that holds local backup sets —
    /// `Application Support/CameraToolkit/Backups` for the live app.
    var localCatalogBackupFolder: URL {
        configurationStore.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    func catalogBackupService(for configuration: AppConfiguration) -> CatalogBackupService {
        let remotePath = configuration.catalogBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogBackupService(
            catalogURL: URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath)),
            configurationURL: configurationStore.url,
            localFolder: localCatalogBackupFolder,
            remoteFolder: remotePath.isEmpty ? nil : URL(fileURLWithPath: Self.expandedPath(remotePath), isDirectory: true)
        )
    }

    /// Launch: back up when the newest local set is over a day old,
    /// otherwise copy the newest set to a NAS that was offline last time.
    func scheduleLaunchCatalogBackup() {
        let service = catalogBackupService(for: configuration)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchCatalogBackupDelay)
            guard let self else { return }
            // Flush first so the config.json copy matches the catalog.
            self.flushConfigurationSave()
            await self.runCatalogBackup(announce: false) {
                try service.backupIfStale()
            }
        }
    }

    /// Called on every catalog-changing action (event and assignment edits,
    /// moves, trash, face review). Schedules one backup after the writes go
    /// quiet, at most once an hour.
    func noteCatalogWrite() {
        catalogBackupDebounceTask?.cancel()
        catalogBackupDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.catalogBackupDebounce)
            } catch {
                return
            }
            guard let self else { return }
            if let last = self.lastCatalogBackupAt,
               Date().timeIntervalSince(last) < Self.catalogBackupMinimumInterval {
                return
            }
            self.flushConfigurationSave()
            let service = self.catalogBackupService(for: self.configuration)
            await self.runCatalogBackup(announce: false) {
                try service.backupNow(reason: .afterWrites)
            }
        }
    }

    /// Settings › Back Up Now.
    func backUpCatalogNow() {
        guard !isBackingUpCatalog else { return }
        flushConfigurationSave()
        let service = catalogBackupService(for: configuration)
        Task { @MainActor [weak self] in
            await self?.runCatalogBackup(announce: true) {
                try service.backupNow(reason: .manual)
            }
        }
    }

    func refreshCatalogBackupSummary() {
        let service = catalogBackupService(for: configuration)
        Task { @MainActor [weak self] in
            let summary = await Task.detached(priority: .utility) { service.summary() }.value
            self?.catalogBackupSummary = summary
        }
    }

    private func runCatalogBackup(
        announce: Bool,
        _ work: @escaping @Sendable () throws -> CatalogBackupResult?
    ) async {
        guard !isBackingUpCatalog else { return }
        isBackingUpCatalog = true
        defer { isBackingUpCatalog = false }
        let catalogPath = Self.expandedPath(configuration.catalogDatabasePath)
        let service = catalogBackupService(for: configuration)
        let outcome: (result: CatalogBackupResult?, error: String?, summary: CatalogBackupSummary) =
            await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: catalogPath) else {
                    return (nil, nil, service.summary())
                }
                do {
                    return (try work(), nil, service.summary())
                } catch {
                    return (nil, error.localizedDescription, service.summary())
                }
            }.value
        catalogBackupSummary = outcome.summary
        if let result = outcome.result {
            lastCatalogBackupAt = result.manifest.createdAt
            if announce {
                statusMessage = "Backed up the photo list: \(Self.catalogBackupRemoteNote(result.remote))."
            }
        } else if let error = outcome.error {
            statusMessage = "Photo list backup failed: \(error)"
            recordActivity(
                action: .verifyManifest,
                state: .failed,
                title: "Photo list backup failed",
                summary: error,
                detail: "No photo files were touched. The previous backups are unchanged."
            )
        }
    }

    static func catalogBackupRemoteNote(_ remote: CatalogBackupResult.Remote) -> String {
        switch remote {
        case .copied, .alreadyPresent: "local and NAS"
        case .notConfigured: "local only (no NAS backup folder set)"
        case .offline: "local only — the NAS is offline and will catch up later"
        case .failed(let message): "local only — NAS copy failed: \(message)"
        }
    }

    /// "Last backup: Today 14:02, local and NAS" — the Settings line.
    static func catalogBackupDescription(_ summary: CatalogBackupSummary?, now: Date = Date()) -> String {
        guard let summary else { return "Checking backups…" }
        guard let lastLocal = summary.lastLocal else { return "No verified backup yet." }
        let when = lastLocal.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let places: String
        if let lastRemote = summary.lastRemote, abs(lastRemote.timeIntervalSince(lastLocal)) < 1 {
            places = "local and NAS"
        } else if !summary.remoteConfigured {
            places = "local only"
        } else if !summary.remoteReachable {
            places = "local; NAS offline"
        } else {
            places = "local; NAS copy pending"
        }
        return "Last backup: \(when), \(places)"
    }

    /// A warning for Settings when backups are stale or the last run
    /// failed; nil when all is well.
    static func catalogBackupWarning(_ summary: CatalogBackupSummary?, now: Date = Date()) -> String? {
        guard let summary else { return nil }
        if let error = summary.lastError {
            return "The last backup attempt failed: \(error)"
        }
        if summary.isStale(now: now, maxAge: 2 * CatalogBackupService.staleAfter) {
            return summary.lastLocal == nil
                ? "The photo list has never been backed up."
                : "The newest backup is more than two days old."
        }
        if summary.remoteConfigured, let lastRemote = summary.lastRemote,
           now.timeIntervalSince(lastRemote) > 7 * CatalogBackupService.staleAfter {
            return "The NAS copy is more than a week old. Mount the NAS to catch up."
        }
        return nil
    }
}
