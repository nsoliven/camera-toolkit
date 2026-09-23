import Foundation
import GRDB

/// The hand-made part of the face index in a small, stable JSON file: who
/// the people are, which detected face the owner confirmed as whom, and
/// which faces were rejected for whom. Embeddings, crops, and automatic
/// groupings are left out — a face re-scan recreates those.
///
/// Every reference to a face is by *photo + box*, not by row id, so the
/// labels survive a total catalog loss: re-scan the photos, then
/// `FaceIndexStore.restoreFaceLabels` finds each new detection overlapping
/// an exported box and puts the owner's label back on it.
public struct FaceLabelExport: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-face-labels"
    public static let currentVersion = 1

    /// The scanned file a face was found in. `pathKey` is the catalog key;
    /// `fileKey` (name + size + modification second) still finds the file
    /// after it moved between folders.
    public struct Photo: Codable, Equatable, Hashable, Sendable {
        public var pathKey: String
        public var path: String
        public var fileKey: String
    }

    public struct Box: Codable, Equatable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        var normalized: NormalizedFaceBox {
            NormalizedFaceBox(x: x, y: y, width: width, height: height)
        }
    }

    public struct FaceReference: Codable, Equatable, Hashable, Sendable {
        public var photo: Photo
        public var box: Box
    }

    public struct Person: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var isRoster: Bool
        public var cover: FaceReference?
    }

    public struct ConfirmedFace: Codable, Equatable, Sendable {
        public var face: FaceReference
        public var personID: String
        /// One of the person's matching templates.
        public var isTemplate: Bool
    }

    public struct Rejection: Codable, Equatable, Sendable {
        public var face: FaceReference
        public var personID: String
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var people: [Person]
    public var confirmedFaces: [ConfirmedFace]
    public var rejections: [Rejection]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FaceLabelExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(FaceLabelExport.self, from: data)
        guard export.format == formatName else {
            throw ToolkitError.commandFailed("This is not a Camera Toolkit face label file.")
        }
        guard export.version <= currentVersion else {
            throw ToolkitError.commandFailed("This face label file is from a newer Camera Toolkit (version \(export.version)).")
        }
        return export
    }
}

/// What a restore did. Faces whose photo has not been re-scanned yet (or
/// whose detection moved too far) are counted as unmatched; running the
/// restore again after more scanning picks them up.
public struct FaceLabelRestoreReport: Equatable, Sendable {
    public var peopleCreated = 0
    public var peopleMatched = 0
    public var facesRestored = 0
    public var facesAlreadyLabeled = 0
    public var facesUnmatched = 0
    /// A detection the catalog already confirmed as someone else — left as
    /// the catalog has it.
    public var facesConflicting = 0
    public var rejectionsRestored = 0
    public var rejectionsUnmatched = 0
    public var coversRestored = 0

    public init() {}
}

extension FaceIndexStore {
    /// Exports every person, confirmed face, and rejection in one read
    /// snapshot. Sorted so two exports of the same labels are identical
    /// apart from `exportedAt`.
    public func exportFaceLabels(now: Date = Date()) throws -> FaceLabelExport {
        guard try faceSchemaExists() else {
            return FaceLabelExport(
                format: FaceLabelExport.formatName,
                version: FaceLabelExport.currentVersion,
                exportedAt: now,
                people: [],
                confirmedFaces: [],
                rejections: []
            )
        }
        return try readSnapshot { database in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func reference(_ row: Row) -> FaceLabelExport.FaceReference {
                let modified: String = row["modified_at"]
                let modifiedAt = formatter.date(from: modified) ?? .distantPast
                return FaceLabelExport.FaceReference(
                    photo: FaceLabelExport.Photo(
                        pathKey: row["path_key"],
                        path: row["path"],
                        fileKey: Self.fileKey(fileName: row["file_name"], byteCount: row["byte_count"], modifiedAt: modifiedAt)
                    ),
                    box: FaceLabelExport.Box(x: row["box_x"], y: row["box_y"], width: row["box_w"], height: row["box_h"])
                )
            }
            let faceColumns = """
                f.id AS face_id, f.box_x, f.box_y, f.box_w, f.box_h,
                ph.path_key, ph.path, ph.file_name, ph.byte_count, ph.modified_at
                """

            let covers = try Row.fetchAll(
                database,
                sql: """
                SELECT p.id AS person_id, \(faceColumns)
                FROM people p
                JOIN faces f ON f.id = p.cover_face_id
                JOIN face_photos ph ON ph.path_key = f.photo_id
                """
            )
            var coverByPerson: [String: FaceLabelExport.FaceReference] = [:]
            for row in covers {
                coverByPerson[row["person_id"]] = reference(row)
            }
            let people = try Row.fetchAll(database, sql: "SELECT id, name, is_roster FROM people")
                .map { row -> FaceLabelExport.Person in
                    let id: String = row["id"]
                    return FaceLabelExport.Person(
                        id: id,
                        name: row["name"],
                        isRoster: (row["is_roster"] as Int64? ?? 0) != 0,
                        cover: coverByPerson[id]
                    )
                }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) }

