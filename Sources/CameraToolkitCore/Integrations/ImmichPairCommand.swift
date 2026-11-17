import Foundation

/// The hidden `--immich-pair` command line of the app binary: which existing
/// Immich albums the app would pair with which events, and why the rest
/// would not pair.
///
/// ```
/// CameraToolkit --immich-pair --dry-run [--list] [--support-dir <folder>]
/// ```
///
/// Dry run only: it reads the account's albums and the catalog and changes
/// nothing anywhere. Pairing itself happens in the app (choosing the library,
/// or Settings › Services › Pair Albums), which owns the event settings.
/// `--list` prints each album with its event or reason; without it only
/// counts are printed.
public enum ImmichPairCommand {
    public static let flag = "--immich-pair"

    public struct Arguments: Equatable, Sendable {
        public var list: Bool
        public var supportDirectory: String?
    }

    public static let usage = """
    usage: CameraToolkit --immich-pair --dry-run [--list]
           options: --support-dir <folder>  (default: the app's Application Support folder;
                                             env CAMERA_TOOLKIT_SUPPORT_DIR also works)
                    --list                  print every album with its event or the reason it would not pair
           Pairing itself is done in the app: choose the library, or Settings › Services › Pair Albums.
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var parsed = Arguments(list: false, supportDirectory: environment[LayoutMigrationCommand.supportDirectoryEnvironmentKey])
        var dryRun = false
        while !args.isEmpty {
            let option = args.removeFirst()
            switch option {
            case "--dry-run": dryRun = true
            case "--list": parsed.list = true
            case "--support-dir":
                guard let next = args.first, !next.hasPrefix("--") else { throw ToolkitError.commandFailed("--support-dir needs a value.\n\(usage)") }
                parsed.supportDirectory = args.removeFirst()
            default: throw ToolkitError.commandFailed("Unknown option \(option).\n\(usage)")
            }
        }
        guard dryRun else { throw ToolkitError.commandFailed("Only --dry-run is available here; the app does the pairing.\n\(usage)") }
        return parsed
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSupportFolder: URL,
        apiKey: () throws -> String?,
        isAppRunning: () -> Bool = { false },
        transport: HTTPTransport = URLSession.shared,
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

            if isAppRunning() { output("Note: Camera Toolkit is running. This only reads, but the numbers can change while it works.") }
            let client = try ImmichClient(serverURL: serverURL, apiKey: key, transport: transport)
            let library = try ImmichStacksCommand.library(chosenID: configuration.immichLibraryID, libraries: try await client.libraries())
            output("Library: \(library.name)")
            let locations = EventStorageLocations(configuration: configuration)
            let files = ImmichCatalogFile.build(assignments: state.photoEventAssignments, events: state.savedEvents, locations: locations, verifiedPathKeys: [])
            let albums = try await ImmichAlbumPairing.readAlbums(client: client)
            let me = try? await client.currentUserID()
            let linked = ImmichEventAlbumStore.handledAlbumIDs(catalogURL: context.catalogURL)
            // Event dates: Immich's own capture dates, else the capture-date cache.
            let assetDates = ImmichAlbumPairing.assetDates(assets: try await client.libraryAssets(libraryID: library.id), library: library)
            let cache = CaptureDateCache(url: LayoutMigrationPlanner.captureDateCacheURL(supportFolder: context.supportFolder))
            let captureDates = ImmichAlbumPairing.captureDates(assignments: state.photoEventAssignments, cache: cache)
            let result = ImmichAlbumPairing.pair(
                albums: albums, events: state.savedEvents, files: files, library: library, locations: locations,
                currentUserID: me, linkedAlbumIDs: linked, assetDates: assetDates, captureDates: captureDates
            )
            output(summaryText(result, albums: albums.count, events: state.savedEvents, list: parsed.list))
            return 0
        } catch {
            output("error: \(error.localizedDescription)")
            return 2
        }
    }

    static func summaryText(_ result: ImmichPairingResult, albums: Int, events: [SavedCameraEvent], list: Bool) -> String {
        let names = Dictionary(events.map { ($0.id, $0.name) }) { first, _ in first }
        var lines = ["Albums on the account: \(albums)"]
        let byBasis = Dictionary(grouping: result.pairs, by: \.basis).mapValues(\.count)
        lines.append("Would pair: \(result.pairs.count) (by name \(byBasis[.name] ?? 0), by photos \(byBasis[.contents] ?? 0), by both \(byBasis[.nameAndContents] ?? 0), by name + dates \(byBasis[.nameAndDates] ?? 0), by dates \(byBasis[.dates] ?? 0))")
        lines.append("  of them kept filled (event albums): \(result.pairs.count(where: \.fills)); linked only (picks albums): \(result.pairs.count { !$0.fills })")
        let linkAlbums = Set(result.links.map(\.album.id))
        let severalAlbums = Set(result.links.filter { $0.basis == .severalEvents }.map(\.album.id))
        lines.append("Would link as also in: \(result.links.count) link(s) on \(linkAlbums.count) album(s) (several events: \(severalAlbums.count) album(s); a second album for an event: \(linkAlbums.subtracting(severalAlbums).count))")
        if !result.privateAlbumIDs.isEmpty {
            lines.append("Albums of private events: \(result.privateAlbumIDs.count) (\(result.privateEventIDs.count) event(s)); Pair Albums offers Allow Album and Pair for them")
        }
        lines.append("Already paired or linked, left as they are: \(result.alreadyPaired)")
        lines.append("Would not pair: \(result.unpaired.count)")
        let reasons = Dictionary(grouping: result.unpaired, by: { reasonKey($0.reason) })
        for key in reasons.keys.sorted() {
            lines.append("  \(key): \(reasons[key]?.count ?? 0)")
        }
        if list {
            lines.append("")
            for pair in result.pairs {
                let label = pair.basis == .dates ? "pair (dates)" : pair.basis == .nameAndDates ? "pair (name + dates)" : "pair"
                lines.append("\(label)  \(pair.album.name)  ↔  \(names[pair.eventID] ?? "?")  [\(pair.basis.text), \(pair.matchedAssets) matched, \(pair.fills ? "kept filled" : "picks, not filled")\(spanText(pair.dateSpan))]")
            }
            for (album, group) in linkGroups(result.links) {
                let eventNames = group.map { names[$0.eventID] ?? "?" }.joined(separator: ", ")
                let label = group.allSatisfy { $0.basis == .severalEvents } ? "link (several events: \(eventNames))"
                    : group.allSatisfy { $0.basis == .dates } ? "link (dates: \(eventNames))" : "link (also in: \(eventNames))"
                let detail = group.map { $0.basis == .severalEvents ? "\($0.matchedAssets)" : $0.basis.text }.joined(separator: " / ")
                lines.append("\(label)  \(album.name)  [\(detail)\(group.first.map { spanText($0.dateSpan) } ?? "")]")
            }
            for (album, group) in linkGroups(result.privatePairs + result.privateLinks) {
                lines.append("private  \(album.name)  ↔  \(group.map { names[$0.eventID] ?? "?" }.joined(separator: ", "))  [waits on Allow album; \(group.map(\.basis.text).joined(separator: " / "))]")
            }
            for row in result.unpaired {
                lines.append("skip  \(row.album.name)  —  \(row.reason.text)\(row.eventID.flatMap { names[$0] }.map { " (\($0))" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Links grouped by album, in album-name order.
    private static func linkGroups(_ links: [ImmichAlbumPair]) -> [(ImmichAlbum, [ImmichAlbumPair])] {
        var order: [String] = []
        var groups: [String: (ImmichAlbum, [ImmichAlbumPair])] = [:]
        for link in links {
            if groups[link.album.id] == nil { order.append(link.album.id); groups[link.album.id] = (link.album, []) }
            groups[link.album.id]?.1.append(link)
        }
        return order.compactMap { groups[$0] }.sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
    }

    private static func spanText(_ span: ClosedRange<Date>?) -> String {
        guard let span else { return "" }
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return ", photos \(span.lowerBound.formatted(format)) – \(span.upperBound.formatted(format))"
    }

    private static func reasonKey(_ reason: ImmichPairingReason) -> String {
        switch reason {
        case .mixed: "Photos from several events"
        case .longSpan: "Photos span too long for one event (system-style album)"
        default: reason.text
        }
    }
}
