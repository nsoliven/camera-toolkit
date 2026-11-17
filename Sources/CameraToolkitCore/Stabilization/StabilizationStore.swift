import Foundation
import GRDB

/// Per-clip stabilization in the catalog, by file identity key
/// (`DisplayRotation.fileKey`), beside the colour grades. A row means
/// "stabilize this clip with these settings"; no row means off.
///
/// The table was added after `color_grades`: a new table only, nothing
/// altered, created by `CatalogStore`'s schema and again here on first use
/// (an older catalog gains it the first time it is opened by this build).
public final class StabilizationStore: @unchecked Sendable {
    public static let tableName = "clip_stabilization"
    public static let schema = """
    CREATE TABLE IF NOT EXISTS clip_stabilization (
        file_key TEXT PRIMARY KEY,
        settings TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """

    public let catalogURL: URL

    public init(catalogURL: URL) {
        self.catalogURL = catalogURL
    }

    private func writer() throws -> any DatabaseWriter {
        let writer = try CatalogDatabase.writer(for: catalogURL)
        try writer.write { try $0.execute(sql: Self.schema) }
        return writer
    }

    /// Every stabilized clip. A row this build cannot read is skipped (the
    /// clip shows unstabilized), never fatal.
    public func load() throws -> [String: StabilizationSettings] {
        try writer().read { database in
            var result: [String: StabilizationSettings] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT file_key, settings FROM clip_stabilization") {
                if let settings = StabilizationSettings.fromCatalogJSON(row["settings"]) {
                    result[row["file_key"]] = settings
                }
            }
            return result
        }
    }

    /// Sets (a value) or clears (nil) each key, in one transaction.
    public func save(_ changes: [String: StabilizationSettings?]) throws {
        guard !changes.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try writer().write { database in
            for (key, settings) in changes {
                if let settings {
                    try database.execute(
                        sql: """
                        INSERT INTO clip_stabilization(file_key, settings, updated_at) VALUES (?, ?, ?)
                        ON CONFLICT(file_key) DO UPDATE SET settings = excluded.settings, updated_at = excluded.updated_at
                        """,
                        arguments: [key, settings.catalogJSON(), now]
                    )
                } else {
                    try database.execute(sql: "DELETE FROM clip_stabilization WHERE file_key = ?", arguments: [key])
                }
            }
        }
    }
}
