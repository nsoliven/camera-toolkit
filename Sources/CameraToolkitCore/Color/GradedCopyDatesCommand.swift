import Foundation

/// The hidden `--graded-copy-dates` command line of the app binary: finds
/// the app's graded copies in events' `Edited/Rec709` folders, writes each
/// down for Immich (`GradedCopyStore`, and a NAS copy Sync has no record of
/// as verified in `nas_sync_files`), and repairs the dates of copies an
/// earlier build made (`GradedCopyDateRepair`).
///
/// ```
/// CameraToolkit --graded-copy-dates --dry-run [--event <name>]...
/// CameraToolkit --graded-copy-dates [--event <name>]...
/// ```
///
/// A dry run only reads. A real run refuses while the app runs. With an
/// Immich library chosen and a key in the Keychain (read inside this one
/// process, never printed), it then asks Immich to scan, and to read again
/// the repaired copies it already lists.
public enum GradedCopyDatesCommand {
    public static let flag = "--graded-copy-dates"

    public struct Arguments: Equatable, Sendable {
        public var dryRun = false
        public var eventNames: [String] = []
        public var supportDirectory: String?
    }

    public static let usage = """
    usage: CameraToolkit --graded-copy-dates --dry-run [--event <name>]...
           CameraToolkit --graded-copy-dates [--event <name>]...
           options: --support-dir <folder>  (default: the app's Application Support folder)
                    --event <name>          only this event (its exact name, any case); repeatable
           A real run refuses while Camera Toolkit is running; a dry run only reads.
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var parsed = Arguments(supportDirectory: environment[LayoutMigrationCommand.supportDirectoryEnvironmentKey])
        while !args.isEmpty {
            let option = args.removeFirst()
            func value() throws -> String {
                guard let next = args.first, !next.hasPrefix("--") else {
                    throw ToolkitError.commandFailed("\(option) needs a value.\n\(usage)")
                }
                args.removeFirst()
                return next
            }
            switch option {
            case "--dry-run": parsed.dryRun = true
            case "--event": parsed.eventNames.append(try value())
            case "--support-dir": parsed.supportDirectory = try value()
            default: throw ToolkitError.commandFailed("Unknown option \(option).\n\(usage)")
            }
        }
        return parsed
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSupportFolder: URL,
        apiKey: () throws -> String?,
        isAppRunning: () -> Bool = { false },
        transport: HTTPTransport = URLSession.shared,
        repair: (GradedCopyDateRepair.Found) throws -> Void = GradedCopyDateRepair.repair,
        hasher: (String, Int64) throws -> String = { try NASFileIO.sha256($0, uncached: true, expectedByteCount: $1) },
        output: @escaping (String) -> Void = { print($0) }
    ) async -> Int32 {
        do {
            let parsed = try parse(arguments, environment: environment)
            let context = try LayoutMigrationCommand.context(supportDirectory: parsed.supportDirectory, defaultSupportFolder: defaultSupportFolder)
            var configuration = context.configuration
            let state = try CatalogStateStore(url: context.catalogURL).load()
            configuration.savedEvents = state.savedEvents
            configuration.photoEventAssignments = state.photoEventAssignments
            var events = state.savedEvents
            if !parsed.eventNames.isEmpty {
                let wanted = Set(parsed.eventNames.map { NASSyncStore.pathKey($0) })
                events = events.filter { wanted.contains(NASSyncStore.pathKey($0.name)) }
                guard !events.isEmpty else { throw ToolkitError.commandFailed("No event has that name.") }
            }
            if !parsed.dryRun, isAppRunning() {
                throw ToolkitError.commandFailed("Camera Toolkit is running; quit it first. (--dry-run works while it runs.)")
            }
            let locations = EventStorageLocations(configuration: configuration)
            let found = GradedCopyDateRepair.survey(
                events: events, allEvents: state.savedEvents,
                assignments: state.photoEventAssignments, locations: locations
            )
            let due = found.filter(\.needsRepair)
            output("Graded copies found: \(found.count) (\(found.count(where: \.isOnNAS)) on the NAS), with dates to repair: \(due.count)")
            for item in due { output("  \(parsed.dryRun ? "would repair" : "repair"): \(item.gradedRelativePath) → \(GradedVideoExporter.creationDateString(item.moment))") }
            guard !parsed.dryRun else { return 0 }

            var problems: [String] = []
            var repaired: [GradedCopyDateRepair.Found] = []
            for item in due {
                do {
                    try repair(item)
                    repaired.append(item)
                } catch {
                    problems.append("\(item.copy.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Written down for Immich; a NAS copy re-read whole and recorded
            // as verified when it was rewritten or Sync has no record of it.
            let syncStore = try NASSyncStore(catalogURL: context.catalogURL)
            let known = NASSyncStore.records(catalogURL: context.catalogURL, nasRoot: locations.nasRoot.path, pathKeys: found.filter(\.isOnNAS).map { NASSyncStore.pathKey($0.gradedRelativePath) })
            let rewritten = Set(repaired.map(\.copy))
            for item in found where item.isOnNAS {
                guard rewritten.contains(item.copy) || known[NASSyncStore.pathKey(item.gradedRelativePath)]?.state != .verified else { continue }
                do {
                    _ = try GradedNASRecorder.record(copyAt: item.copy, eventID: item.eventID, locations: locations, store: syncStore, hasher: hasher)
                } catch {
                    problems.append("\(item.copy.lastPathComponent): not recorded on the NAS (\(error.localizedDescription))")
                }
            }
            try GradedCopyStore(catalogURL: context.catalogURL).save(found.map {
                GradedCopyRecord(eventID: $0.eventID, originalRelativePath: $0.originalRelativePath, gradedRelativePath: $0.gradedRelativePath, sourceKey: $0.sourceKey)
            })
            output("Repaired: \(repaired.count); written down for Immich: \(found.count)")

            await askImmich(configuration: configuration, apiKey: apiKey, transport: transport, repaired: repaired, onNAS: found.contains(where: \.isOnNAS), output: output)
            if !problems.isEmpty { output("Problems: \(problems.count): \(problems.prefix(5).joined(separator: "; "))") }
            return problems.isEmpty ? 0 : 1
        } catch {
            output("error: \(error.localizedDescription)")
            return 2
        }
    }

    /// A scan, so Immich lists copies new to it, and a metadata refresh of
    /// the rewritten copies it already lists. Best effort: the files are
    /// right either way, and the app's next check catches up.
    static func askImmich(
        configuration: AppConfiguration,
        apiKey: () throws -> String?,
        transport: HTTPTransport,
        repaired: [GradedCopyDateRepair.Found],
        onNAS: Bool,
        output: (String) -> Void
    ) async {
        let serverURL = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard onNAS, !serverURL.isEmpty, !configuration.immichLibraryID.isEmpty,
              let key = (try? apiKey())?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let client = try? ImmichClient(serverURL: serverURL, apiKey: key, transport: transport) else { return }
        do {
            try await client.requestLibraryScan(libraryID: configuration.immichLibraryID)
            output("Asked Immich to scan the library.")
        } catch {
            output("Immich scan not asked for: \(error.localizedDescription)")
        }
        let nasRepaired = repaired.filter(\.isOnNAS)
        guard !nasRepaired.isEmpty else { return }
        do {
            let library = try await client.library(id: configuration.immichLibraryID)
            let paths = ImmichLibraryPaths(importPaths: library.importPaths)
            var ids: [String] = []
            for item in nasRepaired {
                guard let server = paths.originalPath(forRelativePath: item.gradedRelativePath) else { continue }
                let assets = try await client.libraryAssets(libraryID: library.id, pathContains: server)
                ids += assets.filter { NASSyncStore.pathKey(paths.relativePath(forOriginalPath: $0.originalPath) ?? "") == NASSyncStore.pathKey(item.gradedRelativePath) }.map(\.id)
            }
            guard !ids.isEmpty else { return }
            try await client.refreshMetadata(assetIDs: ids)
            output("Asked Immich to read \(ids.count) rewritten cop\(ids.count == 1 ? "y" : "ies") again.")
        } catch {
            output("Immich metadata refresh not done (\(error.localizedDescription)); use Refresh metadata on those assets in Immich, or give the key job.create.")
        }
    }
}
