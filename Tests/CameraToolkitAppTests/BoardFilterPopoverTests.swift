import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Guards the fix for the 2026-09-24 crash: the filter popover used to be
/// attached inside each `ViewThatFits` candidate of the board's bottom bar.
/// A popover is a preference, and `ViewThatFits` forwards preferences only
/// from the candidate it picks during layout — so a candidate swap made the
/// open popover's presentation disappear and reappear inside the window's
/// layout pass until AppKit threw. The popover now hangs off one presenter
/// outside the `ViewThatFits`, anchored to whichever button is visible.
@MainActor
final class BoardFilterPopoverTests: XCTestCase {
    /// The mechanism the crash hinged on: which candidate's preferences
    /// (popover presentations included) reach the host is decided by
    /// layout, not by the view tree.
    func testViewThatFitsForwardsOnlyTheChosenCandidatesPreferences() async throws {
        let probe = CandidateProbe()
        let window = Self.window(width: 200, rootView: CandidateBar(probe: probe))
        defer { window.orderOut(nil) }

        try await settle { probe.seen == [0] }
        XCTAssertEqual(probe.seen, [0], "the narrow first candidate fits")

        probe.wide = true
        try await settle { probe.seen == [1] }
        XCTAssertEqual(probe.seen, [1], "once it overflows, only the fallback's preferences arrive")
    }

    /// The anchor the single presenter points at comes from whichever
    /// candidate is showing, so the popover never loses its anchor (or
    /// its presentation) when the bar swaps candidates.
    func testFilterButtonAnchorFollowsTheVisibleCandidate() async throws {
        let probe = AnchorProbe()
        let window = Self.window(width: 240, rootView: FilterBar(probe: probe))
        defer { window.orderOut(nil) }

        try await settle { probe.rect != nil }
        let wideRect = try XCTUnwrap(probe.rect)

        probe.wide = true
        try await settle { probe.rect != nil && probe.rect != wideRect }
        let narrowRect = try XCTUnwrap(probe.rect)
        XCTAssertNotEqual(wideRect, narrowRect, "the anchor moved to the fallback candidate's button")
        XCTAssertGreaterThan(narrowRect.width, 0)
        XCTAssertFalse(probe.isPresented, "a candidate swap does not toggle the presentation")
    }

    // MARK: - Harness

    private static func window(width: CGFloat, rootView: some View) -> NSWindow {
        let window = OffscreenWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        window.contentView = host
        SnapshotWindows.hide(window)
        window.orderFrontRegardless()
        return window
    }

    private func settle(timeout: Duration = .seconds(2), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct CandidateKey: PreferenceKey {
    static let defaultValue: [Int] = []
    static func reduce(value: inout [Int], nextValue: () -> [Int]) { value += nextValue() }
}

@Observable
@MainActor
private final class CandidateProbe {
    var seen: [Int] = []
    var wide = false
}

private struct CandidateBar: View {
    let probe: CandidateProbe

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(probe.wide ? String(repeating: "wide ", count: 20) : "narrow")
                .fixedSize()
                .preference(key: CandidateKey.self, value: [0])
            Text("fallback")
                .fixedSize()
                .preference(key: CandidateKey.self, value: [1])
        }
        .onPreferenceChange(CandidateKey.self) { value in
            MainActor.assumeIsolated { probe.seen = value }
        }
    }
}

@Observable
@MainActor
private final class AnchorProbe {
    var rect: CGRect?
    var wide = false
    var isPresented = false
}

private struct FilterBar: View {
    let probe: AnchorProbe

    var body: some View {
        let presented = Binding(get: { probe.isPresented }, set: { probe.isPresented = $0 })
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(probe.wide ? String(repeating: "wide ", count: 20) : "Sort").fixedSize()
                OrganizeFilterButton(isPresented: presented, search: OrganizeSearchFilter())
            }
            HStack {
                OrganizeFilterButton(isPresented: presented, search: OrganizeSearchFilter())
            }
        }
        .overlayPreferenceValue(BoardFilterAnchorKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.task(id: anchor.map { proxy[$0] }) {
                    probe.rect = anchor.map { proxy[$0] }
                }
            }
        }
    }
}
