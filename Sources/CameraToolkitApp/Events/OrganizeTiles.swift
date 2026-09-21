import AppKit
import AVKit
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
        .help("\(person.faceCount) face\(person.faceCount == 1 ? "" : "s") in this event")
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
        .task(id: "\(url.path)#\(TileImageLoader.bucket(for: pixelSize))") {
            if let cached = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: pixelSize) {
                image = cached
                failed = false
                return
            }
            image = nil
            failed = false
            let loaded = await TileImageLoader.shared.image(for: url, maximumPixelSize: pixelSize)
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
    /// Toggles the inline expansion of a burst. Nil falls back to `onOpen`.
    var onExpand: (() -> Void)? = nil
    /// Opens playback for a video tile. Nil falls back to `onOpen`… callers
    /// pass it so the badge does something sensible everywhere.
    var onPlay: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                TileThumbnail(url: stack.coverItem.primary.url, kind: stack.kind, pixelSize: Int(width * 2))
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

/// Full-size review of one burst at a time with a filmstrip of every frame.
/// The image area is the shared interactive canvas: click toggles zoom at the
/// pointer, drag pans while zoomed, `+`/`-`/`0`/`⌘1` step or reset zoom, and
/// a deeper decode swaps in once zoom passes 1.5×. Right-click offers
/// "Move to Trash" when the board supports it.
struct StackPreviewOverlay: View {
    let stacks: [OrganizeStack]
    @Binding var stackID: String?
    let quickEvents: [SavedCameraEvent]
    /// Scan root used to show where each item lives ("Card/DCIM"); nil shows
    /// just the folder name (event boards have no single scan root).
    var rootPath: String? = nil
    let eventForStack: (OrganizeStack) -> SavedCameraEvent?
    let onAssign: (OrganizeStack, SavedCameraEvent) -> Void
    /// Resolved private flag for chip locks — a subevent can inherit it from
    /// a private parent, so the caller resolves it.
    var isPrivate: (SavedCameraEvent) -> Bool = { $0.resolvedStoragePolicy == .archiveOnly }
    /// Enables the right-click "Move to Trash" item on the frame and on each
    /// filmstrip thumbnail. Nil hides the menu entirely.
    var onTrashItems: (([OrganizeItem]) -> Void)? = nil
    /// Frame the overlay opens on — inline expansions deep-link into a tap.
    var initialFrameIndex: Int = 0

    @State private var frameIndex: Int
    @State private var videoPlayer: AVPlayer?
    /// nil = still checking, true = an AVPlayer is running, false = the codec
    /// can't play in-app and the poster stays on screen.
    @State private var videoPlayable: Bool?
    @State private var image: CGImage?
    /// Path of the frame a high-resolution decode was requested for — set the
    /// moment zoom passes fit so a stale frame never triggers a fetch.
    @State private var hiResRequestPath: String?
    /// The decoded 4800 px frame paired with the path it belongs to.
    @State private var hiResImage: (path: String, image: CGImage)?
    @State private var failed = false
    @State private var zoomCommand: PreviewZoomCommand?
    @FocusState private var isFocused: Bool

    init(
        stacks: [OrganizeStack],
        stackID: Binding<String?>,
        quickEvents: [SavedCameraEvent],
        rootPath: String? = nil,
        initialFrameIndex: Int = 0,
        eventForStack: @escaping (OrganizeStack) -> SavedCameraEvent?,
        onAssign: @escaping (OrganizeStack, SavedCameraEvent) -> Void,
        isPrivate: @escaping (SavedCameraEvent) -> Bool = { $0.resolvedStoragePolicy == .archiveOnly },
        onTrashItems: (([OrganizeItem]) -> Void)? = nil
    ) {
        self.stacks = stacks
        _stackID = stackID
        self.quickEvents = quickEvents
        self.rootPath = rootPath
        self.initialFrameIndex = initialFrameIndex
        self.eventForStack = eventForStack
        self.onAssign = onAssign
        self.isPrivate = isPrivate
        self.onTrashItems = onTrashItems
        _frameIndex = State(initialValue: initialFrameIndex)
    }

    private var stackIndex: Int? { stacks.firstIndex { $0.id == stackID } }
    private var stack: OrganizeStack? { stackIndex.map { stacks[$0] } }
    private var item: OrganizeItem? {
        stack.map { $0.items[min(max(frameIndex, 0), $0.items.count - 1)] }
    }

    /// The frame the canvas should draw: the hi-res decode once it exists for
    /// the current item, scaled so its layout matches the base image exactly.
    private var displayImage: (image: CGImage, scale: CGFloat)? {
        if let hiResImage,
           hiResImage.path == item?.primary.path,
           hiResImage.image.width > (image?.width ?? 0) {
            let scale = image.map { CGFloat(hiResImage.image.width) / CGFloat($0.width) } ?? 1
            return (hiResImage.image, scale)
        }
        return image.map { ($0, CGFloat(1)) }
    }

