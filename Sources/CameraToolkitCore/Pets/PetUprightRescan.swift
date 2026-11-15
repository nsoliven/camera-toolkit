import Foundation
import GRDB

/// How a photo's old (sideways) dog boxes pair with the boxes an upright
/// re-read found. Boxes are compared in the shared stored space. Pure, so
/// each case has a test.
enum PetBoxRemap {
    /// One old box and one new box are the same dog at this IoU or above.
    static let sameDogIoU = 0.5
    /// A new box at least this far inside an old box was covered by it.
    static let containedFraction = 0.7
    /// An old box this close to one covered new box is that dog's box,
    /// however many other boxes sit inside it: a dog with an extra "front"
    /// or "back" box is one dog, not a two-dog merge.
    ///
    /// Measured on real vertical frames: same-dog pairs scored 0.64 to 0.96,
    /// a two-dog box scored 0.29 to 0.59 against each dog, and a different
    /// dog's box 0.00 to 0.05.
    static let oneDogIoU = 0.75

    struct Merge: Equatable {
        var old: UUID
        var covered: [Int]
    }

    struct Plan: Equatable {
        var matched: [(old: UUID, new: Int)]
        var merges: [Merge]
        var unmatchedOld: [UUID]
        var unmatchedNew: [Int]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.matched.map(\.old) == rhs.matched.map(\.old)
                && lhs.matched.map(\.new) == rhs.matched.map(\.new)
                && lhs.merges == rhs.merges
                && lhs.unmatchedOld == rhs.unmatchedOld
                && lhs.unmatchedNew == rhs.unmatchedNew
        }
    }

    private static func area(_ box: NormalizedFaceBox) -> Double {
        box.width * box.height
    }

    /// The share of `inner` that lies inside `outer`.
    private static func coverage(of inner: NormalizedFaceBox, by outer: NormalizedFaceBox) -> Double {
        let overlap = inner.rect.intersection(outer.rect)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0, area(inner) > 0 else { return 0 }
        return (overlap.width * overlap.height) / area(inner)
    }

    static func plan(old: [(id: UUID, box: NormalizedFaceBox)], new: [NormalizedFaceBox]) -> Plan {
        // One-to-one first, strongest overlap first, so a new box close to
        // one old box can never also count as covered by a bigger one.
        var pairs: [(iou: Double, old: Int, new: Int)] = []
        for (oldIndex, oldBox) in old.enumerated() {
            for (newIndex, newBox) in new.enumerated() {
                let iou = oldBox.box.iou(with: newBox)
                if iou >= sameDogIoU { pairs.append((iou, oldIndex, newIndex)) }
            }
        }
        pairs.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.old != $1.old { return $0.old < $1.old }
            return $0.new < $1.new
        }
        var newByOld: [Int: Int] = [:]
        var oldByNew: [Int: Int] = [:]
        for pair in pairs where newByOld[pair.old] == nil && oldByNew[pair.new] == nil {
            newByOld[pair.old] = pair.new
            oldByNew[pair.new] = pair.old
        }

        // A merge: an old box covering two or more distinct new boxes that
        // no other old box claimed, none of which is plainly the old box
        // itself.
        var merges: [Merge] = []
        var mergedOld: Set<Int> = []
        var takenByMerges: Set<Int> = []
        // Largest box first: a new box belongs to at most one merge, and a
        // box spanning everything is the merge when two old boxes overlap.
        for oldIndex in old.indices.sorted(by: { area(old[$0].box) > area(old[$1].box) }) {
            let oldBox = old[oldIndex]
            let covering = new.indices.filter { index in
                !takenByMerges.contains(index)
                    && coverage(of: new[index], by: oldBox.box) >= containedFraction
            }
            guard covering.count >= 2,
                  covering.allSatisfy({ oldBox.box.iou(with: new[$0]) < oneDogIoU }),
                  isDistinct(covering, in: new) else { continue }
            // A dog another old box already claimed stays with that box; the
            // old box still spanned two dogs, so what remains of it goes
            // through the matcher instead of inheriting blindly.
            let covered = covering.filter { index in
                guard let owner = oldByNew[index] else { return true }
                return owner == oldIndex
            }
            guard !covered.isEmpty else { continue }
            merges.append(Merge(old: oldBox.id, covered: covered))
            mergedOld.insert(oldIndex)
            takenByMerges.formUnion(covered)
        }

        var matched: [(old: UUID, new: Int)] = []
        var unmatchedOld: [UUID] = []
        for (oldIndex, oldBox) in old.enumerated() where !mergedOld.contains(oldIndex) {
            if let newIndex = newByOld[oldIndex], !takenByMerges.contains(newIndex) {
                matched.append((oldBox.id, newIndex))
            } else {
                unmatchedOld.append(oldBox.id)
            }
        }
        let usedNew = takenByMerges.union(matched.map(\.new))
        return Plan(
            matched: matched,
            merges: merges,
            unmatchedOld: unmatchedOld,
            unmatchedNew: new.indices.filter { !usedNew.contains($0) }
        )
    }

    /// Whether at least two of the covered boxes are different dogs rather
    /// than overlapping boxes on one.
    private static func isDistinct(_ indices: [Int], in boxes: [NormalizedFaceBox]) -> Bool {
        for (position, first) in indices.enumerated() {
            for second in indices[(position + 1)...] where boxes[first].iou(with: boxes[second]) < sameDogIoU {
                return true
            }
        }
        return false
    }
}

