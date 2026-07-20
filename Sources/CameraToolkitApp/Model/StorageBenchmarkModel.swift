import CameraToolkitCore
import Foundation
import Observation

enum StorageBenchmarkAccess: Hashable, Sendable {
    case readOnly
    case readWrite
}

struct StorageBenchmarkTarget: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var volumeRoot: URL
    var searchRoots: [URL]
    var writeDirectory: URL?
    var roleNames: [String]
    var access: StorageBenchmarkAccess
    var isAvailable: Bool
    var totalCapacity: Int64?

    var roleSummary: String {
        roleNames.joined(separator: " · ")
    }
}

@MainActor
enum StorageBenchmarkTargetDiscovery {
    private struct Builder {
        var id: String
        var name: String
        var volumeRoot: URL
        var searchRoots: [URL] = []
        var writeDirectory: URL?
        var writePriority = Int.max
        var roleNames: Set<String> = []
        var hasCameraSource = false
        var isAvailable = false
        var isReadOnly = false
        var totalCapacity: Int64?
    }

    static func discover(
        configuration: AppConfiguration,
        transferQueue: TransferQueueSnapshot?,
        fileManager: FileManager = .default
    ) -> [StorageBenchmarkTarget] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey
        ]
        let mountedVolumes = (fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? [])
            .map(\.standardizedFileURL)
            .filter { $0.path != "/" }
            .sorted { $0.path.count > $1.path.count }

        let configuredPaths = configuration.configuredLocations.map {
            URL(fileURLWithPath: DashboardModel.expandedPath($0.path), isDirectory: true)
                .standardizedFileURL
        }
        var builders: [String: Builder] = [:]
        let demoRoot = URL(
            fileURLWithPath: DashboardModel.expandedPath(configuration.demoRootPath),
            isDirectory: true
        ).standardizedFileURL

        for volume in mountedVolumes {
            let values = try? volume.resourceValues(forKeys: keys)
            let isConfigured = configuredPaths.contains { isInside($0, root: volume) }
            let isExternal = volume.path.hasPrefix("/Volumes/")
                && (values?.volumeIsRemovable == true || values?.volumeIsEjectable == true)
            guard isConfigured || isExternal else { continue }

            let name = values?.volumeName ?? volume.lastPathComponent
            builders[volume.path] = Builder(
                id: volume.path,
                name: name.isEmpty ? volume.lastPathComponent : name,
                volumeRoot: volume,
                searchRoots: isConfigured ? [] : [volume],
                roleNames: isConfigured ? [] : ["Connected Drive"],
                isAvailable: true,
                isReadOnly: values?.volumeIsReadOnly ?? false,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init)
            )
        }

        for location in configuration.configuredLocations {
            let locationURL = URL(
                fileURLWithPath: DashboardModel.expandedPath(location.path),
                isDirectory: true
            ).standardizedFileURL
            if location.role == .importSource, isInside(locationURL, root: demoRoot) {
                continue
            }
            let matchedVolume = mountedVolumes.first { isInside(locationURL, root: $0) }
            let builderID = matchedVolume?.path ?? "offline:\(locationURL.path)"
            var builder = builders[builderID] ?? Builder(
                id: builderID,
                name: location.name,
                volumeRoot: matchedVolume ?? locationURL,
                isAvailable: matchedVolume != nil && fileManager.fileExists(atPath: locationURL.path),
                isReadOnly: false
            )

            builder.roleNames.insert(roleName(location.role))
            builder.isAvailable = builder.isAvailable || fileManager.fileExists(atPath: locationURL.path)
            switch location.role {
            case .importSource:
                builder.hasCameraSource = true
                if !builder.searchRoots.contains(locationURL) {
                    builder.searchRoots.append(locationURL)
                }
            case .buffer:
                if fileManager.fileExists(atPath: locationURL.path), builder.writePriority > 0 {
                    builder.writeDirectory = locationURL
                    builder.writePriority = 0
                }
            case .archive:
                if fileManager.fileExists(atPath: locationURL.path), builder.writePriority > 1 {
                    builder.writeDirectory = locationURL
                    builder.writePriority = 1
                }
            }
            builders[builderID] = builder
        }

        if let transferQueue {
            let source = URL(fileURLWithPath: transferQueue.sourcePath, isDirectory: true).standardizedFileURL
            if let volume = mountedVolumes.first(where: { isInside(source, root: $0) }),
               var builder = builders[volume.path] {
                builder.hasCameraSource = true
                builder.roleNames.insert("Camera Source")
                if !builder.searchRoots.contains(source) {
                    builder.searchRoots.insert(source, at: 0)
                }
                builders[volume.path] = builder
            }
        }

        return builders.values.map { builder in
            let canWrite = !builder.hasCameraSource
                && !builder.isReadOnly
                && builder.writeDirectory != nil
                && builder.writeDirectory.map { fileManager.isWritableFile(atPath: $0.path) } == true
            return StorageBenchmarkTarget(
                id: builder.id,
                name: builder.name,
                volumeRoot: builder.volumeRoot,
                searchRoots: builder.searchRoots.isEmpty ? [builder.volumeRoot] : builder.searchRoots,
                writeDirectory: canWrite ? builder.writeDirectory : nil,
                roleNames: builder.roleNames.sorted(),
                access: canWrite ? .readWrite : .readOnly,
                isAvailable: builder.isAvailable,
                totalCapacity: builder.totalCapacity
            )
        }
        .sorted {
            let leftRank = rank($0)
            let rightRank = rank($1)
            if leftRank == rightRank { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return leftRank < rightRank
        }
    }

    static func currentSourceTarget(
        in targets: [StorageBenchmarkTarget],
        transferQueue: TransferQueueSnapshot?
    ) -> StorageBenchmarkTarget? {
        let sourceTargets = targets.filter { $0.roleNames.contains("Camera Source") }
        guard let sourcePath = transferQueue?.sourcePath else {
            return sourceTargets.first
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path
        return sourceTargets.first { target in
            let root = target.volumeRoot.standardizedFileURL.path
            return source == root || source.hasPrefix(root + "/")
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func roleName(_ role: ConfiguredLocationRole) -> String {
        switch role {
        case .importSource: "Camera Source"
        case .buffer: "Buffer"
        case .archive: "Photo Library"
        }
    }

    private static func rank(_ target: StorageBenchmarkTarget) -> Int {
        if target.roleNames.contains("Camera Source") { return 0 }
        if target.roleNames.contains("Buffer") { return 1 }
        if target.roleNames.contains("Photo Library") { return 2 }
        return 3
    }
}

enum BenchmarkSampleSize: Int64, CaseIterable, Identifiable {
    case quick = 256
    case standard = 512
    case thorough = 1024

    var id: Int64 { rawValue }
    var bytes: Int64 { rawValue * 1024 * 1024 }
    var label: String { "\(rawValue) MB" }
}

@MainActor
@Observable
final class StorageBenchmarkViewModel {
    var targets: [StorageBenchmarkTarget] = []
    var results: [String: StorageBenchmarkResult] = [:]
    var errors: [String: String] = [:]
    var connectedLinks: [USBLinkSnapshot] = []
    var activeTargetID: String?
    var phase = ""
    var progress = 0.0
    var liveBytesPerSecond = 0.0
    var sampleSize: BenchmarkSampleSize = .standard

    @ObservationIgnored private weak var dashboardModel: DashboardModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { activeTargetID != nil }

    func refresh(from model: DashboardModel) {
        guard !isRunning else { return }
        dashboardModel = model
        targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: model.configuration,
            transferQueue: model.transferQueue
        )
        Task { [weak self] in
            self?.connectedLinks = await USBLinkProbe.connectedStorageLinks()
        }
    }

    func run(_ target: StorageBenchmarkTarget) {
        start(targets: [target])
    }

    func runAll() {
        start(targets: targets.filter(\.isAvailable))
    }

    func cancel() {
        task?.cancel()
        phase = "Cancelling after the current I/O call…"
    }

    private func start(targets selectedTargets: [StorageBenchmarkTarget]) {
        guard !isRunning, !selectedTargets.isEmpty else { return }
        guard let dashboardModel, !dashboardModel.isBusy else {
            errors["global"] = "Wait for the current copy or checksum job to finish before measuring storage speed."
            return
        }

        errors["global"] = nil
        dashboardModel.isStorageBenchmarkRunning = true
        let byteCount = sampleSize.bytes
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                activeTargetID = nil
                progress = 0
                liveBytesPerSecond = 0
                dashboardModel.isStorageBenchmarkRunning = false
            }

            for target in selectedTargets {
                if Task.isCancelled { break }
                activeTargetID = target.id
                phase = target.access == .readOnly
                    ? "Preparing a read-only source test"
                    : "Preparing a temporary destination test"
                progress = 0
                liveBytesPerSecond = 0
                errors[target.id] = nil

                do {
                    let result = try await execute(target: target, byteCount: byteCount)
                    results[target.id] = result
                    phase = "Complete"
                    progress = 1
                    liveBytesPerSecond = 0
                } catch is CancellationError {
                    errors[target.id] = "Cancelled. Any temporary speed-test file was removed."
                    break
                } catch {
                    errors[target.id] = error.localizedDescription
                }
            }
        }
    }

    private func execute(
        target: StorageBenchmarkTarget,
        byteCount: Int64
    ) async throws -> StorageBenchmarkResult {
        let targetID = target.id
        let (updates, continuation) = AsyncStream<FileOperationProgress>.makeStream()
        let progressTask = Task { [weak self] in
            for await update in updates {
                guard let self, self.activeTargetID == targetID else { continue }
                self.phase = update.phase
                self.progress = update.fractionComplete
                self.liveBytesPerSecond = update.bytesPerSecond
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            let progressHandler: FileOperationProgressHandler = { update in
                continuation.yield(update)
            }
            let service = StorageBenchmarkService()
            switch target.access {
            case .readOnly:
                return try service.benchmarkReadOnly(
                    searchRoots: target.searchRoots,
                    byteLimit: byteCount,
                    progress: progressHandler
                )
            case .readWrite:
                guard let directory = target.writeDirectory else {
                    throw ToolkitError.commandFailed("No writable benchmark folder is configured for this drive.")
                }
                return try service.benchmarkReadWrite(
                    directory: directory,
                    byteCount: byteCount,
                    progress: progressHandler
                )
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            continuation.finish()
            _ = await progressTask.result
            return result
        } catch {
            continuation.finish()
            progressTask.cancel()
            throw error
        }
    }
}
