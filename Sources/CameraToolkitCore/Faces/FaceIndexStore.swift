import Foundation
import GRDB

/// Read/write access to the face tables inside the app's catalog database.
///
/// The tables are created by `CatalogStore.bootstrap`; this store only works
/// with rows. All writes go through one GRDB queue so callers on background
/// threads serialize safely, and foreign keys are on so deleted people drop
/// their template links and free their faces.
public final class FaceIndexStore: @unchecked Sendable {
    public let url: URL
    private let queueLock = NSLock()
    private var queue: DatabaseQueue?

    public init(url: URL) {
        self.url = url
    }

    private func database() throws -> DatabaseQueue {
        queueLock.lock()
        defer { queueLock.unlock() }
        if let queue { return queue }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        self.queue = queue
        return queue
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func timestamp(_ date: Date, _ formatter: ISO8601DateFormatter) -> String {
        formatter.string(from: date)
    }

    // MARK: - Photo identity and scan-grade skip rules

    /// The file-identity key used to attribute scanned photos to event
    /// assignments: name + byte count + modification second. It survives a
    /// file moving between the unsorted folder and an event folder, which a
    /// path key cannot.
    public static func fileKey(fileName: String, byteCount: Int64, modifiedAt: Date) -> String {
        let seconds = Int64(modifiedAt.timeIntervalSince1970.rounded())
        return "\(fileName)|\(byteCount)|\(seconds)"
    }

    /// Known photo rows for the given path keys, for the new-files-only skip
    /// rule and the changed-file (same path, new size/mtime) rule.
    public func photos(pathKeys: [String]) throws -> [String: FacePhotoRecord] {
        guard !pathKeys.isEmpty else { return [:] }
        return try database().read { database in
            var result: [String: FacePhotoRecord] = [:]
            // Chunked IN lookups stay well under SQLite's bound-variable
            // limit while keeping one round trip per ~400 keys.
            for chunk in stride(from: 0, to: pathKeys.count, by: 400) {
                let keys = Array(pathKeys[chunk..<min(chunk + 400, pathKeys.count)])
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM face_photos WHERE path_key IN (\(placeholders))",
                    arguments: StatementArguments(keys)
                )
                for row in rows {
                    let record = Self.photoRecord(row)
                    result[record.pathKey] = record
                }
            }
            return result
        }
    }

