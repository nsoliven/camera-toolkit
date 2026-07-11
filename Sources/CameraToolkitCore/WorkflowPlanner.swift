import Foundation

public enum WorkflowPlanKind: String, Codable, CaseIterable, Sendable {
    case ingestBuffer
    case importArchive
    case freeUpBuffer
    case immichUpload
    case editorCheckout
    case metadataRead

    public var displayName: String {
        switch self {
        case .ingestBuffer: "Copy to Buffer"
        case .importArchive: "Save Buffer to Library"
        case .freeUpBuffer: "Clear Buffer Space"
        case .immichUpload: "Send to Immich"
        case .editorCheckout: "Edit a Copy"
        case .metadataRead: "Read Photo Info"
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
            ingestBufferPlan(configuration),
            importPlan(configuration),
            freeUpPlan(configuration),
            immichPlan(configuration, hasAPIKey: hasImmichAPIKey),
            editorPlan(configuration),
            metadataPlan(configuration)
        ]
    }

    private func ingestBufferPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let source = URL(fileURLWithPath: expanded(configuration.importSourcePath), isDirectory: true)
        let bufferBatch = URL(fileURLWithPath: expanded(configuration.bufferIngestFolderPath()), isDirectory: true)
        let builder = rcloneBuilder(configuration)

        let copyCommand = (try? builder.copyCommand(source: source, destination: bufferBatch)) ?? []
        let checkCommand = (try? builder.checkCommand(source: source, destination: bufferBatch)) ?? []
        let hasPaths = !configuration.importSourcePath.isEmpty && !configuration.bufferPath.isEmpty

