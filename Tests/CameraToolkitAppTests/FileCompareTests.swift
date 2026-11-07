import AppKit
@testable import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// The Compare sheet's pieces: pictures decoded from each side's own file,
/// the pixel check for copies that should match, Photomator working copies
/// that never sit beside the originals — and, with `CT_SNAPSHOT_OUT` set,
/// the sheet itself in light and dark. Every file is synthetic.
@MainActor
final class FileCompareTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileCompare-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A small PNG, solid `color` with a square of `mark`.
    static func png(_ color: NSColor, mark: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            color.setFill(); rect.fill()
            mark.setFill(); NSRect(x: 40, y: 20, width: 30, height: 30).fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func write(_ data: Data, _ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }

    func testIdenticalCopiesDifferInNoPixel() throws {
        let data = try Self.png(.systemTeal, mark: .white)
        let drive = try write(data, "Buffer/2026/Beach Day/Originals/DSC00001.png")
        let nas = try write(data, "nas_share/2026/Beach Day/Originals/DSC00001.png")
        let load = CompareLoad.read(ConflictPair(drivePath: drive, nasRoot: root.appendingPathComponent("nas_share").path, relativePath: "2026/Beach Day/Originals/DSC00001.png"), wantsDifference: true)
        XCTAssertTrue(load.comparison.identical)
        XCTAssertNotNil(load.driveImage)
        XCTAssertNotNil(load.nasImage)
        XCTAssertEqual(load.comparison.nas.path, nas, "the NAS side is read from its own path")
        XCTAssertEqual(load.differenceNote, "The two pictures differ in no pixel — the difference image is black.")
    }

    func testDifferentPicturesShowTheirDifference() throws {
        let drive = try write(Self.png(.systemTeal, mark: .white), "Buffer/a/DSC00002.png")
        _ = try write(Self.png(.systemTeal, mark: .black), "nas_share/a/DSC00002.png")
        let load = CompareLoad.read(ConflictPair(drivePath: drive, nasRoot: root.appendingPathComponent("nas_share").path, relativePath: "a/DSC00002.png"), wantsDifference: true)
        XCTAssertFalse(load.comparison.identical)
        XCTAssertTrue(load.differenceNote?.hasPrefix("The pictures differ by up to") ?? false, load.differenceNote ?? "")
    }

    func testAWorkingCopyPairsTheRAWAndLeavesTheOriginalsAlone() throws {
        let raw = try write(Data("raw bytes".utf8), "Buffer/a/DSC00177.ARW")
        let edit = try write(Data("edit bytes".utf8), "Buffer/a/DSC00177.photo-edit")
        let before = try FileManager.default.contentsOfDirectory(atPath: (raw as NSString).deletingLastPathComponent).sorted()
        let working = try CompareWorkingCopy.make(editPath: edit, label: "drive", under: root.appendingPathComponent("Caches"))
        XCTAssertTrue(working.folder.path.hasPrefix(root.appendingPathComponent("Caches").path), "working copies live under the caches, not beside the originals")
        XCTAssertEqual(working.raw?.lastPathComponent, "DSC00177.ARW")
        XCTAssertEqual(working.edit.lastPathComponent, "DSC00177.photo-edit")
        XCTAssertEqual(try Data(contentsOf: working.edit), Data("edit bytes".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: (raw as NSString).deletingLastPathComponent).sorted(), before)
    }

    func testTheSummarySaysWhichIsNewerAndLarger() {
        let comparison = FileComparison(
            drive: ComparedFile(path: "/d", exists: true, size: 231_244, modified: Date(timeIntervalSince1970: 1_790_000_000), sha256: "a"),
            nas: ComparedFile(path: "/n", exists: true, size: 231_368, modified: Date(timeIntervalSince1970: 1_788_000_000), sha256: "b")
        )
        XCTAssertEqual(FileCompareSheet.differenceSummary(comparison), "The copies differ — the drive copy is 124 bytes smaller — the drive version was saved later.")
    }

    // MARK: Snapshots

    func testRenderCompareSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = DashboardModel(jobs: [], configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")))

        let drive = try write(Self.png(.systemOrange, mark: .white), "Buffer/2026/Trip 2026/Originals/DSC00177.png")
        _ = try write(Self.png(.systemOrange, mark: .white), "nas_share/2026/Trip 2026/Originals/DSC00177.png")
        let identicalPair = ConflictPair(drivePath: drive, nasRoot: root.appendingPathComponent("nas_share").path, relativePath: "2026/Trip 2026/Originals/DSC00177.png")
        let identical = CompareLoad.read(identicalPair, wantsDifference: true)

        var conflict = CompareLoad.read(identicalPair, wantsDifference: false)
        conflict.nasImage = CompareImage.decode(try write(Self.png(.systemOrange, mark: .black), "older.png"))
        conflict.comparison.drive.path = "/Volumes/Buffer/2026/Trip 2026/Originals/DSC00177.photo-edit"
        conflict.comparison.nas.path = "/Volumes/nas_share/2026/Trip 2026/Originals/DSC00177.photo-edit"
        conflict.comparison.drive.size = 231_244
        conflict.comparison.nas.size = 231_368
        conflict.comparison.drive.modified = Date(timeIntervalSince1970: 1_790_000_000)
        conflict.comparison.nas.modified = Date(timeIntervalSince1970: 1_788_000_000)
        conflict.comparison.nas.sha256 = String(repeating: "b", count: 64)
        conflict.comparison.settingDifferences = [
            PhotoEditDifference(key: "document_info.content-writer", drive: "Device A", nas: "Device B"),
            PhotoEditDifference(key: "layer_info.color-adjustments.exposure", drive: "0.35", nas: "0.1"),
            PhotoEditDifference(key: "layer_info.raw-parameters-data", drive: "4,096 bytes · 3fa1c2d9e011", nas: "4,096 bytes · 77b0a51c2e9d"),
        ]

        let cases: [(String, CompareRequest, CompareLoad)] = [
            ("compare-conflict", CompareRequest(pair: identicalPair, mode: .conflict, fileName: "DSC00177.photo-edit"), conflict),
            ("compare-identical", CompareRequest(pair: identicalPair, mode: .viewOnly, fileName: "DSC00177.png"), identical),
        ]
        for (name, request, load) in cases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: FileCompareSheet(model: model, request: request, preloaded: load).background(.background))
                host.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 860, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 860, height: 760)
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                window.orderOut(nil)
            }
        }
    }
}
