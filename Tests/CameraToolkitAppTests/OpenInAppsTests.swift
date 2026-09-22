@testable import CameraToolkitApp
import XCTest

final class OpenInAppsTests: XCTestCase {
    /// Stands in for the installed-app lookup: names in `installed` report a
    /// bundle URL, everything else reads as not installed. Nothing is
    /// launched — the tests only check which rows the menu would offer.
    private struct StubLookup: ApplicationLookup {
        let installed: Set<String>

        func applicationURL(named name: String) -> URL? {
            installed.contains(name)
                ? URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
                : nil
        }
    }

    func testOfferedOrderIsGyroflowThenColorApps() {
        XCTAssertEqual(
            OpenInApp.offered.map(\.name),
            ["Gyroflow", "DaVinci Resolve", "Final Cut Pro", "Photomator"]
        )
    }

    func testMissingGyroflowLeavesItOutOfTheMenu() {
        let apps = OpenInApp.installedApps(
            lookup: StubLookup(installed: ["DaVinci Resolve", "Photomator"])
        )

        XCTAssertEqual(apps.map(\.name), ["DaVinci Resolve", "Photomator"])
        XCTAssertFalse(apps.contains(.gyroflow))
    }

    func testInstalledGyroflowIsOffered() {
        let apps = OpenInApp.installedApps(
            lookup: StubLookup(installed: Set(OpenInApp.offered.map(\.name)))
        )

        XCTAssertEqual(apps, OpenInApp.offered)
        XCTAssertEqual(apps.first, .gyroflow)
    }

    func testNothingInstalledOffersNoApps() {
        XCTAssertTrue(
            OpenInApp.installedApps(lookup: StubLookup(installed: [])).isEmpty
        )
    }

    /// The real lookup against a fixture tree: a bundle nested one folder
    /// deep (like the DaVinci Resolve folder) still counts as installed,
    /// while an unknown or too-deep name does not.
    func testLookupFindsNestedAppBundlesByName() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OpenInAppsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try fileManager.createDirectory(
            at: applications.appendingPathComponent("DaVinci Resolve/DaVinci Resolve.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applications.appendingPathComponent("Gyroflow.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applications.appendingPathComponent("a/b/c/Deep.app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let lookup = InstalledApplicationLookup(roots: [applications], ttl: 60)

        XCTAssertEqual(lookup.applicationURL(named: "Gyroflow")?.lastPathComponent, "Gyroflow.app")
        XCTAssertEqual(lookup.applicationURL(named: "DaVinci Resolve")?.lastPathComponent, "DaVinci Resolve.app")
        XCTAssertNil(lookup.applicationURL(named: "Final Cut Pro"))
        XCTAssertNil(lookup.applicationURL(named: "Deep"))
    }
}