        return WorkflowPlan(
            kind: .ingestBuffer,
            title: "Copy to Buffer",
            summary: "Copy the selected camera folder into the buffer. This never deletes the original files and never overwrites conflicts.",
            status: hasPaths ? .ready : .needsConfig,
            steps: [
                WorkflowPlanStep(
                    title: "Scan From Folder",
                    detail: source.path,
                    writesFiles: false,
                    isExecutableNow: hasPaths
                ),
                WorkflowPlanStep(
                    title: "Copy to Buffer",
                    detail: bufferBatch.path,
                    command: copyCommand,
                    writesFiles: true,
                    isExecutableNow: hasPaths
                ),
                WorkflowPlanStep(
                    title: "Check the Copy",
                    detail: "Compare the from folder against the buffer before you clear the camera folder.",
                    command: checkCommand,
                    writesFiles: false,
                    isExecutableNow: hasPaths
                )
            ],
            gates: [
                WorkflowSafetyGate(title: "From folder selected", detail: source.path, isSatisfied: !configuration.importSourcePath.isEmpty),
                WorkflowSafetyGate(title: "Buffer configured", detail: bufferBatch.path, isSatisfied: !configuration.bufferPath.isEmpty),
                WorkflowSafetyGate(title: "Copy only", detail: "No deletes, no overwrites, no one-way sync.", isSatisfied: true)
            ]
        )
    }

    private func importPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let bufferOriginals = URL(fileURLWithPath: expanded(configuration.bufferIngestFolderPath()), isDirectory: true)
        let bufferExports = URL(fileURLWithPath: expanded(configuration.bufferExportsFolderPath()), isDirectory: true)
        let archiveOriginals = URL(fileURLWithPath: expanded(configuration.libraryBatchFolderPath(.originals)), isDirectory: true)
        let archiveEdited = URL(fileURLWithPath: expanded(configuration.libraryBatchFolderPath(.edited)), isDirectory: true)
        let builder = rcloneBuilder(configuration)

        let copyOriginalsCommand = (try? builder.copyCommand(source: bufferOriginals, destination: archiveOriginals)) ?? []
        let copyExportsCommand = (try? builder.copyCommand(source: bufferExports, destination: archiveEdited)) ?? []
        let checkOriginalsCommand = (try? builder.checkCommand(source: bufferOriginals, destination: archiveOriginals)) ?? []
        let manifest = URL(fileURLWithPath: expanded(configuration.libraryBatchFolderPath(.manifests)), isDirectory: true)
            .appendingPathComponent(Manifest.fileName)
        let hasPaths = !configuration.bufferPath.isEmpty && !configuration.cameraLibraryRootPath.isEmpty

        return WorkflowPlan(
            kind: .importArchive,
            title: "Save Buffer to Photo Library",
            summary: "Copy buffer originals into Library Originals and finished exports into Library Edited. The app still requires proof before it unlocks real library writes.",
            status: hasPaths ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(
                    title: "Scan Buffer Folder",
                    detail: URL(fileURLWithPath: expanded(configuration.bufferBatchFolderPath()), isDirectory: true).path,
                    writesFiles: false
                ),
                WorkflowPlanStep(
                    title: "Copy Originals to Library",
                    detail: archiveOriginals.path,
                    command: copyOriginalsCommand,
                    writesFiles: true
                ),
                WorkflowPlanStep(
                    title: "Copy Edited Files",
                    detail: archiveEdited.path,
                    command: copyExportsCommand,
                    writesFiles: true
                ),
                WorkflowPlanStep(
                    title: "Check Originals",
                    detail: "Compare buffer originals and library originals after copy.",
                    command: checkOriginalsCommand,
                    writesFiles: false
                ),
                WorkflowPlanStep(
                    title: "Save Photo List + Proof File",
                    detail: "\(configuration.catalogDatabasePath) and \(manifest.path)",
                    writesFiles: true
                )
            ],
            gates: [
                WorkflowSafetyGate(title: "Buffer folder selected", detail: bufferOriginals.path, isSatisfied: !configuration.bufferPath.isEmpty),
                WorkflowSafetyGate(title: "Photo library selected", detail: archiveOriginals.path, isSatisfied: !configuration.cameraLibraryRootPath.isEmpty),
                WorkflowSafetyGate(title: "Photo list selected", detail: configuration.catalogDatabasePath.isEmpty ? "Missing" : configuration.catalogDatabasePath, isSatisfied: !configuration.catalogDatabasePath.isEmpty),
                WorkflowSafetyGate(title: "Real copy is locked", detail: "This screen explains the move first; it will not copy files until that path is unlocked.", isSatisfied: true)
            ]
        )
    }

    private func freeUpPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let bufferBatch = URL(fileURLWithPath: expanded(configuration.bufferBatchFolderPath()), isDirectory: true)
        let bufferOriginals = URL(fileURLWithPath: expanded(configuration.bufferIngestFolderPath()), isDirectory: true)
        let archiveOriginals = URL(fileURLWithPath: expanded(configuration.libraryBatchFolderPath(.originals)), isDirectory: true)
        let trash = bufferBatch.appendingPathComponent("_Trash", isDirectory: true)
        let checkCommand = (try? rcloneBuilder(configuration).checkCommand(source: bufferOriginals, destination: archiveOriginals)) ?? []
        let hasPaths = !configuration.bufferPath.isEmpty && !configuration.cameraLibraryRootPath.isEmpty

        return WorkflowPlan(
            kind: .freeUpBuffer,
            title: "Clear Buffer Space",
            summary: "Check buffer originals against library originals. Only files already proven in the photo library can be moved aside.",
            status: hasPaths ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Compare Files", detail: "Buffer originals must match library originals first.", command: checkCommand),
                WorkflowPlanStep(title: "Move Matched Files Aside", detail: trash.path, writesFiles: true),
                WorkflowPlanStep(title: "Delete Later", detail: "Requires typing DELETE and uses only the buffer _Trash folder.", writesFiles: true)
            ],
            gates: [
                WorkflowSafetyGate(title: "Buffer folder selected", detail: bufferBatch.path, isSatisfied: !configuration.bufferPath.isEmpty),
                WorkflowSafetyGate(title: "Photo library selected", detail: archiveOriginals.path, isSatisfied: !configuration.cameraLibraryRootPath.isEmpty),
                WorkflowSafetyGate(title: "Move-aside folder selected", detail: trash.path, isSatisfied: trash.pathComponents.contains("_Trash")),
                WorkflowSafetyGate(title: "Real delete is locked", detail: "This screen explains the move first; it will not move/delete files until that path is unlocked.", isSatisfied: true)
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
            title: "Send to Immich",
            summary: "Use Immich after the photo library copy is checked. This app plans the upload but does not upload files yet.",
            status: baseURL != nil && hasAPIKey ? .locked : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Check Server", detail: "GET /server/ping", endpoint: pingEndpoint),
                WorkflowPlanStep(title: "Upload Photo", detail: "photo bytes, created time, modified time", endpoint: assetEndpoint, writesFiles: true),
                WorkflowPlanStep(title: "Keep Photo Library as Truth", detail: expanded(configuration.archivePath), writesFiles: false)
            ],
            gates: [
                WorkflowSafetyGate(title: "Server URL configured", detail: configuration.immichServerURL.isEmpty ? "Missing" : configuration.immichServerURL, isSatisfied: baseURL != nil),
                WorkflowSafetyGate(title: "API key in Keychain", detail: hasAPIKey ? "Saved" : "Missing", isSatisfied: hasAPIKey),
                WorkflowSafetyGate(title: "Upload is locked", detail: "No upload button is exposed until the library copy check is connected to this flow.", isSatisfied: true)
            ]
        )
    }

    private func editorPlan(_ configuration: AppConfiguration) -> WorkflowPlan {
        let workingRoot = URL(fileURLWithPath: expanded(configuration.editorWorkingFolderPath), isDirectory: true)
        let hasWorkingRoot = !configuration.editorWorkingFolderPath.isEmpty
        let bundle = configuration.externalEditor.bundleIdentifier ?? "System default app"

        return WorkflowPlan(
            kind: .editorCheckout,
            title: "Edit a Copy",
            summary: "Copy a selected photo into the edit folder before opening it.",
            status: hasWorkingRoot ? .ready : .needsConfig,
            steps: [
                WorkflowPlanStep(title: "Make Edit Copy", detail: workingRoot.path, writesFiles: true, isExecutableNow: true),
                WorkflowPlanStep(title: "Open App", detail: "\(configuration.externalEditor.displayName) (\(bundle))", writesFiles: false, isExecutableNow: true)
            ],
            gates: [
                WorkflowSafetyGate(title: "Working folder configured", detail: workingRoot.path, isSatisfied: hasWorkingRoot),
                WorkflowSafetyGate(title: "Original protected", detail: "Editors receive a copy, not the original file.", isSatisfied: true)
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
            title: "Read Photo Info",
            summary: "Read photo info for previews, proof files, and future batch naming. This does not change files.",
            status: configuration.importSourcePath.isEmpty ? .needsConfig : .locked,
            steps: [
                WorkflowPlanStep(title: "Read Photo Info", detail: "Read info from files and folders.", command: command, writesFiles: false)
            ],
            gates: [
                WorkflowSafetyGate(title: "Read only", detail: "exiftool is planned without write flags.", isSatisfied: true),
                WorkflowSafetyGate(title: "From folder selected", detail: source.path, isSatisfied: !configuration.importSourcePath.isEmpty)
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
