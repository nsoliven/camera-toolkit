import CameraToolkitCore
import Foundation

private struct RebuildPlan: Decodable {
    var bufferPath: String
    var bufferName: String?
    var events: [PlannedEvent]
}

private struct PlannedEvent: Decodable {
    var name: String
    var date: String
    var deviceID: String
    var sourceRootPath: String
}

private struct EventSummary: Encodable {
    var name: String
    var date: String
    var deviceID: String
    var sourceRootPath: String
    var fileCount: Int
    var byteCount: Int64
    var bufferPresentCount: Int
}

private struct RebuildSummary: Encodable {
    var outputConfigurationPath: String
    var outputCatalogPath: String
    var preservedEventCount: Int
    var totalEventCount: Int
    var totalAssignmentCount: Int
    var indexedAssignmentCount: Int
    var indexedByteCount: Int64
    var sourcePresenceCount: Int
    var bufferPresenceCount: Int
    var events: [EventSummary]
}

private enum RebuildError: LocalizedError {
    case usage(String)
    case invalidPlan(String)
    case outputExists(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidPlan(let message), .outputExists(let message): message
        }
    }
}

private struct Arguments {
    var configuration: URL
    var plan: URL
    var outputConfiguration: URL
    var outputCatalog: URL

    init(_ values: [String]) throws {
        var options: [String: String] = [:]
        var index = 1
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count else {
                throw RebuildError.usage(Self.help)
            }
            options[key] = values[index + 1]
            index += 2
        }
        guard let configuration = options["--configuration"],
              let plan = options["--plan"],
              let outputConfiguration = options["--output-configuration"],
              let outputCatalog = options["--output-catalog"] else {
            throw RebuildError.usage(Self.help)
        }
        self.configuration = URL(fileURLWithPath: configuration)
        self.plan = URL(fileURLWithPath: plan)
        self.outputConfiguration = URL(fileURLWithPath: outputConfiguration)
        self.outputCatalog = URL(fileURLWithPath: outputCatalog)
    }

    static let help = """
    Usage: CameraToolkitCatalogRebuilder \\
      --configuration <existing-config.json> \\
      --plan <event-plan.json> \\
      --output-configuration <candidate-config.json> \\
      --output-catalog <candidate-catalog.sqlite>

    The command never moves or deletes media. It scans each planned source with
    Camera Toolkit's FileScanner, preserves unrelated events, replaces only the
    assignments for planned source roots, and creates new candidate files.
    """
}

private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func standardizedDirectory(_ path: String) -> String {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        .standardizedFileURL.path
}

private func validate(_ plan: RebuildPlan, fileManager: FileManager) throws {
    guard !plan.events.isEmpty else {
        throw RebuildError.invalidPlan("The rebuild plan has no events.")
    }
    var roots: Set<String> = []
    var identities: Set<String> = []
    for event in plan.events {
        guard EventNamePolicy.validate(event.name).isValid else {
            throw RebuildError.invalidPlan("Invalid event name: \(event.name)")
        }
        guard dayFormatter.date(from: event.date) != nil else {
            throw RebuildError.invalidPlan("Invalid event date for \(event.name): \(event.date)")
        }
        let root = standardizedDirectory(event.sourceRootPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RebuildError.invalidPlan("Source folder is unavailable: \(root)")
        }
        guard roots.insert(root).inserted else {
            throw RebuildError.invalidPlan("A source folder appears more than once: \(root)")
        }
        let identity = "\(event.date)\u{0}\(event.name.lowercased())"
        guard identities.insert(identity).inserted else {
            throw RebuildError.invalidPlan("An event appears more than once: \(event.date) \(event.name)")
        }
    }
}

private func configuredEvent(
    matching plan: PlannedEvent,
    in events: [SavedCameraEvent]
) -> SavedCameraEvent? {
    guard let date = dayFormatter.date(from: plan.date) else { return nil }
    return events.first {
        $0.name.localizedCaseInsensitiveCompare(plan.name) == .orderedSame
            && Calendar.current.isDate($0.eventDate, inSameDayAs: date)
    }
}

private func bufferURL(
    for assignment: PhotoEventAssignment,
    event: SavedCameraEvent,
    bufferRoot: URL
) -> URL {
    let layout = OrganizedArchiveLayout(
        eventDate: dayFormatter.string(from: event.eventDate),
        eventName: event.name,
        deviceID: assignment.deviceID ?? "generic-camera"
    )
    return bufferRoot
        .appendingPathComponent(layout.year, isDirectory: true)
        .appendingPathComponent(layout.eventFolder, isDirectory: true)
        .appendingPathComponent(layout.deviceFolder, isDirectory: true)
        .appendingPathComponent("Card Copy", isDirectory: true)
        .appendingPathComponent(assignment.relativePath)
}

