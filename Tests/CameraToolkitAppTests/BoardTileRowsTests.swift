import AppKit
import CameraToolkitCore
import Foundation
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// The tile board is a column of fixed-height rows of tiles. These pin the
/// numbers that keep it looking like the adaptive grid it replaced, and the
/// row splitting that keeps a removal from renaming every row after it.
final class BoardTileRowsTests: XCTestCase {
    private func stack(_ name: String, frames: Int = 1) -> OrganizeStack {
        let date = Date(timeIntervalSince1970: 1_772_000_000)
        return OrganizeStack(items: (0..<frames).map { index in
            OrganizeItem(
                primary: OrganizeFile(path: "/Card/DCIM/\(name)_\(index).JPG", size: 100, modifiedAt: date),
                kind: .photo,
                captureDate: date.addingTimeInterval(Double(index)),
                hasCameraDate: true
            )
        })
    }

    private func ids(_ rows: [BoardTileRow]) -> [String] { rows.map(\.id) }

    private func tileIDs(_ row: BoardTileRow) -> [String] {
        if case .tiles(let stacks) = row.content { return stacks.map(\.id) }
        return []
    }

    // MARK: Layout

    func testColumnsAndCellWidthFollowTheAdaptiveGridRule() {
        // 1000 wide, 16 pt around: 968 for tiles. Four 220 pt tiles and their
        // 12 pt gaps fit (4 × 232 - 12 = 916), five do not; each of the four
        // cells shares the room, (968 - 36) / 4.
        let layout = BoardTileLayout(width: 1_000, tileWidth: 220)
        XCTAssertEqual(layout.columns, 4)
        XCTAssertEqual(layout.cellWidth, 233, accuracy: 0.001)
    }

    func testCellsNeverGrowPastOnePointThreeTimesTheTile() {
        // One column in a very wide board: the cell stops at 1.3× the tile.
        let layout = BoardTileLayout(width: 240, tileWidth: 88 * 2)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertLessThanOrEqual(layout.cellWidth, 88 * 2 * BoardTileLayout.cellGrowth + 0.001)
        XCTAssertGreaterThanOrEqual(layout.cellWidth, 88 * 2)
    }

