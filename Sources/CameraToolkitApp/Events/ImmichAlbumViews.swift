import AppKit
import CameraToolkitCore
import SwiftUI

// MARK: - Event header chip

/// What the event header's Immich chip shows. Values only, so it renders the
/// same in the app and in a screenshot.
struct ImmichAlbumChipInfo: Equatable {
    /// Nil: the event has no album.
    var albumName: String?
    /// Photos of this event in the album, once a check has run.
    var inAlbum: Int?
    /// This event's photos not in the album yet: waiting for Immich, not on
    /// the NAS, or not added yet.
    var toAdd: Int
    var notOnNAS: Int
    var isPrivateWithoutAlbum = false
    /// Stacks the app made in Immich for this event.
    var stackCount = 0
    /// A linked album checks do not fill (a picks album, or an automatic one
    /// with "Make an album for every event" off).
    var isNotFilled = false
    /// The other albums the event is in ("also in" links), by name.
    var alsoIn: [String] = []

    /// From an event's own statuses (not its subevents') and its album state.
    init(albumName: String?, state: ImmichEventAlbumState?, summary: ImmichEventSummary, isPrivateWithoutAlbum: Bool, stackCount: Int = 0, isNotFilled: Bool = false, alsoIn: [String] = []) {
        self.stackCount = stackCount
        self.isNotFilled = isNotFilled
        self.alsoIn = alsoIn
        self.albumName = albumName
        inAlbum = state?.inAlbum
        let notAdded = state.map { max(0, summary.inImmich - $0.inAlbum) } ?? 0
        toAdd = summary.pendingScan + summary.notOnNAS + notAdded
        notOnNAS = summary.notOnNAS
        self.isPrivateWithoutAlbum = isPrivateWithoutAlbum
    }

    init(albumName: String?, inAlbum: Int?, toAdd: Int, notOnNAS: Int, isPrivateWithoutAlbum: Bool = false, stackCount: Int = 0, isNotFilled: Bool = false, alsoIn: [String] = []) {
        self.stackCount = stackCount
        self.isNotFilled = isNotFilled
        self.alsoIn = alsoIn
        self.albumName = albumName
        self.inAlbum = inAlbum
        self.toAdd = toAdd
        self.notOnNAS = notOnNAS
        self.isPrivateWithoutAlbum = isPrivateWithoutAlbum
    }

    /// "Also in A", "Also in A, B", "Also in A +2"; nil without links.
    var alsoInText: String? {
        guard let first = alsoIn.first else { return nil }
        switch alsoIn.count {
        case 1: return "Also in \(first)"
        case 2: return "Also in \(first), \(alsoIn[1])"
        default: return "Also in \(first) +\(alsoIn.count - 1)"
        }
    }
}

/// The event header's Immich album: a tinted capsule with the album's name,
/// how many photos it holds, how many are still to add, its stacks, and
/// buttons to send now or choose another album. View in Immich sits beside it.
struct ImmichAlbumChip<AlbumMenu: View>: View {
    let info: ImmichAlbumChipInfo
    let onSend: () -> Void
    @ViewBuilder let albumMenu: () -> AlbumMenu

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: info.albumName == nil ? "rectangle.stack.badge.plus" : "rectangle.stack.fill")
                .foregroundStyle(info.albumName == nil ? Color.secondary : Color.teal)
            if let name = info.albumName {
                Text("Immich album")
                    .foregroundStyle(.secondary)
                Text(name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(info.inAlbum.map { "\($0.formatted()) photo\($0 == 1 ? "" : "s")" } ?? "not checked yet")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(info.isPrivateWithoutAlbum ? "Private: no Immich album" : "No Immich album")
                    .foregroundStyle(.secondary)
            }
            if info.isNotFilled, info.albumName != nil {
                Text("Picks · not auto-filled")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
                    .help("Linked to this event; checks do not add photos to it. Turn on Keep This Album Filled in the Album menu to change that.")
            } else if info.toAdd > 0, info.albumName != nil {
                Text("\(info.toAdd.formatted()) to add")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                    .foregroundStyle(Color.orange)
                    .help(info.notOnNAS > 0
                        ? "\(info.notOnNAS.formatted()) not on the NAS yet: sync first. The rest are added when Immich lists them."
                        : "Added on the next check, or press Send to Immich now.")
            }
            if info.stackCount > 0 {
                Label("\(info.stackCount.formatted()) stack\(info.stackCount == 1 ? "" : "s")", systemImage: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Bursts, RAW+JPEG pairs and edits the app stacked in Immich")
            }
            if let alsoIn = info.alsoInText {
                Label(alsoIn, systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.teal.opacity(0.18)))
                    .foregroundStyle(Color.teal)
                    .help("Also linked to: \(info.alsoIn.joined(separator: ", ")). Linked albums are never filled by the app; Show Album opens them.")
            }
            Divider().frame(height: 14)
            Menu {
                albumMenu()
            } label: {
                Text(info.albumName == nil ? "Choose Album" : "Album")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(action: onSend) {
                Label("Send to Immich", systemImage: "paperplane")
            }
            .buttonStyle(.borderless)
            .help("Scan now and add this event's photos to its album")
        }
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(info.albumName == nil ? Color.secondary.opacity(0.10) : Color.teal.opacity(0.14)))
        .overlay(Capsule().strokeBorder(info.albumName == nil ? Color.secondary.opacity(0.25) : Color.teal.opacity(0.45)))
    }
}