            let templates = Set(
                try Row.fetchAll(database, sql: "SELECT person_id, face_id FROM face_templates")
                    .map { "\($0["person_id"] as String)|\($0["face_id"] as String)" }
            )
            let confirmed = try Row.fetchAll(
                database,
                sql: """
                SELECT f.person_id, \(faceColumns)
                FROM faces f
                JOIN face_photos ph ON ph.path_key = f.photo_id
                WHERE f.state = 'confirmed' AND f.person_id IS NOT NULL
                """
            )
            .map { row -> FaceLabelExport.ConfirmedFace in
                let personID: String = row["person_id"]
                let faceID: String = row["face_id"]
                return FaceLabelExport.ConfirmedFace(
                    face: reference(row),
                    personID: personID,
                    isTemplate: templates.contains("\(personID)|\(faceID)")
                )
            }
            .sorted { Self.order($0.face, $0.personID) < Self.order($1.face, $1.personID) }

            let rejections = try Row.fetchAll(
                database,
                sql: """
                SELECT r.person_id, \(faceColumns)
                FROM face_rejections r
                JOIN faces f ON f.id = r.face_id
                JOIN face_photos ph ON ph.path_key = f.photo_id
                """
            )
            .map { FaceLabelExport.Rejection(face: reference($0), personID: $0["person_id"]) }
            .sorted { Self.order($0.face, $0.personID) < Self.order($1.face, $1.personID) }