/// The rows behind the upright rescan: a per-photo marker saying its dogs
/// have been detected upright, and the transaction that moves one photo's
/// sideways boxes onto its upright ones without losing the user's sorting.
/// Pet index only — the tables do not exist in the catalog.
extension FaceIndexStore {
    private static let backupStateKey = "upright_rescan_backup"

    /// Path keys that already carry the marker — chunked like every other
    /// IN lookup here.
    func uprightCheckedPhotos(pathKeys: [String]) throws -> Set<String> {
        guard !pathKeys.isEmpty else { return [] }
        return try readSnapshot { database in
            var result: Set<String> = []
            for start in stride(from: 0, to: pathKeys.count, by: 400) {
                let keys = Array(pathKeys[start..<min(start + 400, pathKeys.count)])
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                result.formUnion(try String.fetchAll(
                    database,
                    sql: "SELECT path_key FROM pet_photo_orientation WHERE path_key IN (\(placeholders))",
                    arguments: StatementArguments(keys)
                ))
            }
            return result
        }
    }

    /// Marks RAWs whose header read says they were never sideways. One
    /// transaction for the batch; the scan calls it batch by batch, so a
    /// quit loses at most one batch of header reads.
    func markDetectedUpright(pathKeys: [String]) throws {
        guard !pathKeys.isEmpty else { return }
        try inWriteTransaction { database in
            for key in pathKeys {
                try Self.writeUprightMarker(pathKey: key, cameraTurns: 0, database: database)
            }
        }
    }

