import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A small library built in a temp folder for the move audit: a Buffer and a
/// private staging folder on one "drive", a card folder, an optional NAS, and
/// events the tests name by a short key. Files hold real bytes so identical
/// and different photos with one name can be told apart, and every file the
/// fixture writes is tracked so tests can prove nothing was lost. Nothing
/// touches the real Application Support folder, `/Volumes`, or a NAS.
@MainActor
final class AuditLibrary {
    struct Placed {
        var url: URL
        var assignment: PhotoEventAssignment
    }

    let root: URL
    let model: DashboardModel
    let workspace: EventsWorkspace
    private(set) var ids: [String: UUID] = [:]
    /// Everything the fixture ever wrote, by content, so a test can prove the
    /// multiset of files is conserved.
    private(set) var writtenContents: [Data] = []

    var drive: URL { root.appendingPathComponent("Drive", isDirectory: true) }
    var card: URL { root.appendingPathComponent("Card/DCIM", isDirectory: true) }
    var nasRoot: URL { workspace.locations.nasRoot }
    var locations: EventStorageLocations { workspace.locations }
    var catalogURL: URL { root.appendingPathComponent("CameraToolkit/catalog.sqlite") }
    static let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_772_000_000))

    static func make(catalogBacked: Bool = false, bufferPath: String? = nil) throws -> AuditLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitAudit-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: bufferPath ?? root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: support.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let configURL = support.appendingPathComponent("config.json")
        let store = ConfigurationStore(url: configURL)
        let model: DashboardModel
        if catalogBacked {
            try store.save(configuration)
            let outcome = CatalogStateStartup.resolve(
                configurationURL: configURL,
                defaults: configuration,
                backups: { url in
                    CatalogBackupService(
                        catalogURL: url,
                        configurationURL: configURL,
                        localFolder: support.appendingPathComponent("Backups"),
                        remoteFolder: nil
                    )
                }
            )
            model = DashboardModel(jobs: [], configuration: outcome.configuration, configurationStore: store)
            model.adoptCatalogState(outcome)
        } else {
            model = DashboardModel(jobs: [], configuration: configuration, configurationStore: store)
        }
        let workspace = EventsWorkspace(
            model: model,
            supportFolder: root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        workspace.captureDateReadProbe = { _ in nil }
        return AuditLibrary(root: root, model: model, workspace: workspace)
    }

    private init(root: URL, model: DashboardModel, workspace: EventsWorkspace) {
        self.root = root
        self.model = model
        self.workspace = workspace
    }

    func tearDown() {
        CatalogDatabase.checkpointAndClose(url: catalogURL)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Events

    @discardableResult
    func addEvent(
        _ key: String,
        name: String,
        date: Date = AuditLibrary.day,
        policy: EventStoragePolicy? = .buffer,
        parent: String? = nil
    ) -> UUID {
        let event = SavedCameraEvent(name: name, eventDate: date, storagePolicy: policy, parentEventID: parent.flatMap { ids[$0] })
        ids[key] = event.id
        model.updateConfiguration { $0.savedEvents.append(event) }
        return event.id
    }

    func id(_ key: String) -> UUID { ids[key]! }

    func event(_ key: String) -> SavedCameraEvent { workspace.event(ids[key]!)! }

    func key(of eventID: UUID) -> String { ids.first { $0.value == eventID }?.key ?? eventID.uuidString }

    // MARK: Files

    /// The folder an event keeps one camera's originals in, on its own drive.
    func folder(_ key: String, device: String = "sony-a7v") -> URL {
        let event = self.event(key)
        return locations.originalsRoot(for: event, deviceID: device, policy: locations.resolvedPolicy(for: event))
    }

    /// Writes a file where the event keeps it and adds its assignment.
    /// `sourceRoot` is where the catalog says the file came from (a card or
    /// unsorted folder, possibly one that no longer exists).
    @discardableResult
    func place(
        _ key: String,
        name: String,
        content: String,
        sourceRoot: String? = nil,
        device: String = "sony-a7v",
        modifiedAt: Date? = nil,
        onDrive: Bool = true,
        at folderOverride: URL? = nil,
        commit: Bool = true
    ) throws -> Placed {
        let eventID = id(key)
        let data = Data(content.utf8)
        let stamp = modifiedAt ?? Self.day.addingTimeInterval(Double(writtenContents.count + 1) * 7)
        let url: URL
        if onDrive {
            url = (folderOverride ?? folder(key, device: device)).appendingPathComponent(name)
        } else {
            url = card.appendingPathComponent(name)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.modificationDate: stamp]))
        writtenContents.append(data)
        let relative = name
        let assignment = PhotoEventAssignment(
            sourceRootPath: sourceRoot ?? (onDrive ? drive.appendingPathComponent("Unsorted A7V").path : card.path),
            relativePath: relative,
            fileSize: Int64(data.count),
            modifiedAt: stamp,
            eventID: eventID,
            deviceID: device
        )
        uncommitted.append(assignment)
        if commit { self.commit() }
        return Placed(url: url, assignment: assignment)
    }

    private var uncommitted: [PhotoEventAssignment] = []

    /// Adds the assignments of every `place(commit: false)` in one catalog write.
    func commit() {
        let batch = uncommitted
        uncommitted = []
        guard !batch.isEmpty else { return }
        model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: batch) }
    }

    /// A photo whose only copy is on the NAS (taken off the drive): the file
    /// sits at the event's mirror path, and its source and drive copies are gone.
    @discardableResult
    func placeOnNASOnly(_ key: String, name: String, content: String, device: String = "sony-a7v") throws -> Placed {
        let data = Data(content.utf8)
        let stamp = Self.day.addingTimeInterval(Double(writtenContents.count + 1) * 7)
        let assignment = PhotoEventAssignment(
            sourceRootPath: drive.appendingPathComponent("Unsorted A7V").path,
            relativePath: name,
            fileSize: Int64(data.count),
            modifiedAt: stamp,
            eventID: id(key),
            deviceID: device
        )
        let url = try XCTUnwrap(locations.archiveURL(for: assignment, event: event(key)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.modificationDate: stamp]))
        writtenContents.append(data)
        model.updateConfiguration { $0.photoEventAssignments.append(assignment) }
        return Placed(url: url, assignment: assignment)
    }

    /// An assignment with no file on disk anywhere (the card is gone).
    @discardableResult
    func assignWithoutFile(_ key: String, name: String, size: Int64 = 9, sourceRoot: String) -> PhotoEventAssignment {
        let assignment = PhotoEventAssignment(
            sourceRootPath: sourceRoot,
            relativePath: name,
            fileSize: size,
            modifiedAt: Self.day.addingTimeInterval(3),
            eventID: id(key),
            deviceID: "sony-a7v"
        )
        model.updateConfiguration { $0.photoEventAssignments.append(assignment) }
        return assignment
    }

    func assignments(_ key: String) -> [PhotoEventAssignment] {
        model.configuration.photoEventAssignments.filter { $0.eventID == ids[key] }
    }

    /// Assignments of the event and every descendant.
    func familyAssignments(_ eventID: UUID) -> [PhotoEventAssignment] {
        let family = workspace.scopeIDs(eventID)
        return model.configuration.photoEventAssignments.filter { family.contains($0.eventID) }
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func data(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// Where the app implies an assignment's drive copy is.
    func impliedPath(_ assignment: PhotoEventAssignment) -> String? {
        guard let event = workspace.event(assignment.eventID) else { return nil }
        return locations.driveURL(for: assignment, event: event, policy: locations.resolvedPolicy(for: event))?.path
    }

    /// The assignments a relaunch would read from the catalog on disk, once
    /// the debounced write has landed.
    func assignmentsOnDisk() -> [PhotoEventAssignment] {
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        let configURL = support.appendingPathComponent("config.json")
        let outcome = CatalogStateStartup.resolve(
            configurationURL: configURL,
            defaults: model.configuration,
            backups: { url in
                CatalogBackupService(catalogURL: url, configurationURL: configURL, localFolder: support.appendingPathComponent("Backups"), remoteFolder: nil)
            }
        )
        return outcome.configuration.photoEventAssignments
    }

    // MARK: Boards

    func open(_ keys: String...) async {
        for key in keys { await workspace.refreshEvent(id(key)) }
    }

    /// The board's stack holding the file at `path`.
    func stack(at path: String, on key: String) -> OrganizeStack? {
        workspace.eventStacks[id(key)]?.first { stack in
            stack.files.contains { $0.path.lowercased() == path.lowercased() }
        }
    }

    func boardFiles(_ eventID: UUID) -> [String] {
        (workspace.eventStacks[eventID] ?? []).flatMap(\.files).map { $0.path.lowercased() }.sorted()
    }

    // MARK: Waiting

    func waitUntil(timeout: TimeInterval = 30, _ message: String = "Timed out", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// No job, no queued move, no board re-reading — twice in a row, so work
    /// a completion just scheduled has started and finished.
    func settle(timeout: TimeInterval = 30) async throws {
        var quietPolls = 0
        let deadline = Date().addingTimeInterval(timeout)
        while quietPolls < 3 {
            if workspace.isQuiet { quietPolls += 1 } else { quietPolls = 0 }
            guard Date() < deadline else { return XCTFail("Timed out settling: \(model.statusMessage)") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: Disk

    /// Every regular file under the drive (Buffer, Private, `_Trash`), the
    /// card, and the NAS, as (path, content).
    func diskFiles() -> [(path: String, content: Data)] {
        var found: [(String, Data)] = []
        for base in [drive, card.deletingLastPathComponent(), root.appendingPathComponent("Library")] {
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                // Bookkeeping, not photos: Trash manifests.
                guard url.lastPathComponent != MediaTrashService.manifestFileName else { continue }
                found.append((url.path, (try? Data(contentsOf: url)) ?? Data()))
            }
        }
        return found
    }

    /// Multiset of the contents on disk, for "nothing was lost or overwritten".
    func contentCensus() -> [Data: Int] {
        var census: [Data: Int] = [:]
        for file in diskFiles() {
            census[file.content, default: 0] += 1
        }
        return census
    }

    func trashedNames() -> [String] {
        MediaTrashService(removedFilesRoot: locations.removedFilesRoot)
            .listItems(under: locations.trashRoots())
            .map(\.fileName)
            .sorted()
    }
}
