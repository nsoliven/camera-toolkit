import AppKit
@testable import CameraToolkitApp
import CameraToolkitCore
import SwiftUI
import XCTest

/// The grade panel drawn at its real size in its real card: every row must
/// sit inside the card's inset at any window height, with long names and
/// narrower than the card (what larger system text amounts to). A row wider
/// than the card used to centre the whole column on itself, so labels
/// started left of the glass and values were cut off on the right.
///
/// `CT_GRADE_PANEL_OUT=/path` also writes each case as a PNG.
@MainActor
final class GradePanelLayoutTests: XCTestCase {
    func testContentStaysInsideTheCard() throws {
        let card = GradePanel.cardWidth
        let cases: [(name: String, width: CGFloat, height: CGFloat, long: Bool, mode: GradeViewMode)] = [
            ("regular", card, 900, false, .split),
            ("short-window", card, 460, false, .before),
            ("long-names", card, 900, true, .before),
            // Squeezed well below the card: every row must still shrink.
            ("narrow-250", 250, 900, true, .before),
            ("narrow-230", 230, 900, true, .split),
        ]
        for testCase in cases {
            let session = Self.session(longNames: testCase.long)
            session.viewMode = testCase.mode
            var content = CGRect.zero
            let panel = GradePanel(
                session: session, canPaste: true,
                onCopy: {}, onPaste: {}, onRemove: {}, onMarkProfile: { _ in }, onRender: {},
                renderNote: "Writes C0001_Rec709.MP4 into the event’s Edited/Rec709. A copy made earlier with another grade is kept, and this one is saved beside it as “(2)”. The original is never changed."
            )
            .onPreferenceChange(GradePanelContentFrameKey.self) { content = $0 }
            let size = CGSize(width: testCase.width, height: testCase.height)
            if testCase.width == card {
                try draw(ZStack { Color.black; panel.gradeInspectorCard() }, size: size, name: "panel-\(testCase.name)")
            } else {
                try draw(ZStack { Color.black; panel.frame(width: testCase.width).environment(\.colorScheme, .dark) }, size: size, name: "panel-\(testCase.name)")
            }

            XCTAssertGreaterThan(content.width, 100, "\(testCase.name): content measured")
            XCTAssertGreaterThanOrEqual(content.minX, GradePanel.contentInset - 0.5, "\(testCase.name): content starts inside the card (\(content))")
            XCTAssertLessThanOrEqual(content.maxX, testCase.width - GradePanel.contentInset + 0.5, "\(testCase.name): content ends inside the card (\(content))")
        }
    }

    func testWipeLineSitsAtTheCompositionsSplitInTheWholePane() {
        // A 16:9 clip in a pane taller than the picture: the line is where
        // the composition splits the frame, measured in the whole pane —
        // never in a pane shortened by the controls strip.
        let pane = CGSize(width: 1_000, height: 600)
        let picture = GradeWipeOverlay.fittedRect(content: CGSize(width: 3_840, height: 2_160), in: pane)
        XCTAssertEqual(picture.width, 1_000, accuracy: 0.5)
        XCTAssertEqual(GradeWipeOverlay.lineX(wipe: 0.5, picture: picture), 500, accuracy: 0.5)
        XCTAssertEqual(GradeWipeOverlay.lineX(wipe: 0.25, picture: picture), 250, accuracy: 0.5)
        XCTAssertEqual(GradeWipeOverlay.lineX(wipe: 2, picture: picture), 1_000, accuracy: 0.5)
    }

    // MARK: Helpers

    static func session(longNames: Bool) -> GradeSession {
        let looks: [GradeLook] = [.none] + BuiltInLook.allCases.map { .builtIn($0) }
        let session = GradeSession(
            itemID: "C0001", clipName: "C0001.MP4",
            grade: ClipGrade(look: .builtIn(.softFilm), intensity: BuiltInLook.softFilm.defaultIntensity),
            profile: .sLog3SGamut3Cine, detectedProfile: .sLog3SGamut3Cine, range: .video,
            looks: looks,
            lookName: { look in
                switch look {
                case .none: "No Look"
                case .builtIn(let builtIn): longNames ? "\(builtIn.displayName) with a very long imported name" : builtIn.displayName
                case .lut: "LUT"
                }
            },
            conversionChoices: [.auto, .builtIn, .off],
            conversionName: { _ in "Built-in (Sony math)" },
            conversionTitle: { _ in
                longNames
                    ? "Sony S-Log3 → Rec.709 · Imported Conversion LUT With An Unusually Long File Name v2"
                    : "Sony S-Log3 → Rec.709 · Built-in (Sony math)"
            }
        )
        return session
    }

    private func draw<V: View>(_ view: V, size: CGSize, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            host.display()
        }
        defer { window.contentView = nil }
        guard let out = ProcessInfo.processInfo.environment["CT_GRADE_PANEL_OUT"] else { return }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }
}
