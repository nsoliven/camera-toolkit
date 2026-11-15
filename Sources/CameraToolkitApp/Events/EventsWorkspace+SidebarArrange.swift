import CameraToolkitCore
import Foundation

/// A sidebar re-parent waiting for its confirmation: the event, where it
/// is listed now and where it would go, the folders that move, and what it
/// holds. Built when the drop (or the menu) asks; the confirm checks again.
struct EventReparentRequest: Identifiable, Equatable {
    let id = UUID()
    var eventID: UUID
    /// The new parent; nil is the top level.
    var newParentID: UUID?
    /// Dropped between two rows: the sibling it goes in front of (nil: the
    /// end of the group). Not placed: it lists by date among its new siblings.
    var placeBefore: UUID?
    var placed: Bool
    var eventName: String
    var fromTitle: String
    var toTitle: String
    /// Each folder that moves, old and new, shown from the drive's own
    /// folder down (`Camera Buffer/2026/…`).
    var folderMoves: [(from: String, to: String)]
    var fileCount: Int
    var subeventCount: Int
    /// Set when the event keeps a storage setting it would otherwise have
    /// inherited differently under the new parent.
    var storageNote: String?

    static func == (lhs: EventReparentRequest, rhs: EventReparentRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// The Move Into… picker, for one event.
struct MoveIntoEventRequest: Identifiable {
    var id: UUID { eventID }
    var eventID: UUID
}

/// Where a dragged sidebar event lands on a row.
enum SidebarEventDropSpot: Equatable {
    /// In front of the row, as its sibling.
    case before(UUID)
    /// Behind the row: as its sibling, or — when the row's subevents are
    /// listed right under it — in front of its first subevent.
    case after(UUID)
    /// Inside the row's event, as a subevent.
    case into(UUID)
}

/// Sidebar arranging: reorder (the sibling order, metadata only — no file
/// moves) and nest / un-nest (a folder move on the drive, followed on the
/// NAS by a journaled folder rename, confirmed first and undoable).
extension EventsWorkspace {
    // MARK: Prefix for event-row drags

    nonisolated static let sidebarEventDragPrefix = "cameratoolkit-event:"

    nonisolated static func sidebarEventDragPayload(_ eventID: UUID) -> String {
        sidebarEventDragPrefix + eventID.uuidString
    }

    nonisolated static func sidebarEventID(fromDragPayload value: String) -> UUID? {
        guard value.hasPrefix(sidebarEventDragPrefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(sidebarEventDragPrefix.count)))
    }

    // MARK: Structure

    /// The event the sidebar lists `eventID` under; nil for the top level.
    func sidebarParentID(of eventID: UUID) -> UUID? {
        guard let event = event(eventID) else { return nil }
        return EventHierarchy.sidebarParentID(of: event, byID: eventsByID)
    }

    /// The events listed under `parentID`, in sidebar order.
    func sidebarSiblings(under parentID: UUID?) -> [SavedCameraEvent] {
        EventHierarchy.siblings(under: parentID, in: model.eventsForDisplay)
    }

    /// Turns a drop spot into the group it lands in and the sibling it goes
    /// in front of. Nil when the spot is the event itself (no move).
    func sidebarPlacement(of eventID: UUID, at spot: SidebarEventDropSpot) -> (parentID: UUID?, before: UUID?)? {
        switch spot {
        case .into(let target):
            return target == eventID ? nil : (target, nil)
        case .before(let target):
            guard target != eventID else { return nil }
            return (sidebarParentID(of: target), target)
        case .after(let target):
            guard target != eventID else { return nil }
            let children = sidebarSiblings(under: target).filter { $0.id != eventID }
            if let first = children.first {
                return (target, first.id)
            }
            let parentID = sidebarParentID(of: target)
            let group = sidebarSiblings(under: parentID).map(\.id).filter { $0 != eventID }
            guard let index = group.firstIndex(of: target) else { return (parentID, nil) }
            return (parentID, index + 1 < group.count ? group[index + 1] : nil)
        }
    }

    /// Whether dropping `eventID` at `spot` would do anything allowed — the
    /// row draws its indicator only then.
    func canDropSidebarEvent(_ eventID: UUID, at spot: SidebarEventDropSpot) -> Bool {
        guard let placement = sidebarPlacement(of: eventID, at: spot) else { return false }
        if placement.parentID == sidebarParentID(of: eventID) {
            if case .into = spot { return false }
            return true
        }
        return reparentRefusal(eventID, to: placement.parentID) == nil
    }

    /// A dragged event dropped on a row. Within its own group it is a
    /// reorder, done at once; into another group it is a re-parent, which
    /// moves folders and so asks first.
    func dropSidebarEvent(_ eventID: UUID, at spot: SidebarEventDropSpot) {
        draggingSidebarEventID = nil
        guard let placement = sidebarPlacement(of: eventID, at: spot) else { return }
        if placement.parentID == sidebarParentID(of: eventID) {
            if case .into = spot { return }
            reorderEvent(eventID, before: placement.before)
        } else {
            let placed: Bool
            if case .into = spot { placed = false } else { placed = true }
            requestReparent(eventID, to: placement.parentID, placeBefore: placement.before, placed: placed)
        }
    }

    // MARK: Reorder (metadata only)

    /// Places `eventID` in front of `beforeID` among its own siblings (at
    /// the end when nil). The first reorder in a group freezes the order it
    /// shows now, then moves the event. Only `sidebarOrder` changes: no
    /// folder, file, parent, name or date — so no confirmation, one Undo.
    func reorderEvent(_ eventID: UUID, before beforeID: UUID?) {
        guard let event = event(eventID) else { return }
        let parentID = sidebarParentID(of: eventID)
        let current = model.configuration.savedEvents
        let reordered = EventHierarchy.placing(eventID, under: parentID, before: beforeID, in: current)
        let shownBefore = EventHierarchy.siblings(under: parentID, in: current).map(\.id)
        let shownAfter = EventHierarchy.siblings(under: parentID, in: reordered).map(\.id)
        guard shownBefore != shownAfter else { return }
        var orders: [UUID: Int?] = [:]
        var pairs: [UndoEventPair] = []
        let previous = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for after in reordered {
            guard let before = previous[after.id], before.sidebarOrder != after.sidebarOrder else { continue }
            orders[after.id] = after.sidebarOrder
            pairs.append(UndoEventPair(before: before, after: after))
        }
        model.updateConfiguration { configuration in
            for index in configuration.savedEvents.indices {
                if let order = orders[configuration.savedEvents[index].id] {
                    configuration.savedEvents[index].sidebarOrder = order
                }
            }
        }
        recordUndo("Reorder \(eventTitle(event))", .config(.events(UndoEventsChange(edited: pairs))))
    }

    /// The sibling `offset` places away (-1 up, +1 down), or nil at the end
    /// of the group.
    func canMoveEvent(_ eventID: UUID, by offset: Int) -> Bool {
        let group = sidebarSiblings(under: sidebarParentID(of: eventID)).map(\.id)
        guard let index = group.firstIndex(of: eventID) else { return false }
        return group.indices.contains(index + offset)
    }

    /// Move Up / Move Down: one place among its siblings.
    func moveEvent(_ eventID: UUID, by offset: Int) {
        var group = sidebarSiblings(under: sidebarParentID(of: eventID)).map(\.id)
        guard let index = group.firstIndex(of: eventID), group.indices.contains(index + offset) else { return }
        group.remove(at: index)
        let target = index + offset
        reorderEvent(eventID, before: target < group.count ? group[target] : nil)
    }

    // MARK: Nest / un-nest (moves folders)

    /// Events `eventID` may move into — what Move Into… offers.
    func moveIntoTargets(for eventID: UUID) -> Set<UUID> {
        EventHierarchy.reparentTargets(for: eventID, in: model.eventsForDisplay)
    }

    /// Why `eventID` can't move under `parentID` (nil: the top level) right
    /// now, in the words the status line uses — or nil when it can.
    func reparentRefusal(_ eventID: UUID, to parentID: UUID?) -> String? {
        guard let event = event(eventID) else { return "That event no longer exists." }
        let events = model.eventsForDisplay
        if let problem = EventHierarchy.reparentProblem(moving: eventID, to: parentID, in: events) {
            let parentName = parentID.flatMap { self.event($0) }.map(eventTitle) ?? "the top level"
            switch problem {
            case .missingEvent:
                return "That event no longer exists."
            case .ontoItself:
                return "\(event.name) can't go inside itself."
            case .intoOwnSubevent:
                return "\(event.name) can't go inside \(parentName) — that is one of its own subevents."
            case .alreadyThere:
                return parentID == nil ? "\(event.name) is already at the top level." : "\(event.name) is already inside \(parentName)."
            case .tooDeep:
                let carried = EventHierarchy.subtreeHeight(of: eventID, in: events) > 0 ? " with its subevents" : ""
                return "Events nest at most \(EventHierarchy.maxDepth + 1) levels deep, so \(event.name)\(carried) can't go inside \(parentName)."
            }
        }
        // A job, or a queued move, holds absolute paths into these folders.
        if model.isBusy || model.isStorageBenchmarkRunning || hasPendingMoves {
            return "A file job or a queued move is running. Move \(event.name) after it finishes — its folders move with it."
        }
        return nil
    }

    /// The storage setting the event keeps when it moves under `parentID`:
    /// its own when it has one; otherwise, when the new parent would make
    /// it inherit a different place, the place it resolves to now — a
    /// re-parent never sends files to another drive.
    func reparentPolicy(for event: SavedCameraEvent, to parentID: UUID?) -> EventStoragePolicy? {
        if let own = event.storagePolicy { return own }
        let now = resolvedPolicy(for: event)
        let inherited = parentID.flatMap { self.event($0) }.map { resolvedPolicy(for: $0) } ?? .buffer
        return inherited == now ? nil : now
    }

    /// Asks to move `eventID` (and its subevents, and their folders) under
    /// `parentID`. Refusals go to the status line; otherwise the
    /// confirmation sheet opens with what would move.
    func requestReparent(_ eventID: UUID, to parentID: UUID?, placeBefore: UUID? = nil, placed: Bool = false) {
        draggingSidebarEventID = nil
        guard let event = event(eventID) else { return }
        if let refusal = reparentRefusal(eventID, to: parentID) {
            refuseMove("Move \(eventTitle(event))", refusal)
            return
        }
        let locations = self.locations
        var moved = event
        moved.parentEventID = parentID
        moved.storagePolicy = reparentPolicy(for: event, to: parentID)
        var folderMoves: [(from: String, to: String)] = []
        for policy in EventStoragePolicy.allCases {
            let old = locations.eventFolder(for: event, policy: policy)
            guard FileManager.default.fileExists(atPath: old.path) else { continue }
            let new = locations.eventFolder(for: moved, policy: policy)
            let base = locations.driveRoot(for: policy).deletingLastPathComponent().path + "/"
            folderMoves.append((
                from: old.path.hasPrefix(base) ? String(old.path.dropFirst(base.count)) : old.path,
                to: new.path.hasPrefix(base) ? String(new.path.dropFirst(base.count)) : new.path
            ))
        }
        let family = Set(eventFamily(eventID).map(\.id))
        let fileCount = model.configuration.photoEventAssignments.count { family.contains($0.eventID) }
        var storageNote: String?
        if event.storagePolicy == nil, moved.storagePolicy != nil {
            let kept = moved.storagePolicy == .archiveOnly ? "Private" : "Shared"
            storageNote = "\(event.name) stays \(kept), so none of its files change drives."
        }
        pendingReparent = EventReparentRequest(
            eventID: eventID,
            newParentID: parentID,
            placeBefore: placeBefore,
            placed: placed,
            eventName: event.name,
            fromTitle: sidebarParentID(of: eventID).flatMap { self.event($0) }.map(eventTitle) ?? "Top level",
            toTitle: parentID.flatMap { self.event($0) }.map(eventTitle) ?? "Top level",
            folderMoves: folderMoves,
            fileCount: fileCount,
            subeventCount: family.count - 1,
            storageNote: storageNote
        )
    }

    /// The Move Into… picker closed: a pick opens the confirmation now that
    /// a second sheet can be presented.
    func moveIntoSheetDidDismiss() {
        guard let choice = moveIntoChoice else { return }
        moveIntoChoice = nil
        requestReparent(choice.eventID, to: choice.parentID)
    }

    /// The confirmed re-parent: checked again (the library may have changed
    /// while the sheet was open), then the same folder move an event edit
    /// does — exclusive same-volume renames, collision refused, NAS folder
    /// rename journaled and queued, one Undo entry.
    func confirmReparent(_ request: EventReparentRequest) {
        pendingReparent = nil
        guard let event = event(request.eventID) else { return }
        if let refusal = reparentRefusal(request.eventID, to: request.newParentID) {
            refuseMove("Move \(eventTitle(event))", refusal)
            return
        }
        editEvent(
            event.id,
            name: event.name,
            date: event.eventDate,
            policy: reparentPolicy(for: event, to: request.newParentID),
            parentEventID: request.newParentID,
            purpose: .reparent(placeBefore: request.placeBefore, placed: request.placed)
        )
    }
}
