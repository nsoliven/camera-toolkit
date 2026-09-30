import AppKit
import CameraToolkitCore
import SwiftUI

/// How the tile board lays its tiles out, worked out from the board's width
/// and the tile size. The board is a column of fixed-height rows of tiles
/// (`BoardTileRows`), not a grid: SwiftUI's lazy grids pay a layout cost per
/// element that grows with how deep the board is scrolled, which a fixed
/// row height and a flat list of rows do not.
///
/// The numbers follow what the adaptive `LazyVGrid` this replaced drew: as
/// many columns as fit at the tile width plus 12 pt of spacing, each cell
/// stretched up to 1.3× the tile width to share the row, the tile centered
/// in its cell, 16 pt around the board and 14 pt between rows.
struct BoardTileLayout: Equatable {
    static let padding: CGFloat = 16
    static let columnSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 14
    /// How far a cell may grow past the tile width.
    static let cellGrowth: CGFloat = 1.3
    /// Gap between the photo and its caption line.
    static let captionSpacing: CGFloat = 5

    let tileWidth: CGFloat
    let columns: Int
    /// The width of one cell; a tile is centered in it.
    let cellWidth: CGFloat

    /// `width` is the board's full width, padding included.
    init(width: CGFloat, tileWidth: CGFloat) {
        self.tileWidth = tileWidth
        let available = max(width - 2 * Self.padding, tileWidth)
        let count = max(1, Int((available + Self.columnSpacing) / (tileWidth + Self.columnSpacing)))
        columns = count
        let stretched = (available - Self.columnSpacing * CGFloat(count - 1)) / CGFloat(count)
        cellWidth = max(tileWidth, min(stretched, tileWidth * Self.cellGrowth))
    }

    /// The height of one tile: the 3:2 photo, the gap, and the caption line.
    /// Every row is exactly this tall, so the lazy stack never has to measure
    /// a row to know where the next one starts.
    var rowHeight: CGFloat {
        tileWidth * 2 / 3 + Self.captionSpacing + Self.captionHeight
    }

    /// The caption line's height: one line of the `.caption` text style.
    static let captionHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil(font.ascender - font.descender + font.leading)
    }()
}

/// One line of the tile board: a run of tiles, or a burst opened in place
/// (which takes a whole line, as it did in the grid).
struct BoardTileRow: Identifiable, Equatable {
    enum Content: Equatable {
        case tiles([OrganizeStack])
        case expansion(OrganizeStack)
    }

    let id: String
    let content: Content
}

/// A section's rows, with the section they belong to.
struct BoardTileSection: Identifiable {
    let section: OrganizeBoardSection
    let rows: [BoardTileRow]
    var id: String { section.id }
}

enum BoardTileRows {
    /// Splits a section's stacks into rows of `columns` tiles. A burst that
    /// is `expanded` ends the line before it and takes its own.
    ///
    /// Tile rows are named by their place in the section, so removing a
    /// stack keeps the rows that stay put — only the rows from there on take
    /// new tiles — and an open burst is named by its stack.
    static func rows(sectionID: String, stacks: [OrganizeStack], columns: Int, expanded: Set<String>) -> [BoardTileRow] {
        let perRow = max(columns, 1)
        var rows: [BoardTileRow] = []
        rows.reserveCapacity(stacks.count / perRow + 1)
        var line: [OrganizeStack] = []
        line.reserveCapacity(perRow)
        func flush() {
            guard !line.isEmpty else { return }
            rows.append(BoardTileRow(id: "\(sectionID)#\(rows.count)", content: .tiles(line)))
            line.removeAll(keepingCapacity: true)
        }
        for stack in stacks {
            if stack.isBurst, expanded.contains(stack.id) {
                flush()
                rows.append(BoardTileRow(id: "\(stack.id)-expansion", content: .expansion(stack)))
                continue
            }
            line.append(stack)
            if line.count == perRow { flush() }
        }
        flush()
        return rows
    }

    static func sections(
        _ sections: [OrganizeBoardSection],
        columns: Int,
        expanded: Set<String>
    ) -> [BoardTileSection] {
        sections.map {
            BoardTileSection(
                section: $0,
                rows: rows(sectionID: $0.id, stacks: $0.visibleStacks, columns: columns, expanded: expanded)
            )
        }
    }

    /// The id of the row a stack is drawn in — what the board scrolls to.
    static func rowID(containing stackID: String, in sections: [BoardTileSection]) -> String? {
        for section in sections {
            for row in section.rows {
                switch row.content {
                case .tiles(let stacks) where stacks.contains(where: { $0.id == stackID }):
                    return row.id
                case .expansion(let stack) where stack.id == stackID:
                    return row.id
                default:
                    continue
                }
            }
        }
        return nil
    }
}

/// A view whose body only calls `content`. Views a lazy stack builds from a
/// closure in the board's own body are evaluated with the board: every
/// change any tile reads (a selection, an edit tag, a badge) re-ran the
/// whole board's closures. Built through this, what a row's tiles read is
/// read while the row's own body runs, so a change re-runs the rows on
/// screen and nothing else.
struct ScopedBody<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// The board's stacks in the order they are drawn, kept where clicks can
/// read the current order without the tiles being rebuilt when it changes.
@MainActor
final class BoardOrder {
    var ids: [String] = []
}
