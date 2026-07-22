import Foundation
import Observation

struct DriveInformationRequest: Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    var symbol: String
    var role: String
}

enum DriveSMARTHealth: Equatable, Sendable {
    case verified
    case warning(String)
    case failing(String)
    case notSupported
    case unavailable
}

struct DriveInformationSnapshot: Equatable, Sendable {
    var request: DriveInformationRequest
    var isMounted: Bool
    var mountPoint: String? = nil
    var volumeName: String? = nil
    var fileSystem: String? = nil
    var capacity: StorageCapacitySnapshot? = nil
    var deviceIdentifier: String? = nil
    var physicalDiskIdentifier: String? = nil
    var model: String? = nil
    var mediaName: String? = nil
    var connection: String? = nil
    var mediaType: String? = nil
    var smartStatus: String? = nil
    var smartHealth: DriveSMARTHealth
    var isSolidState: Bool? = nil
    var isInternal: Bool? = nil
    var isRemovable: Bool? = nil
    var isEjectable: Bool? = nil
    var isWritable: Bool? = nil
    var volumeUUID: String? = nil
    var isNetworkShare: Bool
    var checkedAt: Date
    var errorMessage: String? = nil

    var usedBytes: Int64? {
        guard let capacity else { return nil }
        return max(capacity.totalBytes - capacity.availableBytes, 0)
    }
}

enum DriveInformationReader {
    nonisolated static func read(
        request: DriveInformationRequest,
        authoritativeCapacity: StorageCapacitySnapshot? = nil
    ) async -> DriveInformationSnapshot {
        await DriveInformationReadCoordinator.shared.read(
            request: request,
            authoritativeCapacity: authoritativeCapacity
        )
    }

    nonisolated static func smartHealth(
        status: String?,
        isNetworkShare: Bool
    ) -> DriveSMARTHealth {
        guard !isNetworkShare else { return .unavailable }
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else {
            return .unavailable
        }

        let normalized = status.lowercased()
        if normalized.contains("verified") || normalized == "passed" || normalized == "ok" {
            return .verified
        }
        if normalized.contains("not supported") || normalized.contains("unsupported") {
            return .notSupported
        }
        if normalized.contains("fail") || normalized.contains("fatal") {
            return .failing(status)
        }
        return .warning(status)
    }

    fileprivate nonisolated static func readSynchronously(
        request: DriveInformationRequest,
        authoritativeCapacity: StorageCapacitySnapshot?
    ) -> DriveInformationSnapshot {
        let expandedPath = NSString(string: request.path).expandingTildeInPath
        let requestedURL = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        guard let mountURL = mountedVolume(containing: requestedURL) else {
            return DriveInformationSnapshot(
                request: request,
                isMounted: false,
                smartHealth: .unavailable,
                isNetworkShare: false,
                checkedAt: Date(),
                errorMessage: "This location is not currently mounted."
            )
        }

        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeUUIDStringKey,
        ]
        let values = try? mountURL.resourceValues(forKeys: resourceKeys)
        let isNetworkShare = values?.volumeIsLocal == false
        let capacity = authoritativeCapacity ?? StorageCapacityReader.read(path: mountURL.path)
        let partitionInfo = isNetworkShare ? [:] : diskInformation(for: mountURL.path)
        let deviceIdentifier = string(partitionInfo, "DeviceIdentifier")
        let physicalIdentifier = string(partitionInfo, "ParentWholeDisk") ?? deviceIdentifier
        let wholeDiskInfo = physicalIdentifier.flatMap(diskInformation(for:)) ?? partitionInfo
        let profile = storageProfile(
            deviceIdentifier: deviceIdentifier,
            mountPoint: mountURL.path
        )
        let physicalProfile = profile?["physical_drive"] as? [String: Any]

        let fileSystem = string(partitionInfo, "FilesystemUserVisibleName")
            ?? string(partitionInfo, "FilesystemName")
            ?? values?.volumeLocalizedFormatDescription
        let model = string(physicalProfile, "device_name")
            ?? string(wholeDiskInfo, "DeviceModel")
            ?? nonEmpty(string(wholeDiskInfo, "MediaName"))
        let mediaName = string(physicalProfile, "media_name")
            ?? nonEmpty(string(wholeDiskInfo, "MediaName"))
        let connection = string(physicalProfile, "protocol")
            ?? string(wholeDiskInfo, "BusProtocol")
            ?? string(wholeDiskInfo, "Protocol")
            ?? (isNetworkShare ? networkConnectionName(fileSystem: fileSystem) : nil)
        let smartStatus = string(physicalProfile, "smart_status")
            ?? string(wholeDiskInfo, "SMARTStatus")
        let writable = bool(partitionInfo, "Writable")
            ?? values?.volumeIsReadOnly.map { !$0 }

