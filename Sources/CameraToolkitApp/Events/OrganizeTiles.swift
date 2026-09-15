import AppKit
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

    var body: some View {
        HStack(spacing: 4) {
            if let number {
                Text("\(number)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            }
            if event.resolvedStoragePolicy == .archiveOnly {
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
    let isMixed: Bool
    let isDimmed: Bool
    let badge: TileLocationBadge?

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
                            Label("\(stack.items.count)", systemImage: "square.stack.3d.down.right.fill")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                        } else if stack.kind == .video {
                            Image(systemName: "video.fill")
                                .font(.caption)
                                .padding(5)
                                .background(.black.opacity(0.6), in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let event {
                            EventChip(event: event)
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

struct DayHeader: View {
    let day: OrganizeDay
    let subtitle: String
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select Day", action: onSelect)
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct OrganizeStatusLine: View {
    @Bindable var model: DashboardModel

    var body: some View {
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

/// The shared burst grid: capture days as pinned sections, keyboard focus,
/// click and Shift/Command selection, drag to an event, and a context menu.
struct OrganizeGrid<MenuContent: View>: View {
    @Bindable var workspace: EventsWorkspace
    let days: [OrganizeDay]
    let tileWidth: CGFloat
    let origin: OrganizeDragPayload.Origin
    let containerID: UUID
    let daySubtitle: (OrganizeDay) -> String
    let eventForStack: (OrganizeStack) -> (event: SavedCameraEvent?, mixed: Bool)
    let isDimmed: (OrganizeStack) -> Bool
    let badge: (OrganizeStack) -> TileLocationBadge?
    let onOpen: (OrganizeStack) -> Void
    let onKey: (KeyPress, [String]) -> KeyPress.Result
    @ViewBuilder let menu: (OrganizeStack) -> MenuContent

    @FocusState private var isFocused: Bool
    @State private var columns = 1

    var body: some View {
        let ordered = days.flatMap(\.stacks)
        let orderedIDs = ordered.map(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.3), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 14,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.stacks) { stack in
                                tile(stack, orderedIDs: orderedIDs)
                            }
                        } header: {
                            DayHeader(day: day, subtitle: daySubtitle(day)) {
                                workspace.selectStacks(day.stacks.map(\.id))
                                isFocused = true
                            }
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
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKey(press, ordered: ordered, orderedIDs: orderedIDs, proxy: proxy)
            }
            .onAppear { isFocused = true }
        }
    }

    private func tile(_ stack: OrganizeStack, orderedIDs: [String]) -> some View {
        let assigned = eventForStack(stack)
        return StackTileView(
            stack: stack,
            width: tileWidth,
            isSelected: workspace.selectedStackIDs.contains(stack.id),
            isFocused: workspace.focusedStackID == stack.id,
            event: assigned.event,
            isMixed: assigned.mixed,
            isDimmed: isDimmed(stack),
            badge: badge(stack)
        )
        .id(stack.id)
        .onTapGesture {
            isFocused = true
            let flags = NSEvent.modifierFlags
            workspace.select(
                stackID: stack.id,
                orderedIDs: orderedIDs,
                extend: flags.contains(.shift),
                toggle: flags.contains(.command)
            )
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(stack) })
        .draggable(workspace.dragPayload(for: stack.id, origin: origin, containerID: containerID)) {
            let count = workspace.selectedStackIDs.contains(stack.id) ? workspace.selectedStackIDs.count : 1
            Label("\(count) item\(count == 1 ? "" : "s")", systemImage: "photo.on.rectangle.angled")
                .padding(8)
                .background(.regularMaterial, in: Capsule())
        }
        .contextMenu { menu(stack) }
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
        switch press.key {
        case .leftArrow: return move(-1)
        case .rightArrow: return move(1)
        case .upArrow: return move(-columns)
        case .downArrow: return move(columns)
        case .space:
            if let id = workspace.focusedStackID ?? workspace.selectedStackIDs.first,
               let stack = ordered.first(where: { $0.id == id }) {
                onOpen(stack)
            }
            return .handled
        case .escape:
            workspace.selectedStackIDs.removeAll()
            return .handled
        default:
            return onKey(press, orderedIDs)
        }
    }
}

/// Full-size review of one burst at a time with a filmstrip of every frame.
struct StackPreviewOverlay: View {
    let stacks: [OrganizeStack]
    @Binding var stackID: String?
    let quickEvents: [SavedCameraEvent]
    let eventForStack: (OrganizeStack) -> SavedCameraEvent?
    let onAssign: (OrganizeStack, SavedCameraEvent) -> Void

    @State private var frameIndex = 0
    @State private var image: CGImage?
    @FocusState private var isFocused: Bool

    private var stackIndex: Int? { stacks.firstIndex { $0.id == stackID } }
    private var stack: OrganizeStack? { stackIndex.map { stacks[$0] } }
    private var item: OrganizeItem? {
        stack.map { $0.items[min(max(frameIndex, 0), $0.items.count - 1)] }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            if let stack, let item {
                VStack(spacing: 10) {
                    header(stack: stack, item: item)
                    ZStack {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if stack.items.count > 1 {
                        filmstrip(stack)
                    }
                    Text("← → frames · ↑ ↓ items · 1–9 sort into an event · O open in Photomator · Space or Esc to close")
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
        .task(id: item?.primary.path) { await load() }
    }

    private func header(stack: OrganizeStack, item: OrganizeItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.primary.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(item.captureDate.formatted(date: .abbreviated, time: .standard)) · frame \(min(frameIndex, stack.items.count - 1) + 1) of \(stack.items.count) · item \((stackIndex ?? 0) + 1) of \(stacks.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let event = eventForStack(stack) {
                EventChip(event: event)
            }
            Spacer()
            ForEach(Array(quickEvents.enumerated()), id: \.element.id) { index, event in
                Button {
                    assign(stack, to: event)
                } label: {
                    EventChip(event: event, number: index + 1)
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
                    }
                }
            }
            .frame(height: 70)
            .onChange(of: frameIndex) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let stack, let index = stackIndex else { return .ignored }
        switch press.key {
        case .escape, .space:
            stackID = nil
        case .leftArrow:
            frameIndex = max(0, frameIndex - 1)
        case .rightArrow:
            frameIndex = min(stack.items.count - 1, frameIndex + 1)
        case .upArrow:
            if index > 0 { stackID = stacks[index - 1].id }
        case .downArrow:
            if index + 1 < stacks.count { stackID = stacks[index + 1].id }
        default:
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
        if let full = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 2_400) {
            image = full
        } else {
            image = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 768)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 384)
            if let full = await TileImageLoader.shared.image(for: url, maximumPixelSize: 2_400), !Task.isCancelled {
                image = full
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
}
