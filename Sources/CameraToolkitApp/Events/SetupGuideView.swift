import AppKit
import CameraToolkitCore
import SwiftUI

/// The floating guide card. It stays open while you use the window, and it
/// can shrink to a small button.
struct SetupGuidePanel: View {
    @Bindable var guide: SetupGuide
    @Bindable var workspace: EventsWorkspace
    @Bindable var model: DashboardModel

    var body: some View {
        if guide.isCollapsed {
            Button {
                guide.isCollapsed = false
            } label: {
                Label("Setup Guide · \(guide.progressText)", systemImage: "questionmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        } else {
            expanded
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: guide.step.symbol)
                    .foregroundStyle(Color.accentColor)
                Text("Setup Guide · \(guide.progressText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guide.isCollapsed = true
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .help("Shrink the guide")
                Button {
                    guide.close()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Close the guide")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ProgressView(value: guide.progress)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(guide.step.title)
                        .font(.title2.bold())
                    stepContent
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)

            if let note = guide.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()
            HStack {
                if guide.step != .welcome {
                    Button("Back") { guide.back() }
                }
                Spacer()
                switch guide.step {
                case .welcome:
                    Button("Start") { guide.next() }
                        .buttonStyle(.borderedProminent)
                case .done:
                    Button("Finish") { guide.finish() }
                        .buttonStyle(.borderedProminent)
                default:
                    Button("Next") { guide.next() }
                }
            }
            .padding(14)
        }
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch guide.step {
        case .welcome: welcome
        case .buffer: buffer
        case .privateFolder: privateFolder
        case .library: library
        case .unsorted: unsorted
        case .existingEvents: existingEvents
        case .browse: browse
        case .createEvent: createEvent
        case .apply: apply
        case .eventPage: eventPage
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera Toolkit keeps every photo in up to four places. Each event shows which ones it’s in.")
            PlacesExplainer()
            Text("This guide checks your drives, then walks you through sorting your first burst. Setup never moves or deletes photos. Every button that moves files shows you a plan first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var buffer: some View {
        let status = guide.bufferStatus
        return VStack(alignment: .leading, spacing: 12) {
            Text("The shared Buffer is the folder on your travel drive where shared events live. Each event gets its own folder inside it. Anyone who plugs in the drive can browse it.")
            PlaceStatusCard(title: "Shared Buffer", symbol: "externaldrive.fill", tint: .blue, status: status)
            ForEach(guide.bufferSuggestions, id: \.path) { suggestion in
                Button("Use \(PlaceStatus.check(suggestion, includeFreeSpace: false).locationName)") {
                    guide.useBuffer(suggestion)
                }
            }
            HStack {
                Button("This Is Right") { guide.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.exists)
                Button("Choose a Different Folder…") { guide.chooseBuffer() }
            }
            Text("You can change this later with Change… next to Shared Buffer at the top of the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var privateFolder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private events never go into the shared Buffer. Their photos wait in this folder on the same drive until they’re safely on the NAS. Then you can take them off the drive.")
            PlaceStatusCard(
                title: "Private folder",
                symbol: "lock.fill",
                tint: .purple,
                status: guide.privateStatus,
                missingNote: "Created the first time you move a private event here."
            )
            Text("Finder hides this folder, but it isn’t locked. Anyone who turns on hidden files can still open it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(guide.usesDefaultPrivateFolder ? "Keep the Hidden Folder" : "Use the Hidden Folder Again") {
                    guide.useDefaultPrivateFolder()
                    guide.next()
                }
                .buttonStyle(.borderedProminent)
                Button("Choose a Different Folder…") { guide.choosePrivateFolder() }
            }
        }
    }

    private var library: some View {
        let status = guide.libraryStatus
        return VStack(alignment: .leading, spacing: 12) {
            Text("The NAS library is the permanent home. Archive to NAS copies an event there and checks every file.")
            PlaceStatusCard(title: "NAS library", symbol: "server.rack", tint: .green, status: status)
            if !status.isConnected {
                Text("Your NAS isn’t connected right now. That’s fine. You can sort and use the drive today, and archive later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("This Is Right") { guide.next() }
                    .buttonStyle(.borderedProminent)
                Button("Choose a Different Folder…") { guide.chooseLibrary() }
            }
        }
    }

    private var unsorted: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unsorted photos are camera cards, or folders of card dumps you haven’t sorted into events yet. They show up under Unsorted in the sidebar.")
            if guide.isFindingFolders {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for camera files on your drives…")
                }
            } else if guide.candidates.isEmpty {
                Text("I didn’t find any new cards or photo folders. Plug in a card and press Look Again, or add one later with Add Folder or Card.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Found on your drives")
                    .font(.headline)
                ForEach(guide.candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { guide.chosenCandidatePaths.contains(candidate.path) },
                        set: { isOn in
                            if isOn { guide.chosenCandidatePaths.insert(candidate.path) } else { guide.chosenCandidatePaths.remove(candidate.path) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name).fontWeight(.semibold)
                            Text("\(candidate.volumeName) · \(candidate.cameraFileCount.formatted()) camera files · \(candidate.byteCount.formattedWholeStorage)\(candidate.isCameraCard ? " · camera card" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Folders that look like card dumps are already checked. Leave copies of finished events unchecked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !guide.staleLocations.isEmpty {
                Text("Clean up the list")
                    .font(.headline)
                    .padding(.top, 4)
                ForEach(guide.staleLocations) { location in
                    Toggle(isOn: Binding(
                        get: { guide.removableLocationIDs.contains(location.id) },
                        set: { isOn in
                            if isOn { guide.removableLocationIDs.insert(location.id) } else { guide.removableLocationIDs.remove(location.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name)
                            Text(SetupGuide.isTestSource(location) ? "Test data from an older version" : "Not connected right now")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Removing only hides it from the list. No files change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                let adding = guide.chosenCandidatePaths.count
                let removing = guide.removableLocationIDs.count
                Button(adding + removing == 0 ? "Continue" : "Update the List and Continue") {
                    guide.applyUnsortedChoices()
                    guide.next()
                }
                .buttonStyle(.borderedProminent)
                .disabled(guide.isFindingFolders)
                Button("Look Again") { guide.findFolders() }
                    .disabled(guide.isFindingFolders)
            }
        }
    }

    private var existingEvents: some View {
        let found = workspace.discoveredDriveEvents
        return VStack(alignment: .leading, spacing: 12) {
            if found.isEmpty {
                Text("Every event folder on your drive is already in the Events list. Nothing to add here.")
            } else {
                Text("These event folders are already on your drive, but Camera Toolkit doesn’t list them yet:")
                ForEach(found.prefix(10)) { event in
                    HStack {
                        Image(systemName: event.policy == .buffer ? "folder.fill" : "lock.fill")
                            .foregroundStyle(event.policy == .buffer ? Color.blue : Color.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.name).fontWeight(.semibold)
                            Text("\(event.dateString) · \(event.files.count.formatted()) files · \(event.byteCount.formattedWholeStorage)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if found.count > 10 {
                    Text("and \(found.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add These \(found.count) Events") {
                    workspace.adoptDiscoveredDriveEvents()
                    guide.note = "Added. They’re in the Events list now."
                }
                .buttonStyle(.borderedProminent)
                Text("Adding them only lists them as events. No files move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now let’s look at your photos.")
            if guide.browseChoices.isEmpty {
                Text("There’s no connected unsorted folder yet. Go back one step to add one.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Start with", selection: $guide.browseLocationID) {
                    ForEach(guide.browseChoices) { location in
                        Text(location.name).tag(Optional(location.id))
                    }
                }
                Button("Open It for Me") { guide.openBrowse() }
                    .buttonStyle(.borderedProminent)
                if let status = guide.browseStatus {
                    Label(status, systemImage: "photo.stack")
                        .font(.callout)
                }
            }
            GuideBullet(symbol: "square.stack.3d.down.right.fill", text: "Each tile is one burst or one photo. The number badge counts the frames in a burst.")
            GuideBullet(symbol: "calendar", text: "Each day gets its own section, using your camera’s clock.")
            GuideBullet(symbol: "space", text: "Click a tile to select it. Press Space to see every frame big, and Esc to close.")
        }
    }

    private var createEvent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Events are how you sort. Make one and put your first burst in it.")
            Button("Pick the First Burst and Make an Event…") { guide.pickFirstBurstAndCreateEvent() }
                .buttonStyle(.borderedProminent)
            Text("In the window that opens, type a name, check the date, and choose Shared Buffer or Private.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let event = guide.latestSortedEvent {
                Label("\(event.name) has \(workspace.assignmentCount(for: event.id)) files sorted into it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text("After that, sorting is fast")
                .font(.headline)
                .padding(.top, 4)
            GuideBullet(symbol: "number", text: "Press 1–9 to send the selected photos to the numbered event in the bar above the photos.")
            GuideBullet(symbol: "hand.draw", text: "Or drag tiles onto an event in the sidebar.")
            GuideBullet(symbol: "n.square", text: "Press N to make a new event from what’s selected.")
            GuideBullet(symbol: "arrow.uturn.left", text: "Command-Z undoes a sort. Sorting never moves files by itself.")
        }
    }

    private var apply: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sorting only makes a list. Your files stay where they are until you press Apply.")
            GuideBullet(symbol: "list.bullet.rectangle", text: "Apply shows every move before anything happens.")
            GuideBullet(symbol: "bolt.fill", text: "Files already on your travel drive move into the event folder instantly.")
            GuideBullet(symbol: "sdcard", text: "Files on a card are copied and checked. The card keeps its originals.")
            GuideBullet(symbol: "arrow.uturn.left", text: "Undo moves files back if you change your mind.")
            Button(guide.pendingApplyCount > 0 ? "Show Me the Apply Plan for \(guide.pendingApplyCount) Files" : "Show Me the Apply Plan") {
                guide.showApplyPlan()
            }
            .buttonStyle(.borderedProminent)
            Text("You can also keep sorting and press Apply later. It’s the blue button at the bottom right.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eventPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every event has a page that shows where its photos are, with one button for each place.")
            Button("Open My Newest Event") { guide.openNewestEvent() }
                .buttonStyle(.borderedProminent)
            GuideBullet(symbol: "sdcard", text: "Card / Unsorted: photos still on the card or in the unsorted folder. Free Up Source clears them after checking the drive copies.")
            GuideBullet(symbol: "externaldrive.fill", text: "Shared Buffer or Private: the switch at the top of the event picks which. Put on Buffer or Move to Private does the move.")
            GuideBullet(symbol: "server.rack", text: "NAS: Archive to NAS makes the permanent copy. Take Off Drive then frees the drive after checking every file.")
            GuideBullet(symbol: "cloud.fill", text: "Immich: turn on Send, then press Upload.")
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("That’s the whole loop: sort, Apply, then archive each event when the NAS is connected.")
            GuideBullet(symbol: "keyboard", text: "Space previews · 1–9 sorts · N makes an event · Command-Z undoes.")
            GuideBullet(symbol: "externaldrive", text: "Where Things Live at the top of the sidebar shows your Buffer, private folder, and NAS. Change… points them somewhere else.")
            GuideBullet(symbol: "questionmark.circle", text: "Open this guide again any time with the Guide button in the sidebar or Help › Setup Guide.")
        }
    }
}

struct GuideBullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

struct PlacesExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideBullet(symbol: "sdcard", text: "Card or unsorted folder: where photos start.")
            GuideBullet(symbol: "externaldrive.fill", text: "Your travel drive: each event gets a folder in the shared Buffer, or in a hidden private folder.")
            GuideBullet(symbol: "server.rack", text: "NAS: the permanent, checked copy.")
            GuideBullet(symbol: "cloud.fill", text: "Immich: optional, for events you want to share.")
        }
    }
}

struct PlaceStatusCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let status: PlaceStatus
    var missingNote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    stateLabel
                }
                Text(status.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var detail: String {
        if !status.isConnected { return "Not connected. Plug in the drive or connect the share." }
        if !status.exists { return missingNote ?? "This folder doesn’t exist yet." }
        if let free = status.freeBytes { return "Connected · \(free.formattedWholeStorage) free" }
        return "Connected"
    }

    @ViewBuilder
    private var stateLabel: some View {
        if status.isConnected && (status.exists || missingNote != nil) {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if !status.isConnected {
            Label("Offline", systemImage: "bolt.horizontal.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }
}

struct SidebarPlaceRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let status: PlaceStatus
    let missingIsFine: Bool
    let change: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(status.isConnected ? tint : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(status.isConnected && (status.exists || missingIsFine) ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Change…", action: change)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .help(status.url.path)
        .contextMenu {
            Button("Reveal in Finder") {
                if FileManager.default.fileExists(atPath: status.url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([status.url])
                }
            }
            .disabled(!status.exists)
        }
    }

    private var subtitle: String {
        if !status.isConnected { return "Not connected" }
        if !status.exists && !missingIsFine { return "Folder missing" }
        if let free = status.freeBytes { return "\(status.locationName) · \(free.formattedWholeStorage) free" }
        return status.locationName
    }
}
