import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// A synthetic drive and support folder shaped like the owner's:
///
/// ```
/// Buffer/2026/2026-08-23 Sample Trip 2026/
///   Sony A7V/Card Copy/            DSC00001.ARW (+ .ARW.xmp, ._ twin), DSC00002.ARW + .JPG
///                                  (+ ._ twin and its own ._._ twin),
///                                  DSC00003.ARW.photo-edit, notes.txt (unknown), .DS_Store,
///                                  Transfer 4 (Ridge)/DSC00010.ARW (+ ._ folder twin)
///   Sony A7V/readme.txt            beside Card Copy → left in place
///   DJI Osmo 360/Card Copy/        CAM_0001.OSV + .LRF
///   osmo-360/Card Copy/            a *different* CAM_0001.OSV + .LRF + ._ twin → "(2)"
///   Originals/Sony A7V/DSC00002.ARW  already there (a mixed drive) → "(2)"
///   Photomator/edit.jpg, Exports/Masters/   event-level folders → left in place
/// Buffer/2026/2026-08-23 Unparsed A7V/Sony A7V/Card Copy/.DS_Store   junk folder
/// .Camera Toolkit/Private/2026/2026-08-23 Sample Trip 2026/2026-08-24 Side Trip/
///   Sony A7V/Card Copy/DSC00100.ARW, DJI Nano/Card Copy/DJI_0001.MP4
/// .Camera Toolkit/_Trash/2026-09-21_230244/manifest.json  (entry in a legacy Card Copy)
/// ```
///
/// The catalog holds a parent event, a private subevent, adopted and
/// Apply-style assignments (one missing), presence and Immich rows, three
/// face photos (one re-keyed, one followed by identity, one unrelated) with
/// confirmed faces and a template, a rotation, and a burst split.
struct LayoutMigrationFixture {
    let root: URL
    let support: URL
    let buffer: URL
    let privateRoot: URL
    let trashRoot: URL
    let configurationURL: URL
    let catalogURL: URL
    var configuration: AppConfiguration
    let parent: SavedCameraEvent
    let child: SavedCameraEvent

    var parentFolder: URL { buffer.appendingPathComponent("2026/2026-08-23 Sample Trip 2026", isDirectory: true) }
    var childFolder: URL {
        privateRoot.appendingPathComponent("2026/2026-08-23 Sample Trip 2026/2026-08-24 Side Trip", isDirectory: true)
    }
    var sonyCardCopy: URL { parentFolder.appendingPathComponent("Sony A7V/Card Copy", isDirectory: true) }
    var osmoCardCopy: URL { parentFolder.appendingPathComponent("DJI Osmo 360/Card Copy", isDirectory: true) }
    var osmoAltCardCopy: URL { parentFolder.appendingPathComponent("osmo-360/Card Copy", isDirectory: true) }
    var unsorted: URL { root.appendingPathComponent("Unsorted", isDirectory: true) }

    static let fixedDate = Date(timeIntervalSince1970: 1_787_000_000)

    /// Assignment ids of interest.
    var adoptedSony: PhotoEventAssignment
    var appliedRenamed: PhotoEventAssignment
    var appliedNested: PhotoEventAssignment
    var appliedPrivate: PhotoEventAssignment
    var adoptedOsmo: PhotoEventAssignment
    var adoptedOsmoAlt: PhotoEventAssignment
    var missing: PhotoEventAssignment

