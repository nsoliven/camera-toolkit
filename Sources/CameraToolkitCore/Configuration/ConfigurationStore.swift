import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var demoRootPath: String
    public var importSourcePath: String
    public var archivePath: String
    public var bufferPath: String
    public var cameraLibraryRootPath: String
    /// The root of the NAS mirror layout: a Buffer file at
    /// `<year>/<event>/Originals/<Camera>/<subpath>` is archived at the same
    /// relative path under this folder. Empty means derived from
    /// `cameraLibraryRootPath` (`derivedArchiveLayoutRoot`); a configuration
    /// written before the mirror layout gets the derived value on load.
    public var archiveLayoutRootPath: String
    /// The SMB share the NAS library lives on (`smb://host/share`), opened
    /// by "Connect to NAS…" when the share is not mounted. Empty means none.
    public var nasSMBURL: String
    public var catalogDatabasePath: String
    public var catalogBackupFolderPath: String
    public var configuredLocations: [ConfiguredLocation]
    public var selectedImportSourceID: UUID?
    public var selectedArchiveID: UUID?
    public var selectedBufferID: UUID?
    public var activityLogPath: String
    public var immichServerURL: String
    public var trueNASServerURL: String
    public var trueNASUsername: String
    public var trueNASDataset: String
    public var trueNASTLSPinnedCertificateSHA256: String
    public var selectedDeviceID: String
    public var eventName: String
    public var batchID: String
    public var savedEvents: [SavedCameraEvent]
    public var selectedEventID: UUID?
    public var photoEventAssignments: [PhotoEventAssignment]
    /// Where events marked "Private · NAS only" wait on the working drive
    /// before and while they are archived. Empty means a hidden
    /// `.Camera Toolkit/Private` folder beside the Buffer on the same drive.
    public var privateStagingPath: String
    /// Manual burst splits made on the organize boards. Restacking honors
    /// them so a rescan never glues separated frames back together.
    public var burstSplits: [BurstSplit]
    /// Display-time rotation per file identity key (see
    /// `DisplayRotation.fileKey`), in quarter-turns clockwise. Applied while
    /// decoding tiles and previews; media bytes are never rewritten.
    public var displayOrientations: [String: Int]

    public init(
        demoRootPath: String,
        importSourcePath: String,
        archivePath: String,
        bufferPath: String,
        cameraLibraryRootPath: String = "",
        archiveLayoutRootPath: String = "",
        nasSMBURL: String = "",
        catalogDatabasePath: String = "",
        catalogBackupFolderPath: String = "",
        configuredLocations: [ConfiguredLocation] = [],
        selectedImportSourceID: UUID? = nil,
        selectedArchiveID: UUID? = nil,
        selectedBufferID: UUID? = nil,
        activityLogPath: String,
        immichServerURL: String = "",
        trueNASServerURL: String = "",
        trueNASUsername: String = "",
        trueNASDataset: String = "",
        trueNASTLSPinnedCertificateSHA256: String = "",
        selectedDeviceID: String = "generic-camera",
        eventName: String = "",
        batchID: String = "",
        savedEvents: [SavedCameraEvent] = [],
        selectedEventID: UUID? = nil,
        photoEventAssignments: [PhotoEventAssignment] = [],
        privateStagingPath: String = "",
        burstSplits: [BurstSplit] = [],
        displayOrientations: [String: Int] = [:]
    ) {
        self.demoRootPath = demoRootPath
        self.importSourcePath = importSourcePath
        self.archivePath = archivePath
        self.bufferPath = bufferPath
        self.cameraLibraryRootPath = cameraLibraryRootPath
        self.archiveLayoutRootPath = archiveLayoutRootPath
        self.nasSMBURL = nasSMBURL
        self.catalogDatabasePath = catalogDatabasePath
        self.catalogBackupFolderPath = catalogBackupFolderPath
        self.configuredLocations = configuredLocations
        self.selectedImportSourceID = selectedImportSourceID
        self.selectedArchiveID = selectedArchiveID
        self.selectedBufferID = selectedBufferID
        self.activityLogPath = activityLogPath
        self.immichServerURL = immichServerURL
        self.trueNASServerURL = trueNASServerURL
        self.trueNASUsername = trueNASUsername
        self.trueNASDataset = trueNASDataset
        self.trueNASTLSPinnedCertificateSHA256 = trueNASTLSPinnedCertificateSHA256
        self.selectedDeviceID = selectedDeviceID
        self.eventName = eventName
        self.batchID = batchID.isEmpty ? Self.makeBatchID(deviceID: selectedDeviceID) : batchID
        self.savedEvents = savedEvents
        self.selectedEventID = selectedEventID
        self.photoEventAssignments = photoEventAssignments
        self.privateStagingPath = privateStagingPath
        self.burstSplits = burstSplits
        self.displayOrientations = displayOrientations
        self.normalizeLocationSelections()
        self.normalizeEventSelection()
    }

    private enum CodingKeys: String, CodingKey {
        case demoRootPath
        case importSourcePath
        case archivePath
        case bufferPath
        case cameraLibraryRootPath
        case archiveLayoutRootPath
        case nasSMBURL
        case catalogDatabasePath
        case catalogBackupFolderPath
        case configuredLocations
        case selectedImportSourceID
        case selectedArchiveID
        case selectedBufferID
        case activityLogPath
        case immichServerURL
        case trueNASServerURL
        case trueNASUsername
        case trueNASDataset
        case trueNASTLSPinnedCertificateSHA256
        case selectedDeviceID
        case eventName
        case batchID
        case savedEvents
        case selectedEventID
        case photoEventAssignments
        case privateStagingPath
        case burstSplits
        case displayOrientations
        /// Present (true) in a settings-only file: events, assignments,
        /// display rotations, and burst splits live in the catalog.
        case catalogOwnsEventState
    }

    /// `JSONEncoder.userInfo` flag: encode settings only, leaving out the
    /// state the catalog owns (`CatalogOwnedState`) and writing the
    /// `catalogOwnsEventState` marker instead.
    public static let settingsOnlyUserInfoKey = CodingUserInfoKey(rawValue: "CameraToolkit.settingsOnly")!

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(demoRootPath, forKey: .demoRootPath)
        try values.encode(importSourcePath, forKey: .importSourcePath)
        try values.encode(archivePath, forKey: .archivePath)
        try values.encode(bufferPath, forKey: .bufferPath)
        try values.encode(cameraLibraryRootPath, forKey: .cameraLibraryRootPath)
        try values.encode(archiveLayoutRootPath, forKey: .archiveLayoutRootPath)
        try values.encode(nasSMBURL, forKey: .nasSMBURL)
        try values.encode(catalogDatabasePath, forKey: .catalogDatabasePath)
        try values.encode(catalogBackupFolderPath, forKey: .catalogBackupFolderPath)
        try values.encode(configuredLocations, forKey: .configuredLocations)
        try values.encodeIfPresent(selectedImportSourceID, forKey: .selectedImportSourceID)
        try values.encodeIfPresent(selectedArchiveID, forKey: .selectedArchiveID)
        try values.encodeIfPresent(selectedBufferID, forKey: .selectedBufferID)
        try values.encode(activityLogPath, forKey: .activityLogPath)
        try values.encode(immichServerURL, forKey: .immichServerURL)
        try values.encode(trueNASServerURL, forKey: .trueNASServerURL)
        try values.encode(trueNASUsername, forKey: .trueNASUsername)
        try values.encode(trueNASDataset, forKey: .trueNASDataset)
        try values.encode(trueNASTLSPinnedCertificateSHA256, forKey: .trueNASTLSPinnedCertificateSHA256)
        try values.encode(selectedDeviceID, forKey: .selectedDeviceID)
        try values.encode(eventName, forKey: .eventName)
        try values.encode(batchID, forKey: .batchID)
        try values.encodeIfPresent(selectedEventID, forKey: .selectedEventID)
        try values.encode(privateStagingPath, forKey: .privateStagingPath)
        if encoder.userInfo[Self.settingsOnlyUserInfoKey] as? Bool == true {
            try values.encode(true, forKey: .catalogOwnsEventState)
        } else {
            try values.encode(savedEvents, forKey: .savedEvents)
            try values.encode(photoEventAssignments, forKey: .photoEventAssignments)
            try values.encode(burstSplits, forKey: .burstSplits)
            try values.encode(displayOrientations, forKey: .displayOrientations)
        }
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
        // Missing in a configuration from before the mirror layout: the
        // normalization below derives it from the library root once, and the
        // next save writes it out, so the setting is explicit from then on.
        archiveLayoutRootPath = try values.decodeIfPresent(String.self, forKey: .archiveLayoutRootPath) ?? ""
        nasSMBURL = try values.decodeIfPresent(String.self, forKey: .nasSMBURL) ?? ""
        catalogDatabasePath = try values.decodeIfPresent(String.self, forKey: .catalogDatabasePath) ?? defaults.catalogDatabasePath
        catalogBackupFolderPath = try values.decodeIfPresent(String.self, forKey: .catalogBackupFolderPath) ?? defaults.catalogBackupFolderPath
        configuredLocations = try values.decodeIfPresent([ConfiguredLocation].self, forKey: .configuredLocations) ?? []
        selectedImportSourceID = try values.decodeIfPresent(UUID.self, forKey: .selectedImportSourceID)
        selectedArchiveID = try values.decodeIfPresent(UUID.self, forKey: .selectedArchiveID)
        selectedBufferID = try values.decodeIfPresent(UUID.self, forKey: .selectedBufferID)
        activityLogPath = try values.decodeIfPresent(String.self, forKey: .activityLogPath) ?? defaults.activityLogPath
        immichServerURL = try values.decodeIfPresent(String.self, forKey: .immichServerURL) ?? defaults.immichServerURL
        trueNASServerURL = try values.decodeIfPresent(String.self, forKey: .trueNASServerURL) ?? defaults.trueNASServerURL
        trueNASUsername = try values.decodeIfPresent(String.self, forKey: .trueNASUsername) ?? defaults.trueNASUsername
        trueNASDataset = try values.decodeIfPresent(String.self, forKey: .trueNASDataset) ?? defaults.trueNASDataset
        trueNASTLSPinnedCertificateSHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .trueNASTLSPinnedCertificateSHA256
        ) ?? defaults.trueNASTLSPinnedCertificateSHA256
        selectedDeviceID = try values.decodeIfPresent(String.self, forKey: .selectedDeviceID) ?? defaults.selectedDeviceID
        eventName = try values.decodeIfPresent(String.self, forKey: .eventName) ?? defaults.eventName
        batchID = try values.decodeIfPresent(String.self, forKey: .batchID) ?? Self.makeBatchID(deviceID: selectedDeviceID)
        savedEvents = try values.decodeIfPresent([SavedCameraEvent].self, forKey: .savedEvents) ?? []
        selectedEventID = try values.decodeIfPresent(UUID.self, forKey: .selectedEventID)
        photoEventAssignments = try values.decodeIfPresent([PhotoEventAssignment].self, forKey: .photoEventAssignments) ?? []
        privateStagingPath = try values.decodeIfPresent(String.self, forKey: .privateStagingPath) ?? ""
        burstSplits = try values.decodeIfPresent([BurstSplit].self, forKey: .burstSplits) ?? []
        displayOrientations = try values.decodeIfPresent([String: Int].self, forKey: .displayOrientations) ?? [:]
        normalizeLocationSelections()
        // A settings-only file has no events to validate the selection
        // against; it is normalized once the catalog's events are laid
        // back on (`CatalogOwnedState.apply(to:)`). Normalizing here would
        // clear the selection or invent an event from `eventName`.
        if try values.decodeIfPresent(Bool.self, forKey: .catalogOwnsEventState) != true {
            normalizeEventSelection()
        }
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
        if archiveLayoutRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            archiveLayoutRootPath = Self.derivedArchiveLayoutRoot(cameraLibraryRootPath: cameraLibraryRootPath)
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

    /// The mirror root a library root implies: the library root itself, or
    /// its parent when it ends in `Originals` — so a library configured as
    /// `…/Media/Camera/Originals` mirrors to `…/Media/Camera/<year>/…`
    /// instead of a confusing `Originals/<year>/<event>/Originals/<Camera>`.
    public static func derivedArchiveLayoutRoot(cameraLibraryRootPath: String) -> String {
        let trimmed = cameraLibraryRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let url = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true).standardizedFileURL
        if url.lastPathComponent == CameraLibraryFolder.originals.rawValue {
            return url.deletingLastPathComponent().path
        }
        return url.path
    }

    public func libraryFolderPath(_ folder: CameraLibraryFolder) -> URL {
        URL(fileURLWithPath: cameraLibraryRootPath, isDirectory: true)
            .appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    /// `<event>/Originals/<Camera>` on the Buffer for the selected event and device.
    public func bufferBatchFolderPath() -> String {
        let layout = OrganizedArchiveLayout(configuration: self)
        return URL(fileURLWithPath: bufferEventFolderPath(), isDirectory: true)
            .appendingPathComponent(EventStorageLocations.originalsFolderName, isDirectory: true)
            .appendingPathComponent(layout.cameraFolder, isDirectory: true)
            .path
    }

    public func bufferEventFolderPath() -> String {
        let layout = OrganizedArchiveLayout(configuration: self)
        var url = URL(fileURLWithPath: bufferPath, isDirectory: true)
            .appendingPathComponent(layout.year, isDirectory: true)
        // A selected subevent's folder nests inside its parent's folder.
        for folder in layout.parentEventFolders {
            url.appendPathComponent(folder, isDirectory: true)
        }
        return url.appendingPathComponent(layout.eventFolder, isDirectory: true).path
    }

    public func bufferIngestFolderPath() -> String {
        bufferBatchFolderPath()
    }

    /// `<event>/Edited` — the owner's edits; each first-level folder in it
    /// is an edit tag ("Photomator", "Masters", …).
    public func bufferEditsFolderPath() -> String {
        URL(fileURLWithPath: bufferEventFolderPath(), isDirectory: true)
            .appendingPathComponent(EventStorageLocations.editedFolderName, isDirectory: true)
            .path
    }

    /// `<event>/Edited/<folder>` — one edit tag's folder.
    public func bufferEditedFolderPath(_ folderName: String) -> String {
        URL(fileURLWithPath: bufferEditsFolderPath(), isDirectory: true)
            .appendingPathComponent(Self.pathComponent(folderName, fallback: "Masters"), isDirectory: true)
            .path
    }

    /// The folders a new event starts with: the camera's `Originals`
    /// folder and `Edited`.
    public func eventWorkspaceFolderPaths() -> [String] {
        [
            bufferBatchFolderPath(),
            bufferEditsFolderPath()
        ]
    }

    public var archiveEventDate: String {
        let candidate = String(batchID.prefix(10))
        return Self.dayFormatter.date(from: candidate) == nil ? Self.dayFormatter.string(from: Date()) : candidate
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
        case "dji-nano": "DJI-Nano"
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
    /// `nil` is the migration-safe default and behaves like `.buffer`.
    /// On a subevent, `nil` inherits the parent's resolved policy instead.
    public var storagePolicy: EventStoragePolicy?
    /// The event this subevent nests inside. `nil` is the migration-safe
    /// default for top-level events; the folder then sits directly under the
    /// drive's year folder.
    public var parentEventID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        eventDate: Date,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        immichUploadEnabled: Bool? = nil,
        immichAlbumPolicy: ImmichAlbumPolicy? = nil,
        immichAlbumName: String? = nil,
        storagePolicy: EventStoragePolicy? = nil,
        parentEventID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.eventDate = eventDate
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.immichUploadEnabled = immichUploadEnabled
        self.immichAlbumPolicy = immichAlbumPolicy
        self.immichAlbumName = immichAlbumName
        self.storagePolicy = storagePolicy
        self.parentEventID = parentEventID
    }

    public var sendsToImmich: Bool { immichUploadEnabled ?? false }
    public var resolvedImmichAlbumPolicy: ImmichAlbumPolicy { immichAlbumPolicy ?? .none }
    /// The event's own policy. For a subevent this ignores inheritance —
    /// prefer `EventHierarchy.resolvedPolicy` when the parent link matters.
    public var resolvedStoragePolicy: EventStoragePolicy { storagePolicy ?? .buffer }
}

