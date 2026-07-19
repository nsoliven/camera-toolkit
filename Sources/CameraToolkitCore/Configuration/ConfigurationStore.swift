import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var demoRootPath: String
    public var importSourcePath: String
    public var archivePath: String
    public var bufferPath: String
    public var cameraLibraryRootPath: String
    public var catalogDatabasePath: String
    public var catalogBackupFolderPath: String
    public var configuredLocations: [ConfiguredLocation]
    public var selectedImportSourceID: UUID?
    public var selectedArchiveID: UUID?
    public var selectedBufferID: UUID?
    public var activityLogPath: String
    public var immichServerURL: String
    public var selectedDeviceID: String
    public var eventName: String
    public var batchID: String
    public var savedEvents: [SavedCameraEvent]
    public var selectedEventID: UUID?
    public var photoEventAssignments: [PhotoEventAssignment]

    public init(
        demoRootPath: String,
        importSourcePath: String,
        archivePath: String,
        bufferPath: String,
        cameraLibraryRootPath: String = "",
        catalogDatabasePath: String = "",
        catalogBackupFolderPath: String = "",
        configuredLocations: [ConfiguredLocation] = [],
        selectedImportSourceID: UUID? = nil,
        selectedArchiveID: UUID? = nil,
        selectedBufferID: UUID? = nil,
        activityLogPath: String,
        immichServerURL: String = "",
        selectedDeviceID: String = "generic-camera",
        eventName: String = "",
        batchID: String = "",
        savedEvents: [SavedCameraEvent] = [],
        selectedEventID: UUID? = nil,
        photoEventAssignments: [PhotoEventAssignment] = []
    ) {
        self.demoRootPath = demoRootPath
        self.importSourcePath = importSourcePath
        self.archivePath = archivePath
        self.bufferPath = bufferPath
        self.cameraLibraryRootPath = cameraLibraryRootPath
        self.catalogDatabasePath = catalogDatabasePath
        self.catalogBackupFolderPath = catalogBackupFolderPath
        self.configuredLocations = configuredLocations
        self.selectedImportSourceID = selectedImportSourceID
        self.selectedArchiveID = selectedArchiveID
        self.selectedBufferID = selectedBufferID
        self.activityLogPath = activityLogPath
        self.immichServerURL = immichServerURL
        self.selectedDeviceID = selectedDeviceID
        self.eventName = eventName
        self.batchID = batchID.isEmpty ? Self.makeBatchID(deviceID: selectedDeviceID) : batchID
        self.savedEvents = savedEvents
        self.selectedEventID = selectedEventID
        self.photoEventAssignments = photoEventAssignments
        self.normalizeLocationSelections()
        self.normalizeEventSelection()
    }

    private enum CodingKeys: String, CodingKey {
        case demoRootPath
        case importSourcePath
        case archivePath
        case bufferPath
        case cameraLibraryRootPath
        case catalogDatabasePath
        case catalogBackupFolderPath
        case configuredLocations
        case selectedImportSourceID
        case selectedArchiveID
        case selectedBufferID
        case activityLogPath
        case immichServerURL
        case selectedDeviceID
        case eventName
        case batchID
        case savedEvents
        case selectedEventID
        case photoEventAssignments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let defaults = AppConfiguration.defaults(applicationSupport: support)

        demoRootPath = try values.decodeIfPresent(String.self, forKey: .demoRootPath) ?? defaults.demoRootPath
        importSourcePath = try values.decodeIfPresent(String.self, forKey: .importSourcePath) ?? defaults.importSourcePath
        archivePath = try values.decodeIfPresent(String.self, forKey: .archivePath) ?? defaults.archivePath
        bufferPath = try values.decodeIfPresent(String.self, forKey: .bufferPath) ?? defaults.bufferPath
        cameraLibraryRootPath = try values.decodeIfPresent(String.self, forKey: .cameraLibraryRootPath) ?? defaults.cameraLibraryRootPath
        catalogDatabasePath = try values.decodeIfPresent(String.self, forKey: .catalogDatabasePath) ?? defaults.catalogDatabasePath
        catalogBackupFolderPath = try values.decodeIfPresent(String.self, forKey: .catalogBackupFolderPath) ?? defaults.catalogBackupFolderPath
        configuredLocations = try values.decodeIfPresent([ConfiguredLocation].self, forKey: .configuredLocations) ?? []
        selectedImportSourceID = try values.decodeIfPresent(UUID.self, forKey: .selectedImportSourceID)
        selectedArchiveID = try values.decodeIfPresent(UUID.self, forKey: .selectedArchiveID)
        selectedBufferID = try values.decodeIfPresent(UUID.self, forKey: .selectedBufferID)
        activityLogPath = try values.decodeIfPresent(String.self, forKey: .activityLogPath) ?? defaults.activityLogPath
        immichServerURL = try values.decodeIfPresent(String.self, forKey: .immichServerURL) ?? defaults.immichServerURL
        selectedDeviceID = try values.decodeIfPresent(String.self, forKey: .selectedDeviceID) ?? defaults.selectedDeviceID
        eventName = try values.decodeIfPresent(String.self, forKey: .eventName) ?? defaults.eventName
        batchID = try values.decodeIfPresent(String.self, forKey: .batchID) ?? Self.makeBatchID(deviceID: selectedDeviceID)
        savedEvents = try values.decodeIfPresent([SavedCameraEvent].self, forKey: .savedEvents) ?? []
        selectedEventID = try values.decodeIfPresent(UUID.self, forKey: .selectedEventID)
        photoEventAssignments = try values.decodeIfPresent([PhotoEventAssignment].self, forKey: .photoEventAssignments) ?? []
        normalizeLocationSelections()
        normalizeEventSelection()
    }

    public static func defaults(applicationSupport: URL) -> AppConfiguration {
        let root = applicationSupport.appendingPathComponent("CameraToolkit", isDirectory: true)
        let demoRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Camera Library", isDirectory: true)

        var configuration = AppConfiguration(
            demoRootPath: demoRoot.path,
            importSourcePath: demoRoot.appendingPathComponent("From Folder", isDirectory: true).path,
            archivePath: libraryRoot.appendingPathComponent(CameraLibraryFolder.originals.rawValue, isDirectory: true).path,
            bufferPath: demoRoot.appendingPathComponent("Buffer", isDirectory: true).path,
            cameraLibraryRootPath: libraryRoot.path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            catalogBackupFolderPath: libraryRoot
                .appendingPathComponent(CameraLibraryFolder.manifests.rawValue, isDirectory: true)
                .appendingPathComponent("CameraToolkit", isDirectory: true)
                .appendingPathComponent("catalog-backups", isDirectory: true)
                .path,
            activityLogPath: root.appendingPathComponent("activity-log.jsonl").path
        )
        configuration.normalizeLocationSelections()
        return configuration
    }

    public mutating func normalizeLocationSelections() {
        if cameraLibraryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cameraLibraryRootPath = URL(fileURLWithPath: archivePath, isDirectory: true)
                .deletingLastPathComponent()
                .path
        }
        if catalogBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            catalogBackupFolderPath = libraryFolderPath(.manifests)
                .appendingPathComponent("CameraToolkit", isDirectory: true)
                .appendingPathComponent("catalog-backups", isDirectory: true)
                .path
        }

        if configuredLocations.isEmpty {
            configuredLocations = [
                ConfiguredLocation(
                    role: .importSource,
                    name: defaultLocationName(path: importSourcePath, fallback: "From Folder"),
                    path: importSourcePath
                ),
                ConfiguredLocation(
                    role: .archive,
                    name: defaultLocationName(path: archivePath, fallback: "Photo Library"),
                    path: archivePath
                ),
                ConfiguredLocation(
                    role: .buffer,
                    name: defaultLocationName(path: bufferPath, fallback: "Buffer"),
                    path: bufferPath
                )
            ]
        }

        let locations = configuredLocations
        let importSourceSelection = Self.normalizedSelection(
            selectedImportSourceID,
            role: .importSource,
            selectedPath: importSourcePath,
            locations: locations
        )
        selectedImportSourceID = importSourceSelection.id
        importSourcePath = importSourceSelection.path

        let archiveSelection = Self.normalizedSelection(
            selectedArchiveID,
            role: .archive,
            selectedPath: archivePath,
            locations: locations
        )
        selectedArchiveID = archiveSelection.id
        archivePath = archiveSelection.path

        let bufferSelection = Self.normalizedSelection(
            selectedBufferID,
            role: .buffer,
            selectedPath: bufferPath,
            locations: locations
        )
        selectedBufferID = bufferSelection.id
        bufferPath = bufferSelection.path
    }

    public mutating func normalizeEventSelection() {
        let trimmedName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        if savedEvents.isEmpty, !trimmedName.isEmpty {
            let eventDate = Self.dayFormatter.date(from: archiveEventDate) ?? Date()
            let event = SavedCameraEvent(name: trimmedName, eventDate: eventDate)
            savedEvents = [event]
            selectedEventID = event.id
        }

        if let selectedEventID,
           let selected = savedEvents.first(where: { $0.id == selectedEventID }) {
            eventName = selected.name
        } else if let matching = savedEvents.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) ?? savedEvents.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first {
            selectedEventID = matching.id
            eventName = matching.name
        } else {
            selectedEventID = nil
            eventName = ""
        }
    }

    public func locations(role: ConfiguredLocationRole) -> [ConfiguredLocation] {
        configuredLocations.filter { $0.role == role }
    }

    public func selectedLocationID(for role: ConfiguredLocationRole) -> UUID? {
        switch role {
        case .importSource: selectedImportSourceID
        case .archive: selectedArchiveID
        case .buffer: selectedBufferID
        }
    }

    public func selectedLocation(for role: ConfiguredLocationRole) -> ConfiguredLocation? {
        guard let id = selectedLocationID(for: role) else {
            return nil
        }
        return configuredLocations.first { $0.id == id && $0.role == role }
    }

    private static func normalizedSelection(
        _ selection: UUID?,
        role: ConfiguredLocationRole,
        selectedPath: String,
        locations: [ConfiguredLocation]
    ) -> (id: UUID?, path: String) {
        let matching = locations.filter { $0.role == role }
        guard !matching.isEmpty else {
            return (nil, selectedPath)
        }

        if let selection, let location = matching.first(where: { $0.id == selection }) {
            return (location.id, location.path)
        }

        if let location = matching.first(where: { $0.path == selectedPath }) ?? matching.first {
            return (location.id, location.path)
        }

        return (nil, selectedPath)
    }

    private func defaultLocationName(path: String, fallback: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? fallback : last
    }

    public func libraryFolderPath(_ folder: CameraLibraryFolder) -> URL {
        URL(fileURLWithPath: cameraLibraryRootPath, isDirectory: true)
            .appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    public func bufferBatchFolderPath() -> String {
        let layout = OrganizedArchiveLayout(configuration: self)
        return URL(fileURLWithPath: bufferEventFolderPath(), isDirectory: true)
            .appendingPathComponent(layout.deviceFolder, isDirectory: true)
            .appendingPathComponent("Card Copy", isDirectory: true)
            .path
    }

    public func bufferEventFolderPath() -> String {
        let layout = OrganizedArchiveLayout(configuration: self)
        return URL(fileURLWithPath: bufferPath, isDirectory: true)
            .appendingPathComponent(layout.year, isDirectory: true)
            .appendingPathComponent(layout.eventFolder, isDirectory: true)
            .path
    }

    public func bufferIngestFolderPath() -> String {
        bufferBatchFolderPath()
    }

    public func bufferExportsFolderPath() -> String {
        URL(fileURLWithPath: bufferEventFolderPath(), isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
            .path
    }

    public func bufferEditsFolderPath() -> String {
        URL(fileURLWithPath: bufferEventFolderPath(), isDirectory: true)
            .appendingPathComponent("Photomator", isDirectory: true)
            .path
    }

    public func bufferExportFolderPath(_ folderName: String) -> String {
        URL(fileURLWithPath: bufferExportsFolderPath(), isDirectory: true)
            .appendingPathComponent(Self.pathComponent(folderName, fallback: "Masters"), isDirectory: true)
            .path
    }

    public func eventWorkspaceFolderPaths() -> [String] {
        [
            bufferBatchFolderPath(),
            bufferEditsFolderPath(),
            bufferExportFolderPath("Masters"),
            bufferExportFolderPath("Web"),
            bufferExportFolderPath("Social")
        ]
    }

    public var archiveEventDate: String {
        let candidate = String(batchID.prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: candidate) == nil ? Self.dayFormatter.string(from: Date()) : candidate
    }

    public func libraryBatchFolderPath(_ folder: CameraLibraryFolder) -> String {
        switch folder {
        case .originals, .manifests:
            return libraryFolderPath(folder)
                .appendingPathComponent(batchRelativePath(), isDirectory: true)
                .path
        case .edited:
            return libraryFolderPath(folder)
                .appendingPathComponent(eventFolderName(), isDirectory: true)
                .path
        case .inbox, .selects, .shared:
            return libraryFolderPath(folder)
                .appendingPathComponent(eventFolderName(), isDirectory: true)
                .path
        }
    }

    public mutating func beginNewBatch(now: Date = Date()) {
        batchID = Self.makeBatchID(deviceID: selectedDeviceID, now: now)
    }

    public func batchRelativePath() -> String {
        [
            yearFolderName(),
            eventFolderName(),
            deviceArchiveFolder(),
            Self.pathComponent(batchID, fallback: Self.makeBatchID(deviceID: selectedDeviceID))
        ].joined(separator: "/")
    }

    public func deviceArchiveFolder() -> String {
        switch selectedDeviceID {
        case "generic-camera": "Camera"
        case "sony-a7v": "Sony-A7V"
        case "osmo-360": "Osmo-360"
        case "dji-mini-2": "DJI-Mini-2"
        case "action-6": "Action-6"
        case "iphone": "iPhone"
        default: Self.pathComponent(selectedDeviceID, fallback: "Camera")
        }
    }

    private func yearFolderName() -> String {
        String(batchID.prefix(4)).allSatisfy(\.isNumber) ? String(batchID.prefix(4)) : Self.yearFormatter.string(from: Date())
    }

    private func eventFolderName() -> String {
        let yearMonth = batchID.count >= 7 ? String(batchID.prefix(7)) : Self.monthFormatter.string(from: Date())
        let event = EventNamePolicy.folderName(for: eventName, fallback: "Import")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return "\(yearMonth)_\(event)"
    }

    private static func makeBatchID(deviceID: String, now: Date = Date()) -> String {
        "\(batchFormatter.string(from: now))_\(pathComponent(deviceID, fallback: "camera"))_\(UUID().uuidString.prefix(4).lowercased())"
    }

    private static let yearFormatter: DateFormatter = formatter("yyyy")
    private static let monthFormatter: DateFormatter = formatter("yyyy-MM")
    private static let batchFormatter: DateFormatter = formatter("yyyy-MM-dd_HHmmss")
    private static let dayFormatter: DateFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static func pathComponent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let scalars = source.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return sanitized.isEmpty ? fallback : sanitized
    }
}