    private var hintText: String {
        if item?.kind == .video {
            var text = "Space play/pause · ↑ ↓ items · 1–9 sort · O open"
            if onTrashItems != nil { text += " · right-click trash" }
            return text + " · Esc close"
        }
        var text = "← → frames · ↑ ↓ items · click zoom · drag pan · + − 0 zoom · 1–9 sort · O open"
        if onTrashItems != nil { text += " · right-click trash" }
        return text + " · Esc close"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            if let stack, let item {
                VStack(spacing: 10) {
                    header(stack: stack, item: item)
                    Group {
                        if item.kind == .video {
                            videoPane(item)
                        } else {
                            InteractivePreviewCanvas(
                                image: displayImage?.image,
                                isLoading: !failed,
                                imageScale: displayImage?.scale ?? 1,
                                unavailableTitle: "No Preview",
                                unavailableDescription: "Camera Toolkit could not decode a preview for this file.",
                                zoomCommand: $zoomCommand,
                                onZoomChange: { zoom in
                                    if zoom > 1.5 {
                                        hiResRequestPath = item.primary.path
                                    }
                                }
                            )
                            .contextMenu { frameContextMenu(item) }
                        }
                    }
                    .id(item.primary.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if stack.items.count > 1 {
                        filmstrip(stack)
                    }
                    Text(hintText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(16)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(phases: .down) { handle($0) }
        .onChange(of: stackID) { _, _ in frameIndex = 0 }
        .onChange(of: item?.primary.path) { _, _ in
            // New frame: release the previous hi-res decode (the NSCache still
            // has it if the user zooms back) and stop any in-flight request.
            hiResImage = nil
            hiResRequestPath = nil
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
        .task(id: item?.primary.path) { await load() }
        .task(id: hiResRequestPath) { await loadHiRes() }
    }

    private func header(stack: OrganizeStack, item: OrganizeItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.primary.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(item.captureDate.formatted(date: .abbreviated, time: .standard)) · frame \(min(frameIndex, stack.items.count - 1) + 1) of \(stack.items.count) · item \((stackIndex ?? 0) + 1) of \(stacks.count) · \(OrganizeFolderLabel.title(forFolderPath: item.primary.folderPath, rootPath: rootPath))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let event = eventForStack(stack) {
                EventChip(event: event, isPrivate: isPrivate(event))
            }
            Spacer()
            ForEach(Array(quickEvents.enumerated()), id: \.element.id) { index, event in
                Button {
                    assign(stack, to: event)
                } label: {
                    EventChip(event: event, number: index + 1, isPrivate: isPrivate(event))
                }
                .buttonStyle(.plain)
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

    /// Real playback via AVKit — a playable clip gets the standard player
    /// chrome; a codec AVFoundation can't open keeps its poster with a note.
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
                VideoPlayer(player: videoPlayer)
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
        .contextMenu { frameContextMenu(item) }
        .onDisappear {
            videoPlayer?.pause()
        }
    }

    private func filmstrip(_ stack: OrganizeStack) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, frame in
                        TileThumbnail(url: frame.primary.url, kind: frame.kind, pixelSize: 256)
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(index == frameIndex ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .id(index)
                            .onTapGesture { frameIndex = index }
                            .contextMenu { frameContextMenu(frame) }
                    }
                }
            }
            .frame(height: 70)
            .onChange(of: frameIndex) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func frameContextMenu(_ item: OrganizeItem) -> some View {
        if let onTrashItems {
            Button("Move to Trash") {
                onTrashItems([item])
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Close always works, even if the stack vanished under us.
        if press.key == .escape {
            stackID = nil
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
            frameIndex = max(0, frameIndex - 1)
        case .rightArrow:
            frameIndex = min(stack.items.count - 1, frameIndex + 1)
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
                  (1...9).contains(digit),
                  digit <= quickEvents.count else { return .ignored }
            assign(stack, to: quickEvents[digit - 1])
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

    private func load() async {
        guard let url = item?.primary.url else { return }
        failed = false
        videoPlayer?.pause()
        videoPlayer = nil
        videoPlayable = nil
        if item?.kind == .video {
            // Check playability before handing AVPlayer the file so an
            // unplayable codec keeps its poster instead of a dead spinner.
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            videoPlayable = playable
            if playable {
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                videoPlayer = player
                player.play()
            }
        }
        if let full = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 2_400) {
            image = full
        } else {
            image = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 768)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 384)
            if let full = await TileImageLoader.shared.image(for: url, maximumPixelSize: 2_400), !Task.isCancelled {
                image = full
            }
            if !Task.isCancelled, image == nil {
                failed = true
            }
        }
        guard let stack, !Task.isCancelled else { return }
        for offset in [1, 2] where frameIndex + offset < stack.items.count {
            let next = stack.items[frameIndex + offset].primary.url
            Task.detached(priority: .utility) {
                _ = await TileImageLoader.shared.image(for: next, maximumPixelSize: 2_400)
            }
        }
    }

    /// Zooming past fit asks for the 4800 px decode of the current frame. The
    /// swap is invisible: `displayImage` scales the bigger image to the exact
    /// point size the base decode was shown at.
    private func loadHiRes() async {
        guard let path = hiResRequestPath, path == item?.primary.path else { return }
        let url = URL(fileURLWithPath: path)
        if let cached = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 4_800) {
            guard !Task.isCancelled else { return }
            storeHiRes(cached, path: path)
            return
        }
        if let loaded = await TileImageLoader.shared.image(for: url, maximumPixelSize: 4_800), !Task.isCancelled {
            storeHiRes(loaded, path: path)
        }
    }

    private func storeHiRes(_ loaded: CGImage, path: String) {
        // A decode that isn't larger than what's on screen adds nothing — the
        // source was smaller than the bucket.
        if let image, loaded.width <= image.width { return }
        hiResImage = (path, loaded)
    }
}