/// The Album menu: pair with any album on the account, a new album named
/// after the event, or none. A private event first needs Allow album.
struct ImmichAlbumMenuItems: View {
    let model: DashboardModel
    let event: SavedCameraEvent
    let isPrivate: Bool

    var body: some View {
        if isPrivate {
            Toggle("Allow Album for This Private Event", isOn: Binding(
                get: { event.sendsToImmich },
                set: { model.setEventImmichUploadEnabled(event.id, enabled: $0) }
            ))
        }
        if !isPrivate || event.sendsToImmich {
            if event.immichAlbumID != nil {
                Toggle("Keep This Album Filled with the Whole Event", isOn: Binding(
                    get: { event.isFillingImmichAlbum(albumsForEveryEvent: model.configuration.immichAlbumsForEveryEvent) },
                    set: { model.setImmichAlbumFill(for: event.id, fills: $0) }
                ))
                .disabled(event.immichAlbumShared == true)
                .help(event.immichAlbumShared == true ? "Shared with you: the app never adds to someone else's album" : "Add every photo of this event to the album on each check")
                Divider()
            }
            let links = model.immichAlbumLinks[event.id] ?? []
            if !links.isEmpty {
                Section("Also In (Linked, Not Filled)") {
                    ForEach(links, id: \.albumID) { link in
                        Button("Remove Link to “\(link.albumName)”") { model.removeImmichAlbumLink(eventID: event.id, albumID: link.albumID) }
                    }
                }
                Divider()
            }
            Button("New Album Named After the Event") { model.useNewImmichAlbum(for: event.id) }
            Button("No Album") { model.unpairImmichAlbum(for: event.id) }
            Divider()
            Menu("Existing Album") {
                if model.immichAlbums.isEmpty {
                    Text("Loading albums…")
                }
                ForEach(model.immichAlbums) { album in
                    Button {
                        model.pairEvent(event.id, withImmichAlbum: album)
                    } label: {
                        let shared = model.immichAlbumIsShared(album) ? " · shared with you" : ""
                        if album.id == event.immichAlbumID {
                            Label(album.name + shared, systemImage: "checkmark")
                        } else {
                            Text(album.assetCount.map { "\(album.name) (\($0.formatted()))\(shared)" } ?? album.name + shared)
                        }
                    }
                }
            }
        }
    }
}

/// "View in Immich": a clear button that opens the event's folder in
/// Immich's folder view (else the server) in the browser. Disabled with a
/// hint when no server is set. Show Album opens the albums.
struct ViewInImmichButton: View {
    let url: URL?

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Label("View in Immich", systemImage: "safari")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(url == nil)
        .help(url == nil ? "Add your Immich server in Settings › Services first" : "Open this event's folder in Immich in your browser")
    }
}

/// "Show Album": opens the event's album in the browser; a menu of every
/// album (its own first, then the ones it is also in) when there are
/// several. Hidden when the event has no album.
struct ShowImmichAlbumButton: View {
    let choices: [ImmichAlbumChoice]

