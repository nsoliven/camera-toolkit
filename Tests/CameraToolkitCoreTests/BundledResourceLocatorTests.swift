@testable import CameraToolkitCore
import Foundation
import XCTest

/// Where the face sidecar script is found. Each test builds a throwaway
/// `.app` layout in a temp folder; nothing outside it is read.
final class BundledResourceLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledResourceLocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var app: URL { root.appendingPathComponent("Fake.app", isDirectory: true) }
    private var resources: URL { app.appendingPathComponent("Contents/Resources", isDirectory: true) }
    private var moduleDir: URL { root.appendingPathComponent("build/\(BundledResourceLocator.coreBundleName)", isDirectory: true) }

    @discardableResult
    private func placeScript(in base: URL) throws -> URL {
        let bundle = base.lastPathComponent == BundledResourceLocator.coreBundleName
            ? base : base.appendingPathComponent(BundledResourceLocator.coreBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let script = bundle.appendingPathComponent(CoreResources.faceSidecarScriptName)
        try Data("print('stub')\n".utf8).write(to: script)
        return script
    }

    private func locator(module: @escaping @Sendable () -> Bundle?) -> BundledResourceLocator {
        BundledResourceLocator(resourceURL: resources, bundleURL: app, moduleBundle: module)
    }

    func testPackagedLocationWinsOverAppRootAndModule() throws {
        let packaged = try placeScript(in: resources)
        try placeScript(in: app)
        try placeScript(in: moduleDir)
        let moduleDir = moduleDir
        let asked = Counter()
        let result = locator { asked.bump(); return Bundle(url: moduleDir) }.locate(CoreResources.faceSidecarScriptName)
        XCTAssertEqual(result.location, .packaged)
        XCTAssertEqual(result.url?.standardizedFileURL, packaged.standardizedFileURL)
        XCTAssertEqual(asked.value, 0, "Bundle.module must not be touched when the app has its own copy")
    }

    func testFallsBackToBundleURL() throws {
        let appRoot = try placeScript(in: app)
        let asked = Counter()
        let result = locator { asked.bump(); return nil }.locate(CoreResources.faceSidecarScriptName)
        XCTAssertEqual(result.location, .appRoot)
        XCTAssertEqual(result.url?.standardizedFileURL, appRoot.standardizedFileURL)
        XCTAssertEqual(asked.value, 0)
    }

    func testModuleFallbackComesLast() throws {
        let script = try placeScript(in: moduleDir)
        let moduleDir = moduleDir
        let asked = Counter()
        let result = locator { asked.bump(); return Bundle(url: moduleDir) }.locate(CoreResources.faceSidecarScriptName)
        XCTAssertEqual(result.location, .module)
        XCTAssertEqual(result.url?.resolvingSymlinksInPath(), script.resolvingSymlinksInPath())
        XCTAssertEqual(asked.value, 1)
    }

    func testNothingFoundReturnsNil() throws {
        // An empty resource bundle directory is not the script.
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent(BundledResourceLocator.coreBundleName),
            withIntermediateDirectories: true
        )
        let empty = root.appendingPathComponent("empty-module", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = locator { Bundle(url: empty) }.locate(CoreResources.faceSidecarScriptName)
        XCTAssertEqual(result, .init(url: nil, location: .missing))
        XCTAssertEqual(locator { nil }.locate(CoreResources.faceSidecarScriptName).location, .missing)
    }

    func testMainLocatorResolvesInThisTestProcess() {
        // SwiftPM test runs are not inside a .app, so the module fallback is
        // allowed and the script must resolve somewhere.
        XCTAssertNotNil(BundledResourceLocator.main.locate(CoreResources.faceSidecarScriptName).url)
    }

    func testIsInstalledIsFalseWhenScriptIsMissing() throws {
        let installation = FaceSidecarInstallation(root: root.appendingPathComponent("face-sidecar", isDirectory: true))
        try FileManager.default.createDirectory(at: installation.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: installation.pythonURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.pythonURL.path)
        try FileManager.default.createDirectory(at: installation.packURL, withIntermediateDirectories: true)
        try Data().write(to: installation.packURL.appendingPathComponent("w600k_r50.onnx"))

        let script = try placeScript(in: resources)
        XCTAssertTrue(installation.isInstalled(scriptURL: script))
        XCTAssertFalse(installation.isInstalled(scriptURL: nil))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
