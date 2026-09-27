import AppKit
import AVFoundation
import CameraToolkitCore
import Observation
import SwiftUI

enum EventPalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .brown, .cyan, .mint]
    /// Entries too light for white caption text (orange, teal, green, cyan,
    /// mint): chips filled with them use dark text instead.
    private static let lightEntries: Set<Int> = [3, 4, 6, 9, 10]

    static func index(for id: UUID) -> Int {
        index(hashing: id.uuidString)
    }

    static func color(for id: UUID) -> Color {
        colors[index(for: id)]
    }

    /// Stable color for a name string — the Trash browser tags people and
    /// events that may no longer exist, so it hashes the name itself.
    static func color(forName name: String) -> Color {
        colors[index(hashing: name)]
    }

    /// True when text on a solid fill of this id's color must be dark to
    /// stay legible.
    static func prefersDarkText(for id: UUID) -> Bool {
        lightEntries.contains(index(for: id))
    }

    /// Legible text color on a solid fill of this id's color.
    static func textColor(for id: UUID) -> Color {
        prefersDarkText(for: id) ? .black.opacity(0.85) : .white
    }

    private static func index(hashing value: String) -> Int {
        var hash = 0
        for scalar in value.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return hash % colors.count
    }
}

/// A context menu whose items live in a view body: `.contextMenu` runs
/// its content closure while the row renders, but a nested view's body
/// only runs when the menu actually opens — so per-tile menus stop
/// paying their build cost on every board render.
struct LazyContextMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

/// An event's name capsule — the mark for "this item is in this event",
/// never an action (quick-assign targets are `QuickAssignLabel` buttons).
/// `.filled` is the event's own color with text
/// picked for contrast; `.onPhoto` is a flat dark scrim with a color dot,
/// legible over any photo and quiet across hundreds of tiles.
struct EventChip: View {
    enum Style {
        case filled
        case onPhoto
    }

    let event: SavedCameraEvent
    /// Resolved private flag. Pass it when the event's own `storagePolicy`
    /// can be nil — a subevent inherits the lock from a private parent.
    var isPrivate: Bool?
    var style: Style = .filled

    var body: some View {
        let color = EventPalette.color(for: event.id)
        let text = style == .onPhoto ? Color.white : EventPalette.textColor(for: event.id)
        HStack(spacing: 4) {
            if style == .onPhoto {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            if isPrivate ?? (event.resolvedStoragePolicy == .archiveOnly) {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .accessibilityLabel("Private")
            }
            Text(event.name)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(text)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(style == .onPhoto ? Color.black.opacity(BoardMetrics.badgeScrimOpacity) : color, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A subevent's color mark — on a tile it sits at the trailing end of the
/// time and name line under the photo, on a list row at the title's start. Just the dot — the name is the hover
/// label, never text.
struct EventTagCapsule: View {
    let event: SavedCameraEvent

    var body: some View {
        Circle()
            .fill(EventPalette.color(for: event.id))
            .frame(width: 12, height: 12)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
            .help(event.name)
            .accessibilityLabel(event.name)
    }
}

/// A direct subevent's filter chip in the event header: a standard toggle
/// button that is on while its photos show and off (struck through) while
/// an "is none of" row hides them. The color dot keeps the subevent's
/// identity without putting text on its color.
struct SubeventChip: View {
    let event: SavedCameraEvent
    let isFiltering: Bool
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { !isFiltering }, set: { _ in onToggle() })) {
            HStack(spacing: 5) {
                Circle()
                    .fill(EventPalette.color(for: event.id))
                    .frame(width: 8, height: 8)
                Text(event.name)
                    .lineLimit(1)
                    .strikethrough(isFiltering)
            }
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help(isFiltering
            ? "\(event.name) is filtered out — click to bring its photos back"
            : "Hide \(event.name)'s photos")
        .accessibilityLabel(event.name)
        .accessibilityValue(isFiltering ? "Hidden" : "Shown")
    }
}

/// One camera on the board with its stack count — shown in the event
/// header when the board mixes cameras. A click adds the camera to the
/// board's "Camera is any of" filter row (or takes it back out), so one
/// click narrows the board to that camera.
struct CameraChip: View {
    let camera: OrganizeCamera
    let count: Int
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in onToggle() })) {
            HStack(spacing: 4) {
                Image(systemName: camera.id == OrganizeCamera.unknownID ? "questionmark.circle" : "camera")
                    .imageScale(.small)
                Text(camera.name)
                    .lineLimit(1)
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help(isOn
            ? "Showing \(camera.name) — click to stop filtering by it"
            : "Show only items shot on \(camera.name) (\(count) on this board)")
        .accessibilityLabel("\(camera.name), \(count)")
        .accessibilityValue(isOn ? "Filtering" : "Not filtering")
    }
}

/// A named person detected on an event's photos: a neutral capsule with
/// the person's stable color on the symbol, so the name reads in both
/// appearances whatever the color.
struct PersonChip: View {
    let person: FacePerson

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill")
                .imageScale(.small)
                .foregroundStyle(EventPalette.color(for: person.id))
            Text(person.name)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .fixedSize()
        .help("\(person.faceCount) detection\(person.faceCount == 1 ? "" : "s") in this event")
        .accessibilityElement(children: .combine)
    }
}

enum TileLocationBadge {
    case onSource
    case inBuffer
    case inPrivate
    case nasOnly

    var label: String {
        switch self {
        case .onSource: "On source"
        case .inBuffer: "Still in Buffer"
        case .inPrivate: "In Private"
        case .nasOnly: "NAS only"
        }
    }

    var symbol: String {
        switch self {
        case .onSource: "sdcard"
        case .inBuffer: "externaldrive"
        case .inPrivate: "lock.fill"
        case .nasOnly: "server.rack"
        }
    }
}

struct OrganizeDragPayload: Codable {
    enum Origin: String, Codable {
        case unsorted
        case event
    }

    var origin: Origin
    var containerID: UUID
    var stackIDs: [String]

    private static let prefix = "cameratoolkit-organize:"

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    static func decode(_ value: String) -> OrganizeDragPayload? {
        guard value.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(OrganizeDragPayload.self, from: Data(value.dropFirst(prefix.count).utf8))
    }
}

struct TileThumbnail: View {
    let url: URL
    let kind: OrganizeMediaKind
    /// Longest edge in points — the decode asks for `pointSize × displayScale`
    /// pixels, so a 1× monitor never pays for a Retina-sized bitmap.
    let pointSize: CGFloat
    /// Display rotation in quarter-turns clockwise; part of the task id so a
    /// "Rotate Burst" change re-decodes this tile without a rescan.
    var orientation: Int = 0

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false

    private var pixelSize: Int { Int(pointSize * displayScale) }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(url.path)#\(TileImageLoader.bucket(for: pixelSize))#\(orientation)") {
            if let cached = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: pixelSize, orientation: orientation) {
                image = cached
                failed = false
                return
            }
            image = nil
            failed = false
            let loaded = await TileImageLoader.shared.image(for: url, maximumPixelSize: pixelSize, orientation: orientation)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
        .onDisappear {
            // Scrolled off: drop the tile's own bitmap — the NSCache keeps a
            // share for the scroll back, this copy is what ballooned memory.
            image = nil
        }
    }

    private var symbol: String {
        switch kind {
        case .video: "video"
        case .other: "document"
        default: "photo"
        }
    }
}

private extension View {
    /// A flat dark capsule for labels drawn on a photo — no material, so a
    /// board of hundreds of tiles never runs hundreds of live blurs.
    func photoBadgeScrim() -> some View {
        font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minHeight: BoardMetrics.badgeMinHitSize)
            .background(Color.black.opacity(BoardMetrics.badgeScrimOpacity), in: Capsule())
    }
}

/// Selection colour as a SwiftUI colour for `isEmphasized`.
private func boardSelectionColor(isEmphasized: Bool) -> Color {
    Color(nsColor: BoardSelectionStyle.selectionNSColor(isEmphasized: isEmphasized))
}

private func stackTitle(_ stack: OrganizeStack) -> String {
    if let label = stack.burstLabel, stack.isBurst {
        return "\(label) · \(stack.items.count) frames"
    }
    if stack.isBurst {
        return "Burst · \(stack.items.count) frames"
    }
    return stack.coverItem.primary.name
}

/// "Edited · Photomator", or "Edited · Masters +1" for several tags —
/// the badge an original wears when `Edited/<Tag>` holds an edit of it.
func editTagBadgeTitle(_ tags: [String]) -> String? {
    guard let first = tags.first else { return nil }
    return tags.count == 1 ? "Edited · \(first)" : "Edited · \(first) +\(tags.count - 1)"
}

/// VoiceOver name for a tile or row: what it is, when, and where it went.
private func stackAccessibilityLabel(
    _ stack: OrganizeStack,
    event: SavedCameraEvent?,
    isMixed: Bool,
    badge: TileLocationBadge?,
    editTags: [String] = []
) -> String {
    var parts = [stackTitle(stack), stack.captureDate.formatted(date: .abbreviated, time: .shortened)]
    if stack.kind == .video, !stack.isBurst { parts.append("Video") }
    if let event { parts.append(event.name) }
    if isMixed { parts.append("Mixed events") }
    if let badge { parts.append(badge.label) }
    if !editTags.isEmpty { parts.append("Edited: " + editTags.joined(separator: ", ")) }
    return parts.joined(separator: ", ")
}

