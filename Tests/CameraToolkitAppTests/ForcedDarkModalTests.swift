import Foundation
import XCTest

/// The viewer's glass (grade card, frame inspector, header controls,
/// bottom bar, zoom HUD, 360 banner) forces `.environment(\.colorScheme,
/// .dark)` and white text. A sheet, popover, alert, dialog or file
/// importer attached inside that subtree inherits both, while its window
/// follows the system appearance, so in Light mode it draws white on white
/// (Preview 3 s did exactly that). Modals belong on the board instead.
/// This is a source check: SwiftUI gives no way to read a view's modals.
final class ForcedDarkModalTests: XCTestCase {
    /// Views drawn only inside a forced-dark container.
    private static let forcedDarkViews: [(file: String, declaration: String)] = [
        ("Grading/GradePanelViews.swift", "struct GradePanel: View"),
        ("Grading/GradePanelViews.swift", "struct GradeLookStrip: View"),
        ("Stabilization/StabilizeViews.swift", "struct StabilizePanel: View"),
        ("Preview/FaceOverlayViews.swift", "struct FrameInspectorPanel: View"),
        ("Preview/InteractivePreviewCanvas.swift", "struct PreviewZoomControls: View"),
        ("Preview/DJI360Preview.swift", "struct DJI360PreviewBanner: View"),
        ("Events/OrganizeTiles.swift", "private func headerActions("),
        ("Events/OrganizeTiles.swift", "private func headerTitle("),
        ("Events/OrganizeTiles.swift", "private func bottomBar("),
    ]

    private static let modalModifiers = [
        ".sheet(", ".popover(", ".alert(", ".confirmationDialog(", ".fileImporter(", ".fileExporter(",
        "eventPickerSheet(", "blanketGradeSheet(", "StabilizeSheetHost(",
    ]

    func testNoModalIsAttachedInsideForcedDarkGlass() throws {
        for (file, declaration) in Self.forcedDarkViews {
            let source = try String(contentsOf: Self.sourceRoot.appendingPathComponent(file), encoding: .utf8)
            let body = try XCTUnwrap(Self.declarationBody(declaration, in: source), "\(declaration) not found in \(file)")
            for modifier in Self.modalModifiers {
                XCTAssertFalse(body.contains(modifier), "\(declaration) in \(file) attaches \(modifier) under forced-dark glass; present it from the board")
            }
        }
    }

    /// The Stabilize preview and "Stabilize all clips" sheets hang off the
    /// board host, outside the viewer.
    func testStabilizeSheetsArePresentedFromTheBoardHost() throws {
        let source = try String(contentsOf: Self.sourceRoot.appendingPathComponent("Stabilization/StabilizeViews.swift"), encoding: .utf8)
        let host = try XCTUnwrap(Self.declarationBody("struct StabilizeSheetHost: ViewModifier", in: source))
        XCTAssertTrue(host.contains("StabilizePreviewSheet("))
        XCTAssertTrue(host.contains("StabilizeAllSheet("))
        let blanket = try String(contentsOf: Self.sourceRoot.appendingPathComponent("Grading/BlanketGradeSheet.swift"), encoding: .utf8)
        XCTAssertTrue(blanket.contains(".modifier(StabilizeSheetHost(workspace: workspace))"))
    }

    func testDeclarationBodyMatchesBraces() {
        let source = "struct A: View {\n  var body: some View { Text(\"x\") }\n}\nstruct B: View { .sheet( }"
        XCTAssertEqual(Self.declarationBody("struct A: View", in: source), "{\n  var body: some View { Text(\"x\") }\n}")
        XCTAssertNil(Self.declarationBody("struct C: View", in: source))
    }

    /// The text from the declaration's first `{` to its matching `}`.
    static func declarationBody(_ declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CameraToolkitApp")
}
