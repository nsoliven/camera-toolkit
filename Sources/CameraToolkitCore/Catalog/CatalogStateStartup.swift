import Foundation

/// Decides at launch where events and assignments come from, migrating a
/// legacy `config.json` into the catalog the first time.
///
/// | catalog owns state | config.json            | result                                   |
/// |--------------------|------------------------|------------------------------------------|
/// | yes                | any                    | `.catalog` — rows loaded from the catalog |
/// | no                 | legacy (has events)    | migrate → `.catalog`; on failure `.legacy` |
/// | no                 | missing (fresh)        | migrate the empty state → `.catalog`      |
/// | no                 | settings-only          | `.suspended` — the catalog was replaced   |
/// | —                  | unreadable             | `.suspended` — nothing is written         |
///
/// `.legacy` is the pre-migration path: `config.json` stays the durable
/// store and the catalog mirrors it. `.suspended` writes nothing durable
/// — neither `config.json` nor event rows — until the owner restores the
/// matching files, because every write there could overwrite the only
/// good copy.
public enum CatalogStateStartup {
    public enum Mode: Equatable, Sendable {
        /// The catalog is the durable store; `baseline` is what it holds.
        case catalog(baseline: CatalogOwnedState)
        case legacy
        case suspended
    }

    public struct Outcome: Sendable {
        public var configuration: AppConfiguration
        public var mode: Mode
        /// A line for the status bar when something needs the owner's
        /// attention or a migration just ran.
        public var message: String?
        public var migration: CatalogStateMigrationReport?
        /// True right after a migration: `config.json` still carries the
        /// legacy state and should be rewritten settings-only.
        public var shouldRewriteConfiguration: Bool
    }

    public static func resolve(
        configurationURL: URL,
        defaults: AppConfiguration,
        backups makeBackups: (URL) -> CatalogBackupService,
        hooks: CatalogStateStore.MigrationHooks = CatalogStateStore.MigrationHooks()
    ) -> Outcome {
        let fileManager = FileManager.default

        // 1. config.json — refuse to guess when it exists but won't decode.
        var configuration = defaults
        var settingsOnly = false
        var configurationExists = false
        if fileManager.fileExists(atPath: configurationURL.path) {
            configurationExists = true
            do {
                let data = try Data(contentsOf: configurationURL)
                configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
                settingsOnly = ConfigurationStore.isSettingsOnly(data)
            } catch {
                return Outcome(
                    configuration: defaults,
                    mode: .suspended,
                    message: "config.json could not be read (\(error.localizedDescription)). Camera Toolkit is running without saving so it cannot overwrite it; restore it from Backups.",
                    migration: nil,
                    shouldRewriteConfiguration: false
                )
            }
        }

        let catalogURL = URL(fileURLWithPath: NSString(string: configuration.catalogDatabasePath).expandingTildeInPath)
        let store = CatalogStateStore(url: catalogURL)

        // 2. The catalog's schema, then who owns the state.
        let owns: Bool
        do {
            try CatalogStore(url: catalogURL).prepareSchema()
            owns = try store.catalogOwnsState()
        } catch {
            return Outcome(
                configuration: configuration,
                mode: settingsOnly ? .suspended : .legacy,
                message: "The photo list could not be opened (\(error.localizedDescription)). "
                    + (settingsOnly ? "Events are not shown and nothing is saved until it opens." : "Using config.json as before."),
                migration: nil,
                shouldRewriteConfiguration: false
            )
        }

        if owns {
            do {
                let state = try store.load()
                state.apply(to: &configuration)
                return Outcome(
                    configuration: configuration,
                    mode: .catalog(baseline: state),
                    message: nil,
                    migration: nil,
                    // A crash between the migration's commit and the first
                    // settings-only save leaves the legacy state in
                    // config.json; the catalog wins, and the file shrinks now.
                    shouldRewriteConfiguration: configurationExists && !settingsOnly
                )
            } catch {
                return Outcome(
                    configuration: configuration,
                    mode: .suspended,
                    message: "The events in the photo list could not be read (\(error.localizedDescription)). Nothing is saved until this is fixed; the latest backup is in Backups.",
                    migration: nil,
                    shouldRewriteConfiguration: false
                )
            }
        }

        if settingsOnly {
            return Outcome(
                configuration: configuration,
                mode: .suspended,
                message: "config.json says events live in the photo list, but this photo list was never migrated — it may have been replaced by an older copy. Nothing is saved; restore the catalog and config.json from the same backup set.",
                migration: nil,
                shouldRewriteConfiguration: false
            )
        }

        // 3. First launch after the upgrade: migrate.
        let report: CatalogStateMigrationReport
        do {
            report = try store.migrate(
                state: CatalogOwnedState(configuration: configuration),
                configurationURL: configurationExists ? configurationURL : nil,
                backups: makeBackups(catalogURL),
                hooks: hooks
            )
        } catch {
            return Outcome(
                configuration: configuration,
                mode: .legacy,
                message: "Events stay in config.json for now: moving them into the photo list did not pass its checks (\(error.localizedDescription)). Nothing was changed.",
                migration: nil,
                shouldRewriteConfiguration: false
            )
        }
        // Committed: from here the catalog owns the state, so falling back
        // to config.json would fork it. A failed read-back suspends.
        do {
            let state = try store.load()
            state.apply(to: &configuration)
            var notes = ["Moved \(report.events) events and \(report.assignments) photo assignments into the photo list (backup \(report.backupID))."]
            let dropped = report.duplicateAssignmentsDropped + report.orphanAssignmentsDropped + report.duplicateEventsDropped
            if dropped > 0 {
                notes.append("Skipped \(report.duplicateAssignmentsDropped) duplicate and \(report.orphanAssignmentsDropped) event-less assignment(s); they remain in \(report.legacyConfigurationCopy?.lastPathComponent ?? "the backup").")
            }
            if !report.preexistingForeignKeyViolations.isEmpty {
                notes.append("\(report.preexistingForeignKeyViolations.count) older catalog link problem(s) were left as they were.")
            }
            return Outcome(
                configuration: configuration,
                mode: .catalog(baseline: state),
                message: notes.joined(separator: " "),
                migration: report,
                shouldRewriteConfiguration: configurationExists
            )
        } catch {
            return Outcome(
                configuration: configuration,
                mode: .suspended,
                message: "The events moved into the photo list but could not be read back (\(error.localizedDescription)). Nothing is saved until this is fixed; backup \(report.backupID) holds the state before the move.",
                migration: report,
                shouldRewriteConfiguration: false
            )
        }
    }
}
