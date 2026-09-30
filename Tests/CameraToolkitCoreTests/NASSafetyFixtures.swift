@testable import CameraToolkitCore
import CryptoKit
import Darwin
import Foundation

/// Shared by the sync/move safety tests and the chaos harness: a small world
/// of temp folders standing in for the Buffer and the NAS, and an SSH
/// verifier that runs the same `sha256sum` command with the local `/bin/sh`.
struct NASSafetyWorld {
    var root: URL
    var configuration: AppConfiguration
    var locations: EventStorageLocations
    var store: NASSyncStore
    var queue: NASRenameQueue
    var a: SavedCameraEvent
    var b: SavedCameraEvent

    var nas: URL { locations.nasRoot }
    var journals: URL { root.appendingPathComponent("Move Journals") }

    static let day: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 1
        return Calendar.current.date(from: parts)!
    }()

    /// Two Buffer events ("Trip A" and "Trip B") and an empty NAS folder.
    static func make(_ root: URL, aName: String = "Trip A") throws -> NASSafetyWorld {
        var configuration = testConfiguration(root: root)
        let a = SavedCameraEvent(name: aName, eventDate: day, storagePolicy: .buffer)
        let b = SavedCameraEvent(name: "Trip B", eventDate: day.addingTimeInterval(86_400), storagePolicy: .buffer)
        configuration.savedEvents = [a, b]
        let locations = EventStorageLocations(configuration: configuration)
        try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
        return NASSafetyWorld(
            root: root, configuration: configuration, locations: locations,
            store: try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite")),
            queue: NASRenameQueue(journalFolder: root.appendingPathComponent("Move Journals")), a: a, b: b
        )
    }

    func follower(remote: NASRemoteVerifier? = nil) -> NASMoveFollower {
        NASMoveFollower(store: store, remoteVerifier: remote, queue: queue, retryDelay: 0, isCancelled: { false })
    }

    func plan() -> NASSyncPlan { NASSyncPlanner.plan(events: configuration.savedEvents, locations: locations) }

    @discardableResult
    func sync(parallel: Int = 1) throws -> NASSyncReport {
        try NASSyncService(store: store, options: NASSyncOptions(parallelTransfers: parallel, retryDelay: 0), isCancelled: { false })
            .sync(plan(), nasRoot: nas)
    }

    func assignment(_ event: SavedCameraEvent, _ name: String, size: Int, modified: Double = 1_780_000_000) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer).path,
            relativePath: name, fileSize: Int64(size), modifiedAt: Date(timeIntervalSince1970: modified),
            eventID: event.id, deviceID: "sony-a7v"
        )
    }

    func drivePath(_ event: SavedCameraEvent, _ name: String) -> URL {
        locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer).appendingPathComponent(name)
    }

    func mirror(_ event: SavedCameraEvent, _ name: String) -> String {
        try! locations.layout(for: event, deviceID: "sony-a7v").mirrorRelativePath(for: name)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: nas.appendingPathComponent(relative).path) }

    /// Every regular file under `folder`, relative, without reading any.
    func files(under folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { subpath in
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(subpath).path))?[.type] as? FileAttributeType == .typeRegular
        }.sorted()
    }

    /// Puts a photo only the NAS has at `event`'s mirror path, with a
    /// verified record for it (what a sync would have left).
    @discardableResult
    func placeOnNASOnly(_ event: SavedCameraEvent, _ name: String, _ data: Data, modified: Double = 1_780_000_000, verified: Bool = true) throws -> String {
        let relative = mirror(event, name)
        let url = nas.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        if verified {
            try store.upsert([NASSyncRecord(
                nasRoot: nas.path, relativePath: relative, eventID: event.id, byteCount: Int64(data.count),
                sourceModifiedAt: Date(timeIntervalSince1970: modified).timeIntervalSinceReferenceDate,
                sha256: NASSafetyFixtures.sha(data), state: .verified, checkedAt: Date(), verifiedAt: Date()
            )])
        }
        return relative
    }

    func record(_ relative: String) throws -> NASSyncRecord? {
        try store.records(nasRoot: nas.path)[NASSyncStore.pathKey(relative)]
    }

    /// The SSH verifier that runs `sha256sum` with the local shell, over a
    /// symlink standing in for the server path.
    func localVerifier(commands: SyncLocked<[String]>? = nil) throws -> NASRemoteVerifier {
        try NASSafetyFixtures.localVerifier(root: root, nas: nas, commands: commands)
    }
}

enum NASSafetyFixtures {
    static func bytes(_ seed: Int, _ count: Int = 1_200) -> Data {
        Data((0..<count).map { UInt8(($0 &* (seed + 7)) & 0xFF) })
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func localVerifier(root: URL, nas: URL, commands: SyncLocked<[String]>? = nil) throws -> NASRemoteVerifier {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("sync")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let server = root.appendingPathComponent("Server")
        if !FileManager.default.fileExists(atPath: server.path) {
            try FileManager.default.createSymbolicLink(at: server, withDestinationURL: nas)
        }
        let binPath = bin.path
        return NASRemoteVerifier(localPrefix: nas.path, serverPrefix: server.path, label: "local sh") { command in
            commands?.mutate { $0.append(command) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": binPath + ":/usr/bin:/bin:/sbin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, stdout: data, stderr: Data())
        }
    }
}