private func run() throws {
    let arguments = try Arguments(CommandLine.arguments)
    let fileManager = FileManager.default
    for output in [arguments.outputConfiguration, arguments.outputCatalog] where fileManager.fileExists(atPath: output.path) {
        throw RebuildError.outputExists("Refusing to overwrite existing candidate output: \(output.path)")
    }

    let plan = try JSONDecoder().decode(RebuildPlan.self, from: Data(contentsOf: arguments.plan))
    try validate(plan, fileManager: fileManager)

    let support = arguments.configuration.deletingLastPathComponent().deletingLastPathComponent()
    let defaults = AppConfiguration.defaults(applicationSupport: support)
    var configuration = try ConfigurationStore(url: arguments.configuration).load(defaults: defaults)
    let originalEventCount = configuration.savedEvents.count

    let normalizedBufferPath = standardizedDirectory(plan.bufferPath)
    configuration.bufferPath = normalizedBufferPath
    if let selectedID = configuration.selectedBufferID,
       let index = configuration.configuredLocations.firstIndex(where: { $0.id == selectedID }) {
        configuration.configuredLocations[index].path = normalizedBufferPath
        configuration.configuredLocations[index].name = plan.bufferName ?? configuration.configuredLocations[index].name
    } else if let index = configuration.configuredLocations.firstIndex(where: { $0.role == .buffer }) {
        configuration.configuredLocations[index].path = normalizedBufferPath
        configuration.configuredLocations[index].name = plan.bufferName ?? configuration.configuredLocations[index].name
        configuration.selectedBufferID = configuration.configuredLocations[index].id
    } else {
        let location = ConfiguredLocation(role: .buffer, name: plan.bufferName ?? "Camera Buffer", path: normalizedBufferPath)
        configuration.configuredLocations.append(location)
        configuration.selectedBufferID = location.id
    }

    let managedRoots = Set(plan.events.map { standardizedDirectory($0.sourceRootPath) })
    configuration.photoEventAssignments.removeAll {
        managedRoots.contains(standardizedDirectory($0.sourceRootPath))
    }

    var summaries: [EventSummary] = []
    var indexedAssignments: [PhotoEventAssignment] = []
    var sourceObservations: [CatalogPresenceObservation] = []
    var bufferObservations: [CatalogPresenceObservation] = []
    let bufferRoot = URL(fileURLWithPath: normalizedBufferPath, isDirectory: true)

    for planned in plan.events {
        let rootPath = standardizedDirectory(planned.sourceRootPath)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let event: SavedCameraEvent
        if let existing = configuredEvent(matching: planned, in: configuration.savedEvents) {
            event = existing
        } else {
            guard let eventDate = dayFormatter.date(from: planned.date) else {
                throw RebuildError.invalidPlan("Invalid event date: \(planned.date)")
            }
            event = SavedCameraEvent(name: planned.name, eventDate: eventDate)
            configuration.savedEvents.append(event)
        }

        if !configuration.configuredLocations.contains(where: {
            $0.role == .importSource && standardizedDirectory($0.path) == rootPath
        }) {
            configuration.configuredLocations.append(
                ConfiguredLocation(role: .importSource, name: "Crucial · \(planned.name)", path: rootPath)
            )
        }

        let files = try FileScanner().scan(root: root)
        var bufferPresentCount = 0
        for file in files {
            let assignment = PhotoEventAssignment(
                sourceRootPath: rootPath,
                relativePath: file.path,
                fileSize: file.size,
                modifiedAt: file.modifiedAt,
                eventID: event.id,
                deviceID: planned.deviceID
            )
            indexedAssignments.append(assignment)
            let eventAssetID = CatalogStore.eventAssetID(assignment)
            sourceObservations.append(
                CatalogPresenceObservation(eventAssetID: eventAssetID, location: .source, state: .present)
            )

            let destination = bufferURL(for: assignment, event: event, bufferRoot: bufferRoot)
            let destinationSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let isPresent = destinationSize.map(Int64.init) == assignment.fileSize
            if isPresent { bufferPresentCount += 1 }
            bufferObservations.append(
                CatalogPresenceObservation(
                    eventAssetID: eventAssetID,
                    location: .buffer,
                    state: isPresent ? .present : .missing
                )
            )
        }
        summaries.append(
            EventSummary(
                name: planned.name,
                date: planned.date,
                deviceID: planned.deviceID,
                sourceRootPath: rootPath,
                fileCount: files.count,
                byteCount: files.reduce(Int64(0)) { $0 + $1.size },
                bufferPresentCount: bufferPresentCount
            )
        )
    }

    configuration.photoEventAssignments.append(contentsOf: indexedAssignments)
    configuration.normalizeLocationSelections()
    configuration.normalizeEventSelection()
    try ConfigurationStore(url: arguments.outputConfiguration).save(configuration)
    _ = try CatalogStore(url: arguments.outputCatalog).bootstrap(
        configuration: configuration,
        createBackup: false,
        createLibraryFolders: false
    )
    let inspector = CatalogInspector(url: arguments.outputCatalog)
    try inspector.savePresenceObservations(sourceObservations)
    try inspector.savePresenceObservations(bufferObservations)

    let summary = RebuildSummary(
        outputConfigurationPath: arguments.outputConfiguration.path,
        outputCatalogPath: arguments.outputCatalog.path,
        preservedEventCount: originalEventCount,
        totalEventCount: configuration.savedEvents.count,
        totalAssignmentCount: configuration.photoEventAssignments.count,
        indexedAssignmentCount: indexedAssignments.count,
        indexedByteCount: indexedAssignments.reduce(Int64(0)) { $0 + $1.fileSize },
        sourcePresenceCount: sourceObservations.count,
        bufferPresenceCount: summaries.reduce(0) { $0 + $1.bufferPresentCount },
        events: summaries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(summary))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("CameraToolkitCatalogRebuilder: \(error.localizedDescription)\n".utf8))
    exit(1)
}
