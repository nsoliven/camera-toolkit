import AppKit
import CameraToolkitCore
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
    static let cameraToolkitStorageLocationsChanged = Notification.Name("CameraToolkit.StorageLocationsChanged")
}

/// Places in the window the guide outlines while explaining them.
enum GuideTarget: Hashable {
    case addFolder
    case discovered
    case grid
    case assignBar
    case applyButton
    case storageStrip
}

enum SetupGuideStep: Int, CaseIterable {
    case welcome
    case buffer
    case privateFolder
    case library
    case unsorted
    case existingEvents
    case browse
    case createEvent
    case apply
    case eventPage
    case done

    var title: String {
        switch self {
        case .welcome: "Let’s set up Camera Toolkit"
        case .buffer: "Your shared Buffer"
        case .privateFolder: "Your private folder"
        case .library: "Your NAS library"
        case .unsorted: "Photos you haven’t sorted"
        case .existingEvents: "Events already on your drive"
        case .browse: "Look at your photos"
        case .createEvent: "Make an event"
        case .apply: "Apply your sorting"
        case .eventPage: "See where an event lives"
        case .done: "You’re all set"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave.fill"
        case .buffer: "externaldrive.fill"
        case .privateFolder: "lock.fill"
        case .library: "server.rack"
        case .unsorted: "tray.full.fill"
        case .existingEvents: "sparkle.magnifyingglass"
        case .browse: "square.grid.3x2.fill"
        case .createEvent: "calendar.badge.plus"
        case .apply: "checkmark.circle.fill"
        case .eventPage: "rectangle.split.3x1.fill"
        case .done: "star.fill"
        }
    }

    var highlight: GuideTarget? {
        switch self {
        case .unsorted: .addFolder
        case .existingEvents: .discovered
        case .browse: .grid
        case .createEvent: .assignBar
        case .apply: .applyButton
        case .eventPage: .storageStrip
        case .welcome, .buffer, .privateFolder, .library, .done: nil
        }
    }

    /// The Apply button sits at the bottom right, so that step's panel moves up.
    var prefersTop: Bool { self == .apply }
}

struct PlaceStatus {
    var url: URL
    var isConnected: Bool
    var exists: Bool
    var freeBytes: Int64?

    static func check(_ url: URL, includeFreeSpace: Bool = true) -> PlaceStatus {
        let connected = VolumeInfo.isAvailable(url)
        let exists = connected && FileManager.default.fileExists(atPath: url.path)
        var free: Int64?
        if includeFreeSpace, connected {
            let probe = exists ? url : (VolumeInfo.volumeRoot(for: url) ?? url.deletingLastPathComponent())
            free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        return PlaceStatus(url: url, isConnected: connected, exists: exists, freeBytes: free)
    }

    var locationName: String {
        if let volume = VolumeInfo.volumeRoot(for: url) {
            return "\(volume.lastPathComponent) · \(url.lastPathComponent)"
        }
        return url.lastPathComponent
    }
}

/// A step-by-step setup and tour that checks the drive, finds unsorted
/// folders, and walks through sorting and applying a first burst. Every
/// step explains itself and offers a button that does the work.
@MainActor
@Observable
final class SetupGuide {
    static let completedKey = "CameraToolkit.setupGuideCompleted"

    unowned let workspace: EventsWorkspace
    var step: SetupGuideStep = .welcome
    var candidates: [UnsortedFolderCandidate] = []
    var chosenCandidatePaths: Set<String> = []
    var removableLocationIDs: Set<UUID> = []
    var isFindingFolders = false
    var hasSearched = false
    var note: String?
    var browseLocationID: UUID?
    var isCollapsed = false

    init(workspace: EventsWorkspace) {
        self.workspace = workspace
    }

    private var model: DashboardModel { workspace.model }

    var progress: Double {
        Double(step.rawValue) / Double(SetupGuideStep.allCases.count - 1)
    }

    var progressText: String {
        "Step \(step.rawValue + 1) of \(SetupGuideStep.allCases.count)"
    }

    // MARK: Navigation

    func next() { go(to: step.rawValue + 1) }
    func back() { go(to: step.rawValue - 1) }