    /// Inserts or replaces a photo's detected faces. Confirmed faces are
    /// never touched, and a fresh detection whose box overlaps a confirmed
    /// face is dropped instead of duplicating it.
    public func replaceFaces(
        photo: FacePhotoRecord,
        faces: [FaceRecord],
        confirmedOverlap: Double = 0.5
    ) throws {
        let formatter = Self.formatter()
        let now = formatter.string(from: Date())
        try database().write { database in
            let confirmed = try Row.fetchAll(
                database,
                sql: "SELECT box_x, box_y, box_w, box_h FROM faces WHERE photo_id = ? AND state = 'confirmed'",
                arguments: [photo.pathKey]
            ).map(Self.box)

            try database.execute(
                sql: """
                INSERT INTO face_photos(
                    path_key, path, file_name, byte_count, modified_at,
                    taken_at, scan_grade, face_count, indexed_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path_key) DO UPDATE SET
                    path = excluded.path,
                    file_name = excluded.file_name,
                    byte_count = excluded.byte_count,
                    modified_at = excluded.modified_at,
                    taken_at = excluded.taken_at,
                    scan_grade = excluded.scan_grade,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    photo.pathKey,
                    photo.path,
                    photo.fileName,
                    photo.byteCount,
                    Self.timestamp(photo.modifiedAt, formatter),
                    photo.takenAt.map { Self.timestamp($0, formatter) },
                    photo.scanGrade.rawValue,
                    photo.faceCount,
                    now,
                    now,
                ]
            )

            try database.execute(
                sql: "DELETE FROM faces WHERE photo_id = ? AND state != 'confirmed'",
                arguments: [photo.pathKey]
            )

            for face in faces {
                if confirmed.contains(where: { face.box.iou(with: $0) > confirmedOverlap }) {
                    continue
                }
                try insertFace(face, database: database, now: now, formatter: formatter)
            }

            // face_count reflects every face row that remains — kept
            // confirmed faces plus the new detections that survived dedupe.
            try database.execute(
                sql: """
                UPDATE face_photos SET face_count = (
                    SELECT COUNT(*) FROM faces WHERE faces.photo_id = face_photos.path_key
                ) WHERE path_key = ?
                """,
                arguments: [photo.pathKey]
            )
        }
    }

    /// Marks a file covered at a grade without scanning it — used for burst
    /// members whose siblings were sampled. Existing face rows stay while
    /// the file identity still matches; a changed file's unconfirmed rows
    /// describe other bytes and are dropped. Confirmed faces are never
    /// touched, and the stamped grade keeps the file out of later scans.
    public func markCovered(photo: FacePhotoRecord) throws {
        let formatter = Self.formatter()
        let now = formatter.string(from: Date())
        try database().write { database in
            let stale = try Row.fetchOne(
                database,
                sql: "SELECT byte_count, modified_at FROM face_photos WHERE path_key = ?",
                arguments: [photo.pathKey]
            ).map { row -> Bool in
                let size: Int64 = row["byte_count"]
                let stamp: String = row["modified_at"]
                return size != photo.byteCount
                    || abs((formatter.date(from: stamp) ?? .distantPast).timeIntervalSince(photo.modifiedAt)) >= 1
            } ?? false
            if stale {
                try database.execute(
                    sql: "DELETE FROM faces WHERE photo_id = ? AND state != 'confirmed'",
                    arguments: [photo.pathKey]
                )
            }
            try database.execute(
                sql: """
                INSERT INTO face_photos(
                    path_key, path, file_name, byte_count, modified_at,
                    taken_at, scan_grade, face_count, indexed_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(path_key) DO UPDATE SET
                    path = excluded.path,
                    file_name = excluded.file_name,
                    byte_count = excluded.byte_count,
                    modified_at = excluded.modified_at,
                    taken_at = excluded.taken_at,
                    scan_grade = excluded.scan_grade,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    photo.pathKey,
                    photo.path,
                    photo.fileName,
                    photo.byteCount,
                    Self.timestamp(photo.modifiedAt, formatter),
                    photo.takenAt.map { Self.timestamp($0, formatter) },
                    photo.scanGrade.rawValue,
                    now,
                    now,
                ]
            )
            try database.execute(
                sql: """
                UPDATE face_photos SET face_count = (
                    SELECT COUNT(*) FROM faces WHERE faces.photo_id = face_photos.path_key
                ) WHERE path_key = ?
                """,
                arguments: [photo.pathKey]
            )
        }
    }

    /// The face select shared by every read: joins `face_photos` so each
    /// record carries its photo's last-known path for display.
    private static let faceSelect = """
        SELECT f.*, ph.path AS photo_path FROM faces f
        LEFT JOIN face_photos ph ON ph.path_key = f.photo_id
        """

    /// Faces on a photo that may still move — everything but confirmed.
    public func faces(photoID: String) throws -> [FaceRecord] {
        try database().read { database in
            try faces(photoID: photoID, database: database)
        }
    }

    private func faces(photoID: String, database: Database) throws -> [FaceRecord] {
        try Row.fetchAll(
            database,
            sql: "\(Self.faceSelect) WHERE f.photo_id = ? ORDER BY f.det_score DESC",
            arguments: [photoID]
        ).map { Self.faceRecord($0) }
    }