    static func writeUprightMarker(pathKey: String, cameraTurns: Int, database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO pet_photo_orientation(path_key, camera_turns, checked_at)
            VALUES (?, ?, ?)
            ON CONFLICT(path_key) DO UPDATE SET
                camera_turns = excluded.camera_turns,
                checked_at = excluded.checked_at
            """,
            arguments: [pathKey, cameraTurns, formatter.string(from: Date())]
        )
    }

    /// Backs the pet index up, once ever, ahead of the first rescan: a
    /// checked copy into `folder`, kept afterwards. Returns the copy when
    /// this call made one. Throws before anything is written if it fails.
    @discardableResult
    func backupBeforeFirstUprightRescan(into folder: URL, now: Date = Date()) throws -> URL? {
        let done = try readSnapshot { database in
            try String.fetchOne(
                database,
                sql: "SELECT value FROM pet_index_state WHERE key = ?",
                arguments: [Self.backupStateKey]
            )
        }
        guard done == nil else { return nil }
        let copy = try PetIndexDatabase.backup(writer: database(), into: folder, now: now)
        try inWriteTransaction { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO pet_index_state(key, value) VALUES (?, ?)",
                arguments: [Self.backupStateKey, copy.lastPathComponent]
            )
        }
        return copy
    }

    /// Moves one photo's dogs from its sideways boxes to the boxes an upright
    /// re-read found, in one transaction:
    ///
    /// - same dog (see `PetBoxRemap`): the row is refreshed in place, so its
    ///   person, state, templates, rejections and any cover pointing at it
    ///   stay exactly where they were;
    /// - one old box over two dogs: each new box is checked against the old
    ///   box's group and joins it only where the normal rules would file it;
    ///   the old row goes unless the user has spoken for it;
    /// - a new box with no old box: stored unassigned for the normal pass;
    /// - an old box with no new box: gone only if nothing but the machine
    ///   ever touched it; anything assigned stays, so no sorting is lost.
    func applyUprightRescan(
        photo: FacePhotoRecord,
        detected: [FaceRecord],
        cameraTurns: Int,
        grade: FaceScanGrade,
        options: FaceScanOptions
    ) throws {
        try inWriteTransaction { database in
            let now = Self.formatter.string(from: Date())
            let old = try faces(photoID: photo.pathKey, database: database)
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let guarded = try userGuardedFaceIDs(old.map(\.id), database: database)
            let plan = PetBoxRemap.plan(old: old.map { ($0.id, $0.box) }, new: detected.map(\.box))

            for pair in plan.matched {
                try refresh(faceID: pair.old, from: detected[pair.new], grade: grade, now: now, database: database)
            }
            for index in plan.merges.flatMap(\.covered) + plan.unmatchedNew {
                try insertFace(detected[index], database: database, now: now, formatter: Self.formatter)
            }

            let mergedIDs = Set(plan.merges.map(\.old))
            let rejections = try faceRejections(database: database)
            for merge in plan.merges {
                guard let oldFace = oldByID[merge.old] else { continue }
                var joined: FaceRecord?
                if let personID = oldFace.personID,
                   let person = try person(personID, database: database) {
                    for index in merge.covered {
                        let face = detected[index]
                        if try fileMergedDog(
                            face,
                            into: person,
                            excluding: mergedIDs,
                            rejections: rejections,
                            options: options,
                            database: database
                        ), joined == nil {
                            joined = face
                        }
                    }
                }
                guard !guarded.contains(merge.old),
                      try !isLastFace(oldFace, database: database) else { continue }
                try database.execute(
                    sql: "UPDATE people SET cover_face_id = ? WHERE cover_face_id = ?",
                    arguments: [joined?.id.uuidString, merge.old.uuidString]
                )
                try database.execute(sql: "DELETE FROM faces WHERE id = ?", arguments: [merge.old.uuidString])
            }

            for id in plan.unmatchedOld {
                guard let oldFace = oldByID[id], oldFace.personID == nil, !guarded.contains(id) else { continue }
                try database.execute(sql: "DELETE FROM faces WHERE id = ?", arguments: [id.uuidString])
            }

            try database.execute(
                sql: """
                UPDATE face_photos SET
                    scan_grade = ?, engine = ?, updated_at = ?,
                    face_count = (SELECT COUNT(*) FROM faces WHERE faces.photo_id = face_photos.path_key)
                WHERE path_key = ?
                """,
                arguments: [grade.rawValue, engine, now, photo.pathKey]
            )
            try Self.writeUprightMarker(pathKey: photo.pathKey, cameraTurns: cameraTurns, database: database)
            try refreshFaceCounts(database: database)
        }
    }

    /// Same measurement refresh `replaceFaces` gives a confirmed face. The
    /// row and its id stay, so everything pointing at it stays too.
    private func refresh(
        faceID: UUID,
        from face: FaceRecord,
        grade: FaceScanGrade,
        now: String,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE faces SET
                box_x = ?, box_y = ?, box_w = ?, box_h = ?,
                det_score = ?, embedding = COALESCE(?, embedding),
                quality = ?, face_px = ?, crop = COALESCE(?, crop),
                model = ?, scan_grade = ?, updated_at = ?
            WHERE id = ?
            """,
            arguments: [
                face.box.x, face.box.y, face.box.width, face.box.height,
                face.detScore, face.embeddingData,
                face.quality, face.facePixels, face.crop,
                face.model, grade.rawValue, now,
                faceID.uuidString,
            ]
        )
    }

    /// Rows the user has spoken for: confirmed, a template, or the subject
    /// of a "not this one" verdict. These are never removed by a rescan.
    private func userGuardedFaceIDs(_ ids: [UUID], database: Database) throws -> Set<UUID> {
        var guarded: Set<UUID> = []
        for id in ids {
            let row = try Row.fetchOne(
                database,
                sql: """
                SELECT
                    (SELECT state FROM faces WHERE id = :id) AS state,
                    EXISTS(SELECT 1 FROM face_templates WHERE face_id = :id) AS template,
                    EXISTS(SELECT 1 FROM face_rejections WHERE face_id = :id) AS rejected
                """,
                arguments: ["id": id.uuidString]
            )
            guard let row else { continue }
            let confirmed = (row["state"] as String?) == FaceState.confirmed.rawValue
            if confirmed || (row["template"] as Bool? ?? false) || (row["rejected"] as Bool? ?? false) {
                guarded.insert(id)
            }
        }
        return guarded
    }

    /// True when deleting this row would leave its group empty.
    private func isLastFace(_ face: FaceRecord, database: Database) throws -> Bool {
        guard let personID = face.personID else { return false }
        return try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM faces WHERE person_id = ? AND id != ?",
            arguments: [personID.uuidString, face.id.uuidString]
        ) == 0
    }

    /// One dog from a split-up box: checked against only the group the old
    /// box sat in, by the rules that group would apply to any other dog. An
    /// approved pet's templates and a "looks like" row file it as a
    /// suggestion, an automatic group by average linkage; none of them ever
    /// confirm it. Returns whether the dog landed on `person`'s row.
    private func fileMergedDog(
        _ face: FaceRecord,
        into person: FacePerson,
        excluding merged: Set<UUID>,
        rejections: FaceRejectionIndex,
        options: FaceScanOptions,
        database: Database
    ) throws -> Bool {
        guard let embedding = face.embedding else { return false }
        if person.isRoster || person.suggestedPersonID != nil {
            let target = person.suggestedPersonID ?? person.id
            let templates = try templates(of: target, excluding: merged, database: database)
            guard let match = FaceIndexService.bestMatch(
                embedding,
                faceID: face.id,
                templates: templates.map { (target, $0) },
                threshold: options.matchThreshold,
                rejections: rejections
            ) else { return false }
            let rowID = person.suggestedPersonID == nil
                ? try suggestionRow(for: person, database: database)
                : person.id
            try assignFace(face.id, to: rowID, state: .proposed, score: Double(match.score), database: database)
            return true
        }
        guard FaceIndexService.qualifiesForGrouping(face, options: options) else { return false }
        let members = try memberVectors(of: person.id, excluding: merged, database: database)
        guard !members.isEmpty, members.allSatisfy({ $0.count == embedding.count }) else { return false }
        let score = members.reduce(Float(0)) { $0 + FaceEmbeddingMath.cosine(embedding, $1) } / Float(members.count)
        guard score >= options.clusterThreshold,
              !rejections.blocks(faceID: face.id, personID: person.id),
              !rejections.vetoes(embedding, personID: person.id, score: score) else { return false }
        try assignFace(face.id, to: person.id, state: .other, score: Double(score), database: database)
        return true
    }

    private func templates(of personID: UUID, excluding merged: Set<UUID>, database: Database) throws -> [[Float]] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT f.id, f.embedding FROM face_templates t
            JOIN faces f ON f.id = t.face_id
            WHERE t.person_id = ? AND f.embedding IS NOT NULL AND f.model = ?
            """,
            arguments: [personID.uuidString, engine]
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"] as String? ?? ""), !merged.contains(id),
                  let data: Data = row["embedding"] else { return nil }
            return FaceRecord.embedding(from: data)
        }
    }

    private func memberVectors(of personID: UUID, excluding merged: Set<UUID>, database: Database) throws -> [[Float]] {
        try Row.fetchAll(
            database,
            sql: "SELECT id, embedding FROM faces WHERE person_id = ? AND embedding IS NOT NULL AND model = ?",
            arguments: [personID.uuidString, engine]
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"] as String? ?? ""), !merged.contains(id),
                  let data: Data = row["embedding"] else { return nil }
            return FaceRecord.embedding(from: data)
        }
    }

    /// The "looks like" row for an approved pet, created when it has none —
    /// where the matcher files a dog that resembles it.
    private func suggestionRow(for person: FacePerson, database: Database) throws -> UUID {
        if let existing = try otherGroups(database: database).first(where: { $0.suggestedPersonID == person.id }) {
            return existing.id
        }
        return try createPerson(
            name: person.name,
            isRoster: false,
            suggestedPersonID: person.id,
            database: database
        ).id
    }
}