    func go(to rawValue: Int) {
        let clamped = min(max(rawValue, 0), SetupGuideStep.allCases.count - 1)
        guard let target = SetupGuideStep(rawValue: clamped) else { return }
        step = target
        note = nil
        isCollapsed = false
        switch target {
        case .unsorted:
            if !hasSearched { findFolders() }
            removableLocationIDs = Set(workspace.unsortedLocations.filter(Self.isTestSource).map(\.id))
        case .existingEvents:
            workspace.discoverDriveEvents()
        case .browse, .createEvent, .apply:
            if browseLocationID == nil || !browseChoices.contains(where: { $0.id == browseLocationID }) {
                browseLocationID = preferredBrowseLocation()?.id
            }
        default:
            break
        }
    }

    func close() {
        workspace.guide = nil
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        workspace.guide = nil
        model.statusMessage = "Setup complete. Open the guide again any time with the Guide button."
    }

    // MARK: Places

    var bufferStatus: PlaceStatus {
        // Tracked read: place statuses re-check when connectivity is refreshed.
        _ = workspace.connectivityRevision
        return PlaceStatus.check(workspace.locations.bufferRoot)
    }
    var privateStatus: PlaceStatus {
        _ = workspace.connectivityRevision
        return PlaceStatus.check(workspace.locations.privateStagingRoot)
    }
    var libraryStatus: PlaceStatus {
        _ = workspace.connectivityRevision
        return PlaceStatus.check(workspace.locations.libraryRoot, includeFreeSpace: false)
    }

    var usesDefaultPrivateFolder: Bool {
        model.configuration.privateStagingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bufferSuggestions: [URL] {
        let current = EventStorageLocations.pathKey(workspace.locations.bufferRoot.path)
        return Self.externalVolumes()
            .map { $0.appendingPathComponent("Camera Buffer", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && EventStorageLocations.pathKey($0.path) != current }
    }

    func useBuffer(_ url: URL) {
        model.setConfigPath(\.bufferPath, to: url.path)
        workspace.discoverDriveEvents()
        note = "The shared Buffer is now \(url.lastPathComponent) on \(VolumeInfo.volumeRoot(for: url)?.lastPathComponent ?? "this Mac")."
    }

    func chooseBuffer() {
        if model.chooseFolder(title: "Choose the Shared Buffer Folder", keyPath: \.bufferPath) {
            workspace.discoverDriveEvents()
            note = "Buffer updated."
        }
    }

    func choosePrivateFolder() {
        if model.chooseFolder(title: "Choose the Private Folder", keyPath: \.privateStagingPath) {
            note = "Private folder updated."
        }
    }

    func useDefaultPrivateFolder() {
        if !usesDefaultPrivateFolder {
            model.setConfigPath(\.privateStagingPath, to: "")
        }
    }

    func chooseLibrary() {
        model.chooseCameraLibraryRoot()
    }

    // MARK: Unsorted folders

    var staleLocations: [ConfiguredLocation] {
        workspace.unsortedLocations.filter { Self.isTestSource($0) || !workspace.isConnected($0) }
    }

    static func isTestSource(_ location: ConfiguredLocation) -> Bool {
        let path = location.path
        return path.contains("/Application Support/CameraToolkit/Simulation")
            || path.contains("/Application Support/CameraToolkit/Safety Test")
    }

    static func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard VolumeInfo.volumeRoot(for: url) != nil,
                  !url.lastPathComponent.hasPrefix("Backups of"),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly != true && values.volumeIsBrowsable != false
        }
    }