    /// Photo rows matching a file's identity — name + byte count + modified
    /// second, the same key `fileKey` composes — regardless of where the
    /// file sits now. This is the lookup that keeps faces attached when a
    /// file moves between the unsorted folder and an event folder.
    public func photos(fileName: String, byteCount: Int64, modifiedAt: Date) throws -> [FacePhotoRecord] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM face_photos WHERE file_name = ? AND byte_count = ?",
                arguments: [fileName, byteCount]
            )
            .map(Self.photoRecord)
            .filter { abs($0.modifiedAt.timeIntervalSince(modifiedAt)) < 1 }
        }
    }

    /// Faces on a photo looked up by file identity instead of path, so a
    /// file scanned in the unsorted folder keeps its faces after moving
    /// into an event folder. When several photo rows share the identity —
    /// the same file scanned under different paths — the rows merge and
    /// overlapping boxes dedupe with the rescan's IoU rule: confirmed faces
    /// always win an overlap (a confirmed tag is never shadowed by a bare
    /// re-detection), then `preferredPathKey`'s row.
    public func faces(
        fileName: String,
        byteCount: Int64,
        modifiedAt: Date,
        preferredPathKey: String? = nil
    ) throws -> [FaceRecord] {
        let records = try photos(fileName: fileName, byteCount: byteCount, modifiedAt: modifiedAt)
        let ordered = records.sorted { lhs, rhs in
            let leftPreferred = lhs.pathKey == preferredPathKey
            let rightPreferred = rhs.pathKey == preferredPathKey
            if leftPreferred != rightPreferred { return leftPreferred }
            if lhs.scanGrade != rhs.scanGrade { return lhs.scanGrade > rhs.scanGrade }
            return lhs.faceCount > rhs.faceCount
        }
        var stream: [FaceRecord] = []
        for record in ordered {
            stream.append(contentsOf: try faces(photoID: record.pathKey))
        }
        // Confirmed faces merge first so they claim overlaps before any
        // unconfirmed duplicate of the same detection.
        let deduped = stream.filter { $0.state == .confirmed }
        var faces = deduped
        for face in stream where face.state != .confirmed {
            let duplicate = faces.contains { existing in
                existing.box.iou(with: face.box) > 0.5
            }
            if !duplicate { faces.append(face) }
        }
        return faces
    }

    /// Inserts a face the owner placed by hand. Manual tags are `confirmed`
    /// from the start — frozen like any confirmed face, so no rescan or
    /// re-match reclassifies them. The photo row is created at grade
    /// `.none` when the file was never scanned; an existing row keeps its
    /// scan grade and refreshes its location/identity. When the row's
    /// recorded bytes no longer match the file, stale non-confirmed
    /// detections are dropped — the same rule `markCovered` applies.
    ///
    /// A box drawn over an existing detection claims it instead of
    /// inserting a duplicate: an unconfirmed face is promoted to confirmed
    /// (keeping its embedding and crop); an already-confirmed face is
    /// frozen and returned untouched.
    @discardableResult
    public func addManualFace(
        photo: FacePhotoRecord,
        box: NormalizedFaceBox,
        personID: UUID,
        crop: Data? = nil
    ) throws -> FaceRecord {
        let formatter = Self.formatter()
        let now = formatter.string(from: Date())
        return try database().write { database -> FaceRecord in
            let stale = try Row.fetchOne(
                database,
                sql: "SELECT byte_count, modified_at FROM face_photos WHERE path_key = ?",
                arguments: [photo.pathKey]
            ).map { row -> Bool in
                let size: Int64 = row["byte_count"]
                let stamp: String = row["modified_at"]
                return size != photo.byteCount
                    || abs((formatter.date(from: stamp) ?? .distantPast).timeIntervalSince(photo.modifiedAt)) >= 1
            } ?? false
            if stale {
                try database.execute(
                    sql: "DELETE FROM faces WHERE photo_id = ? AND state != 'confirmed'",
                    arguments: [photo.pathKey]
                )
            }
            try database.execute(
                sql: """
                INSERT INTO face_photos(
                    path_key, path, file_name, byte_count, modified_at,
                    taken_at, scan_grade, face_count, indexed_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'none', 0, ?, ?)
                ON CONFLICT(path_key) DO UPDATE SET
                    path = excluded.path,
                    file_name = excluded.file_name,
                    byte_count = excluded.byte_count,
                    modified_at = excluded.modified_at,
                    taken_at = COALESCE(excluded.taken_at, face_photos.taken_at),
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    photo.pathKey,
                    photo.path,
                    photo.fileName,
                    photo.byteCount,
                    Self.timestamp(photo.modifiedAt, formatter),
                    photo.takenAt.map { Self.timestamp($0, formatter) },
                    now,
                    now,
                ]
            )
            let overlapping = try faces(photoID: photo.pathKey, database: database)
            // Same overlap rule replaceFaces uses for confirmed faces.
            func overlaps(_ face: FaceRecord) -> Bool {
                face.box.iou(with: box) > 0.5
            }
            if let confirmed = overlapping.first(where: { $0.state == .confirmed && overlaps($0) }) {
                return confirmed
            }
            if let promotable = overlapping
                .filter({ $0.state != .confirmed && overlaps($0) })
                .max(by: { $0.box.iou(with: box) < $1.box.iou(with: box) }) {
                try database.execute(
                    sql: "UPDATE faces SET person_id = ?, state = 'confirmed', updated_at = ? WHERE id = ?",
                    arguments: [personID.uuidString, now, promotable.id.uuidString]
                )
                return FaceRecord(
                    id: promotable.id,
                    photoID: photo.pathKey,
                    personID: personID,
                    box: promotable.box,
                    detScore: promotable.detScore,
                    matchScore: promotable.matchScore,
                    embedding: promotable.embedding,
                    crop: promotable.crop,
                    model: promotable.model,
                    state: .confirmed,
                    scanGrade: promotable.scanGrade,
                    photoPath: photo.path
                )
            }
            let face = FaceRecord(
                photoID: photo.pathKey,
                personID: personID,
                box: box,
                detScore: 1,
                crop: crop,
                model: "manual",
                state: .confirmed,
                scanGrade: .none,
                photoPath: photo.path
            )
            try insertFace(face, database: database, now: now, formatter: formatter)
            try database.execute(
                sql: """
                UPDATE face_photos SET face_count = (
                    SELECT COUNT(*) FROM faces WHERE faces.photo_id = face_photos.path_key
                ) WHERE path_key = ?
                """,
                arguments: [photo.pathKey]
            )
            try database.execute(
                sql: """
                UPDATE people SET face_count = (
                    SELECT COUNT(*) FROM faces WHERE person_id = ?
                ) WHERE id = ?
                """,
                arguments: [personID.uuidString, personID.uuidString]
            )
            return face
        }
    }

    // MARK: - Roster, groups, and review queues

    public func rosterPeople() throws -> [FacePerson] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM people WHERE is_roster = 1 ORDER BY name COLLATE NOCASE"
            ).map(Self.person)
        }
    }

    public func otherGroups() throws -> [FacePerson] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM people WHERE is_roster = 0 ORDER BY face_count DESC, name COLLATE NOCASE"
            ).map(Self.person)
        }
    }

    public func person(_ id: UUID) throws -> FacePerson? {
        try database().read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT * FROM people WHERE id = ?",
                arguments: [id.uuidString]
            ).map(Self.person)
        }
    }

    /// Faces awaiting review: machine-proposed matches, lowest confidence
    /// first so the least certain decisions surface first.
    public func unsureFaces() throws -> [FaceRecord] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: """
                \(Self.faceSelect)
                WHERE f.state = 'proposed' AND f.person_id IS NOT NULL
                ORDER BY COALESCE(f.match_score, 0) ASC, f.det_score DESC
                """
            ).map { Self.faceRecord($0) }
        }
    }

    public func face(id: UUID) throws -> FaceRecord? {
        try database().read { database in
            try Row.fetchOne(
                database,
                sql: "\(Self.faceSelect) WHERE f.id = ?",
                arguments: [id.uuidString]
            ).map { Self.faceRecord($0) }
        }
    }

    public func faces(personID: UUID) throws -> [FaceRecord] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: "\(Self.faceSelect) WHERE f.person_id = ? ORDER BY f.det_score DESC",
                arguments: [personID.uuidString]
            ).map { Self.faceRecord($0) }
        }
    }

    /// One face to represent a person in review lists — the most confident
    /// detection, which is usually the clearest portrait.
    public func coverFace(personID: UUID) throws -> FaceRecord? {
        try database().read { database in
            try Row.fetchOne(
                database,
                sql: "\(Self.faceSelect) WHERE f.person_id = ? ORDER BY f.det_score DESC LIMIT 1",
                arguments: [personID.uuidString]
            ).map { Self.faceRecord($0) }
        }
    }

    /// Template embeddings per roster person — the gallery LOW matches
    /// against.
    public func rosterTemplates() throws -> [(personID: UUID, embedding: [Float])] {
        try database().read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT t.person_id, f.embedding FROM face_templates t
                JOIN faces f ON f.id = t.face_id
                JOIN people p ON p.id = t.person_id
                WHERE p.is_roster = 1 AND f.embedding IS NOT NULL
                """
            )
            return rows.compactMap { row in
                guard let personID = UUID(uuidString: row["person_id"] as String? ?? ""),
                      let data: Data = row["embedding"] else { return nil }
                return (personID, FaceRecord.embedding(from: data))
            }
        }
    }

    /// Every face that may still move — embedded, not confirmed — for a
    /// roster re-match or cluster pass. No photo is re-decoded; this reads
    /// stored vectors only.
    public func matchableFaces() throws -> [FaceRecord] {
        try database().read { database in
            try Row.fetchAll(
                database,
                sql: """
                \(Self.faceSelect)
                WHERE f.state IN ('cached', 'proposed', 'other')
                  AND f.embedding IS NOT NULL
                ORDER BY f.det_score DESC
                """
            ).map { Self.faceRecord($0) }
        }
    }

    /// Member embeddings of each non-roster group, for clustering new faces
    /// into existing groups.
    public func groupEmbeddings() throws -> [UUID: [[Float]]] {
        try database().read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT f.person_id, f.embedding FROM faces f
                JOIN people p ON p.id = f.person_id
                WHERE p.is_roster = 0 AND f.embedding IS NOT NULL
                """
            )
            var groups: [UUID: [[Float]]] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["person_id"] as String? ?? ""),
                      let data: Data = row["embedding"] else { continue }
                groups[id, default: []].append(FaceRecord.embedding(from: data))
            }
            return groups
        }
    }

    // MARK: - Mutations (review actions)

    @discardableResult
    public func createPerson(name: String, isRoster: Bool) throws -> FacePerson {
        let person = FacePerson(name: name, isRoster: isRoster)
        let now = Self.formatter().string(from: Date())
        try database().write { database in
            try database.execute(
                sql: """
                INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """,
                arguments: [person.id.uuidString, name, isRoster ? 1 : 0, now, now]
            )
        }
        return person
    }

    /// The next display name for a new Other group: "Person N" with N one
    /// past the highest existing auto label.
    public func nextGroupName() throws -> String {
        try database().read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT name FROM people WHERE is_roster = 0 AND name LIKE 'Person %'"
            )
            var highest = 0
            for row in rows {
                if let name: String = row["name"],
                   let number = Int(name.dropFirst("Person ".count)) {
                    highest = max(highest, number)
                }
            }
            return "Person \(highest + 1)"
        }
    }

    public func renamePerson(_ id: UUID, name: String) throws {
        try database().write { database in
            try database.execute(
                sql: "UPDATE people SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [name, Self.formatter().string(from: Date()), id.uuidString]
            )
        }
    }

    /// Confirms or proposes a face for a person, never touching a confirmed
    /// face that belongs to someone else.
    public func assignFace(_ faceID: UUID, to personID: UUID, state: FaceState, score: Double?) throws {
        try database().write { database in
            try database.execute(
                sql: """
                UPDATE faces SET person_id = ?, state = ?, match_score = ?, updated_at = ?
                WHERE id = ? AND state != 'confirmed'
                """,
                arguments: [
                    personID.uuidString,
                    state.rawValue,
                    score,
                    Self.formatter().string(from: Date()),
                    faceID.uuidString,
                ]
            )
        }
    }

    /// Returns a face to the unmatched pool: it keeps its embedding and is
    /// re-grouped by the next cluster pass instead of being re-detected.
    public func unassignFace(_ faceID: UUID) throws {
        try database().write { database in
            try database.execute(
                sql: """
                UPDATE faces SET person_id = NULL, state = 'cached', match_score = NULL, updated_at = ?
                WHERE id = ? AND state != 'confirmed'
                """,
                arguments: [Self.formatter().string(from: Date()), faceID.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM face_templates WHERE face_id = ?",
                arguments: [faceID.uuidString]
            )
        }
    }

    /// Marks a proposed face confirmed — frozen from here on. Also pins it
    /// as a template so the gallery gains a reviewed view.
    public func confirmFace(_ faceID: UUID) throws {
        try database().write { database in
            try database.execute(
                sql: """
                UPDATE faces SET state = 'confirmed', updated_at = ?
                WHERE id = ? AND person_id IS NOT NULL AND state != 'confirmed'
                """,
                arguments: [Self.formatter().string(from: Date()), faceID.uuidString]
            )
        }
    }

    public func addTemplate(personID: UUID, faceID: UUID) throws {
        try database().write { database in
            try database.execute(
                sql: """
                INSERT OR IGNORE INTO face_templates(person_id, face_id, created_at)
                VALUES (?, ?, ?)
                """,
                arguments: [personID.uuidString, faceID.uuidString, Self.formatter().string(from: Date())]
            )
        }
    }

    public func clearTemplates(personID: UUID) throws {
        try database().write { database in
            try database.execute(
                sql: "DELETE FROM face_templates WHERE person_id = ?",
                arguments: [personID.uuidString]
            )
        }
    }

    /// Promotes a non-roster group to a named roster person. Member faces
    /// become confirmed — naming a group is the review — and up to
    /// `templateCap` distinct-photo members become templates.
    public func promoteGroup(_ personID: UUID, name: String, templateCap: Int) throws {
        let formatter = Self.formatter()
        let now = formatter.string(from: Date())
        try database().write { database in
            try database.execute(
                sql: "UPDATE people SET name = ?, is_roster = 1, updated_at = ? WHERE id = ?",
                arguments: [name, now, personID.uuidString]
            )
            try database.execute(
                sql: """
                UPDATE faces SET state = 'confirmed', updated_at = ?
                WHERE person_id = ? AND state != 'confirmed'
                """,
                arguments: [now, personID.uuidString]
            )
            let members = try Row.fetchAll(
                database,
                sql: """
                SELECT id, photo_id, det_score FROM faces
                WHERE person_id = ? ORDER BY det_score DESC
                """,
                arguments: [personID.uuidString]
            )
            var seenPhotos: Set<String> = []
            var picked = 0
            for member in members where picked < templateCap {
                guard let faceID: String = member["id"],
                      let photoID: String = member["photo_id"],
                      seenPhotos.insert(photoID).inserted else { continue }
                try database.execute(
                    sql: "INSERT OR IGNORE INTO face_templates(person_id, face_id, created_at) VALUES (?, ?, ?)",
                    arguments: [personID.uuidString, faceID, now]
                )
                picked += 1
            }
            try database.execute(
                sql: "UPDATE people SET face_count = (SELECT COUNT(*) FROM faces WHERE person_id = ?) WHERE id = ?",
                arguments: [personID.uuidString, personID.uuidString]
            )
        }
    }

    /// Moves every face and template of `source` onto `target` and removes
    /// the empty source row. Confirmed faces keep their frozen state; faces
    /// that were not confirmed become `proposed` on a roster target so they
    /// stay attached and reviewable — a merge is a claim, not a confirmation.
    public func mergePerson(_ sourceID: UUID, into targetID: UUID) throws {
        let now = Self.formatter().string(from: Date())
        try database().write { database in
            let targetRoster = try Int64.fetchOne(
                database,
                sql: "SELECT is_roster FROM people WHERE id = ?",
                arguments: [targetID.uuidString]
            ) ?? 0
            let movedState = targetRoster != 0 ? FaceState.proposed : FaceState.other
            try database.execute(
                sql: """
                UPDATE faces SET person_id = ?, state = CASE WHEN state = 'confirmed' THEN 'confirmed' ELSE ? END,
                    updated_at = ? WHERE person_id = ?
                """,
                arguments: [targetID.uuidString, movedState.rawValue, now, sourceID.uuidString]
            )
            // Carry templates over without duplicating a pair.
            try database.execute(
                sql: """
                INSERT OR IGNORE INTO face_templates(person_id, face_id, created_at)
                SELECT ?, face_id, ? FROM face_templates WHERE person_id = ?
                """,
                arguments: [targetID.uuidString, now, sourceID.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM people WHERE id = ?",
                arguments: [sourceID.uuidString]
            )
        }
    }

    /// Removes a non-roster group and its faces — the junk action. The
    /// photos keep their scan grade, so the faces are not re-detected by the
    /// same mode. Roster people are refused: junking must never delete a
    /// named person's confirmed faces.
    public func deletePersonAndFaces(_ personID: UUID) throws {
        try database().write { database in
            let roster = try Int64.fetchOne(
                database,
                sql: "SELECT is_roster FROM people WHERE id = ?",
                arguments: [personID.uuidString]
            ) ?? 0
            guard roster == 0 else { return }
            try database.execute(
                sql: "DELETE FROM faces WHERE person_id = ? AND state != 'confirmed'",
                arguments: [personID.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM people WHERE id = ?",
                arguments: [personID.uuidString]
            )
        }
    }

    /// Takes a person off the roster: the row and its faces become an Other
    /// group again instead of disappearing.
    public func demoteFromRoster(_ personID: UUID) throws {
        let now = Self.formatter().string(from: Date())
        try database().write { database in
            try database.execute(
                sql: "UPDATE people SET is_roster = 0, updated_at = ? WHERE id = ?",
                arguments: [now, personID.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM face_templates WHERE person_id = ?",
                arguments: [personID.uuidString]
            )
            try database.execute(
                sql: """
                UPDATE faces SET state = 'other', updated_at = ?
                WHERE person_id = ? AND state != 'confirmed'
                """,
                arguments: [now, personID.uuidString]
            )
        }
    }

    /// Recomputes `people.face_count` after mutations.
    public func refreshFaceCounts() throws {
        try database().write { database in
            try database.execute(
                sql: """
                UPDATE people SET face_count = (
                    SELECT COUNT(*) FROM faces WHERE faces.person_id = people.id
                )
                """
            )
        }
    }

    // MARK: - Event people

    /// Roster people with at least one proposed or confirmed face on a photo
    /// whose file key is in `fileKeys`. This is `event.people`: named people
    /// only — Other groups never clutter event chips.
    public func eventPeople(fileKeys: Set<String>) throws -> [FacePerson] {
        guard !fileKeys.isEmpty else { return [] }
        return try database().read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT p.id, p.name, ph.file_name, ph.byte_count, ph.modified_at
                FROM people p
                JOIN faces f ON f.person_id = p.id
                JOIN face_photos ph ON ph.path_key = f.photo_id
                WHERE p.is_roster = 1 AND f.state IN ('proposed', 'confirmed')
                """
            )
            let formatter = Self.formatter()
            var seen: [UUID: FacePerson] = [:]
            var counts: [UUID: Int] = [:]
            for row in rows {
                let fileName: String = row["file_name"]
                let byteCount: Int64 = row["byte_count"]
                let modifiedAt: String = row["modified_at"]
                guard let personID = UUID(uuidString: row["id"] as String? ?? ""),
                      let modified = formatter.date(from: modifiedAt),
                      fileKeys.contains(Self.fileKey(fileName: fileName, byteCount: byteCount, modifiedAt: modified))
                else { continue }
                if seen[personID] == nil {
                    seen[personID] = FacePerson(
                        id: personID,
                        name: row["name"],
                        isRoster: true,
                        faceCount: 0
                    )
                }
                counts[personID, default: 0] += 1
            }
            return seen.values.map { person in
                var copy = person
                copy.faceCount = counts[person.id] ?? 0
                return copy
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Row mapping

    private func insertFace(
        _ face: FaceRecord,
        database: Database,
        now: String,
        formatter: ISO8601DateFormatter
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO faces(
                id, photo_id, person_id, box_x, box_y, box_w, box_h,
                det_score, match_score, embedding, model, state, scan_grade,
                crop, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                face.id.uuidString,
                face.photoID,
                face.personID?.uuidString,
                face.box.x,
                face.box.y,
                face.box.width,
                face.box.height,
                face.detScore,
                face.matchScore,
                face.embeddingData,
                face.model,
                face.state.rawValue,
                face.scanGrade.rawValue,
                face.crop,
                now,
                now,
            ]
        )
    }

    private static func photoRecord(_ row: Row) -> FacePhotoRecord {
        let formatter = formatter()
        let modified: String = row["modified_at"]
        let taken: String? = row["taken_at"]
        return FacePhotoRecord(
            pathKey: row["path_key"],
            path: row["path"],
            fileName: row["file_name"],
            byteCount: row["byte_count"],
            modifiedAt: formatter.date(from: modified) ?? .distantPast,
            takenAt: taken.flatMap { formatter.date(from: $0) },
            scanGrade: FaceScanGrade(rawValue: row["scan_grade"]) ?? .none,
            faceCount: Int(row["face_count"] as Int64? ?? 0)
        )
    }

    private static func faceRecord(_ row: Row) -> FaceRecord {
        let embeddingData: Data? = row["embedding"]
        let matchScore: Double? = row["match_score"]
        let photoPath: String? = row["photo_path"]
        return FaceRecord(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            photoID: row["photo_id"],
            personID: (row["person_id"] as String?).flatMap(UUID.init(uuidString:)),
            box: box(row),
            detScore: row["det_score"],
            matchScore: matchScore,
            embedding: embeddingData.map(FaceRecord.embedding(from:)),
            crop: row["crop"],
            model: row["model"],
            state: FaceState(rawValue: row["state"]) ?? .cached,
            scanGrade: FaceScanGrade(rawValue: row["scan_grade"]) ?? .low,
            photoPath: photoPath ?? ""
        )
    }

    private static func box(_ row: Row) -> NormalizedFaceBox {
        NormalizedFaceBox(
            x: row["box_x"],
            y: row["box_y"],
            width: row["box_w"],
            height: row["box_h"]
        )
    }

    private static func person(_ row: Row) -> FacePerson {
        FacePerson(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            name: row["name"],
            isRoster: (row["is_roster"] as Int64? ?? 0) != 0,
            faceCount: Int(row["face_count"] as Int64? ?? 0)
        )
    }
}
