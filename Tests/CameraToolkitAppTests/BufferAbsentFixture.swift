import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The Buffer is a buffer: it is not plugged in all the time and one day it
/// is wiped, so the NAS mirror is the permanent library. Every board test
/// runs with the Buffer plugged in and again with it absent and only the NAS
/// mounted; the loading tests also run with nothing mounted at all.
enum LibraryMode: String, CaseIterable {
    /// The Buffer holds the files and the NAS is not consulted.
    case bufferPlugged
    /// The Buffer's volume is not mounted; the NAS stand-in holds every file
    /// at its mirror path.
    case nasOnly
    /// Neither the Buffer nor the NAS is mounted; the catalog is all there is.
    case nothingMounted
}

extension MoveLibrary {
    /// Unplugs the Buffer (its root moves to a `/Volumes` name that is never
    /// mounted), and — for `.nasOnly` — copies every catalog file to its
    /// mirror path on the NAS stand-in, which is a folder in the temp
    /// library. `.nothingMounted` also moves the NAS off to an unmounted
    /// volume, so only the catalog remains.
    func apply(_ mode: LibraryMode, populateNAS: Bool = true) throws {
        switch mode {
        case .bufferPlugged:
            return
        case .nasOnly, .nothingMounted:
            let volume = "/Volumes/CTAbsent-\(UUID().uuidString.prefix(8))"
            let nasMounted = mode == .nasOnly
            // Build the NAS mirror where the library keeps it now, then move it.
            if nasMounted, populateNAS {
                try populateNASMirror()
            }
            model.updateConfiguration { configuration in
                // The selected Buffer / Photo Library locations decide these
                // paths, so they are moved along with the plain settings.
                let buffer = "\(volume)/Camera Buffer"
                configuration.bufferPath = buffer
                for index in configuration.configuredLocations.indices where configuration.configuredLocations[index].role == .buffer {
                    configuration.configuredLocations[index].path = buffer
                }
                if !nasMounted {
                    let library = "/Volumes/CTAbsentNAS-\(UUID().uuidString.prefix(8))/Library"
                    configuration.cameraLibraryRootPath = library
                    configuration.archiveLayoutRootPath = ""
                    configuration.archivePath = library + "/Originals"
                    for index in configuration.configuredLocations.indices where configuration.configuredLocations[index].role == .archive {
                        configuration.configuredLocations[index].path = library + "/Originals"
                    }
                }
            }
            XCTAssertFalse(VolumeInfo.isAvailable(workspace.locations.bufferRoot), "the Buffer must be unmounted")
            XCTAssertEqual(nasMounted, VolumeInfo.isAvailable(workspace.locations.nasRoot), "the NAS mount state is wrong")
        }
    }

    /// One 1-byte file per catalog assignment at its NAS mirror path.
    func populateNASMirror() throws {
        let locations = workspace.locations
        let fileManager = FileManager.default
        for assignment in model.configuration.photoEventAssignments {
            guard let event = model.configuration.savedEvents.first(where: { $0.id == assignment.eventID }) else { continue }
            let mirror = try locations.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath)
            let url = locations.nasRoot.appendingPathComponent(mirror)
            if fileManager.fileExists(atPath: url.path) { continue }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x78]).write(to: url)
            try fileManager.setAttributes([.modificationDate: assignment.modifiedAt], ofItemAtPath: url.path)
        }
    }
}

/// Runs `body` once per mode against a fresh library, tearing each down.
@MainActor
func eachLibrary(
    _ shape: MoveLibrary.Shape,
    modes: [LibraryMode] = [.bufferPlugged, .nasOnly],
    populateNAS: Bool = true,
    _ body: @MainActor (MoveLibrary, LibraryMode) async throws -> Void
) async throws {
    for mode in modes {
        let library = try MoveLibrary.make(shape)
        defer { library.tearDown() }
        try library.apply(mode, populateNAS: populateNAS)
        // A window reloads the configuration file when it looks changed;
        // without this file the library's events would vanish from under it.
        try library.model.configurationStore.save(library.model.configuration)
        do {
            try await body(library, mode)
        } catch {
            XCTFail("[\(mode.rawValue)] \(error)")
            throw error
        }
    }
}
