import Foundation
import GRDB

/// One SQLite value, kept as it was stored so a face row round-trips
/// byte for byte (embeddings and crops included).
public enum FaceSnapshotValue: Codable, Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let number): self = .integer(number)
        case .double(let number): self = .real(number)
        case .string(let text): self = .text(text)
        case .blob(let data): self = .blob(data)
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .integer(let number): number.databaseValue
        case .real(let number): number.databaseValue
        case .text(let text): text.databaseValue
        case .blob(let data): data.databaseValue
        }
    }

    var byteCount: Int {
        switch self {
        case .null, .integer, .real: 8
        case .text(let text): text.utf8.count
        case .blob(let data): data.count
        }
    }
}

/// A table row by column name.
public struct FaceSnapshotRow: Codable, Equatable, Sendable {
    public var values: [String: FaceSnapshotValue]

    public init(values: [String: FaceSnapshotValue]) {
        self.values = values
    }

    init(_ row: Row) {
        var values: [String: FaceSnapshotValue] = [:]
        for column in row.columnNames {
            let value: DatabaseValue = row[column]
            values[column] = FaceSnapshotValue(value)
        }
        self.values = values
    }

    public func text(_ column: String) -> String? {
        if case .text(let text)? = values[column] { return text }
        return nil
    }

    var byteCount: Int { values.values.reduce(0) { $0 + $1.byteCount } }
}

/// The face rows an action could change, as they were at one moment:
/// `people` and `faces` rows, and every template and rejection that names
/// one of them. Swapping it back (`FaceIndexStore.swapSnapshot`) writes
/// them in one transaction and hands back the rows it replaced, so the same
/// value serves Undo and then Redo.
public struct FaceSnapshot: Codable, Equatable, Sendable {
    /// Every person and face the snapshot speaks for — including one that
    /// has no row (it did not exist then).
    public var personIDs: [UUID]
    public var faceIDs: [UUID]
    public var people: [FaceSnapshotRow]
    public var faces: [FaceSnapshotRow]
    public var templates: [FaceSnapshotRow]
    public var rejections: [FaceSnapshotRow]

    public init(
        personIDs: [UUID] = [],
        faceIDs: [UUID] = [],
        people: [FaceSnapshotRow] = [],
        faces: [FaceSnapshotRow] = [],
        templates: [FaceSnapshotRow] = [],
        rejections: [FaceSnapshotRow] = []
    ) {
        self.personIDs = personIDs
        self.faceIDs = faceIDs
        self.people = people
        self.faces = faces
        self.templates = templates
        self.rejections = rejections
    }

    /// Roughly how much memory and disk the rows take.
    public var byteCount: Int {
        (people + faces + templates + rejections).reduce(0) { $0 + $1.byteCount }
    }
}

extension FaceIndexStore {
    /// The rows a face action can change, captured before it runs:
    ///
    /// - `expandingPeople`: people whose every face the action may move,
    ///   change or delete (a merge's source, a junked group) — their faces
    ///   come along;
    /// - `people`: people whose row, templates and rejections the action
    ///   touches without touching all of their faces (a tag's target);
    /// - `faces`: faces the action changes.
    ///
    /// The people the captured faces belong to, the approved person a
    /// "looks like" row points at, the rows that point at a captured person,
    /// and every template and rejection that names a captured person or
    /// face come along too.
    public func captureSnapshot(
        expandingPeople: Set<UUID> = [],
        people: Set<UUID> = [],
        faces: Set<UUID> = []
    ) throws -> FaceSnapshot {
        try readSnapshot { database in
            var faceIDs = faces
            for chunk in Self.chunks(Array(expandingPeople)) {
                for text in try String.fetchAll(
                    database,
                    sql: "SELECT id FROM faces WHERE person_id IN (\(Self.marks(chunk.count)))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = UUID(uuidString: text) { faceIDs.insert(id) }
                }
            }
            return try Self.capture(database, people: people.union(expandingPeople), faces: faceIDs, expanding: true)
        }
    }