public struct SavedCameraEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var eventDate: Date
    public var createdAt: Date
    public var lastUsedAt: Date
    /// `nil` is the migration-safe default for events created before Immich routing existed.
    /// It intentionally behaves like `false`: storage-only until the user opts in.
    public var immichUploadEnabled: Bool?
    public var immichAlbumPolicy: ImmichAlbumPolicy?
    public var immichAlbumName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        eventDate: Date,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        immichUploadEnabled: Bool? = nil,
        immichAlbumPolicy: ImmichAlbumPolicy? = nil,
        immichAlbumName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.eventDate = eventDate
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.immichUploadEnabled = immichUploadEnabled
        self.immichAlbumPolicy = immichAlbumPolicy
        self.immichAlbumName = immichAlbumName
    }

    public var sendsToImmich: Bool { immichUploadEnabled ?? false }
    public var resolvedImmichAlbumPolicy: ImmichAlbumPolicy { immichAlbumPolicy ?? .none }
}

public enum ImmichAlbumPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case event
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "No album"
        case .event: "Event album"
        case .custom: "Custom album"
        }
    }
}

public struct PhotoEventAssignment: Codable, Equatable, Hashable, Sendable {
    public var sourceRootPath: String
    public var relativePath: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var eventID: UUID
    public var deviceID: String?
    /// `nil` follows the event setting; `false` is explicitly storage-only.
    public var immichUploadOverride: Bool?

