import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var demoRootPath: String
    public var importSourcePath: String
    public var archivePath: String
    public var bufferPath: String
    public var activityLogPath: String
    public var selectedDeviceID: String
    public var eventName: String
    public var importDestination: TransferLocation

    public init(
        demoRootPath: String,
        importSourcePath: String,
        archivePath: String,
        bufferPath: String,
        activityLogPath: String,
        selectedDeviceID: String = "sony-a7v",
        eventName: String = "Lee Canyon",
        importDestination: TransferLocation = .nas
    ) {
        self.demoRootPath = demoRootPath
        self.importSourcePath = importSourcePath
        self.archivePath = archivePath
        self.bufferPath = bufferPath
        self.activityLogPath = activityLogPath
        self.selectedDeviceID = selectedDeviceID
        self.eventName = eventName
        self.importDestination = importDestination
    }

    public static func defaults(applicationSupport: URL) -> AppConfiguration {
        let root = applicationSupport.appendingPathComponent("CameraToolkit", isDirectory: true)
        let demoRoot = root.appendingPathComponent("Simulation", isDirectory: true)

        return AppConfiguration(
            demoRootPath: demoRoot.path,
            importSourcePath: demoRoot.appendingPathComponent("Fake Card", isDirectory: true).path,
            archivePath: demoRoot.appendingPathComponent("Archive", isDirectory: true).path,
            bufferPath: demoRoot.appendingPathComponent("Buffer", isDirectory: true).path,
            activityLogPath: root.appendingPathComponent("activity-log.jsonl").path
        )
    }
}

public struct ConfigurationStore {
    public let url: URL

    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load(defaults: AppConfiguration) throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: url.path) else {
            return defaults
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    public func save(_ configuration: AppConfiguration) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }
}
