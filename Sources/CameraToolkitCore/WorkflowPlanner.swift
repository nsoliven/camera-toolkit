import Foundation

public enum WorkflowPlanKind: String, Codable, CaseIterable, Sendable {
    case importArchive
    case freeUpBuffer
    case immichUpload
    case editorCheckout
    case metadataRead

    public var displayName: String {
        switch self {
        case .importArchive: "Import to Archive"
        case .freeUpBuffer: "Free Up Buffer"
        case .immichUpload: "Immich Upload"
        case .editorCheckout: "External Editor"
        case .metadataRead: "Metadata Read"
        }
    }
}

public enum WorkflowPlanStatus: String, Codable, Sendable {
    case ready
    case needsConfig
    case locked
}

public struct WorkflowPlan: Identifiable, Codable, Equatable, Sendable {
    public var id: WorkflowPlanKind { kind }
    public var kind: WorkflowPlanKind
    public var title: String
    public var summary: String
    public var status: WorkflowPlanStatus
    public var steps: [WorkflowPlanStep]
    public var gates: [WorkflowSafetyGate]

    public init(
        kind: WorkflowPlanKind,
        title: String,
        summary: String,
        status: WorkflowPlanStatus,
        steps: [WorkflowPlanStep],
        gates: [WorkflowSafetyGate]
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.status = status
        self.steps = steps
        self.gates = gates
    }
}

public struct WorkflowPlanStep: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var command: [String]?
    public var endpoint: String?
    public var writesFiles: Bool
    public var isExecutableNow: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        command: [String]? = nil,
        endpoint: String? = nil,
        writesFiles: Bool = false,
        isExecutableNow: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.command = command
        self.endpoint = endpoint
        self.writesFiles = writesFiles
        self.isExecutableNow = isExecutableNow
    }
}

public struct WorkflowSafetyGate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var isSatisfied: Bool

    public init(id: UUID = UUID(), title: String, detail: String, isSatisfied: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isSatisfied = isSatisfied
    }
}

public struct WorkflowPlanner {
    public init() {}

    public func plans(for configuration: AppConfiguration, hasImmichAPIKey: Bool = false) -> [WorkflowPlan] {
        [
            importPlan(configuration),
            freeUpPlan(configuration),
            immichPlan(configuration, hasAPIKey: hasImmichAPIKey),
            editorPlan(configuration),
            metadataPlan(configuration)
        ]
    }

    private func importPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let source = URL(fileURLWithPath: expanded(configuration.importSourcePath), isDirectory: true)
        let archive = URL(fileURLWithPath: expanded(configuration.archivePath), isDirectory: true)
        let builder = rcloneBuilder(configuration)

        let copyCommand = (try? builder.copyCommand(source: source, destination: archive)) ?? []
        let checkCommand = (try? builder.checkCommand(source: source, destination: archive)) ?? []
        let manifest = archive.appendingPathComponent(Manifest.fileName)
        let hasPaths = !configuration.importSourcePath.isEmpty && !configuration.archivePath.isEmpty

