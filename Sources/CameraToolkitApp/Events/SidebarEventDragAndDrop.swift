import CameraToolkitCore
import SwiftUI
import UniformTypeIdentifiers

/// Which part of an event row a drag is over. The top and bottom edges
/// place the dragged event between rows; the middle drops it inside.
enum SidebarRowDropZone: Equatable, Sendable {
    case top
    case middle
    case bottom

    /// The edge bands are a bit over a quarter of the row each, never
    /// thinner than a few points, so the middle stays the easy target.
    static func zone(atY y: CGFloat, height: CGFloat) -> SidebarRowDropZone {
        guard height > 0 else { return .middle }
        let band = max(4, height * 0.28)
        if y < band { return .top }
        if y > height - band { return .bottom }
        return .middle
    }

    func spot(on eventID: UUID) -> SidebarEventDropSpot {
        switch self {
        case .top: .before(eventID)
        case .middle: .into(eventID)
        case .bottom: .after(eventID)
        }
    }
}

/// The insertion line a reorder or move drag shows between rows.
struct SidebarInsertionIndicator: Equatable {
    var atTop: Bool
    /// The depth of the group the event would join, for the line's indent.
    var depth: Int
}

/// An event row as a drag source (its event, while the whole list is
/// shown) and as a drop target for both event rows and board tiles. Tiles
/// land on the whole row (assign or move them, as before). An event lands
/// between rows — an insertion line — or inside the row — the row lights
/// up — and only where the move is allowed.
struct SidebarEventDragAndDrop: ViewModifier {
    let eventID: UUID
    let depth: Int
    let arrangeable: Bool
    let workspace: EventsWorkspace
    @Binding var targetedEventID: UUID?

    @State private var height: CGFloat = 0
    @State private var indicator: SidebarInsertionIndicator?

    func body(content: Content) -> some View {
        dragSource(content)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: indicator?.atTop == false ? .bottom : .top) {
                if let indicator {
                    SidebarInsertionLine()
                        .padding(.leading, CGFloat(indicator.depth) * 14)
                        .offset(y: indicator.atTop ? -2 : 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.plainText],
                delegate: SidebarEventRowDropDelegate(
                    eventID: eventID,
                    depth: depth,
                    height: height,
                    workspace: workspace,
                    indicator: $indicator,
                    targetedEventID: $targetedEventID
                )
            )
    }

    @ViewBuilder
    private func dragSource(_ content: Content) -> some View {
        if arrangeable {
            content.onDrag {
                workspace.draggingSidebarEventID = eventID
                return NSItemProvider(object: EventsWorkspace.sidebarEventDragPayload(eventID) as NSString)
            }
        } else {
            content
        }
    }
}

/// A short accent line with a ring at its start, like Finder's.
private struct SidebarInsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .frame(height: 7)
    }
}

struct SidebarEventRowDropDelegate: DropDelegate {
    let eventID: UUID
    let depth: Int
    let height: CGFloat
    let workspace: EventsWorkspace
    @Binding var indicator: SidebarInsertionIndicator?
    @Binding var targetedEventID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        _ = update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
    }

    func dropExited(info: DropInfo) {
        clear()
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = SidebarRowDropZone.zone(atY: info.location.y, height: height)
        clear()
        let providers = info.itemProviders(for: [.plainText])
        guard !providers.isEmpty else { return false }
        let target = eventID
        let workspace = workspace
        // Every string the drag carries, then one decision on the main
        // actor: an event row's payload arranges the sidebar, a board
        // tile's payload sorts or moves its photos — never both.
        Task { @MainActor in
            var strings: [String] = []
            for provider in providers {
                if let string = await Self.loadString(provider) { strings.append(string) }
            }
            if let dragged = strings.lazy.compactMap(EventsWorkspace.sidebarEventID(fromDragPayload:)).first {
                workspace.dropSidebarEvent(dragged, at: zone.spot(on: target))
            } else {
                workspace.draggingSidebarEventID = nil
                _ = workspace.handleDrop(strings, onto: target)
            }
        }
        return true
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    /// Draws what a drop here would do and answers the drag. An event drag
    /// shows the line or the row highlight only where the move is allowed;
    /// a tile drag lights the whole row, as it always has.
    private func update(_ info: DropInfo) -> DropProposal? {
        guard let dragged = workspace.draggingSidebarEventID else {
            setIndicator(nil)
            setTargeted(true)
            return DropProposal(operation: .copy)
        }
        let zone = SidebarRowDropZone.zone(atY: info.location.y, height: height)
        let spot = zone.spot(on: eventID)
        guard workspace.canDropSidebarEvent(dragged, at: spot) else {
            clear()
            return DropProposal(operation: .forbidden)
        }
        switch zone {
        case .middle:
            setIndicator(nil)
            setTargeted(true)
        case .top:
            setTargeted(false)
            setIndicator(SidebarInsertionIndicator(atTop: true, depth: depth))
        case .bottom:
            setTargeted(false)
            let opensIntoChildren = !workspace.sidebarSiblings(under: eventID).filter { $0.id != dragged }.isEmpty
            setIndicator(SidebarInsertionIndicator(atTop: false, depth: opensIntoChildren ? depth + 1 : depth))
        }
        return DropProposal(operation: .move)
    }

    private func clear() {
        setIndicator(nil)
        setTargeted(false)
    }

    private func setIndicator(_ value: SidebarInsertionIndicator?) {
        if indicator != value { indicator = value }
    }

    private func setTargeted(_ on: Bool) {
        if on {
            if targetedEventID != eventID { targetedEventID = eventID }
        } else if targetedEventID == eventID {
            targetedEventID = nil
        }
    }
}