    public init(
        sourceRootPath: String,
        relativePath: String,
        fileSize: Int64,
        modifiedAt: Date,
        eventID: UUID,
        deviceID: String? = nil,
        immichUploadOverride: Bool? = nil
    ) {
        self.sourceRootPath = sourceRootPath
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.eventID = eventID
        self.deviceID = deviceID
        self.immichUploadOverride = immichUploadOverride
    }

    public func matches(sourceRootPath: String, file: FileRecord) -> Bool {
        self.sourceRootPath == sourceRootPath
            && relativePath == file.path
            && fileSize == file.size
            && abs(modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
    }
}

public enum CameraLibraryFolder: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox = "_Inbox"
    case manifests = "_Manifests"
    case originals = "Originals"
    case edited = "Edited"
    case selects = "Selects"
    case shared = "Shared"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .manifests: "Proof Files"
        case .originals: "Originals"
        case .edited: "Edited"
        case .selects: "Selects"
        case .shared: "Shared"
        }
    }
}

public enum ConfiguredLocationRole: String, Codable, CaseIterable, Sendable {
    case importSource
    case archive
    case buffer

    public var displayName: String {
        switch self {
        case .importSource: "From Folder"
        case .archive: "Photo Library Target"
        case .buffer: "Buffer Drive"
        }
    }
}

public struct ConfiguredLocation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ConfiguredLocationRole
    public var name: String
    public var path: String

    public init(
        id: UUID = UUID(),
        role: ConfiguredLocationRole,
        name: String,
        path: String
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.path = path
    }
}

public struct ConfigurationStore {
    public let url: URL

    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load(defaults: AppConfiguration) throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: url.path) else {
            return defaults
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    public func save(_ configuration: AppConfiguration) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }
}
