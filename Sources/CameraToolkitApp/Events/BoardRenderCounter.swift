import Foundation

/// How many times the heavy board views built their content — the count
/// `HostedMoveResponsivenessTests` holds to a budget. One tap on Move to
/// Event used to redraw the open board seven times (eleven with a NAS), each
/// pass walking every tile of a 15,000-file family; each such redraw is one
/// hit here. Counting costs a dictionary increment on the main actor.
@MainActor
enum BoardRenderCounter {
    enum Kind: String, CaseIterable {
        /// `OrganizeGrid.body`: the board's tiles or rows.
        case grid
        /// One tile or row built by the grid (`OrganizeGrid.tile` / `row`).
        case gridTile
        /// `StackTileView.body` and `StackRowView.body`: a tile or row drawn.
        case stackTile
        /// `TileThumbnail.body`: a thumbnail (or its placeholder) drawn.
        case thumbnail
        /// `EventBoardView.body`: the board's toolbar and header.
        case board
        /// `EventStorageSummary.body`: the storage strip.
        case storageStrip
        /// `EventInfoInspector.body`: the Event Info side panel.
        case inspector
    }

    private(set) static var counts: [Kind: Int] = [:]

    static func count(_ kind: Kind) -> Int { counts[kind, default: 0] }

    static func reset() { counts = [:] }

    /// Records one build; returns true so a view body can call it as
    /// `let _ = BoardRenderCounter.hit(.grid)`.
    @discardableResult
    static func hit(_ kind: Kind) -> Bool {
        counts[kind, default: 0] += 1
        return true
    }
}