struct StackTileView: View {
    let stack: OrganizeStack
    let width: CGFloat
    let isSelected: Bool
    let isFocused: Bool
    /// True while the board holds focus in the active window: selection
    /// draws in the accent colour, otherwise in the grey unemphasized one.
    var isEmphasized: Bool = true
    let event: SavedCameraEvent?
    /// Resolved private flag for `event` — a subevent can inherit the lock
    /// from a private parent, so the caller resolves it.
    var isPrivate: Bool? = nil
    /// The owning subevent's color dot, drawn on its own line under the
    /// title. Nil hides it.
    var tag: SavedCameraEvent? = nil
    let isMixed: Bool
    let isDimmed: Bool
    let badge: TileLocationBadge?
    /// Edit tags linked to the stack's originals (`Edited/<Tag>`), sorted;
    /// empty hides the "Edited · <Tag>" badge.
    var editTags: [String] = []
    /// Subfolder the stack lives in, relative to the scan root — shown as a
    /// tooltip. Nil when the stack sits directly in the scanned folder.
    var originFolder: String? = nil
    /// Display rotation of the cover frame in quarter-turns clockwise.
    var orientation: Int = 0
    /// Toggles the inline expansion of a burst. Nil falls back to `onOpen`.
    var onExpand: (() -> Void)? = nil
    /// Opens playback for a video tile. Nil falls back to `onOpen`… callers
    /// pass it so the badge does something sensible everywhere.
    var onPlay: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BoardMetrics.tileRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                TileThumbnail(url: stack.coverItem.primary.url, kind: stack.kind, pointSize: width, orientation: orientation)
                    .frame(width: width, height: width * 2 / 3)
                    .clipped()
                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        if let badge {
                            Label(badge.label, systemImage: badge.symbol)
                                .photoBadgeScrim()
                        }
                        Spacer(minLength: 0)
                        if stack.isBurst {
                            Button {
                                (onExpand ?? onOpen)?()
                            } label: {
                                Label("\(stack.items.count)", systemImage: "square.stack.3d.down.right.fill")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .photoBadgeScrim()
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .help("Show every frame of this burst in the board")
                        } else if stack.kind == .video {
                            Button {
                                (onPlay ?? onOpen)?()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .frame(width: BoardMetrics.badgeMinHitSize, height: BoardMetrics.badgeMinHitSize)
                                    .background(Color.black.opacity(BoardMetrics.badgeScrimOpacity), in: Circle())
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .help("Play this video")
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let event {
                            EventChip(event: event, isPrivate: isPrivate, style: .onPhoto)
                        }
                        if isMixed {
                            Label {
                                Text("Mixed")
                            } icon: {
                                Image(systemName: "square.split.2x1")
                                    .foregroundStyle(.orange)
                            }
                            .photoBadgeScrim()
                        }
                        if let title = editTagBadgeTitle(editTags) {
                            Label(title, systemImage: "slider.horizontal.3")
                                .lineLimit(1)
                                .photoBadgeScrim()
                                .help("Edits in Edited/: " + editTags.joined(separator: ", "))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(6)
            }
            .frame(width: width, height: width * 2 / 3)
            .background(.quaternary)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .overlay { selectionRing }

            HStack(spacing: 6) {
                Text(stack.captureDate.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                Text(stackTitle(stack))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let tag {
                    EventTagCapsule(event: tag)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
        }
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(originFolder.map { "In \($0)" } ?? stack.coverItem.primary.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stackAccessibilityLabel(stack, event: event, isMixed: isMixed, badge: badge, editTags: editTags))
        .accessibilityValue(isDimmed ? "Sorted" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if stack.isBurst {
                Button("Show All Frames") { (onExpand ?? onOpen)?() }
            } else if stack.kind == .video {
                Button("Play") { (onPlay ?? onOpen)?() }
            }
        }
    }

    /// The selection ring sits just outside the photo — a gap, then the
    /// ring — so it never covers pixels. Focus without selection (the
    /// keyboard cursor after a ⌘-click) gets a thinner, lighter ring.
    @ViewBuilder
    private var selectionRing: some View {
        let gap = BoardMetrics.selectionRingGap
        if isSelected || isFocused {
            let lineWidth = isSelected ? BoardMetrics.selectionRingWidth : BoardMetrics.focusRingWidth
            let color = boardSelectionColor(isEmphasized: isEmphasized)
            RoundedRectangle(cornerRadius: BoardMetrics.tileRadius + gap + lineWidth, style: .continuous)
                .strokeBorder(isSelected ? color : color.opacity(0.6), lineWidth: lineWidth)
                .padding(-(gap + lineWidth))
                .allowsHitTesting(false)
        }
    }
}

/// Header of one board section — a day, folder, kind, or event group.
/// The whole bar opens and closes the group, with the disclosure chevron
/// leading as in the sidebar's sections. Select stays its own button so it
/// does not toggle the section.
struct BoardGroupHeader: View {
    let group: OrganizeBoardGroup
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    onToggleCollapse()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 14)
                    if let symbol = group.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                    }
                    Text(group.title)
                        .font(.headline)
                    Text(group.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 8)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand this group" : "Collapse this group")
            .accessibilityLabel(group.title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            Button("Select", action: onSelect)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(group.stacks.isEmpty)
                .help("Select everything in this group")
                .accessibilityLabel("Select All in \(group.title)")
                .padding(.vertical, 8)
                .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No background of its own: in the content it sits between tiles,
        // and in the top bar the scroll edge effect is its backdrop.
    }
}

/// Which section's header the board's top bar shows. The grid feeds it the
/// in-content header positions (they change only on layout) and the
/// visible top (on scroll); only `BoardStickyHeader` reads `currentID`, so
/// scrolling past a day re-renders that one header and never the grid.
@MainActor
@Observable
final class BoardStickyHeaderState {
    private(set) var currentID: String?
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var sectionForStack: [String: Int] = [:]
    @ObservationIgnored private var headerTops: [String: CGFloat] = [:]
    @ObservationIgnored private var visibleTop: CGFloat = 0
    @ObservationIgnored private var firstVisibleSectionID: String?

    func setSections(_ sections: [OrganizeBoardSection]) {
        let ids = sections.map(\.id)
        order = ids
        var map: [String: Int] = [:]
        for (index, section) in sections.enumerated() {
            for stack in section.group.stacks { map[stack.id] = index }
        }
        sectionForStack = map
        let kept = Set(ids)
        headerTops = headerTops.filter { kept.contains($0.key) }
        refresh()
    }

    func setHeaderTop(_ top: CGFloat, for id: String) {
        guard headerTops[id] != top else { return }
        headerTops[id] = top
        refresh()
    }

    func setVisibleTop(_ top: CGFloat) {
        guard top != visibleTop else { return }
        visibleTop = top
        refresh()
    }

    /// The scroll targets on screen — tiles, rows and burst expansions.
    func setVisibleStacks(_ ids: [String]) {
        let first = ids.compactMap { id in
            sectionForStack[id] ?? sectionForStack[String(id.dropLast("-expansion".count))]
        }.min()
        let next = first.map { order[$0] }
        guard next != firstVisibleSectionID else { return }
        firstVisibleSectionID = next
        refresh()
    }

    /// Forgets every position — a different board or layout mode.
    func reset() {
        headerTops = [:]
        visibleTop = 0
        firstVisibleSectionID = nil
        refresh()
    }

    private func refresh() {
        let next = OrganizeBoardPlan.stickySectionID(
            order: order,
            headerTops: headerTops,
            visibleTop: visibleTop,
            firstVisibleSectionID: firstVisibleSectionID
        )
        if next != currentID { currentID = next }
    }
}

/// The current section's header, in a bar above the board's scroll view.
/// It shares the toolbar's scroll edge effect (and any bar above it, like
/// the event board's storage strip), so the chrome is one surface: tiles
/// scroll under all of it, and no header ever draws over another layer.
struct BoardStickyHeader: View {
    let state: BoardStickyHeaderState
    let sections: [OrganizeBoardSection]
    let horizontalPadding: CGFloat
    let onToggleCollapse: (OrganizeBoardSection) -> Void
    let onSelect: (OrganizeBoardSection) -> Void

    var body: some View {
        if let section = sections.first(where: { $0.id == state.currentID }) ?? sections.first {
            BoardGroupHeader(
                group: section.group,
                isCollapsed: section.isCollapsed,
                onToggleCollapse: { onToggleCollapse(section) },
                onSelect: { onSelect(section) }
            )
            .padding(.horizontal, horizontalPadding)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("boardStickyHeader")
            .boardChromeProbe("boardStickyHeader", label: section.group.title)
        }
    }
}

/// Which list row shows its `···` menu. The grid owns one instance; only
/// the small menu slots read it, so a hover change re-renders those slots
/// and never the grid or the rows.
@MainActor
@Observable
final class BoardHoverState {
    var rowID: String?

    func set(_ id: String, hovering: Bool) {
        if hovering {
            rowID = id
        } else if rowID == id {
            rowID = nil
        }
    }
}

/// The trailing `···` slot of a list row. It holds a real menu only on the
/// hovered or keyboard-focused row, so at most a couple of `Menu`s exist
/// at once; the menu's items stay in a `LazyContextMenu` and build when it
/// opens. The slot keeps its width either way so columns never jump.
struct BoardRowMoreMenu<Content: View>: View {
    let hover: BoardHoverState
    let stackID: String
    let isFocused: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if isFocused || hover.rowID == stackID {
                Menu {
                    content()
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for this item")
            }
        }
        .frame(width: 24)
    }
}

/// One row of the board's list mode — the same stack as a tile, compressed
/// into a single line so hundreds of bursts fit on screen. Leading thumb
/// and title; trailing columns for capture time, size, event, and the
/// burst/play control; then the `···` slot.
struct StackRowView<MoreMenu: View>: View {
    let stack: OrganizeStack
    let isSelected: Bool
    let isFocused: Bool
    var isEmphasized: Bool = true
    let isExpanded: Bool
    let event: SavedCameraEvent?
    var isPrivate: Bool? = nil
    /// The owning subevent's color dot, at the start of the title line on
    /// a list row. Nil hides it.
    var tag: SavedCameraEvent? = nil
    let isMixed: Bool
    let isDimmed: Bool
    let badge: TileLocationBadge?
    var editTags: [String] = []
    var originFolder: String? = nil
    var onExpand: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var moreMenu: () -> MoreMenu

