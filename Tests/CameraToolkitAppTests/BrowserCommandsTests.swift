import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class BrowserCommandsTests: XCTestCase {
    func testShortcutCatalogCoversFinderNavigationPreviewAndSafety() {
        let shortcuts = CameraToolkitShortcutCatalog.sections.flatMap(\.shortcuts)
        let actions = Set(shortcuts.map(\.action))

        XCTAssertTrue(actions.contains("Previous or next item"))
        XCTAssertTrue(actions.contains("Copy selected files"))
        XCTAssertTrue(actions.contains("Rename selected item"))
        XCTAssertTrue(actions.contains("Delete an empty folder"))
        XCTAssertTrue(actions.contains("Select across folders"))
        XCTAssertTrue(actions.contains("Larger or smaller thumbnails"))
        XCTAssertTrue(actions.contains("Previous or next camera"))
        XCTAssertTrue(actions.contains("Zoom to fit"))
        XCTAssertTrue(actions.contains("Open in Photomator"))
        XCTAssertTrue(actions.contains("Move, paste, or delete files"))
    }

    func testThumbnailSizingStepsThroughPresetsAndClampsAtEnds() {
        XCTAssertEqual(BrowserThumbnailSizing.larger(than: 32), 44)
        XCTAssertEqual(BrowserThumbnailSizing.smaller(than: 32), 24)
        XCTAssertEqual(BrowserThumbnailSizing.larger(than: 104), 104)
        XCTAssertEqual(BrowserThumbnailSizing.smaller(than: 24), 24)
    }

    func testThumbnailSizingUsesDisplayScaleForDecodeBudget() {
        XCTAssertEqual(BrowserThumbnailSizing.width(for: 60), 80)
        XCTAssertEqual(BrowserThumbnailSizing.maximumPixelSize(for: 32), 128)
        XCTAssertEqual(BrowserThumbnailSizing.maximumPixelSize(for: 104), 208)
    }

    func testThumbnailShortcutsAcceptBothPhysicalEqualsAndShiftedPlus() {
        XCTAssertEqual(
            BrowserThumbnailShortcut.command(for: "=", modifierFlags: [.command]),
            .increaseThumbnailSize
        )
        XCTAssertEqual(
            BrowserThumbnailShortcut.command(for: "+", modifierFlags: [.command, .shift]),
            .increaseThumbnailSize
        )
        XCTAssertEqual(
            BrowserThumbnailShortcut.command(for: "-", modifierFlags: [.command]),
            .decreaseThumbnailSize
        )
    }

    func testThumbnailShortcutsIgnoreUnmodifiedAndConflictingChords() {
        XCTAssertNil(BrowserThumbnailShortcut.command(for: "=", modifierFlags: []))
        XCTAssertNil(BrowserThumbnailShortcut.command(for: "=", modifierFlags: [.command, .option]))
        XCTAssertNil(BrowserThumbnailShortcut.command(for: "-", modifierFlags: [.control]))
    }

    func testFileClipboardWriterCreatesFinderCompatibleFileReferences() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CameraToolkitTests-\(UUID().uuidString)"))
        let first = URL(fileURLWithPath: "/tmp/CameraToolkit/ONE.ARW")
        let second = URL(fileURLWithPath: "/tmp/CameraToolkit/TWO.ARW")

        XCTAssertTrue(FileClipboardWriter.copy([first, second], to: pasteboard))

        let copiedURLs = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        )
        XCTAssertEqual(copiedURLs.map(\.standardizedFileURL), [first.standardizedFileURL, second.standardizedFileURL])
        pasteboard.clearContents()
    }

    func testEventMediaSupportIncludesDJIOsmo360Files() {
        XCTAssertTrue(EventMediaSupport.canAssign(URL(fileURLWithPath: "/camera/CAM_0001.OSV")))
        XCTAssertTrue(EventMediaSupport.canAssign(URL(fileURLWithPath: "/camera/CAM_0001.LRF")))
        XCTAssertFalse(EventMediaSupport.canAssign(URL(fileURLWithPath: "/camera/README.TXT")))
    }

    func testDJIVideoFilesNeverEnterAutomaticImagePreviewPipeline() {
        XCTAssertFalse(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/camera/17-gigabyte.OSV")))
        XCTAssertFalse(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/camera/proxy.LRF")))
    }

    func testBrowserItemNamesAcceptFinderStyleNamesAndRejectUnsafeComponents() {
        XCTAssertEqual(BrowserItemNamePolicy.normalizedName("  Event Photos  "), "Event Photos")
        XCTAssertEqual(BrowserItemNamePolicy.normalizedName("UCSC Library w Eileen"), "UCSC Library w Eileen")
        XCTAssertNil(BrowserItemNamePolicy.normalizedName(""))
        XCTAssertNil(BrowserItemNamePolicy.normalizedName(".."))
        XCTAssertNil(BrowserItemNamePolicy.normalizedName("folder/name"))
        XCTAssertNil(BrowserItemNamePolicy.normalizedName("folder:name"))
    }
}