    func testABoardNarrowerThanOneTileStillHasOneColumn() {
        let layout = BoardTileLayout(width: 100, tileWidth: 300)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.cellWidth, 300, accuracy: 0.001)
    }

    func testColumnCountMatchesTheFormulaTheGridUsed() {
        for width in stride(from: 320.0, through: 2_400.0, by: 37.0) {
            for tile in [88.0, 150.0, 220.0, 330.0, 460.0] {
                let expected = max(1, Int((width - 32 + 12) / (tile + 12)))
                XCTAssertEqual(BoardTileLayout(width: width, tileWidth: tile).columns, expected, "width \(width), tile \(tile)")
            }
        }
    }

    /// A row is exactly as tall as a tile drawn at its natural height, so
    /// fixing the row's height changes nothing about the look.
    @MainActor
    func testRowHeightIsTheTilesOwnHeight() {
        for tileWidth in [120.0, 220.0, 301.0] {
            let single = stack("A")
            let burst = stack("B", frames: 4)
            for subject in [single, burst] {
                let view = StackTileView(
                    stack: subject, width: tileWidth, isSelected: false, isFocused: false, event: nil,
                    tag: nil, isMixed: false, isDimmed: false, badge: nil, editTags: subject.isBurst ? ["Edit"] : []
                )
                let host = NSHostingView(rootView: view.frame(width: tileWidth))
                host.frame = NSRect(x: 0, y: 0, width: tileWidth, height: 1_000)
                let natural = host.fittingSize.height
                let layout = BoardTileLayout(width: 2_000, tileWidth: tileWidth)
                XCTAssertEqual(layout.rowHeight, natural, accuracy: 0.51, "tile width \(tileWidth)")
            }
        }
    }

    // MARK: Rows

    func testRowsHoldColumnsTilesEachAndKeepEveryStackOnce() {
        let stacks = (0..<10).map { stack("S\($0)") }
        let rows = BoardTileRows.rows(sectionID: "day|1", stacks: stacks, columns: 4, expanded: [])
        XCTAssertEqual(rows.map { tileIDs($0).count }, [4, 4, 2])
        XCTAssertEqual(rows.flatMap(tileIDs), stacks.map(\.id))
        XCTAssertEqual(ids(rows), ["day|1#0", "day|1#1", "day|1#2"])
    }

    func testAnEmptySectionHasNoRows() {
        XCTAssertTrue(BoardTileRows.rows(sectionID: "x", stacks: [], columns: 3, expanded: []).isEmpty)
    }

    func testAnOpenBurstTakesItsOwnRowAndEndsTheLineBeforeIt() {
        let stacks = [stack("A"), stack("B"), stack("C", frames: 5), stack("D"), stack("E"), stack("F")]
        let open = stacks[2]
        let rows = BoardTileRows.rows(sectionID: "s", stacks: stacks, columns: 3, expanded: [open.id])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(tileIDs(rows[0]), [stacks[0].id, stacks[1].id])
        XCTAssertEqual(rows[1].content, .expansion(open))
        XCTAssertEqual(rows[1].id, "\(open.id)-expansion")
        XCTAssertEqual(tileIDs(rows[2]), [stacks[3].id, stacks[4].id, stacks[5].id])
    }

    func testAnExpandedSingleFrameIsStillATile() {
        // Only a burst opens in place.
        let single = stack("A")
        let rows = BoardTileRows.rows(sectionID: "s", stacks: [single], columns: 3, expanded: [single.id])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(tileIDs(rows[0]), [single.id])
    }

    func testRemovingAStackKeepsTheRowsBeforeItAndTheirIds() {
        let stacks = (0..<12).map { stack("S\($0)") }
        let before = BoardTileRows.rows(sectionID: "s", stacks: stacks, columns: 4, expanded: [])
        var fewer = stacks
        fewer.remove(at: 5)
        let after = BoardTileRows.rows(sectionID: "s", stacks: fewer, columns: 4, expanded: [])
        XCTAssertEqual(ids(before), ids(after), "rows are named by place, so the ids stay")
        XCTAssertEqual(after[0], before[0], "the row before the removal is unchanged")
        XCTAssertNotEqual(after[1], before[1])
    }

    func testRowIDContainingAStackFindsTileAndExpansionRows() {
        let stacks = [stack("A"), stack("B"), stack("C", frames: 3), stack("D")]
        let open = stacks[2]
        let section = OrganizeBoardSection(
            group: OrganizeBoardGroup(id: "g", title: "G", symbol: nil, stacks: stacks),
            isCollapsed: false
        )
        let plan = BoardTileRows.sections([section], columns: 2, expanded: [open.id])
        XCTAssertEqual(BoardTileRows.rowID(containing: stacks[1].id, in: plan), "g#0")
        XCTAssertEqual(BoardTileRows.rowID(containing: open.id, in: plan), "\(open.id)-expansion")
        XCTAssertEqual(BoardTileRows.rowID(containing: stacks[3].id, in: plan), "g#2")
        XCTAssertNil(BoardTileRows.rowID(containing: "missing", in: plan))
    }

    func testACollapsedSectionHasHeaderButNoRows() {
        let stacks = (0..<6).map { stack("S\($0)") }
        let section = OrganizeBoardSection(
            group: OrganizeBoardGroup(id: "g", title: "G", symbol: nil, stacks: stacks),
            isCollapsed: true
        )
        let plan = BoardTileRows.sections([section], columns: 3, expanded: [])
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan[0].rows.isEmpty)
    }

    // MARK: Adaptive bars

    func testABarKeepsTheWidestRenderingThatFits() {
        let naturals: [Double?] = [900, 700, 500]
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 0, tierCount: 3, available: 1_000, naturals: naturals), 0)
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 0, tierCount: 3, available: 900, naturals: naturals), 0, "exactly fitting fits")
    }

    func testABarStepsDownOneTierAtATimeUntilItFits() {
        var naturals: [Double?] = [900, nil, nil]
        var tier = AdaptiveBarChoice.tier(current: 0, tierCount: 3, available: 600, naturals: naturals)
        XCTAssertEqual(tier, 1)
        naturals[1] = 700
        tier = AdaptiveBarChoice.tier(current: tier, tierCount: 3, available: 600, naturals: naturals)
        XCTAssertEqual(tier, 2)
        naturals[2] = 500
        XCTAssertEqual(AdaptiveBarChoice.tier(current: tier, tierCount: 3, available: 600, naturals: naturals), 2)
        // The narrowest stays, even when it does not fit.
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 2, tierCount: 3, available: 100, naturals: naturals), 2)
    }

    func testABarStepsBackUpOnlyWhenTheWiderRenderingWasMeasuredToFit() {
        let naturals: [Double?] = [900, 700, 500]
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 2, tierCount: 3, available: 650, naturals: naturals), 2)
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 2, tierCount: 3, available: 700, naturals: naturals), 1)
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 1, tierCount: 3, available: 899, naturals: naturals), 1)
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 1, tierCount: 3, available: 900, naturals: naturals), 0)
        XCTAssertEqual(AdaptiveBarChoice.tier(current: 1, tierCount: 3, available: 800, naturals: [nil, 700, 500]), 1, "an unmeasured wider tier is not guessed at")
    }

    func testNoWidthFlipsABetweenTwoTiers() {
        // The same numbers drive both directions, so from any tier the choice
        // reaches a fixed point and stays there.
        let naturals: [Double?] = [900, 700, 500]
        for available in stride(from: 300.0, through: 1_200.0, by: 10.0) {
            var tier = 0
            for _ in 0..<6 { tier = AdaptiveBarChoice.tier(current: tier, tierCount: 3, available: available, naturals: naturals) }
            let settled = AdaptiveBarChoice.tier(current: tier, tierCount: 3, available: available, naturals: naturals)
            XCTAssertEqual(settled, tier, "available \(available)")
            var other = 2
            for _ in 0..<6 { other = AdaptiveBarChoice.tier(current: other, tierCount: 3, available: available, naturals: naturals) }
            XCTAssertEqual(other, tier, "available \(available): the tier does not depend on where it started")
        }
    }
}