    private var isProminent: Bool { isSelected && isEmphasized }

    var body: some View {
        HStack(spacing: 10) {
            TileThumbnail(url: stack.coverItem.primary.url, kind: stack.kind, pointSize: 88)
                .frame(width: 72, height: 48)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: BoardMetrics.listThumbRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BoardMetrics.listThumbRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let tag {
                        EventTagCapsule(event: tag)
                    }
                    if stack.isBurst {
                        Image(systemName: "square.stack.3d.down.right.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(stackTitle(stack))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    if let originFolder {
                        Label(originFolder, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isMixed {
                        Label("Mixed", systemImage: "square.split.2x1")
                            .foregroundStyle(isProminent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                    if let badge {
                        Label(badge.label, systemImage: badge.symbol)
                    }
                    if let title = editTagBadgeTitle(editTags) {
                        Label(title, systemImage: "slider.horizontal.3")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Text(stack.captureDate.formatted(date: .numeric, time: .shortened))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            Text(stack.byteCount.formattedBytes)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
            // ZStack, not Group: an empty Group drops its frame and the
            // columns would shift on rows without an event or burst.
            ZStack(alignment: .leading) {
                if let event {
                    EventChip(event: event, isPrivate: isPrivate)
                }
            }
            .frame(width: 132, alignment: .leading)
            ZStack(alignment: .leading) {
                if stack.isBurst {
                    Button {
                        (onExpand ?? onOpen)?()
                    } label: {
                        Label("\(stack.items.count)", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                            .monospacedDigit()
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Collapse this burst" : "Show every frame in the board")
                    .accessibilityLabel(isExpanded ? "Collapse Burst" : "Show All \(stack.items.count) Frames")
                } else if stack.kind == .video {
                    Button("Play", systemImage: "play.fill") {
                        (onPlay ?? onOpen)?()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Play this video")
                }
            }
            .frame(width: 48, alignment: .leading)
            moreMenu()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(Color(nsColor: isSelected
            ? BoardSelectionStyle.selectedTextNSColor(isEmphasized: isEmphasized)
            : .labelColor))
        .background {
            let shape = RoundedRectangle(cornerRadius: BoardMetrics.rowSelectionRadius, style: .continuous)
            if isSelected {
                shape.fill(boardSelectionColor(isEmphasized: isEmphasized))
            } else if isFocused {
                shape.strokeBorder(boardSelectionColor(isEmphasized: isEmphasized).opacity(0.6), lineWidth: 1)
            }
        }
        .environment(\.backgroundProminence, isProminent ? .increased : .standard)
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .help(originFolder.map { "In \($0)" } ?? stack.coverItem.primary.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stackAccessibilityLabel(stack, event: event, isMixed: isMixed, badge: badge, editTags: editTags))
        .accessibilityValue(isDimmed ? "Sorted" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Every frame of a burst laid out inside the board — what the count badge
/// expands into. Clicking a frame opens the full preview at that frame.
struct BurstExpansionView: View {
    let stack: OrganizeStack
    /// Edge length of the small frame thumbnails.
    var frameSize: CGFloat = 104
    var onOpenFrame: ((Int) -> Void)? = nil
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        let card = RoundedRectangle(cornerRadius: BoardMetrics.expansionRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .foregroundStyle(.secondary)
                Text(stack.burstLabel.map { "\($0) · \(stack.items.count) frames" } ?? "\(stack.items.count) frames")
                    .font(.headline)
                Text("\(stack.captureDate.formatted(date: .omitted, time: .shortened)) – \(stack.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Collapse", systemImage: "chevron.up") {
                    onCollapse?()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: frameSize, maximum: frameSize * 1.4), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, frame in
                    let shape = RoundedRectangle(cornerRadius: BoardMetrics.frameRadius, style: .continuous)
                    TileThumbnail(url: frame.primary.url, kind: frame.kind, pointSize: frameSize)
                        .frame(width: frameSize, height: frameSize * 2 / 3)
                        .clipped()
                        .clipShape(shape)
                        .overlay(alignment: .bottomTrailing) {
                            if frame.kind == .video {
                                Image(systemName: "video.fill")
                                    .font(.caption2)
                                    .imageScale(.small)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.black.opacity(BoardMetrics.badgeScrimOpacity), in: Circle())
                                    .padding(3)
                            }
                        }
                        .overlay {
                            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .contentShape(shape)
                        .onTapGesture { onOpenFrame?(index) }
                        .help(frame.primary.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Frame \(index + 1) of \(stack.items.count), \(frame.primary.name)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onOpenFrame?(index) }
                }
            }
        }
        .padding(10)
        .background(.tint.quinary, in: card)
        .overlay {
            card.strokeBorder(.tint.quaternary, lineWidth: 1)
        }
    }
}

struct OrganizeStatusLine: View {
    @Bindable var model: DashboardModel
    /// Boards pass the workspace so the source → destination diagram of a
    /// running Apply stays visible above the status line.
    var workspace: EventsWorkspace? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let running = workspace?.runningApply,
               model.jobs.contains(where: { $0.id == running.jobID && $0.state == .running }) {
                ApplyProgressBanner(running: running)
                Divider()
            }
            HStack(spacing: 8) {
                if let job = model.activeJob {
                    ProgressView(value: job.progress)
                        .frame(width: 120)
                    Text(job.note)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(model.statusMessage)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// The shared burst board: collapsible groups (day, folder, kind, or event)
/// as pinned sections, either as tiles or a dense list. Keyboard focus,
/// click and Shift/Command selection, drag to an event, a context menu, and
/// inline burst expansion via the count badge or `E`.
struct OrganizeGrid<MenuContent: View>: View {
    @Bindable var workspace: EventsWorkspace
    let groups: [OrganizeBoardGroup]
    let mode: OrganizeBoardMode
    let tileWidth: CGFloat
    let origin: OrganizeDragPayload.Origin
    let containerID: UUID
    /// Scan root used to label each tile's origin subfolder; nil hides the
    /// label (event boards have no single scan root).
    var rootPath: String? = nil
    let eventForStack: (OrganizeStack) -> (event: SavedCameraEvent?, mixed: Bool)
    /// The subevent tag a tile or row wears — event boards resolve the
    /// owning subevent here; nil keeps the tag off (unsorted boards).
    var tagForStack: (OrganizeStack) -> SavedCameraEvent? = { _ in nil }
    /// Edit tags for a tile's "Edited · <Tag>" badge — event boards only.
    var editTagsForStack: (OrganizeStack) -> [String] = { _ in [] }
    let isDimmed: (OrganizeStack) -> Bool
    let badge: (OrganizeStack) -> TileLocationBadge?
    /// Display rotation recorded for a file, in quarter-turns clockwise —
    /// the cover frame's value drives the tile decode.
    var orientationForFile: (OrganizeFile) -> Int = { _ in 0 }
    /// Opens the full preview at a specific frame of the stack (0 for the
    /// usual double-click/Space path).
    let onOpen: (OrganizeStack, Int) -> Void
    let onKey: (KeyPress, [String]) -> KeyPress.Result
    @ViewBuilder let menu: (OrganizeStack) -> MenuContent

    @FocusState private var isFocused: Bool
    @State private var columns = 1
    /// One grid-level read of the window's active state — tiles get the
    /// result as a plain Bool rather than each reading the environment.
    @Environment(\.appearsActive) private var appearsActive
    /// Which list row shows its `···` menu; only the menu slots observe it.
    @State private var hover = BoardHoverState()
    /// Which section's header sits in the top bar; only that bar reads it.
    @State private var sticky = BoardStickyHeaderState()
    /// Content coordinates for in-content header positions — stable while
    /// scrolling, so a header reports only when the layout moves it.
    private static var contentSpace: String { "OrganizeGridContent" }

    /// Accent selection while the window is active, grey only in the
    /// background — independent of which control has keyboard focus.
    private var isEmphasized: Bool {
        BoardSelectionStyle.isEmphasized(windowIsActive: appearsActive)
    }

    /// One section per group — collapsing hides a group's rows, never the
    /// group itself, so headers keep their real counts and Select still
    /// sees the stacks.
    private var sections: [OrganizeBoardSection] {
        OrganizeBoardPlan.sections(for: groups, collapsedIDs: workspace.collapsedGroupIDs)
    }

    var body: some View {
        let ordered = sections.flatMap(\.visibleStacks)
        let orderedIDs = ordered.map(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                if mode == .tiles {
                    tileBoard(orderedIDs: orderedIDs)
                } else {
                    listBoard(orderedIDs: orderedIDs)
                }
            }
            // The current section's header rides in a bar rather than as a
            // pinned header inside the content: a pinned header needs its
            // own backdrop, which never matched the edge effect above it
            // and let tiles show between the two. As a bar it joins the
            // toolbar's (and the storage strip's) edge effect instead.
            .safeAreaBar(edge: .top) {
                BoardStickyHeader(
                    state: sticky,
                    sections: sections,
                    horizontalPadding: mode == .tiles ? 16 : 0,
                    onToggleCollapse: { section in
                        workspace.setGroupCollapsed(section.id, collapsed: !section.isCollapsed)
                    },
                    onSelect: { section in
                        workspace.selectStacks(section.group.stacks.map(\.id))
                        isFocused = true
                    }
                )
            }
            // A firm, even backdrop under the whole top chrome — a soft edge
            // fades out before the lower bars and leaves their text over
            // bare tiles.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, top in
                sticky.setVisibleTop(top)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                sticky.setVisibleStacks(ids)
            }
            .onChange(of: groups.map { "\($0.id)#\($0.stacks.count)" }, initial: true) { sticky.setSections(sections) }
            .onChange(of: containerID) { sticky.reset() }
            .onChange(of: mode) { sticky.reset() }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKey(press, ordered: ordered, orderedIDs: orderedIDs, proxy: proxy)
            }
            .onAppear { isFocused = true }
            // Return in the toolbar search field hands the keyboard back.
            .onChange(of: workspace.boardFocusRequest) { isFocused = true }
            .onChange(of: workspace.focusedStackID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func tileBoard(orderedIDs: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.3), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.visibleStacks) { stack in
                        if workspace.expandedStackIDs.contains(stack.id), stack.isBurst {
                            expansion(stack)
                                .gridCellColumns(max(columns, 1))
                        } else {
                            tile(stack, orderedIDs: orderedIDs)
                        }
                    }
                } header: {
                    inlineHeader(section)
                }
            }
        }
        .scrollTargetLayout()
        .padding(16)
        .coordinateSpace(.named(Self.contentSpace))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateColumns(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
            }
        }
    }

    private func listBoard(orderedIDs: [String]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.visibleStacks) { stack in
                        row(stack, orderedIDs: orderedIDs)
                        if workspace.expandedStackIDs.contains(stack.id), stack.isBurst {
                            expansion(stack, compact: true)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                    }
                } header: {
                    inlineHeader(section)
                }
            }
        }
        .scrollTargetLayout()
        .padding(.vertical, 8)
        .coordinateSpace(.named(Self.contentSpace))
    }

    /// A section's header inside the content. The first section's lives
    /// only in the top bar — it is current until the second header scrolls
    /// up, so drawing it here too would show it twice.
    @ViewBuilder
    private func inlineHeader(_ section: OrganizeBoardSection) -> some View {
        if section.id != groups.first?.id {
            BoardGroupHeader(
                group: section.group,
                isCollapsed: section.isCollapsed,
                onToggleCollapse: {
                    workspace.setGroupCollapsed(section.id, collapsed: !section.isCollapsed)
                },
                onSelect: {
                    workspace.selectStacks(section.group.stacks.map(\.id))
                    isFocused = true
                }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.contentSpace)).minY
            } action: { top in
                sticky.setHeaderTop(top, for: section.id)
            }
        }
    }

    private func expansion(_ stack: OrganizeStack, compact: Bool = false) -> some View {
        BurstExpansionView(
            stack: stack,
            frameSize: compact ? 96 : min(max(tileWidth * 0.5, 84), 132),
            onOpenFrame: { onOpen(stack, $0) },
            onCollapse: { workspace.setExpanded(stack.id, expanded: false) }
        )
        .id("\(stack.id)-expansion")
    }

    private func tile(_ stack: OrganizeStack, orderedIDs: [String]) -> some View {
        let assigned = eventForStack(stack)
        return StackTileView(
            stack: stack,
            width: tileWidth,
            isSelected: workspace.selectedStackIDs.contains(stack.id),
            isFocused: workspace.focusedStackID == stack.id,
            isEmphasized: isEmphasized,
            event: assigned.event,
            isPrivate: assigned.event.map { workspace.resolvedPolicy(for: $0) == .archiveOnly },
            tag: tagForStack(stack),
            isMixed: assigned.mixed,
            isDimmed: isDimmed(stack),
            badge: badge(stack),
            editTags: editTagsForStack(stack),
            originFolder: OrganizeFolderLabel.subfolder(
                forFolderPath: stack.coverItem.primary.folderPath,
                rootPath: rootPath
            ),
            orientation: orientationForFile(stack.coverItem.primary),
            onExpand: { workspace.setExpanded(stack.id, expanded: true) },
            onPlay: { onOpen(stack, 0) },
            onOpen: { onOpen(stack, 0) }
        )
        .id(stack.id)
        .onTapGesture {
            select(stack, orderedIDs: orderedIDs)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(stack, 0) })
        .accessibilityAction { select(stack, orderedIDs: orderedIDs) }
        .accessibilityAction(named: "Preview") { onOpen(stack, 0) }
        .draggable(workspace.dragPayload(for: stack.id, origin: origin, containerID: containerID)) {
            dragPreview(for: stack)
        }
        .contextMenu { menu(stack) }
    }

    private func row(_ stack: OrganizeStack, orderedIDs: [String]) -> some View {
        let assigned = eventForStack(stack)
        let isFocusedRow = workspace.focusedStackID == stack.id
        return StackRowView(
            stack: stack,
            isSelected: workspace.selectedStackIDs.contains(stack.id),
            isFocused: isFocusedRow,
            isEmphasized: isEmphasized,
            isExpanded: workspace.expandedStackIDs.contains(stack.id),
            event: assigned.event,
            isPrivate: assigned.event.map { workspace.resolvedPolicy(for: $0) == .archiveOnly },
            tag: tagForStack(stack),
            isMixed: assigned.mixed,
            isDimmed: isDimmed(stack),
            badge: badge(stack),
            editTags: editTagsForStack(stack),
            originFolder: OrganizeFolderLabel.title(
                forFolderPath: stack.coverItem.primary.folderPath,
                rootPath: rootPath
            ),
            onExpand: { workspace.toggleExpanded(stack.id) },
            onPlay: { onOpen(stack, 0) },
            onOpen: { onOpen(stack, 0) },
            moreMenu: {
                BoardRowMoreMenu(hover: hover, stackID: stack.id, isFocused: isFocusedRow) {
                    menu(stack)
                }
            }
        )
        .onHover { hover.set(stack.id, hovering: $0) }
        .id(stack.id)
        .onTapGesture {
            select(stack, orderedIDs: orderedIDs)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(stack, 0) })
        .accessibilityAction { select(stack, orderedIDs: orderedIDs) }
        .accessibilityAction(named: "Preview") { onOpen(stack, 0) }
        .draggable(workspace.dragPayload(for: stack.id, origin: origin, containerID: containerID)) {
            dragPreview(for: stack)
        }
        .contextMenu { menu(stack) }
    }