        return DriveInformationSnapshot(
            request: request,
            isMounted: true,
            mountPoint: mountURL.path,
            volumeName: string(partitionInfo, "VolumeName") ?? values?.volumeName ?? mountURL.lastPathComponent,
            fileSystem: fileSystem,
            capacity: capacity,
            deviceIdentifier: deviceIdentifier,
            physicalDiskIdentifier: physicalIdentifier,
            model: isNetworkShare ? nil : model,
            mediaName: isNetworkShare ? nil : mediaName,
            connection: connection,
            mediaType: string(physicalProfile, "medium_type")
                ?? string(wholeDiskInfo, "MediaType"),
            smartStatus: smartStatus,
            smartHealth: smartHealth(status: smartStatus, isNetworkShare: isNetworkShare),
            isSolidState: bool(wholeDiskInfo, "SolidState"),
            isInternal: bool(wholeDiskInfo, "Internal"),
            isRemovable: bool(wholeDiskInfo, "RemovableMedia")
                ?? bool(wholeDiskInfo, "Removable")
                ?? values?.volumeIsRemovable,
            isEjectable: bool(wholeDiskInfo, "Ejectable") ?? values?.volumeIsEjectable,
            isWritable: writable,
            volumeUUID: string(partitionInfo, "VolumeUUID") ?? values?.volumeUUIDString,
            isNetworkShare: isNetworkShare,
            checkedAt: Date(),
            errorMessage: nil
        )
    }

    private nonisolated static func mountedVolume(containing requestedURL: URL) -> URL? {
        let fileManager = FileManager.default
        let probeURL: URL
        if fileManager.fileExists(atPath: requestedURL.path) {
            probeURL = requestedURL
        } else {
            let components = requestedURL.pathComponents
            guard components.count >= 3, components[1] == "Volumes" else { return nil }
            let expectedVolume = URL(
                fileURLWithPath: "/Volumes/\(components[2])",
                isDirectory: true
            ).standardizedFileURL
            guard fileManager.fileExists(atPath: expectedVolume.path) else { return nil }
            probeURL = expectedVolume
        }

        var candidates = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        candidates.append(URL(fileURLWithPath: "/", isDirectory: true))

        let requestedPath = probeURL.path
        return candidates
            .map(\.standardizedFileURL)
            .filter { volume in
                let root = volume.path
                return requestedPath == root || requestedPath.hasPrefix(root == "/" ? "/" : root + "/")
            }
            .max { $0.path.count < $1.path.count }
    }

    private nonisolated static func diskInformation(for target: String) -> [String: Any] {
        guard let data = commandOutput(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", target]
        ),
        let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
        let dictionary = value as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private nonisolated static func storageProfile(
        deviceIdentifier: String?,
        mountPoint: String
    ) -> [String: Any]? {
        guard let data = commandOutput(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPStorageDataType", "-json", "-detailLevel", "full"]
        ),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let profiles = root["SPStorageDataType"] as? [[String: Any]] else {
            return nil
        }
        return profiles.first { profile in
            let profileDevice = profile["bsd_name"] as? String
            let profileMount = profile["mount_point"] as? String
            return (deviceIdentifier != nil && profileDevice == deviceIdentifier)
                || profileMount == mountPoint
        }
    }

    private nonisolated static func commandOutput(
        executable: String,
        arguments: [String]
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private nonisolated static func string(_ dictionary: [String: Any]?, _ key: String) -> String? {
        if let value = dictionary?[key] as? String { return nonEmpty(value) }
        return nil
    }

    private nonisolated static func bool(_ dictionary: [String: Any]?, _ key: String) -> Bool? {
        dictionary?[key] as? Bool
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private nonisolated static func networkConnectionName(fileSystem: String?) -> String {
        guard let fileSystem, !fileSystem.isEmpty else { return "Network share" }
        return "Network · \(fileSystem)"
    }
}

private actor DriveInformationReadCoordinator {
    struct ActiveRead {
        var id: UUID
        var task: Task<DriveInformationSnapshot, Never>
    }

    static let shared = DriveInformationReadCoordinator()

    private var activeRead: ActiveRead?

    func read(
        request: DriveInformationRequest,
        authoritativeCapacity: StorageCapacitySnapshot?
    ) async -> DriveInformationSnapshot {
        while let activeRead {
            _ = await activeRead.task.value
            if self.activeRead?.id == activeRead.id {
                self.activeRead = nil
            }
        }

        let id = UUID()
        let task = Task.detached(priority: .utility) {
            DriveInformationReader.readSynchronously(
                request: request,
                authoritativeCapacity: authoritativeCapacity
            )
        }
        activeRead = ActiveRead(id: id, task: task)
        let result = await task.value
        if activeRead?.id == id {
            activeRead = nil
        }
        return result
    }
}

@MainActor
@Observable
final class DriveInformationViewModel {
    private(set) var request: DriveInformationRequest?
    private(set) var snapshot: DriveInformationSnapshot?
    private(set) var isLoading = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var authoritativeCapacity: StorageCapacitySnapshot?

    func inspect(
        _ request: DriveInformationRequest,
        authoritativeCapacity: StorageCapacitySnapshot?
    ) {
        self.request = request
        self.authoritativeCapacity = authoritativeCapacity
        snapshot = nil
        refresh()
    }

    func refresh() {
        guard let request else { return }
        task?.cancel()
        isLoading = true
        let capacity = authoritativeCapacity
        task = Task { [weak self] in
            let result = await DriveInformationReader.read(
                request: request,
                authoritativeCapacity: capacity
            )
            guard !Task.isCancelled, self?.request == request else { return }
            self?.snapshot = result
            self?.isLoading = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isLoading = false
    }
}
