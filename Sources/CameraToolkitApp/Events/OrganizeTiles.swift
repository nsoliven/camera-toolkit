import AppKit
import AVFoundation
import CameraToolkitCore
import SwiftUI

enum EventPalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .brown, .cyan, .mint]

    static func color(for id: UUID) -> Color {
        var hash = 0
        for scalar in id.uuidString.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return colors[hash % colors.count]
    }
}

struct EventChip: View {
    let event: SavedCameraEvent
    var number: Int?
    /// Resolved private flag. Pass it when the event's own `storagePolicy`
    /// can be nil — a subevent inherits the lock from a private parent.
    var isPrivate: Bool?

    var body: some View {
        HStack(spacing: 4) {
            if let number {
                Text("\(number)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            }
            if isPrivate ?? (event.resolvedStoragePolicy == .archiveOnly) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
            }
            Text(event.name)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(EventPalette.color(for: event.id), in: Capsule())
    }
}

/// A named person detected on an event's photos. Shares the event-chip
/// capsule look; the color is stable per person.
struct PersonChip: View {
    let person: FacePerson

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill")
                .font(.caption2)
            Text(person.name)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(EventPalette.color(for: person.id), in: Capsule())
        .help("\(person.faceCount) detection\(person.faceCount == 1 ? "" : "s") in this event")
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
        case .inPrivate: "lock"
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
    let pixelSize: Int
    /// Display rotation in quarter-turns clockwise; part of the task id so a
    /// "Rotate Burst" change re-decodes this tile without a rescan.
    var orientation: Int = 0

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: symbol)
                    .font(.system(size: 26))
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
    }

    private var symbol: String {
        switch kind {
        case .video: "video"
        case .other: "doc"
        default: "photo"
        }
    }
}