    var body: some View {
        if choices.count == 1, let only = choices.first {
            Button {
                NSWorkspace.shared.open(only.url)
            } label: {
                Label("Show Album", systemImage: "rectangle.stack")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open the album “\(only.name)” in Immich in your browser")
        } else if choices.count > 1 {
            Menu {
                ImmichAlbumChoiceItems(choices: choices)
            } label: {
                Label("Show Album", systemImage: "rectangle.stack")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Open one of this event's \(choices.count) albums in Immich in your browser")
        }
    }
}

/// One menu item per album: "Name" for the event's own, "Name · also in" for
/// the rest.
struct ImmichAlbumChoiceItems: View {
    let choices: [ImmichAlbumChoice]

    var body: some View {
        ForEach(choices) { choice in
            Button(choice.isMain ? choice.name : "\(choice.name) · also in") { NSWorkspace.shared.open(choice.url) }
        }
    }
}

/// The header row that holds the chip and View in Immich. Reads its own
/// state, so a check redraws the chip and not the board.
struct ImmichEventAlbumBar: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let eventID: UUID

    var body: some View {
        if let event = workspace.event(eventID) {
            HStack(spacing: 8) {
                if workspace.immichIsConfigured {
                    chip(event)
                }
                ViewInImmichButton(url: model.immichWebURL(for: event))
                ShowImmichAlbumButton(choices: model.immichAlbumChoices(for: event))
            }
            .task {
                guard workspace.immichIsConfigured else { return }
                model.loadImmichAlbumsIfNeeded()
                if model.immichAlbumStates.isEmpty && model.immichStackCounts.isEmpty { model.loadImmichAlbumStates() }
            }
        }
    }

    private func chip(_ event: SavedCameraEvent) -> some View {
        let isPrivate = workspace.locations.resolvedPolicy(for: event) == .archiveOnly
        let target = workspace.immichAlbumTargets[eventID]
        let state = model.immichAlbumStates[eventID]
        // Paired but not filled: a picks album, or an automatic one with the
        // every-event switch off.
        let linkedName = event.immichAlbumID == nil ? nil : (event.immichAlbumName ?? event.name)
        let isNotFilled = linkedName != nil && target == nil && !(isPrivate && !event.sendsToImmich)
        // The event's own files only: a subevent can have its own album.
        let prefix = eventID.uuidString + "|"
        let own = (workspace.eventImmichStatuses[eventID] ?? [:]).filter { $0.key.hasPrefix(prefix) }.values
        return ImmichAlbumChip(
            info: ImmichAlbumChipInfo(
                albumName: state?.albumName ?? target?.displayName ?? linkedName,
                state: state,
                summary: ImmichEventSummary(statuses: own),
                isPrivateWithoutAlbum: isPrivate && !event.sendsToImmich,
                stackCount: model.immichStackCounts[eventID] ?? 0,
                isNotFilled: isNotFilled,
                alsoIn: model.immichAlbumChoices(for: event).filter { !$0.isMain }.map(\.name)
            ),
            onSend: { workspace.requestImmichSend([eventID]) },
            albumMenu: { ImmichAlbumMenuItems(model: model, event: event, isPrivate: isPrivate) }
        )
    }
}

// MARK: - Sidebar marker

/// The small album mark beside a paired event's name in the sidebar.
struct ImmichAlbumMarker: View {
    var body: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.caption2)
            .foregroundStyle(Color.teal)
            .help("Paired with an Immich album")
            .accessibilityLabel("Immich album")
    }
}

/// The small mark on a burst tile the app stacked in Immich.
struct ImmichStackedMark: View {
    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.teal.opacity(0.85)))
            .help("Stacked in Immich")
            .accessibilityLabel("Stacked in Immich")
    }
}

// MARK: - Settings pairs list

struct ImmichPairRow: Identifiable, Equatable {
    var id: UUID { eventID }
    var eventID: UUID
    var eventName: String
    var albumName: String
    var inAlbum: Int?
    var albumCount: Int?
    /// Linked only: checks do not add to it.
    var isPicks = false
}

/// An "also in" link: an album the event is in besides its own.
struct ImmichLinkRow: Identifiable, Equatable {
    var id: String { "\(eventID.uuidString)|\(albumID)" }
    var eventID: UUID
    var eventName: String
    var albumID: String
    var albumName: String
    /// Why it was linked: "several events", "dates", …
    var basis: String
}

struct ImmichUnpairedRow: Identifiable, Equatable {
    var id: String { albumID }
    var albumID: String
    var albumName: String
    var assetCount: Int?
    var reason: String
}

