import Foundation

extension Notification.Name {
    static let cameraToolkitShowTransferQueue = Notification.Name("CameraToolkitShowTransferQueue")
}

enum TransferQueueState: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum TransferQueueItemState: String, Codable, Sendable {
    case waiting
    case copying
    case copied
    case verifying
    case verified
    case alreadyPresent
    case conflict
    case failed

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .copying: "Copying"
        case .copied: "Copied"
        case .verifying: "Verifying"
        case .verified: "Verified"
        case .alreadyPresent: "Already verified"
        case .conflict: "Conflict"
        case .failed: "Stopped"
        }
    }
}

struct TransferQueueItemStatusText: Equatable, Sendable {
    var label: String
    var detail: String?
}

struct TransferQueueItem: Identifiable, Codable, Sendable {
    var id: UUID
    var relativePath: String
    var size: Int64
    var copiedBytes: Int64
    var state: TransferQueueItemState
    var detail: String?

    init(
        id: UUID = UUID(),
        relativePath: String,
        size: Int64,
        copiedBytes: Int64 = 0,
        state: TransferQueueItemState = .waiting,
        detail: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.size = size
        self.copiedBytes = copiedBytes
        self.state = state
        self.detail = detail
    }
}

struct TransferQueueSnapshot: Codable, Sendable {
    var id: UUID
    var state: TransferQueueState
    var sourcePath: String
    var destinationPath: String
    var items: [TransferQueueItem]
    var progress: Double
    var processedBytes: Int64
    var totalBytes: Int64
    var phaseProcessedBytes: Int64?
    var phaseTotalBytes: Int64?
    var bytesPerSecond: Double
    var phase: String
    var message: String?
    var technicalDetail: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        state: TransferQueueState = .running,
        sourcePath: String,
        destinationPath: String,
        items: [TransferQueueItem],
        progress: Double = 0,
        processedBytes: Int64 = 0,
        totalBytes: Int64,
        phaseProcessedBytes: Int64? = nil,
        phaseTotalBytes: Int64? = nil,
        bytesPerSecond: Double = 0,
        phase: String = "Preparing transfer",
        message: String? = nil,
        technicalDetail: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.state = state
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.items = items
        self.progress = progress
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.phaseProcessedBytes = phaseProcessedBytes
        self.phaseTotalBytes = phaseTotalBytes
        self.bytesPerSecond = bytesPerSecond
        self.phase = phase
        self.message = message
        self.technicalDetail = technicalDetail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var verifiedCount: Int {
        items.count { $0.state == .verified || $0.state == .alreadyPresent }
    }

    func statusText(for item: TransferQueueItem) -> TransferQueueItemStatusText {
        guard item.state == .waiting else {
            return TransferQueueItemStatusText(label: item.state.label, detail: nil)
        }

        switch state {
        case .failed:
            return TransferQueueItemStatusText(label: "Not started", detail: "transfer stopped")
        case .cancelled:
            return TransferQueueItemStatusText(label: "Not started", detail: "transfer cancelled")
        case .completed:
            return TransferQueueItemStatusText(label: "Not started", detail: "needs attention")
        case .running:
            guard let index = items.firstIndex(where: { $0.id == item.id }) else {
                return TransferQueueItemStatusText(label: "Waiting", detail: "for its turn")
            }
            let hasActiveItem = items.contains { $0.state == .copying || $0.state == .verifying }
            let firstWaitingIndex = items.firstIndex { $0.state == .waiting }
            if !hasActiveItem, firstWaitingIndex == index {
                let detail = index == 0 ? "opening drives" : "opening next file"
                return TransferQueueItemStatusText(label: "Starting", detail: detail)
            }
            return TransferQueueItemStatusText(label: "Waiting", detail: "for file \(index)")
        }
    }
}

struct TransferQueueStore {
    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() throws -> TransferQueueSnapshot? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TransferQueueSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: TransferQueueSnapshot) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