    private func select(_ stack: OrganizeStack, orderedIDs: [String]) {
        isFocused = true
        let flags = NSEvent.modifierFlags
        workspace.select(
            stackID: stack.id,
            orderedIDs: orderedIDs,
            extend: flags.contains(.shift),
            toggle: flags.contains(.command)
        )
    }

    private func dragPreview(for stack: OrganizeStack) -> some View {
        let count = workspace.selectedStackIDs.contains(stack.id) ? workspace.selectedStackIDs.count : 1
        return Label("\(count) item\(count == 1 ? "" : "s")", systemImage: "photo.on.rectangle.angled")
            .padding(8)
            .background(.regularMaterial, in: Capsule())
    }

    private func updateColumns(_ width: CGFloat) {
        columns = max(1, Int((width - 32 + 12) / (tileWidth + 12)))
    }

    private func handleKey(
        _ press: KeyPress,
        ordered: [OrganizeStack],
        orderedIDs: [String],
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        // Never board keys while a text field owns typing — Delete edits
        // the search text, it does not unsort the selection.
        guard !KeyboardTextFocus.isTypingInTextField() else { return .ignored }
        let current = workspace.focusedStackID.flatMap { orderedIDs.firstIndex(of: $0) }
        func move(_ delta: Int) -> KeyPress.Result {
            guard !orderedIDs.isEmpty else { return .handled }
            let target = min(max((current ?? -1) + delta, 0), orderedIDs.count - 1)
            let id = orderedIDs[target]
            workspace.select(stackID: id, orderedIDs: orderedIDs, extend: press.modifiers.contains(.shift), toggle: false)
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(id)
            }
            return .handled
        }
        let focusedStack = workspace.focusedStackID.flatMap { id in ordered.first { $0.id == id } }
        switch press.key {
        case .leftArrow:
            if mode == .list {
                if let stack = focusedStack, workspace.expandedStackIDs.contains(stack.id) {
                    workspace.setExpanded(stack.id, expanded: false)
                }
                return .handled
            }
            return move(-1)
        case .rightArrow:
            if mode == .list {
                if let stack = focusedStack, stack.isBurst, !workspace.expandedStackIDs.contains(stack.id) {
                    workspace.setExpanded(stack.id, expanded: true)
                }
                return .handled
            }
            return move(1)
        case .upArrow: return mode == .list ? move(-1) : move(-columns)
        case .downArrow: return mode == .list ? move(1) : move(columns)
        case .space:
            if let stack = focusedStack ?? workspace.selectedStackIDs.first.flatMap({ id in ordered.first { $0.id == id } }) {
                onOpen(stack, 0)
            }
            return .handled
        case .escape:
            workspace.selectedStackIDs.removeAll()
            return .handled
        default:
            // E toggles the focused burst's inline expansion.
            if press.modifiers.isEmpty, press.characters.lowercased() == "e",
               let stack = focusedStack, stack.isBurst {
                workspace.toggleExpanded(stack.id)
                return .handled
            }
            return onKey(press, orderedIDs)
        }
    }
}

/// Folder labels for tiles and the burst review header: where an item
/// physically lives relative to the scan root.
enum OrganizeFolderLabel {
    /// The item's folder under `rootPath` — e.g. "Transfer 3/100MSDCF" — or the
    /// root's own name for files sitting directly in it. Falls back to the
    /// folder's name when the item isn't under the root at all.
    static func title(forFolderPath folderPath: String, rootPath: String?) -> String {
        let folder = standardized(folderPath)
        let folderName = folder.isEmpty ? folderPath : (folder as NSString).lastPathComponent
        guard let root = standardizedRoot(rootPath) else { return folderName }
        if let sub = subfolder(forFolderPath: folderPath, rootPath: rootPath) {
            let rootName = (root as NSString).lastPathComponent
            return rootName.isEmpty ? sub : "\(rootName)/\(sub)"
        }
        if let range = folder.range(of: root, options: [.anchored, .caseInsensitive]),
           folder[range.upperBound...].isEmpty {
            return (root as NSString).lastPathComponent
        }
        return folderName
    }

