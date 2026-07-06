import Foundation

public struct ActivityLogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var action: JobAction
    public var state: JobState
    public var title: String
    public var summary: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        action: JobAction,
        state: JobState,
        title: String,
        summary: String,
        detail: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.state = state
        self.title = title
        self.summary = summary
        self.detail = detail
    }
}

public struct ActivityLogStore {
    public let url: URL

    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> [ActivityLogEntry] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolkitError.commandFailed("Activity log is not valid UTF-8")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return text
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(ActivityLogEntry.self, from: Data(line.utf8))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func append(_ entry: ActivityLogEntry) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)

        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