    /// `support` defaults to `<root>/Support`; the exFAT test keeps it on
    /// the local disk while the drive tree lives on the exFAT volume.
    static func make(in root: URL, support supportOverride: URL? = nil) throws -> LayoutMigrationFixture {
        let support = supportOverride ?? root.appendingPathComponent("Support", isDirectory: true)
        let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
        let privateRoot = root.appendingPathComponent(".Camera Toolkit/Private", isDirectory: true)
        let trashRoot = root.appendingPathComponent(".Camera Toolkit/_Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalogURL)
        configuration.bufferPath = buffer.path
        configuration.selectedDeviceID = "sony-a7v"

        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let parent = SavedCameraEvent(name: "Sample Trip 2026", eventDate: day.date(from: "2026-08-23")!, storagePolicy: .buffer)
        let child = SavedCameraEvent(
            name: "Side Trip",
            eventDate: day.date(from: "2026-08-24")!,
            storagePolicy: .archiveOnly,
            parentEventID: parent.id
        )

        let parentFolder = buffer.appendingPathComponent("2026/2026-08-23 Sample Trip 2026", isDirectory: true)
        let sony = parentFolder.appendingPathComponent("Sony A7V/Card Copy", isDirectory: true)
        let osmo = parentFolder.appendingPathComponent("DJI Osmo 360/Card Copy", isDirectory: true)
        let osmoAlt = parentFolder.appendingPathComponent("osmo-360/Card Copy", isDirectory: true)
        let childFolder = privateRoot.appendingPathComponent("2026/2026-08-23 Sample Trip 2026/2026-08-24 Side Trip", isDirectory: true)

        func put(_ url: URL, _ text: String) throws {
            try writeFile(url, text)
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        }
        try put(sony.appendingPathComponent("DSC00001.ARW"), "raw-one")
        try put(sony.appendingPathComponent("DSC00001.ARW.xmp"), "<xmp one/>")
        try put(sony.appendingPathComponent("._DSC00001.ARW"), "appledouble-one")
        try put(sony.appendingPathComponent("DSC00002.ARW"), "raw-two")
        try put(sony.appendingPathComponent("DSC00002.JPG"), "jpeg-two")
        try put(sony.appendingPathComponent("._DSC00002.JPG"), "appledouble-jpeg")
        try put(sony.appendingPathComponent("._._DSC00002.JPG"), "appledouble-of-appledouble")
        try put(sony.appendingPathComponent("DSC00003.ARW.photo-edit"), "edit-three")
        try put(sony.appendingPathComponent("notes.txt"), "unknown to the catalog")
        try put(sony.appendingPathComponent(".DS_Store"), "finder")
        try put(sony.appendingPathComponent("Transfer 4 (Ridge)/DSC00010.ARW"), "raw-ten")
        try put(sony.appendingPathComponent("._Transfer 4 (Ridge)"), "folder twin")
        try put(parentFolder.appendingPathComponent("Sony A7V/readme.txt"), "beside card copy")
        try put(osmo.appendingPathComponent("CAM_0001.OSV"), "osv-a")
        try put(osmo.appendingPathComponent("CAM_0001.LRF"), "lrf-a")
        try put(osmoAlt.appendingPathComponent("CAM_0001.OSV"), "osv-b-different")
        try put(osmoAlt.appendingPathComponent("CAM_0001.LRF"), "lrf-b")
        try put(osmoAlt.appendingPathComponent("._CAM_0001.OSV"), "appledouble-b")
        try put(parentFolder.appendingPathComponent("Originals/Sony A7V/DSC00002.ARW"), "an older raw-two already migrated")
        try put(parentFolder.appendingPathComponent("Photomator/edit.jpg"), "photomator edit")
        try FileManager.default.createDirectory(at: parentFolder.appendingPathComponent("Exports/Masters"), withIntermediateDirectories: true)
        try put(buffer.appendingPathComponent("2026/2026-08-23 Unparsed A7V/Sony A7V/Card Copy/.DS_Store"), "junk")
        try put(buffer.appendingPathComponent("2026/2026-08-23 Unparsed A7V/._Sony A7V"), "junk twin")
        try put(childFolder.appendingPathComponent("Sony A7V/Card Copy/DSC00100.ARW"), "private raw")
        try put(childFolder.appendingPathComponent("DJI Nano/Card Copy/DJI_0001.MP4"), "private clip")

        func assignment(_ root: URL, _ relative: String, _ event: SavedCameraEvent, _ device: String, size: Int) -> PhotoEventAssignment {
            PhotoEventAssignment(
                sourceRootPath: root.standardizedFileURL.path,
                relativePath: relative,
                fileSize: Int64(size),
                modifiedAt: fixedDate,
                eventID: event.id,
                deviceID: device
            )
        }
        let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
        let adoptedSony = assignment(sony, "DSC00001.ARW", parent, "sony-a7v", size: 7)
        let appliedRenamed = assignment(unsorted.appendingPathComponent("Transfer 2"), "DSC00002.ARW", parent, "sony-a7v", size: 7)
        let appliedNested = assignment(unsorted, "Transfer 4 (Ridge)/DSC00010.ARW", parent, "sony-a7v", size: 7)
        let appliedPrivate = assignment(unsorted.appendingPathComponent("Private"), "DSC00100.ARW", child, "sony-a7v", size: 11)
        let adoptedOsmo = assignment(osmo, "CAM_0001.OSV", parent, "osmo-360", size: 5)
        let adoptedOsmoAlt = assignment(osmoAlt, "CAM_0001.OSV", parent, "osmo-360", size: 15)
        let missing = assignment(unsorted, "GONE.ARW", parent, "sony-a7v", size: 3)

        let state = CatalogOwnedState(
            savedEvents: [parent, child],
            photoEventAssignments: [adoptedSony, appliedRenamed, appliedNested, appliedPrivate, adoptedOsmo, adoptedOsmoAlt, missing],
            displayOrientations: [
                FaceIndexStore.fileKey(fileName: "DSC00002.ARW", byteCount: 7, modifiedAt: fixedDate): 1,
            ],
            burstSplits: [BurstSplit(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                createdAt: fixedDate,
                memberPathKeys: [
                    EventStorageLocations.pathKey(sony.appendingPathComponent("DSC00001.ARW").path),
                    EventStorageLocations.pathKey(unsorted.appendingPathComponent("elsewhere.ARW").path),
                ]
            )]
        )
        try CatalogStore(url: catalogURL).prepareSchema()
        _ = try CatalogStateStore(url: catalogURL).migrate(
            state: state,
            configurationURL: nil,
            backups: CatalogBackupService(
                catalogURL: catalogURL,
                configurationURL: nil,
                localFolder: support.appendingPathComponent("Backups", isDirectory: true),
                remoteFolder: nil
            )
        )

        // Presence, Immich, faces.
        let writer = try CatalogDatabase.writer(for: catalogURL)
        let now = "2026-09-20T00:00:00.000Z"
        try writer.write { db in
            let adoptedID = CatalogStore.eventAssetID(adoptedSony)
            try db.execute(sql: "INSERT INTO event_asset_locations(event_asset_id, location, state, checked_at) VALUES (?, 'buffer', 1, ?)", arguments: [adoptedID, now])
            try db.execute(sql: "INSERT INTO immich_assets(event_asset_id, status, checked_at) VALUES (?, 'uploaded', ?)", arguments: [adoptedID, now])
            try db.execute(sql: "INSERT INTO immich_assets(event_asset_id, status, checked_at) VALUES (?, 'uploaded', ?)", arguments: [CatalogStore.eventAssetID(appliedRenamed), now])
            try db.execute(sql: "INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at) VALUES ('P1', 'Riley', 1, 3, ?, ?)", arguments: [now, now])
            let modified = ISO8601DateFormatter.fractional.string(from: fixedDate)
            func photo(_ path: String, _ name: String, _ size: Int) throws -> String {
                let key = EventStorageLocations.pathKey(path)
                try db.execute(
                    sql: """
                    INSERT INTO face_photos(path_key, path, file_name, byte_count, modified_at, scan_grade, face_count, engine, indexed_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'med', 0, 'insightface/buffalo_l', ?, ?)
                    """,
                    arguments: [key, path, name, size, modified, now, now]
                )
                return key
            }
            func face(_ id: String, _ photo: String, _ state: String, person: String?) throws {
                try db.execute(
                    sql: """
                    INSERT INTO faces(id, photo_id, person_id, box_x, box_y, box_w, box_h, det_score, state, created_at, updated_at)
                    VALUES (?, ?, ?, 0.1, 0.1, 0.2, 0.2, 0.9, ?, ?, ?)
                    """,
                    arguments: [id, photo, person, state, now, now]
                )
            }
            // B: the drive copy itself — re-keyed.
            let drivePhoto = try photo(sony.appendingPathComponent("DSC00001.ARW").path, "DSC00001.ARW", 7)
            try face("F-B1", drivePhoto, "confirmed", person: "P1")
            try face("F-B2", drivePhoto, "cached", person: nil)
            try db.execute(sql: "INSERT INTO face_templates(person_id, face_id, created_at) VALUES ('P1', 'F-B1', ?)", arguments: [now])
            // A: a stale unsorted path; the file now sits in Card Copy and
            // gets a "(2)" name — the row follows by identity.
            let stalePhoto = try photo(unsorted.appendingPathComponent("Transfer 2/DSC00002.ARW").path, "DSC00002.ARW", 7)
            try face("F-A1", stalePhoto, "confirmed", person: "P1")
            // C: unrelated.
            try writeFile(unsorted.appendingPathComponent("other.ARW"), "other")
            let otherPhoto = try photo(unsorted.appendingPathComponent("other.ARW").path, "other.ARW", 5)
            try face("F-C1", otherPhoto, "confirmed", person: "P1")
            try db.execute(sql: "UPDATE face_photos SET face_count = (SELECT COUNT(*) FROM faces WHERE faces.photo_id = face_photos.path_key)")
        }
        CatalogDatabase.checkpointAndClose(url: catalogURL)

        // config.json holds settings only once the catalog owns the state.
        let configurationURL = support.appendingPathComponent("config.json")
        try ConfigurationStore(url: configurationURL).save(configuration, settingsOnly: true)

        // Capture-date cache keyed by full path.
        let cache: [String: Any] = [
            "version": 2,
            "entries": [
                sony.appendingPathComponent("DSC00001.ARW").path: ["size": 7, "modified": fixedDate.timeIntervalSinceReferenceDate],
                unsorted.appendingPathComponent("other.ARW").path: ["size": 5, "modified": fixedDate.timeIntervalSinceReferenceDate],
            ],
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: support.appendingPathComponent("capture-dates.json"))

        // A trash batch whose file came out of a legacy Card Copy.
        let batch = trashRoot.appendingPathComponent("2026-09-21_230244", isDirectory: true)
        try writeFile(batch.appendingPathComponent("Buffer/2026/2026-08-23 Sample Trip 2026/Sony A7V/Card Copy/DSC08937.ARW"), "trashed")
        let manifest = MediaTrashManifest(
            version: 1,
            batchID: "2026-09-21_230244",
            createdAt: fixedDate,
            entries: [MediaTrashEntry(
                trashedRelativePath: "Buffer/2026/2026-08-23 Sample Trip 2026/Sony A7V/Card Copy/DSC08937.ARW",
                originalAbsolutePath: sony.appendingPathComponent("DSC08937.ARW").path,
                originalLocationName: "Sample Trip 2026",
                size: 7
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: batch.appendingPathComponent("manifest.json"))

        // One Apply journal from before the migration.
        try writeFile(support.appendingPathComponent("Move Journals/20260920-000000-000001-ABCDEF01.json"), "{}")

        return LayoutMigrationFixture(
            root: root,
            support: support,
            buffer: buffer,
            privateRoot: privateRoot,
            trashRoot: trashRoot,
            configurationURL: configurationURL,
            catalogURL: catalogURL,
            configuration: configuration,
            parent: parent,
            child: child,
            adoptedSony: adoptedSony,
            appliedRenamed: appliedRenamed,
            appliedNested: appliedNested,
            appliedPrivate: appliedPrivate,
            adoptedOsmo: adoptedOsmo,
            adoptedOsmoAlt: adoptedOsmoAlt,
            missing: missing
        )
    }

    var inputs: LayoutMigrationPlanner.Inputs {
        var settings = configuration
        settings.savedEvents = []
        settings.photoEventAssignments = []
        return .init(configuration: settings, supportFolder: support, configurationURL: configurationURL, catalogURL: catalogURL)
    }

    func plan() throws -> LayoutMigrationPlan {
        try LayoutMigrationPlanner().plan(inputs)
    }

    /// Every file and folder under the drive roots (the fixture root minus
    /// the support folder): relative path → (kind, size, inode, bytes).
    func driveTree() throws -> [String: String] {
        var result: [String: String] = [:]
        let base = root.standardizedFileURL.path
        func walk(_ path: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                let child = (path as NSString).appendingPathComponent(name)
                let relative = String(child.dropFirst(base.count + 1))
                if relative.hasPrefix("Support") { continue }
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    result[relative] = "dir"
                    try walk(child)
                } else {
                    let data = try Data(contentsOf: URL(fileURLWithPath: child))
                    // A trash manifest is rewritten atomically (new inode);
                    // its bytes are what must round-trip.
                    let inode = name == "manifest.json" ? "" : " ino \(info.st_ino)"
                    result[relative] = "file \(info.st_size)\(inode) \(data.base64EncodedString())"
                }
            }
        }
        try walk(base)
        return result
    }

    func readCatalog<T>(_ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read(body)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