    /// Path of the item's folder below `rootPath` ("100MSDCF", "A/B"), or nil
    /// when the item sits directly in the root or outside it.
    static func subfolder(forFolderPath folderPath: String, rootPath: String?) -> String? {
        guard let root = standardizedRoot(rootPath) else { return nil }
        let folder = standardized(folderPath)
        guard let range = folder.range(of: root, options: [.anchored, .caseInsensitive]) else { return nil }
        let rest = folder[range.upperBound...]
        guard !rest.isEmpty else { return nil }
        guard rest.hasPrefix("/") else { return nil }
        let relative = rest.dropFirst()
        return relative.isEmpty ? nil : String(relative)
    }

    /// `standardizedFileURL` walks the filesystem — realpath stats each
    /// component, and folder labels ask for the same few roots once per
    /// stack per render or search keystroke. Resolved strings are cached
    /// by input path, the same trade-off `OrganizeFile.pathKey` makes.
    nonisolated(unsafe) private static let standardizedCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4_096
        return cache
    }()

    private static func standardized(_ path: String) -> String {
        if let cached = standardizedCache.object(forKey: path as NSString) {
            return cached as String
        }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        standardizedCache.setObject(resolved as NSString, forKey: path as NSString)
        return resolved
    }

    private static func standardizedRoot(_ rootPath: String?) -> String? {
        guard let rootPath, !rootPath.isEmpty else { return nil }
        return standardized(rootPath)
    }
}

/// Finder-style frame selection for the burst filmstrip, kept as a pure
/// value type so the range rules are unit-testable without a view.
///
/// A plain click selects one frame and anchors there. ⇧-click re-ranges from
/// the anchor to the click. ⌘-click pins or unpins single frames — pins
/// survive later range moves. ⇧←/⇧→ move the range's open `edge`, so backing
/// the edge up shrinks the range again. The large preview always shows
/// `edge`: the end of the selection the user touched last.
struct FilmstripSelection: Equatable {
    /// Index the next ⇧-range starts from — set by the last plain or ⌘ click.
    private(set) var anchor = 0
    /// Index the preview shows: the end of the selection last touched.
    private(set) var edge = 0
    /// IDs contributed by the live anchor→edge range. The next range move
    /// replaces these wholesale, which is what lets a range shrink.
    private var ranged: Set<String> = []
    /// IDs ⌘-clicked in; they survive range moves until ⌘-clicked out.
    private var pinned: Set<String> = []

    /// `OrganizeItem.id` of every selected frame — `pinned ∪ ranged`.
    var selectedIDs: Set<String> { pinned.union(ranged) }

    /// Filmstrip positions of the selected frames inside `items`.
    func indexes(in items: [OrganizeItem]) -> Set<Int> {
        let ids = selectedIDs
        guard !ids.isEmpty else { return [] }
        return Set(items.indices.filter { ids.contains(items[$0].id) })
    }

    /// The selected frames in filmstrip order — the trash/split target.
    func selectedItems(in items: [OrganizeItem]) -> [OrganizeItem] {
        let ids = selectedIDs
        return items.filter { ids.contains($0.id) }
    }

    /// Plain click or arrow move: select that one frame and re-anchor.
    mutating func select(_ index: Int, in items: [OrganizeItem]) {
        guard !items.isEmpty else { reset(); return }
        let i = min(max(index, 0), items.count - 1)
        anchor = i
        edge = i
        ranged = [items[i].id]
        pinned = []
    }

    /// ⇧-click or ⇧-arrow: the anchor→index span becomes the range. Pinned
    /// frames stay selected even when they sit outside it.
    mutating func extendRange(to index: Int, in items: [OrganizeItem]) {
        guard !items.isEmpty else { return }
        let i = min(max(index, 0), items.count - 1)
        edge = i
        ranged = Set(items[min(anchor, i)...max(anchor, i)].map(\.id))
    }

    /// ⌘-click: pin an unselected frame or unpin a selected one. The current
    /// range is promoted into pins first — like Finder, a selection that
    /// existed before a ⌘-click survives the next ⇧-range instead of being
    /// replaced by it. The clicked frame becomes the anchor either way.
    mutating func toggle(_ index: Int, in items: [OrganizeItem]) {
        guard items.indices.contains(index) else { return }
        pinned.formUnion(ranged)
        ranged = []
        let id = items[index].id
        if pinned.contains(id) {
            pinned.remove(id)
        } else {
            pinned.insert(id)
        }
        anchor = index
        edge = index
    }

    /// ⇧←/⇧→: slide the open edge one step. The range part regrows or shrinks
    /// to the new edge; pinned frames are untouched.
    mutating func moveEdge(by delta: Int, in items: [OrganizeItem]) {
        extendRange(to: edge + delta, in: items)
    }

    /// The stack changed under the selection (trash, split, rescan): drop
    /// the IDs that left. When nothing selected survives, re-anchor on the
    /// frame that slid into the edge's slot so the preview keeps a footing.
    mutating func sanitize(in items: [OrganizeItem]) {
        guard !items.isEmpty else { reset(); return }
        edge = min(max(edge, 0), items.count - 1)
        anchor = min(max(anchor, 0), items.count - 1)
        let alive = Set(items.map(\.id))
        ranged.formIntersection(alive)
        pinned.formIntersection(alive)
        if selectedIDs.isEmpty {
            ranged = [items[edge].id]
        }
    }

    /// A different stack opened (or none did): start over at frame zero.
    mutating func reset() {
        anchor = 0
        edge = 0
        ranged = []
        pinned = []
    }
}

/// A high-resolution decode request: the frame's path plus the display
/// rotation it should be decoded with.
private struct HiResRequest: Equatable {
    var path: String
    var turns: Int
}

/// Full-size review of one burst at a time with a filmstrip of every frame.
/// The image area is the shared interactive canvas: click toggles zoom at the
/// pointer, drag pans while zoomed, `+`/`-`/`0`/`⌘1` step or reset zoom, and
/// a deeper decode swaps in once zoom passes 1.5×. `[`/`]`/`R` rotate the
/// whole stack at once. The filmstrip selects Finder-style — click,
/// ⇧-click for a range, ⌘-click to toggle — and right-click offers "Move
/// to Trash" and "Move to New Burst" for the whole selection when the
/// board supports them.
struct StackPreviewOverlay: View {
    let workspace: EventsWorkspace
    let stacks: [OrganizeStack]
    @Binding var stackID: String?
    /// Scan root used to show where each item lives ("Card/DCIM"); nil shows
    /// just the folder name (event boards have no single scan root).
    var rootPath: String? = nil
    /// The board's own event when the overlay moves stacks between events —
    /// not a valid target, so the chips, digit keys, and picker drop it.
    var excludedEventID: UUID? = nil
    /// Verb for the assign chips and picker — "Sort into" on an unsorted
    /// board, "Move to" on an event board.
    var assignVerb = "Sort into"
    let eventForStack: (OrganizeStack) -> SavedCameraEvent?
    let onAssign: (OrganizeStack, SavedCameraEvent) -> Void
    /// "New Event…" inside the picker: creates the event, then puts the
    /// previewed stack in it — the same target the chips assign.
    let onNewEvent: (OrganizeStack) -> Void
    /// Enables the right-click "Move to Trash" item on the frame and on each
    /// filmstrip thumbnail. The selection is passed in filmstrip order. Nil
    /// hides the item.
    var onTrashItems: (([OrganizeItem]) -> Void)? = nil
    /// Enables "Move to New Burst" on the frame and thumbnail menus: the
    /// selected frames leave this stack and stay split on later rescans.
    var onSplitItems: (([OrganizeItem]) -> Void)? = nil
    /// Display rotation recorded for a file, in quarter-turns clockwise.
    var orientationForFile: (OrganizeFile) -> Int = { _ in 0 }
    /// "Rotate Burst" — applies `delta` quarter-turns clockwise to every
    /// frame of the stack. Nil hides the menu and disables the keys.
    var onRotate: ((OrganizeStack, Int) -> Void)? = nil
    /// Frame the overlay opens on — inline expansions deep-link into a tap.
    var initialFrameIndex: Int = 0

    /// Frame selection state — `edge` is the frame the preview shows.
    @State private var selection = FilmstripSelection()
    @State private var videoPlayer: AVPlayer?
    /// nil = still checking, true = an AVPlayer is running, false = the codec
    /// can't play in-app and the poster stays on screen.
    @State private var videoPlayable: Bool?
    /// Shows a 360° clip on a look-around sphere instead of the flat
    /// equirectangular frame. Off by default; survives stepping between
    /// clips in one preview session.
    @State private var sphericalView = false
    @State private var image: CGImage?
    /// The frame+rotation a high-resolution decode was requested for — set
    /// the moment zoom passes fit so a stale frame never triggers a fetch.
    @State private var hiResRequest: HiResRequest?
    /// The decoded 4800 px frame paired with the request it belongs to.
    @State private var hiResImage: (key: HiResRequest, image: CGImage)?
    @State private var failed = false
    @State private var zoomCommand: PreviewZoomCommand?
    /// The canvas's zoom as a percentage, for the bottom bar's readout.
    @State private var zoomPercent = 100
    /// Face rows for the frame on screen, resolved off the main actor from
    /// the ArcFace catalog — independent of image loading, which never
    /// waits on them.
    @State private var facesOnFrame: [FaceRecord] = []
    /// nil means the file was never face-scanned — the inspector shows
    /// "Not scanned" and no boxes draw.
    @State private var framePhotoRecord: FacePhotoRecord?
    @State private var facePersonNames: [UUID: String] = [:]
    /// Roster for the tag picker's person list.
    @State private var rosterPeople: [FacePerson] = []
    /// The current frame's EXIF — read on a background queue after paint.
    @State private var frameMetadata: PhotoMetadata?
    @State private var frameMetadataLoaded = false
    /// The `i` inspector's slide-out state.
    @State private var inspectorVisible = false
    /// Markup mode: drags on the canvas draw a face box instead of panning.
    @State private var tagMode = false
    /// The photo's displayed rect in canvas coordinates, reported by the
    /// canvas — face boxes align to it.
    @State private var canvasImageFrame: CGRect = .zero
    @State private var tagRequest: FaceTagRequest?
    /// The header's Event… picker, owned outside its `ViewThatFits`.
    @State private var showEventPicker = false
    @FocusState private var isFocused: Bool