struct StackTileView: View {
    let stack: OrganizeStack
    let width: CGFloat
    let isSelected: Bool
    let isFocused: Bool
    let event: SavedCameraEvent?
    /// Resolved private flag for `event` — a subevent can inherit the lock
    /// from a private parent, so the caller resolves it.
    var isPrivate: Bool? = nil
    let isMixed: Bool
    let isDimmed: Bool
    let badge: TileLocationBadge?
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
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                TileThumbnail(url: stack.coverItem.primary.url, kind: stack.kind, pixelSize: Int(width * 2), orientation: orientation)
                    .frame(width: width, height: width * 2 / 3)
                    .clipped()
                VStack {
                    HStack(spacing: 4) {
                        if let badge {
                            Label(badge.label, systemImage: badge.symbol)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if stack.isBurst {
                            Button {
                                (onExpand ?? onOpen)?()
                            } label: {
                                Label("\(stack.items.count)", systemImage: "square.stack.3d.down.right.fill")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .help("Show every frame of this burst in the board")
                        } else if stack.kind == .video {
                            Button {
                                (onPlay ?? onOpen)?()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.caption)
                                    .padding(5)
                                    .background(.black.opacity(0.6), in: Circle())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .help("Play this video")
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let event {
                            EventChip(event: event, isPrivate: isPrivate)
                        }
                        if isMixed {
                            Label("Mixed", systemImage: "square.split.2x1")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(6)
            }
            .frame(width: width, height: width * 2 / 3)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 3 : (isFocused ? 2 : 0.5))
            }

            HStack(spacing: 6) {
                Text(stack.captureDate.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
        }
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(originFolder.map { "In \($0)" } ?? stack.coverItem.primary.name)
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isFocused { return .accentColor.opacity(0.6) }
        return .primary.opacity(0.1)
    }

    private var title: String {
        if let label = stack.burstLabel, stack.isBurst {
            return "\(label) · \(stack.items.count) frames"
        }
        if stack.isBurst {
            return "Burst · \(stack.items.count) frames"
        }
        return stack.coverItem.primary.name
    }
}

/// Header of one board section — a day, folder, kind, or event group. The
/// chevron collapses the whole group so hundreds of bursts stay scannable.
struct BoardGroupHeader: View {
    let group: OrganizeBoardGroup
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand this group" : "Collapse this group")
            if let symbol = group.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(group.title)
                .font(.title3.weight(.semibold))
            Text(group.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select", action: onSelect)
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(group.stacks.isEmpty || isCollapsed)
                .help("Select everything in this group")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// One row of the board's list mode — the same stack as a tile, compressed
/// into a single line so hundreds of bursts fit on screen.
struct StackRowView: View {
    let stack: OrganizeStack
    let isSelected: Bool
    let isFocused: Bool
    let isExpanded: Bool
    let event: SavedCameraEvent?
    var isPrivate: Bool? = nil
    let isMixed: Bool
    let isDimmed: Bool
    let badge: TileLocationBadge?
    var originFolder: String? = nil
    var onExpand: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            TileThumbnail(url: stack.coverItem.primary.url, kind: stack.kind, pixelSize: 176)
                .frame(width: 88, height: 56)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if stack.isBurst {
                        Image(systemName: "square.stack.3d.down.right.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isMixed {
                        Label("Mixed", systemImage: "square.split.2x1")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if let badge {
                        Label(badge.label, systemImage: badge.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(stack.captureDate.formatted(date: .abbreviated, time: .shortened))
                    if let originFolder {
                        Text("·")
                        Text(originFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("·")
                    Text(stack.byteCount.formattedBytes)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if let event {
                EventChip(event: event, isPrivate: isPrivate)
            }
            if stack.isBurst {
                Button {
                    (onExpand ?? onOpen)?()
                } label: {
                    Label("\(stack.items.count)", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse this burst" : "Show every frame in the board")
            } else if stack.kind == .video {
                Button {
                    (onPlay ?? onOpen)?()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play this video")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : (isFocused ? Color.accentColor.opacity(0.07) : Color.clear))
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(originFolder.map { "In \($0)" } ?? stack.coverItem.primary.name)
    }

    private var title: String {
        if let label = stack.burstLabel, stack.isBurst {
            return "\(label) · \(stack.items.count) frames"
        }
        if stack.isBurst {
            return "Burst · \(stack.items.count) frames"
        }
        return stack.coverItem.primary.name
    }
}

/// Every frame of a burst laid out inside the board — what the count badge
/// expands into. Tapping a frame opens the full preview at that frame.
struct BurstExpansionView: View {
    let stack: OrganizeStack
    /// Edge length of the small frame thumbnails.
    var frameSize: CGFloat = 104
    var onOpenFrame: ((Int) -> Void)? = nil
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .foregroundStyle(.secondary)
                Text(stack.burstLabel.map { "\($0) · \(stack.items.count) frames" } ?? "\(stack.items.count) frames")
                    .font(.callout.weight(.semibold))
                Text("\(stack.captureDate.formatted(date: .omitted, time: .shortened)) – \(stack.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button {
                    onCollapse?()
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: frameSize, maximum: frameSize * 1.4), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, frame in
                    TileThumbnail(url: frame.primary.url, kind: frame.kind, pixelSize: Int(frameSize * 2))
                        .frame(width: frameSize, height: frameSize * 2 / 3)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if frame.kind == .video {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                    .padding(3)
                                    .background(.black.opacity(0.6), in: Circle())
                                    .foregroundStyle(.white)
                                    .padding(3)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .onTapGesture { onOpenFrame?(index) }
                        .help(frame.primary.name)
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
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

    /// Stacks the board is actually showing — collapsed groups hide theirs.
    private var visibleGroups: [OrganizeBoardGroup] {
        groups.map { group in
            guard workspace.collapsedGroupIDs.contains(group.id) else { return group }
            return OrganizeBoardGroup(id: group.id, title: group.title, symbol: group.symbol, stacks: [])
        }
    }

    var body: some View {
        let ordered = visibleGroups.flatMap(\.stacks)
        let orderedIDs = ordered.map(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                if mode == .tiles {
                    tileBoard(orderedIDs: orderedIDs)
                } else {
                    listBoard(orderedIDs: orderedIDs)
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKey(press, ordered: ordered, orderedIDs: orderedIDs, proxy: proxy)
            }
            .onAppear { isFocused = true }
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
            spacing: 14,
            pinnedViews: [.sectionHeaders]
        ) {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.stacks) { stack in
                        if workspace.expandedStackIDs.contains(stack.id), stack.isBurst {
                            expansion(stack)
                                .gridCellColumns(max(columns, 1))
                        } else {
                            tile(stack, orderedIDs: orderedIDs)
                        }
                    }
                } header: {
                    BoardGroupHeader(
                        group: group,
                        isCollapsed: workspace.collapsedGroupIDs.contains(group.id),
                        onToggleCollapse: {
                            workspace.setGroupCollapsed(group.id, collapsed: !workspace.collapsedGroupIDs.contains(group.id))
                        },
                        onSelect: {
                            workspace.selectStacks(group.stacks.map(\.id))
                            isFocused = true
                        }
                    )
                }
            }
        }
        .padding(16)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateColumns(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
            }
        }
    }

    private func listBoard(orderedIDs: [String]) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.stacks) { stack in
                        row(stack, orderedIDs: orderedIDs)
                        if workspace.expandedStackIDs.contains(stack.id), stack.isBurst {
                            expansion(stack, compact: true)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 108)
                    }
                } header: {
                    BoardGroupHeader(
                        group: group,
                        isCollapsed: workspace.collapsedGroupIDs.contains(group.id),
                        onToggleCollapse: {
                            workspace.setGroupCollapsed(group.id, collapsed: !workspace.collapsedGroupIDs.contains(group.id))
                        },
                        onSelect: {
                            workspace.selectStacks(group.stacks.map(\.id))
                            isFocused = true
                        }
                    )
                }
            }
        }
        .padding(.vertical, 8)
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
            event: assigned.event,
            isPrivate: assigned.event.map { workspace.resolvedPolicy(for: $0) == .archiveOnly },
            isMixed: assigned.mixed,
            isDimmed: isDimmed(stack),
            badge: badge(stack),
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
        .draggable(workspace.dragPayload(for: stack.id, origin: origin, containerID: containerID)) {
            dragPreview(for: stack)
        }
        .contextMenu { menu(stack) }
    }

    private func row(_ stack: OrganizeStack, orderedIDs: [String]) -> some View {
        let assigned = eventForStack(stack)
        return StackRowView(
            stack: stack,
            isSelected: workspace.selectedStackIDs.contains(stack.id),
            isFocused: workspace.focusedStackID == stack.id,
            isExpanded: workspace.expandedStackIDs.contains(stack.id),
            event: assigned.event,
            isPrivate: assigned.event.map { workspace.resolvedPolicy(for: $0) == .archiveOnly },
            isMixed: assigned.mixed,
            isDimmed: isDimmed(stack),
            badge: badge(stack),
            originFolder: OrganizeFolderLabel.title(
                forFolderPath: stack.coverItem.primary.folderPath,
                rootPath: rootPath
            ),
            onExpand: { workspace.toggleExpanded(stack.id) },
            onPlay: { onOpen(stack, 0) },
            onOpen: { onOpen(stack, 0) }
        )
        .id(stack.id)
        .onTapGesture {
            select(stack, orderedIDs: orderedIDs)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(stack, 0) })
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

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
    @State private var image: CGImage?
    /// The frame+rotation a high-resolution decode was requested for — set
    /// the moment zoom passes fit so a stale frame never triggers a fetch.
    @State private var hiResRequest: HiResRequest?
    /// The decoded 4800 px frame paired with the request it belongs to.
    @State private var hiResImage: (key: HiResRequest, image: CGImage)?
    @State private var failed = false
    @State private var zoomCommand: PreviewZoomCommand?
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

    private var hintText: String {
        if item?.kind == .video {
            var text = "Space play/pause · ↑ ↓ items · 1–3 sort · O open"
            if onTrashItems != nil { text += " · ⌫/right-click trash" }
            return text + " · Esc close"
        }
        var text = "← → frames · ⇧← → select · ⇧/⌘-click frames · ↑ ↓ items · click zoom · drag pan · + − 0 zoom · [ ] rotate · 1–3 sort · O open · T tag face · I info"
        if onTrashItems != nil { text += " · ⌫/right-click trash" }
        return text + " · Esc close"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            if let stack, let item {
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        header(stack: stack, item: item)
                        previewPane(stack: stack, item: item)
                        if stack.items.count > 1 {
                            filmstrip(stack)
                        }
                        Text(hintText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if inspectorVisible {
                        FrameInspectorPanel(
                            item: item,
                            photoRecord: framePhotoRecord,
                            faces: facesOnFrame,
                            personNames: facePersonNames,
                            metadata: frameMetadata,
                            metadataLoaded: frameMetadataLoaded
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: inspectorVisible)
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

    private func header(stack: OrganizeStack, item: OrganizeItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.primary.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                let selectedCount = selection.selectedItems(in: stack.items).count
                Text("\(item.captureDate.formatted(date: .abbreviated, time: .standard)) · frame \(min(frameIndex, stack.items.count - 1) + 1) of \(stack.items.count)\(selectedCount > 1 ? " · \(selectedCount) selected" : "") · item \((stackIndex ?? 0) + 1) of \(stacks.count) · \(OrganizeFolderLabel.title(forFolderPath: item.primary.folderPath, rootPath: rootPath))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let event = eventForStack(stack) {
                EventChip(event: event, isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly)
            }
            Spacer()
            EventAssignControls(
                workspace: workspace,
                verb: assignVerb,
                excludedEventID: excludedEventID,
                onAssign: { assign(stack, to: $0) },
                onNewEvent: { onNewEvent(stack) }
            )
            if item.kind != .video {
                Button {
                    tagMode.toggle()
                    isFocused = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tagMode ? Color.accentColor : Color.white.opacity(0.8))
                .help(tagMode ? "Stop drawing face boxes (T)" : "Draw a box on the photo to tag a face (T)")
            }
            Button {
                inspectorVisible.toggle()
                isFocused = true
            } label: {
                Image(systemName: inspectorVisible ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            .help("Frame info — people, capture time, camera, file (I)")
            if onRotate != nil {
                Menu {
                    Button { rotate(by: -1) } label: {
                        Label("Rotate All 90° Left", systemImage: "rotate.left")
                    }
                    Button { rotate(by: 2) } label: {
                        Label("Rotate All 180°", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { rotate(by: 1) } label: {
                        Label("Rotate All 90° Right", systemImage: "rotate.right")
                    }
                } label: {
                    Label("Rotate Burst", systemImage: "rotate.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(DisplayRotation.rotatableFiles(in: stack).isEmpty)
                .help("Rotate every frame in this burst together ( [ ] or R / Shift-R ). Display-only — originals are never rewritten.")
            }
            Button {
                PhotomatorLauncher.open(item.files.map(\.url))
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            Button {
                stackID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
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
        .overlay {
            if let tagRequest {
                tagPickerLayer(tagRequest)
            }
        }
        .contextMenu {
            frameContextMenu(stack, index: min(max(frameIndex, 0), stack.items.count - 1))
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
                if zoom > 1.5 {
                    hiResRequest = currentHiResKey
                }
            },
            markupActive: $tagMode,
            onMarkupRect: { rect in handleMarkupRect(rect) },
            onImageFrameChange: { frame in canvasImageFrame = frame }
        )
    }

    /// Real playback via AVKit's `AVPlayerView` (wrapped by
    /// `VideoPreviewPane` — SwiftUI's `VideoPlayer` aborts this binary in
    /// `_AVKit_SwiftUI` metadata init). A playable clip gets the standard
    /// player chrome; a clip the probe can't prove playable keeps its
    /// poster with a note.
    private func videoPane(_ item: OrganizeItem) -> some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(videoPlayer == nil ? 1 : 0)
            }
            if let videoPlayer {
                VideoPreviewPane(player: videoPlayer)
            } else if videoPlayable == false {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("This clip can't play in-app.")
                        .foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 12) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.primary.url])
                        }
                        Button("Open") {
                            PhotomatorLauncher.open(item.files.map(\.url))
                        }
                    }
                    .foregroundStyle(.white)
                }
                .padding(24)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .contextMenu {
            if let stack {
                frameContextMenu(stack, index: min(max(frameIndex, 0), stack.items.count - 1))
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
                        TileThumbnail(url: frame.primary.url, kind: frame.kind, pixelSize: 256, orientation: orientationForFile(frame.primary))
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? Color.accentColor.opacity(0.3) : .clear)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        isCurrent ? Color.accentColor : (isSelected ? Color.white.opacity(0.85) : .clear),
                                        lineWidth: isCurrent ? 2 : 1.5
                                    )
                            }
                            .id(index)
                            .onTapGesture { selectFrame(index, in: stack) }
                            .contextMenu { frameContextMenu(stack, index: index) }
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
                PhotomatorLauncher.open(item.files.map(\.url))
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
            // can't-play affordances instead of a dead spinner.
            let player = await VideoPreviewSupport.readyPlayer(for: url)
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
        let url = URL(fileURLWithPath: request.path)
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
                    names[id] = person.name
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
            if let cropped = FaceAligner.boxCrop(decoded, box: displayedBox) {
                crop = FaceAligner.jpegData(cropped)
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

    /// The floating person picker, dimmed against the canvas and anchored
    /// near the box it is tagging. Clicks outside dismiss it.
    private func tagPickerLayer(_ request: FaceTagRequest) -> some View {
        GeometryReader { geometry in
            let panelSize = CGSize(width: 240, height: 320)
            let preferred = CGPoint(x: request.anchor.midX, y: request.anchor.maxY + panelSize.height / 2 + 14)
            let center = CGPoint(
                x: min(max(preferred.x, panelSize.width / 2 + 8), geometry.size.width - panelSize.width / 2 - 8),
                y: min(max(preferred.y, panelSize.height / 2 + 8), geometry.size.height - panelSize.height / 2 - 8)
            )
            ZStack {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { tagRequest = nil }
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
                .position(center)
            }
        }
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