    func findFolders() {
        isFindingFolders = true
        hasSearched = true
        let volumes = Self.externalVolumes()
        let locations = workspace.locations
        let excluded = [locations.bufferRoot, locations.privateStagingRoot, locations.libraryRoot, locations.removedFilesRoot]
        let added = workspace.unsortedLocations.map { DashboardModel.expandedPath($0.path) }
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                UnsortedFolderDiscovery.candidates(volumeRoots: volumes, excludedRoots: excluded, alreadyAddedPaths: added)
            }.value
            guard let self else { return }
            candidates = found
            chosenCandidatePaths = Set(found.filter(\.isSuggested).map(\.path))
            isFindingFolders = false
        }
    }

    func applyUnsortedChoices() {
        let chosen = candidates.filter { chosenCandidatePaths.contains($0.path) }
        let removing = removableLocationIDs
        guard !chosen.isEmpty || !removing.isEmpty else { return }
        let newLocations = chosen.map { candidate -> ConfiguredLocation in
            var location = ConfiguredLocation(role: .importSource, name: candidate.name, path: candidate.path)
            location.deviceID = DashboardModel.inferredDeviceID(for: location)
            return location
        }
        model.updateConfiguration { configuration in
            configuration.configuredLocations.removeAll { removing.contains($0.id) }
            configuration.configuredLocations.append(contentsOf: newLocations)
        }
        for id in removing {
            workspace.sources[id] = nil
        }
        if case .unsorted(let id) = workspace.selection, removing.contains(id) {
            workspace.selection = nil
        }
        candidates.removeAll { chosenCandidatePaths.contains($0.path) }
        chosenCandidatePaths = []
        removableLocationIDs = []
        if browseLocationID == nil || removing.contains(browseLocationID!) {
            browseLocationID = newLocations.first(where: { UnsortedFolderDiscovery.looksUnsorted($0.name) })?.id ?? newLocations.first?.id
        }
        note = "Added \(newLocations.count) and removed \(removing.count). No files changed."
    }

    // MARK: Tour

    var browseChoices: [ConfiguredLocation] {
        workspace.unsortedLocations.filter { !Self.isTestSource($0) && workspace.isConnected($0) }
    }

    func preferredBrowseLocation() -> ConfiguredLocation? {
        let choices = browseChoices
        return choices.first { UnsortedFolderDiscovery.looksUnsorted($0.name) } ?? choices.first
    }

    func openBrowse() {
        guard let id = browseLocationID ?? preferredBrowseLocation()?.id else {
            note = "Add an unsorted folder first. Go back one step."
            return
        }
        browseLocationID = id
        workspace.selection = .unsorted(id)
    }

    var browseStatus: String? {
        guard let id = browseLocationID, let location = workspace.location(id) else { return nil }
        let state = workspace.sources[id]
        if state?.isScanning == true {
            if let progress = state?.progress, progress.total > 0 {
                return "Reading \(location.name): \(progress.processed.formatted()) of \(progress.total.formatted()) photos…"
            }
            return "Reading \(location.name)…"
        }
        if let error = state?.error { return error }
        if let result = state?.result {
            let left = result.stacks.count { !workspace.isSorted($0) }
            return "Ready: \(result.stacks.count.formatted()) items over \(result.days.count) days. \(left.formatted()) left to sort."
        }
        return nil
    }

    func pickFirstBurstAndCreateEvent() {
        guard let id = browseLocationID ?? preferredBrowseLocation()?.id else {
            note = "Open your unsorted photos first."
            return
        }
        browseLocationID = id
        workspace.selection = .unsorted(id)
        guard let result = workspace.sources[id]?.result else {
            if workspace.sources[id]?.isScanning != true, let location = workspace.location(id) {
                workspace.scan(location)
            }
            note = "Your photos are still loading. Try again in a moment."
            return
        }
        guard let stack = result.stacks.first(where: { $0.isBurst && !workspace.isSorted($0) })
            ?? result.stacks.first(where: { !workspace.isSorted($0) }) else {
            note = "Everything in this folder is already sorted."
            return
        }
        workspace.selectStacks([stack.id])
        workspace.requestNewEvent(from: id)
    }

    var latestSortedEvent: SavedCameraEvent? {
        model.configuration.savedEvents
            .filter { workspace.assignmentCount(for: $0.id) > 0 }
            .max { $0.createdAt < $1.createdAt }
    }

    var pendingApplyCount: Int {
        guard let id = browseLocationID, let result = workspace.sources[id]?.result else { return 0 }
        return workspace.sortedFiles(in: result).files
    }

    func showApplyPlan() {
        guard let id = browseLocationID, workspace.sources[id]?.result != nil else {
            note = "Open and sort some photos first."
            return
        }
        guard pendingApplyCount > 0 else {
            note = "Nothing is sorted in this folder yet, so there is nothing to apply."
            return
        }
        workspace.selection = .unsorted(id)
        workspace.prepareApply(sourceLocationID: id)
    }

    func openNewestEvent() {
        guard let event = latestSortedEvent ?? model.configuration.savedEvents.max(by: { $0.createdAt < $1.createdAt }) else {
            note = "Make an event first."
            return
        }
        workspace.selection = .event(event.id)
    }
}

struct GuideHighlightModifier: ViewModifier {
    let isActive: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(pulse ? 1 : 0.3)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .onDisappear { pulse = false }
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func guideHighlight(_ target: GuideTarget, in workspace: EventsWorkspace) -> some View {
        modifier(GuideHighlightModifier(isActive: workspace.guide?.step.highlight == target))
    }
}
