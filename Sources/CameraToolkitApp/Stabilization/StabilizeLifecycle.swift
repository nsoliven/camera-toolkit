import CameraToolkitCore
import Foundation

/// Stabilizer runs never outlive the app. Quitting — also Quit Anyway with
/// a render running — ends every Gyroflow run first; each run also sits
/// under a guard that ends it when the app is gone (a crash, a force quit).
/// At launch, runs an earlier session left behind are ended, then their
/// partial files are swept from the events' `Edited` folders.
enum StabilizeLifecycle {
    /// Ends every stabilizer run this app has going (quit paths).
    static func endAllRuns() {
        StabilizerProcesses.terminateAll()
    }

    /// The folders a stabilizer partial can be in: each event's
    /// `Edited/Stabilized` and `Edited/Rec709` (intermediates), on the drive
    /// and on the NAS, plus the preview cache.
    @MainActor
    static func partialFolders(workspace: EventsWorkspace) -> [URL] {
        var folders: [URL] = [ClipStabilizing.previewFolder]
        let locations = workspace.locations
        for event in workspace.model.configuration.savedEvents {
            let policy = workspace.resolvedPolicy(for: event)
            for edited in [locations.editedRoot(for: event, policy: policy), locations.nasEditedRoot(for: event)] {
                folders.append(StabilizedRenderNaming.outputFolder(editedRoot: edited))
                folders.append(GradedRenderNaming.outputFolder(editedRoot: edited))
            }
        }
        return folders
    }

    /// At launch, off the main actor: ends leftover runs, then removes
    /// stabilizer partials written before this launch. Only folders that
    /// exist are read; an offline drive or NAS is skipped.
    @MainActor
    static func cleanUpAtLaunch(workspace: EventsWorkspace) {
        // Made now, so its Gyroflow search is done before any render asks.
        _ = workspace.grading.stabilizing
        let folders = partialFolders(workspace: workspace)
        let launched = Date()
        Task.detached(priority: .utility) {
            StabilizerProcesses.killLeftovers()
            sweep(folders, olderThan: launched)
        }
    }

    @discardableResult
    nonisolated static func sweep(_ folders: [URL], olderThan: Date) -> Int {
        var removed = 0
        let mounted = VolumeInfo.mountedVolumePaths()
        for folder in Set(folders) where VolumeInfo.isAvailable(folder, mountedVolumes: mounted) {
            removed += StabilizedRenderNaming.removeStalePartials(in: folder, olderThan: olderThan)
        }
        return removed
    }
}