            return FaceLabelExport(
                format: FaceLabelExport.formatName,
                version: FaceLabelExport.currentVersion,
                exportedAt: now,
                people: people,
                confirmedFaces: confirmed,
                rejections: rejections
            )
        }
    }

    /// Puts exported labels back onto the catalog's current detections, in
    /// one transaction:
    ///
    /// - each exported person is matched by id, then by roster name, and
    ///   otherwise recreated with its exported id;
    /// - each confirmed face is found by photo (path key, else file
    ///   identity) and the detection overlapping its box by at least
    ///   `minimumOverlap` IoU, then confirmed as that person (and pinned as
    ///   a template when it was one). A detection already confirmed as
    ///   someone else is left alone and counted as a conflict;
    /// - rejections and covers are restored the same way;
    /// - unnamed groups the restore emptied are removed.
    ///
    /// Idempotent: a second run over the same catalog changes nothing.
    @discardableResult
    public func restoreFaceLabels(
        _ export: FaceLabelExport,
        minimumOverlap: Double = 0.5
    ) throws -> FaceLabelRestoreReport {
        let now = ISO8601DateFormatter.faceLabelTimestamp.string(from: Date())
        return try inWriteTransaction { database in
            var report = FaceLabelRestoreReport()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Photos by catalog key and by file identity.
            var photoKeysByFileKey: [String: [String]] = [:]
            var knownPathKeys: Set<String> = []
            for row in try Row.fetchAll(database, sql: "SELECT path_key, file_name, byte_count, modified_at FROM face_photos") {
                let pathKey: String = row["path_key"]
                knownPathKeys.insert(pathKey)
                let modifiedAt = formatter.date(from: row["modified_at"] as String) ?? .distantPast
                let fileKey = Self.fileKey(fileName: row["file_name"], byteCount: row["byte_count"], modifiedAt: modifiedAt)
                photoKeysByFileKey[fileKey, default: []].append(pathKey)
            }
            var facesByPhoto: [String: [(id: String, box: NormalizedFaceBox, personID: String?, state: String)]] = [:]
            func detections(_ pathKey: String) throws -> [(id: String, box: NormalizedFaceBox, personID: String?, state: String)] {
                if let cached = facesByPhoto[pathKey] { return cached }
                let rows = try Row.fetchAll(
                    database,
                    sql: "SELECT id, box_x, box_y, box_w, box_h, person_id, state FROM faces WHERE photo_id = ?",
                    arguments: [pathKey]
                )
                let faces = rows.map { row in
                    (
                        id: row["id"] as String,
                        box: NormalizedFaceBox(x: row["box_x"], y: row["box_y"], width: row["box_w"], height: row["box_h"]),
                        personID: row["person_id"] as String?,
                        state: row["state"] as String
                    )
                }
                facesByPhoto[pathKey] = faces
                return faces
            }
            func locate(_ reference: FaceLabelExport.FaceReference) throws -> (id: String, personID: String?, state: String, photo: String)? {
                var candidates: [String] = []
                if knownPathKeys.contains(reference.photo.pathKey) { candidates.append(reference.photo.pathKey) }
                candidates += (photoKeysByFileKey[reference.photo.fileKey] ?? []).filter { $0 != reference.photo.pathKey }
                var best: (id: String, personID: String?, state: String, photo: String, overlap: Double)?
                for pathKey in candidates {
                    for face in try detections(pathKey) {
                        let overlap = face.box.iou(with: reference.box.normalized)
                        if overlap >= minimumOverlap, overlap > (best?.overlap ?? 0) {
                            best = (face.id, face.personID, face.state, pathKey, overlap)
                        }
                    }
                    // The exact catalog key wins over a same-file copy.
                    if best != nil { break }
                }
                return best.map { ($0.id, $0.personID, $0.state, $0.photo) }
            }
            func updateCached(photo: String, faceID: String, personID: String, state: String) {
                guard var faces = facesByPhoto[photo], let index = faces.firstIndex(where: { $0.id == faceID }) else { return }
                faces[index].personID = personID
                faces[index].state = state
                facesByPhoto[photo] = faces
            }

            // People.
            var personMap: [String: String] = [:]
            let existing = try Row.fetchAll(database, sql: "SELECT id, name, is_roster FROM people")
            let existingIDs = Set(existing.map { $0["id"] as String })
            var rosterByName: [String: String] = [:]
            for row in existing where (row["is_roster"] as Int64? ?? 0) != 0 {
                rosterByName[row["name"] as String] = row["id"] as String
            }
            for person in export.people {
                if existingIDs.contains(person.id) {
                    personMap[person.id] = person.id
                    report.peopleMatched += 1
                } else if person.isRoster, let match = rosterByName[person.name] {
                    personMap[person.id] = match
                    report.peopleMatched += 1
                } else {
                    try database.execute(
                        sql: """
                        INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at)
                        VALUES (?, ?, ?, 0, ?, ?)
                        """,
                        arguments: [person.id, person.name, person.isRoster ? 1 : 0, now, now]
                    )
                    personMap[person.id] = person.id
                    if person.isRoster { rosterByName[person.name] = person.id }
                    report.peopleCreated += 1
                }
            }

            // Confirmed faces.
            var emptiedCandidates: Set<String> = []
            let mappedPeople = Set(personMap.values)
            for label in export.confirmedFaces {
                guard let personID = personMap[label.personID] else { continue }
                guard let face = try locate(label.face) else {
                    report.facesUnmatched += 1
                    continue
                }
                if face.state == "confirmed" {
                    if face.personID == personID {
                        report.facesAlreadyLabeled += 1
                    } else {
                        report.facesConflicting += 1
                        continue
                    }
                } else {
                    if let previous = face.personID, previous != personID, !mappedPeople.contains(previous) {
                        emptiedCandidates.insert(previous)
                    }
                    try database.execute(
                        sql: """
                        UPDATE faces SET person_id = ?, state = 'confirmed', match_score = NULL, updated_at = ?
                        WHERE id = ? AND state != 'confirmed'
                        """,
                        arguments: [personID, now, face.id]
                    )
                    updateCached(photo: face.photo, faceID: face.id, personID: personID, state: "confirmed")
                    report.facesRestored += 1
                }
                if label.isTemplate {
                    try database.execute(
                        sql: "INSERT OR IGNORE INTO face_templates(person_id, face_id, created_at) VALUES (?, ?, ?)",
                        arguments: [personID, face.id, now]
                    )
                }
            }

            // Rejections.
            for rejection in export.rejections {
                guard let personID = personMap[rejection.personID] else { continue }
                guard let face = try locate(rejection.face) else {
                    report.rejectionsUnmatched += 1
                    continue
                }
                if try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM face_rejections WHERE person_id = ? AND face_id = ?",
                    arguments: [personID, face.id]
                ) == 0 {
                    try database.execute(
                        sql: "INSERT INTO face_rejections(person_id, face_id, created_at) VALUES (?, ?, ?)",
                        arguments: [personID, face.id, now]
                    )
                    report.rejectionsRestored += 1
                }
            }

            // Covers.
            for person in export.people {
                guard let cover = person.cover, let personID = personMap[person.id],
                      let face = try locate(cover), face.personID == personID else { continue }
                let current = try String.fetchOne(
                    database,
                    sql: "SELECT cover_face_id FROM people WHERE id = ?",
                    arguments: [personID]
                )
                guard current != face.id else { continue }
                try database.execute(
                    sql: "UPDATE people SET cover_face_id = ?, updated_at = ? WHERE id = ?",
                    arguments: [face.id, now, personID]
                )
                report.coversRestored += 1
            }

            for group in emptiedCandidates {
                try deleteEmptyGroup(UUID(uuidString: group) ?? UUID(), database: database)
            }
            try refreshFaceCounts(database: database)
            return report
        }
    }

    private static func order(_ reference: FaceLabelExport.FaceReference, _ personID: String) -> String {
        String(
            format: "%@|%.6f|%.6f|%.6f|%.6f|%@",
            reference.photo.pathKey, reference.box.x, reference.box.y,
            reference.box.width, reference.box.height, personID
        )
    }
}

extension ISO8601DateFormatter {
    fileprivate static var faceLabelTimestamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