/// Settings › Services: every event paired with its own album, with Unpair;
/// every "also in" link, with Unlink; and every album left unpaired with the
/// reason.
struct ImmichPairsListView: View {
    let pairs: [ImmichPairRow]
    var links: [ImmichLinkRow] = []
    let unpaired: [ImmichUnpairedRow]
    let onUnpair: (UUID) -> Void
    var onUnlink: (UUID, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired (\(pairs.count))")
                .font(.headline)
            if pairs.isEmpty {
                Text("No event is paired with an Immich album yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(pairs) { pair in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.fill").foregroundStyle(Color.teal)
                    Text(pair.eventName).lineLimit(1)
                    Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary).font(.caption)
                    Text(pair.albumName).fontWeight(.semibold).lineLimit(1)
                    if pair.isPicks {
                        Text("Picks · not filled")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let inAlbum = pair.inAlbum {
                        Text(pair.albumCount.map { "\(inAlbum.formatted()) of \($0.formatted())" } ?? inAlbum.formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help("This event's photos in the album, of all photos in the album")
                    }
                    Button("Unpair") { onUnpair(pair.eventID) }
                        .controlSize(.small)
                }
            }
            if !links.isEmpty {
                Divider()
                Text("Also in (\(links.count))")
                    .font(.headline)
                Text("Albums an event is in besides its own: albums of several events, and phone albums of an event that has its own album. Linked only; the app never adds photos to them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(links) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(Color.teal)
                        Text(link.eventName).lineLimit(1)
                        Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary).font(.caption)
                        Text(link.albumName).fontWeight(.semibold).lineLimit(1)
                        Text("Also in · \(link.basis)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.teal.opacity(0.16)))
                            .foregroundStyle(Color.teal)
                        Spacer(minLength: 8)
                        Button("Unlink") { onUnlink(link.eventID, link.albumID) }
                            .controlSize(.small)
                    }
                }
            }
            if !unpaired.isEmpty {
                Divider()
                Text("Not paired (\(unpaired.count))")
                    .font(.headline)
                ForEach(unpaired) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.albumName).lineLimit(1)
                            Text(row.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let count = row.assetCount {
                            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

extension DashboardModel {
    var immichPairRows: [ImmichPairRow] {
        configuration.savedEvents
            .filter { $0.immichAlbumID != nil }
            .map { event in
                let state = immichAlbumStates[event.id]
                return ImmichPairRow(
                    eventID: event.id,
                    eventName: event.name,
                    albumName: state?.albumName ?? event.immichAlbumName ?? event.name,
                    inAlbum: state?.inAlbum,
                    albumCount: state?.albumCount,
                    isPicks: !event.fillsImmichAlbum || (event.immichAlbumAutomatic == true && !configuration.immichAlbumsForEveryEvent)
                )
            }
            .sorted { $0.eventName.localizedStandardCompare($1.eventName) == .orderedAscending }
    }

    var immichLinkRows: [ImmichLinkRow] {
        let events = Dictionary(configuration.savedEvents.map { ($0.id, $0) }) { first, _ in first }
        let currentNames = Dictionary(immichAlbums.map { ($0.id, $0.name) }) { first, _ in first }
        return immichAlbumLinks.flatMap { eventID, links -> [ImmichLinkRow] in
            guard let event = events[eventID] else { return [] }
            return links.filter { $0.albumID != event.immichAlbumID }.map { link in
                ImmichLinkRow(eventID: eventID, eventName: event.name, albumID: link.albumID, albumName: currentNames[link.albumID] ?? link.albumName, basis: link.basisText)
            }
        }
        .sorted {
            let order = $0.eventName.localizedStandardCompare($1.eventName)
            return order == .orderedSame ? $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending : order == .orderedAscending
        }
    }

    var immichUnpairedRows: [ImmichUnpairedRow] {
        let paired = Set(configuration.savedEvents.compactMap(\.immichAlbumID)).union(immichAlbumLinks.values.flatMap { $0.map(\.albumID) })
        return (immichPairing?.unpaired ?? [])
            .filter { !paired.contains($0.album.id) }
            .map { ImmichUnpairedRow(albumID: $0.album.id, albumName: $0.album.name, assetCount: $0.album.assetCount, reason: $0.reason.text) }
    }
}

/// Pair Albums found albums of private events: one line saying how many,
/// and one button that allows an album for exactly those events and pairs.
struct ImmichPrivateAlbumsBanner: View {
    let albumCount: Int
    let eventNames: [String]
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(Color.orange)
            Text("\(albumCount) album\(albumCount == 1 ? "" : "s") belong\(albumCount == 1 ? "s" : "") to private events")
                .help(eventNames.joined(separator: ", "))
            Spacer(minLength: 8)
            Button("Allow Album and Pair", action: onAllow)
                .help("Turns on Allow album for exactly these private events (\(eventNames.joined(separator: ", "))) and pairs their albums. Nothing is changed in Immich.")
        }
    }
}

extension DashboardModel {
    var immichPrivateEventNames: [String] {
        let ids = immichPairing?.privateEventIDs ?? []
        return configuration.savedEvents.filter { ids.contains($0.id) }.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - Send to Immich

/// The progress and result of a send: one line saying what is happening,
/// then one row per event.
struct ImmichSendProgressView: View {
    let state: ImmichSendState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                switch state.phase {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                default:
                    ProgressView().controlSize(.small)
                }
                Text(state.line).font(.headline)
            }
            if !state.results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(result.eventName).fontWeight(.semibold)
                                if let album = result.albumName {
                                    Image(systemName: "rectangle.stack.fill").foregroundStyle(Color.teal).font(.caption)
                                    Text(album).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Text(resultLine(result)).font(.callout).foregroundStyle(.secondary)
                            if result.notOnNAS > 0 {
                                Label("\(result.notOnNAS.formatted()) not on the NAS yet: sync first", systemImage: "exclamationmark.circle")
                                    .font(.callout)
                                    .foregroundStyle(Color.orange)
                            }
                            if result.waiting > 0 {
                                Label("\(result.waiting.formatted()) not listed by Immich yet: added on the next check", systemImage: "clock")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ImmichSendGradedLines(result: result)
                        }
                    }
                }
            }
        }
    }

    private func resultLine(_ result: ImmichSendResult) -> String {
        var parts = ["\(result.inImmich.formatted()) in Immich"]
        if let inAlbum = result.inAlbum { parts.append("\(inAlbum.formatted()) in the album") }
        else if result.albumName == nil { parts.append("no album") }
        return parts.joined(separator: " · ")
    }
}