        return WorkflowPlan(
            kind: .importArchive,
            title: "Archive Import",
            summary: "Plan source files into the archive with immutable copy, checksum verification, and manifest write. UI stays locked until real mode is explicitly enabled.",
            status: hasPaths ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(
                    title: "Scan Source",
                    detail: source.path,
                    writesFiles: false
                ),
                WorkflowPlanStep(
                    title: "Immutable Copy",
                    detail: "rclone copy with checksum and immutable flags.",
                    command: copyCommand,
                    writesFiles: true
                ),
                WorkflowPlanStep(
                    title: "Verify Archive",
                    detail: "Compare source and archive after copy.",
                    command: checkCommand,
                    writesFiles: false
                ),
                WorkflowPlanStep(
                    title: "Write Manifest",
                    detail: manifest.path,
                    writesFiles: true
                )
            ],
            gates: [
                WorkflowSafetyGate(title: "Source configured", detail: source.path, isSatisfied: !configuration.importSourcePath.isEmpty),
                WorkflowSafetyGate(title: "Archive configured", detail: archive.path, isSatisfied: !configuration.archivePath.isEmpty),
                WorkflowSafetyGate(title: "Real execution lock", detail: "Plan is displayed only; no bytes move from this UI.", isSatisfied: true)
            ]
        )
    }

    private func freeUpPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let buffer = URL(fileURLWithPath: expanded(configuration.bufferPath), isDirectory: true)
        let archive = URL(fileURLWithPath: expanded(configuration.archivePath), isDirectory: true)
        let trash = buffer.appendingPathComponent("_Trash", isDirectory: true)
        let checkCommand = (try? rcloneBuilder(configuration).checkCommand(source: buffer, destination: archive)) ?? []
        let hasPaths = !configuration.bufferPath.isEmpty && !configuration.archivePath.isEmpty

        return WorkflowPlan(
            kind: .freeUpBuffer,
            title: "Free-Up Buffer",
            summary: "Compare buffer against archive, quarantine only matched files into _Trash, then require a separate DELETE confirmation for permanent removal.",
            status: hasPaths ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Checksum Compare", detail: "Buffer must match archive before quarantine.", command: checkCommand),
                WorkflowPlanStep(title: "Quarantine Matches", detail: trash.path, writesFiles: true),
                WorkflowPlanStep(title: "Permanent Delete", detail: "Requires exact DELETE token and _Trash path.", writesFiles: true)
            ],
            gates: [
                WorkflowSafetyGate(title: "Buffer configured", detail: buffer.path, isSatisfied: !configuration.bufferPath.isEmpty),
                WorkflowSafetyGate(title: "Archive configured", detail: archive.path, isSatisfied: !configuration.archivePath.isEmpty),
                WorkflowSafetyGate(title: "Trash scoped", detail: trash.path, isSatisfied: trash.pathComponents.contains("_Trash")),
                WorkflowSafetyGate(title: "Real execution lock", detail: "Plan is displayed only; no quarantine/delete runs from this UI.", isSatisfied: true)
            ]
        )
    }

    private func immichPlan(_ configuration: AppConfiguration, hasAPIKey: Bool) -> WorkflowPlan {
        let baseURL = ImmichClient.normalizedAPIBaseURL(configuration.immichServerURL)
        let assetEndpoint = baseURL?.appendingPathComponent("assets").absoluteString ?? "Configure Immich server URL"
        let pingEndpoint = baseURL?
            .appendingPathComponent("server")
            .appendingPathComponent("ping")
            .absoluteString

        return WorkflowPlan(
            kind: .immichUpload,
            title: "Immich Upload",
            summary: "Use Immich as the view layer after archive verification. The upload endpoint and required multipart fields are planned, not executed.",
            status: baseURL != nil && hasAPIKey ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Ping Server", detail: "GET /server/ping", endpoint: pingEndpoint),
                WorkflowPlanStep(title: "Upload Asset", detail: "multipart fields: assetData, fileCreatedAt, fileModifiedAt", endpoint: assetEndpoint, writesFiles: true),
                WorkflowPlanStep(title: "Keep Archive Source of Truth", detail: expanded(configuration.archivePath), writesFiles: false)
            ],
            gates: [
                WorkflowSafetyGate(title: "Server URL configured", detail: configuration.immichServerURL.isEmpty ? "Missing" : configuration.immichServerURL, isSatisfied: baseURL != nil),
                WorkflowSafetyGate(title: "API key in Keychain", detail: hasAPIKey ? "Saved" : "Missing", isSatisfied: hasAPIKey),
                WorkflowSafetyGate(title: "Upload lock", detail: "No asset upload is exposed until archive verification is wired into the upload flow.", isSatisfied: true)
            ]
        )
    }

    private func editorPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let workingRoot = URL(fileURLWithPath: expanded(configuration.editorWorkingFolderPath), isDirectory: true)
        let hasWorkingRoot = !configuration.editorWorkingFolderPath.isEmpty
        let bundle = configuration.externalEditor.bundleIdentifier ?? "System default app"

        return WorkflowPlan(
            kind: .editorCheckout,
            title: "External Editor Checkout",
            summary: "Copy a selected photo into the working-copy folder before opening it in the configured editor.",
            status: hasWorkingRoot ? .ready : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Make Working Copy", detail: workingRoot.path, writesFiles: true, isExecutableNow: true),
                WorkflowPlanStep(title: "Open Editor", detail: "\(configuration.externalEditor.displayName) (\(bundle))", writesFiles: false, isExecutableNow: true)
            ],
            gates: [
                WorkflowSafetyGate(title: "Working folder configured", detail: workingRoot.path, isSatisfied: hasWorkingRoot),
                WorkflowSafetyGate(title: "Source original protected", detail: "Editors receive a copy, not the source path.", isSatisfied: true)
            ]
        )
    }

    private func metadataPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let source = URL(fileURLWithPath: expanded(configuration.importSourcePath), isDirectory: true)
        let command = [
            tool(configuration.exiftoolBinaryPath, fallback: "exiftool"),
            "-json",
            "-r",
            source.path
        ]

        return WorkflowPlan(
            kind: .metadataRead,
            title: "Metadata Read",
            summary: "Read camera metadata for preview, manifests, and future batch naming. This is planned as read-only.",
            status: configuration.importSourcePath.isEmpty ? .needsConfig : .locked,
            steps: [
                WorkflowPlanStep(title: "Read Metadata", detail: "Recursive JSON metadata scan.", command: command, writesFiles: false)
            ],
            gates: [
                WorkflowSafetyGate(title: "Read-only command", detail: "exiftool is planned without write flags.", isSatisfied: true),
                WorkflowSafetyGate(title: "Source configured", detail: source.path, isSatisfied: !configuration.importSourcePath.isEmpty)
            ]
        )
    }

    private func rcloneBuilder(_ configuration: AppConfiguration) -> RcloneCommandBuilder {
        RcloneCommandBuilder(binary: tool(configuration.rcloneBinaryPath, fallback: "rclone"))
    }

    private func tool(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : expanded(trimmed)
    }

    private func expanded(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
