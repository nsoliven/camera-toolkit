import CameraToolkitCore
import Foundation
import SwiftUI

extension View {
    /// Tooltip only when there is one — an empty `.help("")` can still
    /// install a blank tooltip, so nil skips the modifier entirely.
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(Text(text)) } else { self }
    }
}

/// One row in a "Move to Event"/"Sort Into" submenu.
struct EventMenuTarget: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
}

/// Everything a board's right-click menu needs to decide, resolved by the
/// workspace from indexes it already maintains. Building this value does no
/// filesystem work — no `standardizedFileURL`, no `resourceValues`, no stack
/// scan, no app discovery — so the menu opens instantly even while its board
/// is still loading.
struct OrganizeStackMenuState: Equatable, Sendable {
    /// Stack ids every action applies to — the selection when the clicked
    /// stack is inside it, otherwise the clicked stack alone.
    var targetIDs: Set<String>
    /// Events the stacks can move or sort into, in sidebar order.
    var eventTargets: [EventMenuTarget]
    /// True when at least one targeted stack holds a rotatable file.
    var canRotate: Bool
    /// Why Rotate is greyed out — surfaced as the submenu's help line.
    var rotateHelp: String?

    var isMultiSelect: Bool { targetIDs.count > 1 }
    var rotateTitle: String { isMultiSelect ? "Rotate Selection" : "Rotate Burst" }

    init(targetIDs: Set<String>, stacks: [OrganizeStack], eventTargets: [EventMenuTarget]) {
        self.targetIDs = targetIDs
        self.eventTargets = eventTargets
        if stacks.isEmpty {
            canRotate = false
            rotateHelp = "The selection is not on this board anymore — click the stacks again."
        } else {
            canRotate = stacks.contains { !DisplayRotation.rotatableFiles(in: $0).isEmpty }
            rotateHelp = canRotate ? nil : "Nothing to rotate — the selection holds only sidecars or other non-photo files."
        }
    }
}