/// Choose events, then send: scan now, wait for the files, fill albums.
struct ImmichSendSheet: View {
    let model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let request: ImmichSendRequest
    @State private var selected: Set<UUID>
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    init(model: DashboardModel, workspace: EventsWorkspace, request: ImmichSendRequest) {
        self.model = model
        self.workspace = workspace
        self.request = request
        _selected = State(initialValue: request.eventIDs)
    }

    var body: some View {
        if let ask = workspace.grading.immichSendAsk {
            ImmichSendGradeAskView(grading: workspace.grading, ask: ask)
        } else {
            sendBody
        }
    }

    private var sendBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send to Immich").font(.title2.weight(.semibold))
            if let state = workspace.immichSend {
                ScrollView { ImmichSendProgressView(state: state).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 160, maxHeight: 380)
                HStack {
                    Spacer()
                    if state.isFinished {
                        Button("Done") { workspace.cancelImmichSend(); dismiss() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Stop") { workspace.cancelImmichSend(); dismiss() }
                    }
                }
            } else {
                Text("Immich reads your NAS. This asks it to scan now, then adds each chosen event's photos to its album. Nothing is uploaded or removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Filter events", text: $filter)
                    .textFieldStyle(.roundedBorder)
                List {
                    ForEach(shownEvents) { event in
                        Toggle(isOn: Binding(
                            get: { selected.contains(event.id) },
                            set: { isOn in if isOn { selected.insert(event.id) } else { selected.remove(event.id) } }
                        )) {
                            HStack(spacing: 6) {
                                Text(event.name)
                                if event.immichAlbumID != nil { ImmichAlbumMarker() }
                                Spacer()
                                Text(event.eventDate.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
                HStack {
                    Text("\(selected.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { workspace.cancelImmichSend(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send \(selected.count) Event\(selected.count == 1 ? "" : "s")") {
                        workspace.grading.beginImmichSend(selected)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var shownEvents: [SavedCameraEvent] {
        let all = workspace.events.sorted { $0.eventDate > $1.eventDate }
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