    /// Writes `snapshot` back and returns the rows it replaced, in one
    /// transaction, so the same value serves Undo and then Redo.
    ///
    /// - a face the snapshot names but has no row for is removed;
    /// - a person the snapshot names but has no row for is removed;
    /// - a person that now holds the snapshot's faces but is not in it (a
    ///   group the action created) is removed once it is empty and not on
    ///   the roster;
    /// - templates and rejections of the snapshot's people and faces are
    ///   replaced by the snapshot's; other rows are untouched.
    @discardableResult
    public func swapSnapshot(_ snapshot: FaceSnapshot) throws -> FaceSnapshot {
        try inWriteTransaction { database in
            try database.execute(sql: "PRAGMA defer_foreign_keys = ON")
            let wantedPeople = Set(snapshot.personIDs)
            let wantedFaces = Set(snapshot.faceIDs)
            // Who holds the snapshot's faces right now — an action may have
            // moved them to a group it created.
            var involved = wantedPeople
            for chunk in Self.chunks(Array(wantedFaces)) {
                for text in try String.fetchAll(
                    database,
                    sql: "SELECT DISTINCT person_id FROM faces WHERE id IN (\(Self.marks(chunk.count))) AND person_id IS NOT NULL",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = UUID(uuidString: text) { involved.insert(id) }
                }
            }
            let replaced = try Self.capture(database, people: involved, faces: wantedFaces, expanding: false)

            for table in ["face_templates", "face_rejections"] {
                for chunk in Self.chunks(Array(involved)) {
                    try database.execute(
                        sql: "DELETE FROM \(table) WHERE person_id IN (\(Self.marks(chunk.count)))",
                        arguments: StatementArguments(chunk.map(\.uuidString))
                    )
                }
                for chunk in Self.chunks(Array(wantedFaces)) {
                    try database.execute(
                        sql: "DELETE FROM \(table) WHERE face_id IN (\(Self.marks(chunk.count)))",
                        arguments: StatementArguments(chunk.map(\.uuidString))
                    )
                }
            }
            let keptFaces = Set(snapshot.faces.compactMap { $0.text("id") })
            for face in wantedFaces where !keptFaces.contains(face.uuidString) {
                try database.execute(sql: "DELETE FROM faces WHERE id = ?", arguments: [face.uuidString])
            }

            // People first, their "looks like" pointers after (a pointer may
            // name a row later in the list), then faces.
            for row in snapshot.people {
                var plain = row.values
                plain["suggested_person_id"] = FaceSnapshotValue.null
                try Self.upsert(database, table: "people", key: "id", values: plain)
            }
            for row in snapshot.people {
                guard case .text(let target)? = row.values["suggested_person_id"],
                      case .text(let id)? = row.values["id"],
                      try Self.exists(database, table: "people", id: target) else { continue }
                try database.execute(
                    sql: "UPDATE people SET suggested_person_id = ? WHERE id = ?",
                    arguments: [target, id]
                )
            }
            for row in snapshot.faces {
                var values = row.values
                // A face whose person is gone is left unassigned rather than
                // failing the whole step.
                if case .text(let holder)? = values["person_id"],
                   try !Self.exists(database, table: "people", id: holder) {
                    values["person_id"] = .null
                }
                try Self.upsert(database, table: "faces", key: "id", values: values)
            }
            for (table, rows) in [("face_templates", snapshot.templates), ("face_rejections", snapshot.rejections)] {
                for row in rows {
                    guard case .text(let person)? = row.values["person_id"],
                          case .text(let face)? = row.values["face_id"],
                          try Self.exists(database, table: "people", id: person),
                          try Self.exists(database, table: "faces", id: face) else { continue }
                    let columns = row.values.keys.sorted()
                    try database.execute(
                        sql: """
                        INSERT OR IGNORE INTO \(table)(\(columns.joined(separator: ", ")))
                        VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
                        """,
                        arguments: Self.arguments(columns.map { row.values[$0]!.databaseValue })
                    )
                }
            }
            // People the snapshot says do not exist, and groups the action
            // made that nothing lives in any more.
            let keptPeople = Set(snapshot.people.compactMap { $0.text("id") })
            for person in wantedPeople where !keptPeople.contains(person.uuidString) {
                try database.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [person.uuidString])
            }
            for person in involved.subtracting(wantedPeople) {
                try database.execute(
                    sql: """
                    DELETE FROM people WHERE id = ? AND is_roster = 0
                      AND NOT EXISTS(SELECT 1 FROM faces WHERE faces.person_id = people.id)
                    """,
                    arguments: [person.uuidString]
                )
            }
            try refreshFaceCounts(database: database)
            return replaced
        }
    }

    private static func chunks(_ ids: [UUID], size: Int = 400) -> [[UUID]] {
        guard !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// The rows for these people and faces. `expanding` also adds the people
    /// the faces belong to, their "looks like" targets, and the rows that
    /// point at a person named; a swap passes the exact sets it wants.
    private static func capture(
        _ database: Database,
        people wanted: Set<UUID>,
        faces: Set<UUID>,
        expanding: Bool
    ) throws -> FaceSnapshot {
        var people = wanted
        if expanding {
            for chunk in chunks(Array(faces)) {
                for text in try String.fetchAll(
                    database,
                    sql: "SELECT DISTINCT person_id FROM faces WHERE id IN (\(marks(chunk.count))) AND person_id IS NOT NULL",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = UUID(uuidString: text) { people.insert(id) }
                }
            }
            for chunk in chunks(Array(people)) {
                for text in try String.fetchAll(
                    database,
                    sql: "SELECT DISTINCT suggested_person_id FROM people WHERE id IN (\(marks(chunk.count))) AND suggested_person_id IS NOT NULL",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = UUID(uuidString: text) { people.insert(id) }
                }
            }
            for chunk in chunks(Array(wanted)) {
                for text in try String.fetchAll(
                    database,
                    sql: "SELECT id FROM people WHERE suggested_person_id IN (\(marks(chunk.count)))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = UUID(uuidString: text) { people.insert(id) }
                }
            }
        }
        var snapshot = FaceSnapshot(
            personIDs: people.sorted { $0.uuidString < $1.uuidString },
            faceIDs: faces.sorted { $0.uuidString < $1.uuidString }
        )
        for chunk in chunks(Array(people)) {
            snapshot.people += try Row.fetchAll(
                database,
                sql: "SELECT * FROM people WHERE id IN (\(marks(chunk.count))) ORDER BY id",
                arguments: StatementArguments(chunk.map(\.uuidString))
            ).map(FaceSnapshotRow.init)
        }
        for chunk in chunks(Array(faces)) {
            snapshot.faces += try Row.fetchAll(
                database,
                sql: "SELECT * FROM faces WHERE id IN (\(marks(chunk.count))) ORDER BY id",
                arguments: StatementArguments(chunk.map(\.uuidString))
            ).map(FaceSnapshotRow.init)
        }
        for (table, keyPath) in [("face_templates", \FaceSnapshot.templates), ("face_rejections", \FaceSnapshot.rejections)] {
            var seen: Set<String> = []
            var rows: [FaceSnapshotRow] = []
            func collect(_ column: String, _ chunk: [UUID]) throws {
                for row in try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM \(table) WHERE \(column) IN (\(marks(chunk.count)))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    let key = "\(row["person_id"] as String)|\(row["face_id"] as String)"
                    if seen.insert(key).inserted { rows.append(FaceSnapshotRow(row)) }
                }
            }
            for chunk in chunks(Array(people)) { try collect("person_id", chunk) }
            for chunk in chunks(Array(faces)) { try collect("face_id", chunk) }
            rows.sort { ($0.text("person_id") ?? "", $0.text("face_id") ?? "") < ($1.text("person_id") ?? "", $1.text("face_id") ?? "") }
            snapshot[keyPath: keyPath] = rows
        }
        return snapshot
    }

    private static func arguments(_ values: [DatabaseValue]) -> StatementArguments {
        StatementArguments(values.map { Optional<any DatabaseValueConvertible>($0) })
    }

    private static func exists(_ database: Database, table: String, id: String) throws -> Bool {
        try Int.fetchOne(database, sql: "SELECT 1 FROM \(table) WHERE id = ?", arguments: [id]) != nil
    }

    /// Inserts a row, or overwrites the columns of the row with the same
    /// key — never a delete-and-insert, so nothing that points at the row
    /// is nulled on the way.
    private static func upsert(_ database: Database, table: String, key: String, values: [String: FaceSnapshotValue]) throws {
        let columns = values.keys.sorted()
        let updates = columns.filter { $0 != key }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try database.execute(
            sql: """
            INSERT INTO \(table)(\(columns.joined(separator: ", ")))
            VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
            ON CONFLICT(\(key)) DO UPDATE SET \(updates)
            """,
            arguments: arguments(columns.map { values[$0]!.databaseValue })
        )
    }
}
