import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A move only renames files on the drives. What is not on the NAS is
/// recounted from the drive plan and Sync to NAS's records — the NAS is not
/// listed again for it, because nothing on it changed.
@MainActor
final class NASPresenceBufferChangeTests: XCTestCase {
    func testABufferChangeRecountsButNeverListsTheNAS() {
        XCTAssertTrue(NASPresenceTrigger.bufferChanged.recountsWithoutListing)
        XCTAssertTrue(NASPresenceTrigger.bufferChanged.isAutomatic)
        typealias Request = NASPresenceModel.Request
        // A waiting board-open or mount check keeps its scope; a stronger
        // trigger still wins the merge.
        XCTAssertEqual(Request(trigger: .bufferChanged, scope: nil).merged(with: Request(trigger: .boardOpened, scope: nil)).trigger, .bufferChanged)
        XCTAssertEqual(Request(trigger: .bufferChanged, scope: nil).merged(with: Request(trigger: .jobFinished, scope: nil)).trigger, .jobFinished)
        XCTAssertEqual(Request(trigger: .bufferChanged, scope: nil).merged(with: Request(trigger: .manual, scope: nil)).trigger, .manual)
    }

    private func makeContext() throws -> (NASPresenceContext, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-nas-buffer-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var configuration = AppConfiguration.defaults(applicationSupport: root)
        configuration.bufferPath = root.appendingPathComponent("Buffer").path
        configuration.cameraLibraryRootPath = library.path
        configuration.savedEvents = [SavedCameraEvent(name: "Trip", eventDate: Date(), storagePolicy: .buffer)]
        let locations = EventStorageLocations(configuration: configuration)
        try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
        let context = NASPresenceContext(
            events: configuration.savedEvents,
            locations: locations,
            catalogURL: root.appendingPathComponent("catalog.sqlite"),
            configuration: configuration,
            nasAvailable: true,
            nasJobRunning: false
        )
        return (context, { try? FileManager.default.removeItem(at: root) })
    }

    private func settle(_ model: NASPresenceModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isChecking || model.report == nil {
            guard Date() < deadline else { return XCTFail("The check never finished") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testABufferChangeCheckDoesNotListWhereAFinishedOtherJobWould() async throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }

        let recount = NASPresenceModel()
        recount.isEnabled = true
        recount.context = { context }
        recount.refresh(.bufferChanged)
        try await settle(recount)
        XCTAssertNil(recount.report?.listedAt, "the NAS was not listed")
        XCTAssertNil(recount.listing)

        let listing = NASPresenceModel()
        listing.isEnabled = true
        listing.context = { context }
        listing.refresh(.jobFinished)
        try await settle(listing)
        XCTAssertNotNil(listing.listing, "any other finished job lists a NAS that was never listed")
    }

    func testAnOrganizeJobCountsAsABufferChange() async throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        let model = NASPresenceModel()
        model.isEnabled = true
        model.context = { context }
        model.jobFinished(.organize)
        try await settle(model)
        XCTAssertNil(model.report?.listedAt)
    }
}
