import Foundation

/// The hidden `--immich-stacks` command line of the app binary: makes the
/// Immich stacks a check would make, from a script.
///
/// ```
/// CameraToolkit --immich-stacks --dry-run [--event <name>]... [--support-dir <folder>]
/// CameraToolkit --immich-stacks [--event <name>]... [--log <file.jsonl>] [--support-dir <folder>]
/// ```
///
/// It uses the saved server URL and the chosen library; with none chosen, the
/// only external library on the account, and it refuses when there are
/// several. The API key comes from the Keychain inside this one process and
/// is never printed. `--dry-run` only reads. A real run writes one line per
/// stack it made to the log (its stack ID and assets), which is the list to
/// undo from; it never deletes or changes a stack it did not make.
public enum ImmichStacksCommand {
    public static let flag = "--immich-stacks"

    public struct Arguments: Equatable, Sendable {
        public var dryRun: Bool
        public var eventNames: [String]
        public var logPath: String?
        public var supportDirectory: String?
    }

    public static let usage = """
    usage: CameraToolkit --immich-stacks --dry-run [--event <name>]...
           CameraToolkit --immich-stacks [--event <name>]... [--log <file.jsonl>]
           options: --support-dir <folder>  (default: the app's Application Support folder;
                                             env CAMERA_TOOLKIT_SUPPORT_DIR also works)
                    --event <name>          only this event (its exact name, any case); repeatable
                    --log <file>            where a real run lists the stacks it made
                                            (default: <support folder>/Immich Stack Logs/stacks-<time>.jsonl)
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var parsed = Arguments(dryRun: false, eventNames: [], logPath: nil, supportDirectory: environment[LayoutMigrationCommand.supportDirectoryEnvironmentKey])
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
            case "--log": parsed.logPath = try value()
            case "--support-dir": parsed.supportDirectory = try value()
            default: throw ToolkitError.commandFailed("Unknown option \(option).\n\(usage)")
            }
        }
        return parsed
    }

    /// Picks the library: the chosen one, else the only external library.
    static func library(chosenID: String, libraries: [ImmichLibrary]) throws -> ImmichLibrary {
        if !chosenID.isEmpty {
            guard let chosen = libraries.first(where: { $0.id == chosenID }) else {
                throw ToolkitError.commandFailed("The library chosen in Settings is not on the server any more.")
            }
            return chosen
        }
        guard libraries.count == 1, let only = libraries.first else {
            throw ToolkitError.commandFailed(libraries.isEmpty
                ? "The server has no external library."
                : "No library is chosen in Settings and the server has \(libraries.count) external libraries; choose one in Settings › Services first.")
        }
        return only
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSupportFolder: URL,
        apiKey: () throws -> String?,
        transport: HTTPTransport = URLSession.shared,
        now: Date = Date(),
        output: @escaping (String) -> Void = { print($0) }
    ) async -> Int32 {
        do {
            let parsed = try parse(arguments, environment: environment)
            let context = try LayoutMigrationCommand.context(supportDirectory: parsed.supportDirectory, defaultSupportFolder: defaultSupportFolder)
            var configuration = context.configuration
            let serverURL = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverURL.isEmpty else { throw ToolkitError.commandFailed("No Immich server URL is saved in Settings.") }
            guard let key = try apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                throw ToolkitError.commandFailed("No Immich API key is saved in the Keychain. Save one in Settings › Services.")
            }
            let state = try CatalogStateStore(url: context.catalogURL).load()
            configuration.savedEvents = state.savedEvents
            configuration.photoEventAssignments = state.photoEventAssignments

            var events = state.savedEvents
            if !parsed.eventNames.isEmpty {
                let wanted = Set(parsed.eventNames.map { NASSyncStore.pathKey($0) })
                events = events.filter { wanted.contains(NASSyncStore.pathKey($0.name)) }
                guard !events.isEmpty else { throw ToolkitError.commandFailed("No event has that name.") }
            }
            let eventIDs = Set(events.map(\.id))

            let client = try ImmichClient(serverURL: serverURL, apiKey: key, transport: transport)
            let library = try library(chosenID: configuration.immichLibraryID, libraries: try await client.libraries())
            output("Library: \(library.name)")
            let locations = EventStorageLocations(configuration: configuration)
            let files = ImmichCatalogFile.build(
                assignments: state.photoEventAssignments.filter { eventIDs.contains($0.eventID) },
                events: state.savedEvents,
                locations: locations,
                verifiedPathKeys: []
            )
            let paths = ImmichLibraryPaths(importPaths: library.importPaths)
            var assets: [ImmichLibraryAsset] = []
            if parsed.eventNames.isEmpty {
                assets = try await client.libraryAssets(libraryID: library.id)
            } else {
                for folder in ImmichLibrarySync.eventFolders(of: files) {
                    guard let serverFolder = paths.originalPath(forRelativePath: folder) else { continue }
                    assets += try await client.libraryAssets(libraryID: library.id, pathContains: serverFolder + "/")
                }
            }
            let report = ImmichReconciler.reconcile(files: files, assets: assets, library: library, mediaExtensions: [])
            guard report.pathsLineUp else {
                throw ToolkitError.commandFailed("“\(library.name)” does not read the NAS root this catalog syncs to; nothing was done.")
            }
            let editPaths = assets.compactMap { asset -> String? in
                guard !asset.isOffline, !asset.isTrashed, let relative = paths.relativePath(forOriginalPath: asset.originalPath),
                      relative.localizedCaseInsensitiveContains("/Edited/") else { return nil }
                return relative
            }
            let groups = ImmichStackGrouping.groups(files: files, editPaths: editPaths)
            output("Events: \(events.count), files: \(files.count), Immich assets read: \(assets.count), groups: \(groups.count)")

            var logHandle: FileHandle?
            var logURL: URL?
            if !parsed.dryRun {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate, .withTime]
                let url = parsed.logPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                    ?? context.supportFolder.appendingPathComponent("Immich Stack Logs", isDirectory: true)
                        .appendingPathComponent("stacks-\(formatter.string(from: now).replacingOccurrences(of: ":", with: "")).jsonl")
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolkitError.commandFailed("\(url.path) already exists; pick a new --log path.")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                logHandle = try FileHandle(forWritingTo: url)
                logURL = url
            }
            defer { try? logHandle?.close() }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let result = try await ImmichStackRunner.run(
                client: client,
                groups: groups,
                assets: assets,
                library: library,
                store: ImmichStackStore(catalogURL: context.catalogURL),
                dryRun: parsed.dryRun
            ) { record in
                if let data = try? encoder.encode(record) { logHandle?.write(data + Data("\n".utf8)) }
            }
            output(summaryText(result, dryRun: parsed.dryRun))
            if let logURL { output("Log of stacks made (to undo from): \(logURL.path)") }
            return result.problems.isEmpty ? 0 : 1
        } catch {
            output("error: \(error.localizedDescription)")
            return 2
        }
    }

    static func summaryText(_ report: ImmichStackRunReport, dryRun: Bool) -> String {
        let plan = report.plan
        var lines: [String] = []
        let byKind = Dictionary(grouping: plan.creates, by: \.group.kind).mapValues(\.count)
        lines.append("\(dryRun ? "Would make" : "Stacks to make"): \(plan.creates.count) (bursts \(byKind[.burst] ?? 0), RAW+JPEG \(byKind[.rawPair] ?? 0), with edits \(byKind[.edit] ?? 0)); \(plan.creates.count { $0.replacing != nil }) of them replace the app's own earlier stack")
        lines.append("Already stacked by the app, unchanged: \(plan.unchanged)")
        lines.append("Left alone, already in a stack the app did not make: \(plan.skippedForeign)")
        let notMatched = plan.skipped.filter { if case .notInImmich = $0.reason { true } else { false } }
        let none = notMatched.count { if case .notInImmich(let found, _) = $0.reason { found == 0 } else { false } }
        lines.append("Not matched in Immich: \(notMatched.count) (\(none) with no file in Immich, \(notMatched.count - none) with only one)")
        if !dryRun { lines.append("Made: \(report.created.count)") }
        if !report.problems.isEmpty { lines.append("Problems: \(report.problems.count): \(report.problems.prefix(5).joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }
}