/// Parent/child structure between events. A subevent's folder lives inside
/// its parent's folder, so every path and breadcrumb resolves through the
/// ancestor chain. A missing parent or a link loop ends the chain — the
/// event then behaves as top-level instead of trapping callers in a cycle.
public enum EventHierarchy {
    /// ID → event lookup. Callers evaluating many events against the same
    /// array (flattened, descendants, `EventStorageLocations`) build it once
    /// and share it through the `byID` overloads instead of rebuilding per
    /// event.
    public static func index(_ events: [SavedCameraEvent]) -> [UUID: SavedCameraEvent] {
        var byID: [UUID: SavedCameraEvent] = [:]
        for event in events where byID[event.id] == nil { byID[event.id] = event }
        return byID
    }

    /// Ancestors of `event`, root first. Stops at a missing parent or a cycle.
    public static func ancestors(of event: SavedCameraEvent, in events: [SavedCameraEvent]) -> [SavedCameraEvent] {
        ancestors(of: event, byID: index(events))
    }

    public static func ancestors(of event: SavedCameraEvent, byID: [UUID: SavedCameraEvent]) -> [SavedCameraEvent] {
        var chain: [SavedCameraEvent] = []
        var seen: Set<UUID> = [event.id]
        var current = event
        while let parentID = current.parentEventID,
              let parent = byID[parentID],
              seen.insert(parent.id).inserted {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// `event` with its ancestors, root first.
    public static func chain(of event: SavedCameraEvent, in events: [SavedCameraEvent]) -> [SavedCameraEvent] {
        chain(of: event, byID: index(events))
    }

    public static func chain(of event: SavedCameraEvent, byID: [UUID: SavedCameraEvent]) -> [SavedCameraEvent] {
        ancestors(of: event, byID: byID) + [event]
    }

    /// The first explicit storage policy walking up from `event`; `.buffer`
    /// when the whole chain leaves it unset.
    public static func resolvedPolicy(of event: SavedCameraEvent, in events: [SavedCameraEvent]) -> EventStoragePolicy {
        resolvedPolicy(of: event, byID: index(events))
    }

    public static func resolvedPolicy(of event: SavedCameraEvent, byID: [UUID: SavedCameraEvent]) -> EventStoragePolicy {
        var seen: Set<UUID> = [event.id]
        var current = event
        while true {
            if let policy = current.storagePolicy { return policy }
            guard let parentID = current.parentEventID,
                  let parent = byID[parentID],
                  seen.insert(parent.id).inserted else { return .buffer }
            current = parent
        }
    }

    /// Events whose ancestor chain contains `eventID` — its subevents at any
    /// depth. Used to keep a parent picker from offering a descendant and to
    /// rewrite every assignment a rename moves on disk.
    public static func descendants(of eventID: UUID, in events: [SavedCameraEvent]) -> [SavedCameraEvent] {
        let byID = index(events)
        return events.filter { candidate in
            candidate.id != eventID && ancestors(of: candidate, byID: byID).contains { $0.id == eventID }
        }
    }

    /// Direct subevents of `eventID` in the same sibling order `flattened`
    /// uses — newest first, then by name.
    public static func children(of eventID: UUID, in events: [SavedCameraEvent]) -> [SavedCameraEvent] {
        events.filter { $0.parentEventID == eventID }
            .sorted { $0.eventDate == $1.eventDate ? $0.name < $1.name : $0.eventDate > $1.eventDate }
    }

    /// The deepest a saved event may nest: depth 0 is a top-level event,
    /// depth 1 its subevent, depth 2 a subevent of that subevent. An event
    /// already deeper than this (adopted folders or pre-cap data) still
    /// lists and opens — the cap only refuses new children under it.
    public static let maxDepth = 2

    /// How deep the event sits: 0 for a top-level event, plus one per
    /// ancestor. A broken chain just ends the count, like `ancestors`.
    public static func depth(of event: SavedCameraEvent, in events: [SavedCameraEvent]) -> Int {
        ancestors(of: event, byID: index(events)).count
    }

    /// True when the event may take a new subevent — its own depth is below
    /// `maxDepth`. A deeper event stays in the list but can't parent a new
    /// level under it.
    public static func canParent(_ event: SavedCameraEvent, in events: [SavedCameraEvent]) -> Bool {
        ancestors(of: event, byID: index(events)).count < maxDepth
    }

    /// "Parent / Child" title for menus and headers.
    public static func displayName(of event: SavedCameraEvent, in events: [SavedCameraEvent]) -> String {
        displayName(of: event, byID: index(events))
    }

    public static func displayName(of event: SavedCameraEvent, byID: [UUID: SavedCameraEvent]) -> String {
        chain(of: event, byID: byID).map(\.name).joined(separator: " / ")
    }

    /// Events flattened for list display: parents in the usual newest-first
    /// order, each followed by its subevents (depth drives indentation).
    /// Members of a parent loop have no top-level root; they surface sorted
    /// at the end instead of vanishing.
    public static func flattened(_ events: [SavedCameraEvent]) -> [(event: SavedCameraEvent, depth: Int)] {
        let order: (SavedCameraEvent, SavedCameraEvent) -> Bool = {
            $0.eventDate == $1.eventDate ? $0.name < $1.name : $0.eventDate > $1.eventDate
        }
        let byID = index(events)
        var children: [UUID: [SavedCameraEvent]] = [:]
        var roots: [SavedCameraEvent] = []
        for event in events {
            if let parent = ancestors(of: event, byID: byID).last {
                children[parent.id, default: []].append(event)
            } else {
                roots.append(event)
            }
        }
        var rows: [(event: SavedCameraEvent, depth: Int)] = []
        var visited: Set<UUID> = []
        func walk(_ event: SavedCameraEvent, _ depth: Int) {
            guard visited.insert(event.id).inserted else { return }
            rows.append((event, depth))
            for child in (children[event.id] ?? []).sorted(by: order) {
                walk(child, depth + 1)
            }
        }
        for root in roots.sorted(by: order) { walk(root, 0) }
        for event in events.sorted(by: order) where !visited.contains(event.id) {
            walk(event, 0)
        }
        return rows
    }
}

/// Where an event lives on the working drive.
public enum EventStoragePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The event's originals sit in the shared Camera Buffer folder.
    case buffer
    /// The event never goes into the shared Buffer. Originals wait in the
    /// hidden private staging folder until they are archived to the NAS.
    case archiveOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .buffer: "Shared Buffer"
        case .archiveOnly: "Private · NAS only"
        }
    }
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
    /// Camera that produced this source's files. `nil` infers it from the name.
    public var deviceID: String?

    public init(
        id: UUID = UUID(),
        role: ConfiguredLocationRole,
        name: String,
        path: String,
        deviceID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.path = path
        self.deviceID = deviceID
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

    /// The config file's modification date and size — the cheap "did the
    /// file change on disk" fingerprint an activation check compares
    /// before paying for a decode. Nil when the file is absent.
    public func fileStamp() -> (modifiedAt: Date, byteCount: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return (modified, Int64(size))
    }

    /// Writes the configuration atomically. `settingsOnly` leaves out the
    /// events, assignments, rotations, and burst splits once the catalog
    /// owns them (see `CatalogStateStore`).
    public func save(_ configuration: AppConfiguration, settingsOnly: Bool = false) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(configuration, settingsOnly: settingsOnly).write(to: url, options: .atomic)
    }

    public static func encode(_ configuration: AppConfiguration, settingsOnly: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if settingsOnly {
            encoder.userInfo[AppConfiguration.settingsOnlyUserInfoKey] = true
        }
        return try encoder.encode(configuration)
    }

    /// True when `data` is a settings-only file written after the catalog
    /// took over events and assignments.
    public static func isSettingsOnly(_ data: Data) -> Bool {
        struct Marker: Decodable { var catalogOwnsEventState: Bool? }
        return (try? JSONDecoder().decode(Marker.self, from: data))?.catalogOwnsEventState == true
    }
}
