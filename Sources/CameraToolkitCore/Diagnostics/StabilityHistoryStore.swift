import Foundation

/// The feature's own small results file under Application Support —
/// remembered cable labels plus graded run records. No paths, no machine
/// names, nothing user-identifying beyond what the owner typed as labels.
public struct StabilityHistory: Codable, Equatable, Sendable {
    public var knownCableLabels: [String]
    public var records: [StabilityTestRecord]

    public init(knownCableLabels: [String] = [], records: [StabilityTestRecord] = []) {
        self.knownCableLabels = knownCableLabels
        self.records = records
    }

    /// Runs belonging to this drive — by volume UUID when known, falling
    /// back to the enclosure identity tuple so units sharing a placeholder
    /// serial still compare correctly.
    public func records(
        forVolumeUUID uuid: String?,
        enclosure: USBDeviceIdentity?
    ) -> [StabilityTestRecord] {
        records
            .filter { $0.isSameDrive(asVolumeUUID: uuid, enclosure: enclosure) }
            .sorted { $0.finishedAt > $1.finishedAt }
    }
}

/// Loads and saves `stability-tests.json` — atomic writes, tolerant reads
/// (a corrupt or missing file starts empty rather than failing), records
/// capped so the file stays small.
public struct StabilityHistoryStore: Sendable {
    /// Oldest records are dropped past this count.
    public static let recordLimit = 200

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultFileURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("CameraToolkit", isDirectory: true)
            .appendingPathComponent("stability-tests.json", isDirectory: false)
    }

    public func load() -> StabilityHistory {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return StabilityHistory()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StabilityHistory.self, from: data)) ?? StabilityHistory()
    }

    /// Appends a run and remembers its cable label for the picker.
    @discardableResult
    public func append(_ record: StabilityTestRecord) throws -> StabilityHistory {
        var history = load()
        history.records.insert(record, at: 0)
        if history.records.count > Self.recordLimit {
            history.records = Array(history.records.prefix(Self.recordLimit))
        }
        let label = record.cableLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, !history.knownCableLabels.contains(label) {
            history.knownCableLabels.append(label)
            history.knownCableLabels.sort()
        }
        try save(history)
        return history
    }

    /// Removes a run — for the history table's cleanup affordance.
    @discardableResult
    public func remove(recordID: UUID) throws -> StabilityHistory {
        var history = load()
        history.records.removeAll { $0.id == recordID }
        try save(history)
        return history
    }

    public func save(_ history: StabilityHistory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(history)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic write: a crash mid-save leaves the previous file intact.
        try data.write(to: url, options: [.atomic])
    }
}