    private var stackIndex: Int? { stacks.firstIndex { $0.id == stackID } }
    private var stack: OrganizeStack? { stackIndex.map { stacks[$0] } }
    /// The previewed frame is the selection's open edge — the end a click or
    /// ⇧-arrow touched last.
    private var frameIndex: Int { selection.edge }
    private var item: OrganizeItem? {
        stack.map { $0.items[min(max(frameIndex, 0), $0.items.count - 1)] }
    }
    /// Quarter-turns recorded for the frame on screen right now.
    private var itemRotation: Int {
        item.map { orientationForFile($0.primary) } ?? 0
    }
    /// What the hi-res decode should be working on for the current frame.
    private var currentHiResKey: HiResRequest? {
        item.map { HiResRequest(path: $0.primary.path, turns: itemRotation) }
    }

    /// The frame the canvas should draw: the hi-res decode once it exists for
    /// the current item, scaled so its layout matches the base image exactly.
    private var displayImage: (image: CGImage, scale: CGFloat)? {
        if let hiResImage,
           hiResImage.key == currentHiResKey,
           hiResImage.image.width > (image?.width ?? 0) {
            let scale = image.map { CGFloat(hiResImage.image.width) / CGFloat($0.width) } ?? 1
            return (hiResImage.image, scale)
        }
        return image.map { ($0, CGFloat(1)) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            if let stack, let item {
                VStack(spacing: 12) {
                    header(stack: stack, item: item)
                    HStack(spacing: 12) {
                        previewPane(stack: stack, item: item)
                        if inspectorVisible {
                            FrameInspectorPanel(
                                item: item,
                                photoRecord: framePhotoRecord,
                                faces: facesOnFrame,
                                personNames: facePersonNames,
                                metadata: frameMetadata,
                                metadataLoaded: frameMetadataLoaded
                            )
                            .frame(width: 260)
                            // Explicit hierarchical levels: the panel is
                            // always on dark glass over the black backdrop.
                            .foregroundStyle(.white, .white.opacity(0.65), .white.opacity(0.45))
                            .glassEffect(.regular, in: .rect(cornerRadius: 18))
                            .environment(\.colorScheme, .dark)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: inspectorVisible)
                    bottomBar(stack: stack, item: item)
                }
                .padding(16)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            // Inline expansions deep-link to the tapped frame.
            if let stack { selection.select(initialFrameIndex, in: stack.items) }
        }
        .onKeyPress(phases: .down) { handle($0) }
        .onChange(of: stackID) { _, _ in
            selection.reset()
            if let stack { selection.select(0, in: stack.items) }
        }
        .onChange(of: stack?.items) { _, items in
            // Frames were trashed or split out: keep the selection to the
            // frames still here.
            selection.sanitize(in: items ?? [])
        }
        .onChange(of: item?.primary.path) { _, _ in
            // New frame: release the previous hi-res decode (the NSCache still
            // has it if the user zooms back) and stop any in-flight request.
            hiResImage = nil
            hiResRequest = nil
        }
        .onChange(of: itemRotation) { _, _ in
            // Rotate Burst turned the stack: drop the old hi-res decode and
            // re-request it at the new orientation if still zoomed in.
            hiResImage = nil
            if hiResRequest != nil { hiResRequest = currentHiResKey }
        }
        .onChange(of: tagRequest == nil) { _, closed in
            // The tag popover took the keyboard; hand it back so the
            // overlay's keys work again the moment it closes.
            if closed { isFocused = true }
        }
        .onChange(of: stackIndex) { old, new in
            // The current stack vanished — e.g. its remaining frames were
            // trashed or it was moved to an event. Show whatever slid into its
            // slot, or close when nothing is left.
            guard new == nil, stackID != nil else { return }
            if stacks.isEmpty {
                stackID = nil
            } else {
                stackID = stacks[min(max(old ?? 0, 0), stacks.count - 1)].id
            }
        }
        .task(id: "\(item?.primary.path ?? "")#\(itemRotation)") { await load() }
        .task(id: hiResRequest) { await loadHiRes() }
        // Face rows and EXIF ride their own tasks, detached from `load()` —
        // the cheap preview paint never waits on the catalog or ImageIO.
        .task(id: "\(item?.primary.pathKey ?? "")#\(workspace.facesRevision)") {
            await loadFaceInfo()
        }
        .task(id: item?.primary.path) { await loadMetadata() }
    }

    /// Back button, title and position, the assign chips, then the glass
    /// controls: Tag Face, Frame Info, Rotate, Open. Every action hands
    /// focus back to the overlay so its keys keep working. The shortcuts
    /// live in each control's help text and the Keyboard Shortcuts window.
    /// One row when it fits; in a narrow detail pane the controls drop to a
    /// second row instead of squeezing the title and chips.
    private func header(stack: OrganizeStack, item: OrganizeItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                headerTitle(stack: stack, item: item)
                Spacer(minLength: 8)
                headerActions(stack: stack, item: item)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    headerTitle(stack: stack, item: item)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    headerActions(stack: stack, item: item)
                }
            }
        }
        // Outside the `ViewThatFits`: a sheet inside a candidate only
        // exists while layout keeps picking that candidate.
        .eventPickerSheet(
            isPresented: $showEventPicker,
            workspace: workspace,
            verb: assignVerb,
            excludedEventID: excludedEventID,
            onPick: { assign(stack, to: $0) },
            onNewEvent: { onNewEvent(stack) }
        )
    }

    private func headerTitle(stack: OrganizeStack, item: OrganizeItem) -> some View {
        HStack(spacing: 12) {
            Button("Back to Board", systemImage: "chevron.backward") {
                stackID = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Back to the board (Esc or Space)")
            .environment(\.colorScheme, .dark)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.primary.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headerCaption(stack: stack, item: item))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            .layoutPriority(1)
            // The filled capsule is the one "this item is in" mark; the
            // quick-assign buttons beside it are glass buttons, never chips.
            if let event = eventForStack(stack) {
                EventChip(event: event, isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly)
                    .help("In \(workspace.eventTitle(event))")
                    .accessibilityLabel("In \(workspace.eventTitle(event))")
            }
        }
    }

    private func headerActions(stack: OrganizeStack, item: OrganizeItem) -> some View {
        HStack(spacing: 12) {
            EventAssignControls(
                workspace: workspace,
                verb: assignVerb,
                excludedEventID: excludedEventID,
                currentEventID: currentEventID(for: stack),
                pickerPresented: $showEventPicker,
                onAssign: { assign(stack, to: $0) },
                onNewEvent: { onNewEvent(stack) }
            )
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if item.kind != .video {
                        PreviewGlassToggle(
                            title: "Tag Face",
                            systemImage: "person.crop.rectangle.badge.plus",
                            isOn: tagMode,
                            help: tagMode ? "Stop drawing face boxes (T)" : "Draw a box on the photo to tag a face (T)"
                        ) {
                            tagMode.toggle()
                            isFocused = true
                        }
                    }
                    PreviewGlassToggle(
                        title: "Frame Info",
                        systemImage: "info",
                        isOn: inspectorVisible,
                        help: "Frame info — people, capture time, camera, file (I)"
                    ) {
                        inspectorVisible.toggle()
                        isFocused = true
                    }
                    if onRotate != nil {
                        Menu {
                            Button("Rotate All 90° Left", systemImage: "rotate.left") { rotate(by: -1); isFocused = true }
                            Button("Rotate All 180°", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { rotate(by: 2); isFocused = true }
                            Button("Rotate All 90° Right", systemImage: "rotate.right") { rotate(by: 1); isFocused = true }
                        } label: {
                            Label("Rotate Burst", systemImage: "rotate.right")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(DisplayRotation.rotatableFiles(in: stack).isEmpty)
                        .help("Rotate every frame in this burst together ( [ ] or R / Shift-R ). Display-only — originals are never rewritten.")
                    }
                    Menu {
                        LazyContextMenu { OpenInAppMenuItems(urls: [item.primary.url]) }
                    } label: {
                        Label("Open In", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Open \(item.primary.name) in another app (O opens it in \(DJIStudio.isOffered(for: [item.primary.url], resolver: WorkspaceBundleResolver.shared) ? DJIStudio.name : "Photomator"))")
                }
            }
            .controlSize(.large)
            .environment(\.colorScheme, .dark)
        }
    }

    /// The event every frame of the stack is already in, if there is one —
    /// its quick-assign button shows as current. A partly sorted stack has
    /// none, so its buttons can still finish the job.
    private func currentEventID(for stack: OrganizeStack) -> UUID? {
        let assigned = workspace.assignedEvent(for: stack)
        return assigned.mixed ? nil : assigned.event?.id
    }

    private func headerCaption(stack: OrganizeStack, item: OrganizeItem) -> String {
        let selectedCount = selection.selectedItems(in: stack.items).count
        return "\(item.captureDate.formatted(date: .abbreviated, time: .standard)) · frame \(min(frameIndex, stack.items.count - 1) + 1) of \(stack.items.count)\(selectedCount > 1 ? " · \(selectedCount) selected" : "") · item \((stackIndex ?? 0) + 1) of \(stacks.count) · \(OrganizeFolderLabel.title(forFolderPath: item.primary.folderPath, rootPath: rootPath))"
    }

    /// Filmstrip and zoom on one floating glass layer under the photo.
    @ViewBuilder
    private func bottomBar(stack: OrganizeStack, item: OrganizeItem) -> some View {
        let showsFilmstrip = stack.items.count > 1
        let showsZoom = item.kind != .video && displayImage != nil
        if showsFilmstrip || showsZoom {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    if showsFilmstrip {
                        filmstrip(stack)
                            .padding(6)
                            .frame(maxWidth: CGFloat(stack.items.count) * 102 + 6)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
                    if showsZoom {
                        PreviewZoomControls(zoomPercent: zoomPercent) { command in
                            zoomCommand = command
                            isFocused = true
                        }
                    }
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    /// The zoomable still canvas — or the video pane — plus the face boxes
    /// keyed to the canvas's reported image frame and the floating tag
    /// picker. Face rows are read only from the catalog; nothing here waits
    /// on them before the image paints.
    private func previewPane(stack: OrganizeStack, item: OrganizeItem) -> some View {
        Group {
            if item.kind == .video {
                videoPane(item)
            } else {
                stillPane(item)
            }
        }
        .id(item.primary.path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if item.kind != .video {
                FaceBoxesOverlay(
                    faces: facesOnFrame,
                    personNames: facePersonNames,
                    rotation: itemRotation,
                    imageFrame: canvasImageFrame,
                    onConfirm: { workspace.confirmFace($0.id) },
                    onTag: { face, rect in
                        tagRequest = FaceTagRequest(target: .face(face.id), anchor: rect)
                    }
                )
            }
        }
        .clipped()
        .popover(
            item: $tagRequest,
            attachmentAnchor: .rect(.rect(tagRequest?.anchor ?? .zero)),
            arrowEdge: .bottom
        ) { _ in
            FaceTagPicker(
                people: rosterPeople,
                onPick: { person in applyTag(person) },
                onCreate: { name in
                    if let person = workspace.createRosterPerson(named: name) {
                        applyTag(person)
                    }
                },
                onCancel: { tagRequest = nil }
            )
        }
        .contextMenu {
            LazyContextMenu { frameContextMenu(stack, index: min(max(frameIndex, 0), stack.items.count - 1)) }
        }
    }

    private func stillPane(_ item: OrganizeItem) -> InteractivePreviewCanvas {
        InteractivePreviewCanvas(
            image: displayImage?.image,
            isLoading: !failed,
            imageScale: displayImage?.scale ?? 1,
            file: item.primary.url,
            unavailableTitle: "No Preview",
            unavailableDescription: "Camera Toolkit could not decode a preview for this file.",
            zoomCommand: $zoomCommand,
            onZoomChange: { zoom in
                zoomPercent = Int(zoom * 100)
                if zoom > 1.5 {
                    hiResRequest = currentHiResKey
                }
            },
            markupActive: $tagMode,
            onMarkupRect: { rect in handleMarkupRect(rect) },
            onImageFrameChange: { frame in canvasImageFrame = frame },
            showsZoomControls: false
        )
    }

    /// Real playback via AVKit's `AVPlayerView` (wrapped by
    /// `VideoPreviewPane` — SwiftUI's `VideoPlayer` aborts this binary in
    /// `_AVKit_SwiftUI` metadata init). A playable clip gets the standard
    /// player chrome; a clip the probe can't prove playable keeps its
    /// poster with a note.
    private func videoPane(_ item: OrganizeItem) -> some View {
        let dji360 = DJI360PreviewKind(item: item)
        let studioAvailable = dji360 != nil
            && DJIStudio.isOffered(for: [item.primary.url], resolver: WorkspaceBundleResolver.shared)
        return ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(videoPlayer == nil ? 1 : 0)
            }
            if let videoPlayer {
                if sphericalView, dji360 == .proxy {
                    SphericalVideoView(player: videoPlayer)
                } else {
                    VideoPreviewPane(player: videoPlayer)
                }
            } else if videoPlayable == false {
                ContentUnavailableView {
                    Label("Can’t Play In-App", systemImage: "video.slash")
                } description: {
                    Text("This clip’s format doesn’t play here. Open it in another app, or find it in Finder.")
                } actions: {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.primary.url])
                        isFocused = true
                    }
                    if studioAvailable {
                        Button("Open in \(DJIStudio.name)") {
                            DJIStudio.open([item.primary.url])
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Open in Photomator") {
                            PhotomatorLauncher.open(item.files.map(\.url))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .environment(\.colorScheme, .dark)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .top) {
            if let dji360, videoPlayer != nil {
                DJI360PreviewBanner(
                    kind: dji360,
                    studioAvailable: studioAvailable,
                    sphericalView: $sphericalView,
                    onOpenInStudio: { DJIStudio.open([item.primary.url]) }
                )
                .padding(.top, 12)
            }
        }
        .contextMenu {
            if let stack {
                LazyContextMenu { frameContextMenu(stack, index: min(max(frameIndex, 0), stack.items.count - 1)) }
            }
        }
        .onDisappear {
            videoPlayer?.pause()
        }
    }

    private func filmstrip(_ stack: OrganizeStack) -> some View {
        let selectedIndexes = selection.indexes(in: stack.items)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, frame in
                        let isSelected = selectedIndexes.contains(index)
                        let isCurrent = index == frameIndex
                        let shape = RoundedRectangle(cornerRadius: BoardMetrics.frameRadius, style: .continuous)
                        let highlight = Color(nsColor: .selectedContentBackgroundColor)
                        TileThumbnail(url: frame.primary.url, kind: frame.kind, pointSize: 96, orientation: orientationForFile(frame.primary))
                            .frame(width: 96, height: 64)
                            .clipShape(shape)
                            .overlay {
                                shape.fill(isSelected && !isCurrent ? highlight.opacity(0.25) : .clear)
                            }
                            .overlay {
                                shape.strokeBorder(
                                    isCurrent ? highlight : (isSelected ? highlight.opacity(0.7) : .clear),
                                    lineWidth: isCurrent ? 2.5 : 1.5
                                )
                            }
                            .contentShape(shape)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Frame \(index + 1) of \(stack.items.count), \(frame.primary.name)")
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { selectFrame(index, in: stack) }
                            .id(index)
                            .onTapGesture { selectFrame(index, in: stack) }
                            .contextMenu { LazyContextMenu { frameContextMenu(stack, index: index) } }
                    }
                }
            }
            .frame(height: 70)
            .onChange(of: frameIndex) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    /// Filmstrip click with Finder modifiers: ⇧ re-ranges from the anchor,
    /// ⌘ toggles a pin, plain click selects the one frame and anchors there.
    private func selectFrame(_ index: Int, in stack: OrganizeStack) {
        isFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.toggle(index, in: stack.items)
        } else if flags.contains(.shift) {
            selection.extendRange(to: index, in: stack.items)
        } else {
            selection.select(index, in: stack.items)
        }
    }

    /// Right-click aims at the whole selection when the clicked frame is part
    /// of it, otherwise at just that frame — Finder's rule.
    @ViewBuilder
    private func frameContextMenu(_ stack: OrganizeStack, index: Int) -> some View {
        let item = stack.items[index]
        let targets = selection.selectedIDs.contains(item.id) ? selection.selectedItems(in: stack.items) : [item]
        if onRotate != nil {
            Menu("Rotate Burst") {
                Button("Rotate All 90° Left") { rotate(by: -1) }
                Button("Rotate All 180°") { rotate(by: 2) }
                Button("Rotate All 90° Right") { rotate(by: 1) }
            }
            .disabled(DisplayRotation.rotatableFiles(in: stack).isEmpty)
        }
        if let onSplitItems, targets.count < stack.items.count {
            Button(targets.count > 1 ? "Move \(targets.count) Frames to New Burst" : "Move Frame to New Burst") {
                if !selection.selectedIDs.contains(item.id) { selection.select(index, in: stack.items) }
                onSplitItems(targets)
            }
        }
        if let onTrashItems {
            Button(targets.count > 1 ? "Move \(targets.count) Frames to Trash…" : "Move to Trash…") {
                if !selection.selectedIDs.contains(item.id) { selection.select(index, in: stack.items) }
                onTrashItems(targets)
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Never overlay keys while a text field owns typing — Delete edits
        // the field, it does not trash filmstrip frames.
        guard !KeyboardTextFocus.isTypingInTextField() else { return .ignored }
        // Close always works, even if the stack vanished under us — but a
        // tag picker or draw mode peels off first.
        if press.key == .escape {
            if tagRequest != nil {
                tagRequest = nil
            } else if tagMode {
                tagMode = false
            } else {
                stackID = nil
            }
            return .handled
        }
        if press.key == .space {
            if item?.kind == .video {
                // Space plays/pauses instead of closing the video preview.
                if let videoPlayer {
                    if videoPlayer.timeControlStatus == .playing {
                        videoPlayer.pause()
                    } else {
                        videoPlayer.play()
                    }
                }
            } else {
                stackID = nil
            }
            return .handled
        }
        guard let stack, let index = stackIndex else { return .ignored }
        switch press.key {
        case .leftArrow:
            // ⇧← shrinks or regrows the range from its open edge; a plain ←
            // steps the current frame and collapses the selection to it.
            if press.modifiers.contains(.shift) {
                selection.moveEdge(by: -1, in: stack.items)
            } else {
                selection.select(frameIndex - 1, in: stack.items)
            }
        case .rightArrow:
            if press.modifiers.contains(.shift) {
                selection.moveEdge(by: 1, in: stack.items)
            } else {
                selection.select(frameIndex + 1, in: stack.items)
            }
        case .delete, .deleteForward:
            guard let onTrashItems else { return .ignored }
            let targets = selection.selectedItems(in: stack.items)
            guard !targets.isEmpty else { return .ignored }
            onTrashItems(targets)
        case .upArrow:
            if index > 0 { stackID = stacks[index - 1].id }
        case .downArrow:
            if index + 1 < stacks.count { stackID = stacks[index + 1].id }
        default:
            // Unmodified and Shift-modified keys only: ⌘0/⌘1 are handled by
            // the canvas's own buttons, and ⌘O should stay free.
            if press.modifiers.isEmpty || press.modifiers == .shift {
                switch press.characters {
                case "+", "=":
                    zoomCommand = .zoomIn
                    return .handled
                case "-", "_":
                    zoomCommand = .zoomOut
                    return .handled
                case "0":
                    zoomCommand = .fit
                    return .handled
                case "]", "}":
                    rotate(by: 1)
                    return .handled
                case "[", "{":
                    rotate(by: -1)
                    return .handled
                case "r":
                    rotate(by: 1)
                    return .handled
                case "R":
                    rotate(by: -1)
                    return .handled
                case "i", "I":
                    inspectorVisible.toggle()
                    return .handled
                case "t", "T":
                    if item?.kind != .video {
                        tagMode.toggle()
                    }
                    return .handled
                default:
                    break
                }
            }
            if press.characters.lowercased() == "o", let item {
                // A 360 clip goes to DJI Studio when it's installed; every
                // other file, as before, to Photomator.
                if !DJIStudio.open([item.primary.url]) {
                    PhotomatorLauncher.open(item.files.map(\.url))
                }
                return .handled
            }
            guard press.modifiers.isEmpty,
                  let digit = press.characters.first?.wholeNumberValue,
                  (1...3).contains(digit) else { return .ignored }
            let recents = workspace.assignableRecents(excluding: excludedEventID)
            guard digit <= recents.count else { return .ignored }
            assign(stack, to: recents[digit - 1])
        }
        return .handled
    }

    private func assign(_ stack: OrganizeStack, to event: SavedCameraEvent) {
        let index = stackIndex
        onAssign(stack, event)
        if let index, index + 1 < stacks.count {
            stackID = stacks[index + 1].id
        }
        isFocused = true
    }

    /// One action turns the whole stack: every still plus JPEG companions,
    /// via the board's `onRotate` callback.
    private func rotate(by delta: Int) {
        guard let stack, let onRotate else { return }
        onRotate(stack, delta)
    }

    private func load() async {
        guard let item else { return }
        let url = item.primary.url
        let orientation = itemRotation
        failed = false
        videoPlayer?.pause()
        videoPlayer = nil
        videoPlayable = nil
        if let full = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 2_400, orientation: orientation) {
            image = full
        } else {
            image = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 1_280, orientation: orientation)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 768, orientation: orientation)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 384, orientation: orientation)
            if image == nil {
                // Cheap paint first: the filmstrip bucket reads only the
                // embedded thumbnail on RAW, so it lands long before the
                // full-size read on slow storage. Both run ahead of tile
                // decodes; each result paints only over a smaller image.
                await withTaskGroup(of: CGImage?.self) { group in
                    group.addTask {
                        await TileImageLoader.shared.image(for: url, maximumPixelSize: 384, orientation: orientation, priority: .veryHigh)
                    }
                    group.addTask {
                        await TileImageLoader.shared.image(for: url, maximumPixelSize: 2_400, orientation: orientation, priority: .high)
                    }
                    for await decoded in group {
                        guard !Task.isCancelled, let decoded else { continue }
                        if decoded.width > (image?.width ?? 0) {
                            image = decoded
                        }
                    }
                }
            } else if let full = await TileImageLoader.shared.image(for: url, maximumPixelSize: 2_400, orientation: orientation, priority: .high), !Task.isCancelled {
                image = full
            }
            if !Task.isCancelled, image == nil {
                failed = true
            }
        }
        if item.kind == .video {
            // The poster is already up; now prove the clip can actually
            // play before handing it to AVPlayer. The probe is bounded, so
            // an unopenable codec or a stalled source ends on the
            // can't-play affordances instead of a dead spinner. An Osmo 360
            // OSV plays its stitched LRF proxy when it has one.
            let player = await VideoPreviewSupport.readyPlayer(for: DJI360Media.playbackFile(for: item).url)
            guard !Task.isCancelled else { return }
            if let player {
                videoPlayable = true
                videoPlayer = player
                player.play()
            } else {
                videoPlayable = false
            }
        }
        guard let stack, !Task.isCancelled else { return }
        for offset in [1, 2] where frameIndex + offset < stack.items.count {
            let next = stack.items[frameIndex + offset].primary
            let nextOrientation = orientationForFile(next)
            Task.detached(priority: .utility) {
                _ = await TileImageLoader.shared.image(for: next.url, maximumPixelSize: 2_400, orientation: nextOrientation, priority: .low)
            }
        }
    }

    /// Zooming past fit asks for the 4800 px decode of the current frame at
    /// its current rotation. The swap is invisible: `displayImage` scales the
    /// bigger image to the exact point size the base decode was shown at.
    private func loadHiRes() async {
        guard let request = hiResRequest, request == currentHiResKey else { return }
        let url = URL(filePath: request.path, directoryHint: .notDirectory)
        if let cached = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 4_800, orientation: request.turns) {
            guard !Task.isCancelled else { return }
            storeHiRes(cached, key: request)
            return
        }
        if let loaded = await TileImageLoader.shared.image(for: url, maximumPixelSize: 4_800, orientation: request.turns, priority: .high), !Task.isCancelled {
            storeHiRes(loaded, key: request)
        }
    }

    private func storeHiRes(_ loaded: CGImage, key: HiResRequest) {
        // A decode that isn't larger than what's on screen adds nothing — the
        // source was smaller than the bucket.
        if let image, loaded.width <= image.width { return }
        hiResImage = (key, loaded)
    }

    // MARK: - Faces and frame metadata

    /// Reads the frame's face rows off the main actor. Lookup is by file
    /// identity (name + size + modified second) — the same key the scan
    /// attributes faces to — so boxes survive the file moving into an
    /// event folder. A file that was never scanned simply yields no rows;
    /// no detection ever runs here.
    private func loadFaceInfo() async {
        guard let item else {
            facesOnFrame = []
            framePhotoRecord = nil
            facePersonNames = [:]
            return
        }
        let file = item.primary
        let store = workspace.faceStore
        let result = await Task.detached(priority: .userInitiated) {
            () -> (FacePhotoRecord?, [FaceRecord], [UUID: String], [FacePerson]) in
            let records = (try? store.photos(
                fileName: file.name,
                byteCount: file.size,
                modifiedAt: file.modifiedAt
            )) ?? []
            let photo = records.first { $0.pathKey == file.pathKey }
                ?? records.max { $0.scanGrade < $1.scanGrade }
            let faces = (try? store.faces(
                fileName: file.name,
                byteCount: file.size,
                modifiedAt: file.modifiedAt,
                preferredPathKey: file.pathKey
            )) ?? []
            var names: [UUID: String] = [:]
            for id in Set(faces.compactMap(\.personID)) {
                if let person = try? store.person(id) {
                    // A "looks like" row wears its target's live name.
                    names[id] = person.suggestedPersonName ?? person.name
                }
            }
            return (photo, faces, names, (try? store.rosterPeople()) ?? [])
        }.value
        guard !Task.isCancelled else { return }
        framePhotoRecord = result.0
        facesOnFrame = result.1
        facePersonNames = result.2
        rosterPeople = result.3
    }

    /// EXIF for the inspector, read through ImageIO properties on a utility
    /// queue — never on the paint path.
    private func loadMetadata() async {
        guard let item else {
            frameMetadata = nil
            frameMetadataLoaded = false
            return
        }
        frameMetadata = nil
        frameMetadataLoaded = false
        let url = item.primary.url
        let isStill = item.kind == .raw || item.kind == .photo
        let read = await Task.detached(priority: .utility) {
            isStill ? PhotoMetadataReader.metadata(for: url) : PhotoMetadata()
        }.value
        guard !Task.isCancelled else { return }
        frameMetadata = read
        frameMetadataLoaded = true
    }

    /// A markup drag ended: the rect the owner drew (in the rotated display
    /// space) becomes a stored-space box plus an aligned crop, and the tag
    /// picker opens at the drawn spot.
    private func handleMarkupRect(_ normalized: CGRect) {
        guard item != nil else { return }
        let storedRect = FaceBoxProjection.unrotatedTopLeftRect(normalized, quarterTurnsCW: itemRotation)
        let box = FaceBoxProjection.box(ofTopLeftRect: storedRect)
        var crop: Data?
        if let decoded = displayImage?.image {
            let displayedBox = CGRect(
                x: normalized.minX,
                y: 1 - normalized.minY - normalized.height,
                width: normalized.width,
                height: normalized.height
            )
            if let cropped = FaceCropRenderer.boxCrop(decoded, box: displayedBox) {
                crop = FaceImageEncoding.jpegData(cropped)
            }
        }
        let anchor = CGRect(
            x: canvasImageFrame.minX + normalized.minX * canvasImageFrame.width,
            y: canvasImageFrame.minY + normalized.minY * canvasImageFrame.height,
            width: normalized.width * canvasImageFrame.width,
            height: normalized.height * canvasImageFrame.height
        )
        tagRequest = FaceTagRequest(target: .drawnBox(box, crop: crop), anchor: anchor)
    }

    /// Applies the picker's choice: an existing face is assigned+confirmed;
    /// a drawn box becomes a new confirmed catalog face. Both go through
    /// the store — confirmed faces stay frozen, photos are never rewritten.
    private func applyTag(_ person: FacePerson) {
        guard let request = tagRequest else { return }
        switch request.target {
        case .face(let faceID):
            workspace.tagFace(faceID, as: person.id)
        case .drawnBox(let box, let crop):
            if let item {
                workspace.tagDrawnFace(
                    on: item.primary,
                    box: box,
                    personID: person.id,
                    takenAt: item.captureDate,
                    crop: crop
                )
            }
        }
        tagRequest = nil
    }
}

/// An icon-only glass button that shows its on state the native way —
/// prominent (accent-filled) glass while on, plain glass while off.
private struct PreviewGlassToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Group {
            if isOn {
                Button(title, systemImage: systemImage, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
            } else {
                Button(title, systemImage: systemImage, action: action)
                    .buttonStyle(.glass)
            }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
