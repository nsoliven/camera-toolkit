import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var demoRootPath: String
    public var importSourcePath: String
    public var archivePath: String
    public var bufferPath: String
    public var activityLogPath: String
    public var immichServerURL: String
    public var editorWorkingFolderPath: String
    public var externalEditor: ExternalEditor
    public var rcloneBinaryPath: String
    public var exiftoolBinaryPath: String
    public var selectedDeviceID: String
    public var eventName: String
    public var importDestination: TransferLocation

    public init(
        demoRootPath: String,
        importSourcePath: String,
        archivePath: String,
        bufferPath: String,
        activityLogPath: String,
        immichServerURL: String = "",
        editorWorkingFolderPath: String = "",
        externalEditor: ExternalEditor = .preview,
        rcloneBinaryPath: String = "rclone",
        exiftoolBinaryPath: String = "exiftool",
        selectedDeviceID: String = "sony-a7v",
        eventName: String = "Lee Canyon",
        importDestination: TransferLocation = .nas
    ) {
        self.demoRootPath = demoRootPath
        self.importSourcePath = importSourcePath
        self.archivePath = archivePath
        self.bufferPath = bufferPath
        self.activityLogPath = activityLogPath
        self.immichServerURL = immichServerURL
        self.editorWorkingFolderPath = editorWorkingFolderPath
        self.externalEditor = externalEditor
        self.rcloneBinaryPath = rcloneBinaryPath
        self.exiftoolBinaryPath = exiftoolBinaryPath
        self.selectedDeviceID = selectedDeviceID
        self.eventName = eventName
        self.importDestination = importDestination
    }

    private enum CodingKeys: String, CodingKey {
        case demoRootPath
        case importSourcePath
        case archivePath
        case bufferPath
        case activityLogPath
        case immichServerURL
        case editorWorkingFolderPath
        case externalEditor
        case rcloneBinaryPath
        case exiftoolBinaryPath
        case selectedDeviceID
        case eventName
        case importDestination
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let defaults = AppConfiguration.defaults(applicationSupport: support)

        demoRootPath = try values.decodeIfPresent(String.self, forKey: .demoRootPath) ?? defaults.demoRootPath
        importSourcePath = try values.decodeIfPresent(String.self, forKey: .importSourcePath) ?? defaults.importSourcePath
        archivePath = try values.decodeIfPresent(String.self, forKey: .archivePath) ?? defaults.archivePath
        bufferPath = try values.decodeIfPresent(String.self, forKey: .bufferPath) ?? defaults.bufferPath
        activityLogPath = try values.decodeIfPresent(String.self, forKey: .activityLogPath) ?? defaults.activityLogPath
        immichServerURL = try values.decodeIfPresent(String.self, forKey: .immichServerURL) ?? defaults.immichServerURL
        editorWorkingFolderPath = try values.decodeIfPresent(String.self, forKey: .editorWorkingFolderPath) ?? defaults.editorWorkingFolderPath
        externalEditor = try values.decodeIfPresent(ExternalEditor.self, forKey: .externalEditor) ?? defaults.externalEditor
        rcloneBinaryPath = try values.decodeIfPresent(String.self, forKey: .rcloneBinaryPath) ?? defaults.rcloneBinaryPath
        exiftoolBinaryPath = try values.decodeIfPresent(String.self, forKey: .exiftoolBinaryPath) ?? defaults.exiftoolBinaryPath
        selectedDeviceID = try values.decodeIfPresent(String.self, forKey: .selectedDeviceID) ?? defaults.selectedDeviceID
        eventName = try values.decodeIfPresent(String.self, forKey: .eventName) ?? defaults.eventName
        importDestination = try values.decodeIfPresent(TransferLocation.self, forKey: .importDestination) ?? defaults.importDestination
    }

    public static func defaults(applicationSupport: URL) -> AppConfiguration {
        let root = applicationSupport.appendingPathComponent("CameraToolkit", isDirectory: true)
        let demoRoot = root.appendingPathComponent("Simulation", isDirectory: true)
        let workingRoot = root.appendingPathComponent("Editor Working Copies", isDirectory: true)

        return AppConfiguration(
            demoRootPath: demoRoot.path,
            importSourcePath: demoRoot.appendingPathComponent("Source Card", isDirectory: true).path,
            archivePath: demoRoot.appendingPathComponent("Archive", isDirectory: true).path,
            bufferPath: demoRoot.appendingPathComponent("Buffer", isDirectory: true).path,
            activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
            editorWorkingFolderPath: workingRoot.path
        )
    }
}

public enum ExternalEditor: String, Codable, CaseIterable, Sendable {
    case preview
    case systemDefault
    case photomator
    case topazPhoto

    public var displayName: String {
        switch self {
        case .preview: "Preview"
        case .systemDefault: "System Default"
        case .photomator: "Photomator"
        case .topazPhoto: "Topaz Photo"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .preview: "com.apple.Preview"
        case .systemDefault: nil
        case .photomator: "com.pixelmatorteam.pixelmator.touch.x.photo"
        case .topazPhoto: "com.topazlabs.TopazPhoto"
        }
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
