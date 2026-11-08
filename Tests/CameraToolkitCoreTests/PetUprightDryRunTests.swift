import CoreGraphics
import CoreText
import Foundation
import GRDB
import ImageIO
@testable import CameraToolkitCore
import XCTest

/// Opt-in: runs the upright rescan with the real pet sidecar over photos
/// named by a copy of a pet index, read-only on the photos, and writes a
/// plain-text report plus overlay PNGs. Skipped without its environment.
///
/// `CT_PET_DRYRUN_DB`      a scratch copy of pets.sqlite (it is written)
/// `CT_PET_DRYRUN_OUT`     a scratch folder for the report and PNGs
/// `CT_PET_SIDECAR_ROOT`   the installed pet sidecar
/// `CT_PET_DRYRUN_NAMES`   comma-separated stems of photos that must be
///                         included (found by `face_photos.path`)
/// `CT_PET_DRYRUN_EXTRA`   how many more vertical RAWs with boxes to add
/// `CT_PET_DRYRUN_NOBOX`   how many vertical RAWs with no boxes to add
/// `CT_PET_DRYRUN_MODE`    `measure`, `run`, or `baseline`
final class PetUprightDryRunTests: XCTestCase {
    private struct Row1 {
        var id: UUID
        var box: NormalizedFaceBox
        var personName: String?
        var state: FaceState
        var isTemplate: Bool
        var embedding: [Float]?
    }

    func testDryRunOnACopy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dbPath = environment["CT_PET_DRYRUN_DB"],
              let outPath = environment["CT_PET_DRYRUN_OUT"] else {
            throw XCTSkip("Set CT_PET_DRYRUN_DB and CT_PET_DRYRUN_OUT to run.")
        }
        let db = URL(fileURLWithPath: dbPath)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mode = environment["CT_PET_DRYRUN_MODE"] ?? "run"
        let store = try PetIndexDatabase.open(url: db)
        let writer = try CatalogDatabase.writer(for: db)
        var report = ""

        if mode == "baseline" {
            let before = try groupCounts(writer)
            let service = FaceIndexService(store: store, options: .pets(mode: .high))
            let scan = try service.scan(stacks: [], analyzer: NoAnalyzer())
            report += "baseline (ordinary scan with nothing new):\n"
            report += "  groups before \(before)\n  groups after  \(try groupCounts(writer))\n  moved \(scan.facesMoved) proposed \(scan.facesProposed) grouped \(scan.facesGrouped)\n"
            print(report)
            try report.write(to: out.appendingPathComponent("baseline.txt"), atomically: true, encoding: .utf8)
            return
        }

        guard let rootPath = environment["CT_PET_SIDECAR_ROOT"] else {
            throw XCTSkip("Set CT_PET_SIDECAR_ROOT to run.")
        }
        let installation = PetSidecarInstallation(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        let pool = try PetSidecarPool(installation: installation)
        defer { pool.shutdown() }

        let names = (environment["CT_PET_DRYRUN_NAMES"] ?? "").split(separator: ",").map(String.init)
        let extra = Int(environment["CT_PET_DRYRUN_EXTRA"] ?? "20") ?? 20

        // Which photos: every named one, then vertical RAWs with boxes.
        let allRows = try writer.read { database in
            try Row.fetchAll(database, sql: "SELECT DISTINCT p.path_key AS key, p.path AS path FROM face_photos p JOIN faces f ON f.photo_id = p.path_key ORDER BY p.path")
                .map { (key: $0["key"] as String, path: $0["path"] as String) }
        }
        let namedRows = try names.flatMap { name in
            try writer.read { database in
                try Row.fetchAll(database, sql: "SELECT path_key AS key, path FROM face_photos WHERE path LIKE ?", arguments: ["%\(name)%"])
                    .map { (key: $0["key"] as String, path: $0["path"] as String) }
            }
        }
        var chosen: [(key: String, path: String, turns: Int)] = []
        var seen = Set<String>()
        for row in namedRows {
            let url = URL(fileURLWithPath: row.path)
            chosen.append((row.key, row.path, FaceImageDecoder.cameraQuarterTurns(for: url) ?? -1))
            seen.insert(row.key)
        }
        var added = 0
        for row in allRows where !seen.contains(row.key) && added < extra {
            let url = URL(fileURLWithPath: row.path)
            guard FaceImageDecoder.cameraQuarterTurns(for: url) ?? 0 != 0 else { continue }
            chosen.append((row.key, row.path, FaceImageDecoder.cameraQuarterTurns(for: url) ?? 0))
            added += 1
        }
        // Vertical RAWs where the sideways scan found nothing: where a miss hides.
        let noBoxWanted = Int(environment["CT_PET_DRYRUN_NOBOX"] ?? "0") ?? 0
        let noBoxRows = try writer.read { database in
            try Row.fetchAll(database, sql: "SELECT path_key AS key, path FROM face_photos WHERE face_count = 0 AND file_name LIKE '%.ARW' ORDER BY file_name LIMIT 5000")
                .map { (key: $0["key"] as String, path: $0["path"] as String) }
        }
        var noBoxAdded = 0
        for row in noBoxRows.shuffled() where !seen.contains(row.key) && noBoxAdded < noBoxWanted {
            let url = URL(fileURLWithPath: row.path)
            guard let turns = FaceImageDecoder.cameraQuarterTurns(for: url), turns != 0 else { continue }
            chosen.append((row.key, row.path, turns))
            noBoxAdded += 1
        }
        report += "photos: \(chosen.count) (named \(namedRows.count), extra \(added), no-box \(noBoxAdded))\n"

        let stacks = chosen.map { entry -> OrganizeStack in
            OrganizeStack(items: [try! item(path: entry.path)])
        }
        let before = try groupCounts(writer)
        report += "groups before: \(before)\n"

        var beforeRows: [String: [Row1]] = [:]
        var measuredBest: [Double] = []
        for entry in chosen {
            let rows = try faceRows(entry.key, writer: writer)
            beforeRows[entry.key] = rows
            if mode == "measure" || mode == "run" {
                let image = try XCTUnwrap(FaceImageDecoder.uprightDetectionImage(for: URL(fileURLWithPath: entry.path), maximumPixelSize: FaceScanOptions.pets(mode: .high).detectPixels))
                let analyzed = try pool.analyze(image.image, options: .pets(mode: .high))
                let boxes = analyzed.map { FaceBoxProjection.storedBox(fromTurned: $0.box, quarterTurnsCW: image.cameraTurns) }
                    .filter { min($0.width * image.storedPixelSize.width, $0.height * image.storedPixelSize.height) >= FaceScanOptions.pets(mode: .high).minimumFacePixels }
                let plan = PetBoxRemap.plan(old: rows.map { ($0.id, $0.box) }, new: boxes)
                report += "\n\(name(entry.path)) turns \(entry.turns) old \(rows.count) new \(boxes.count) plan matched \(plan.matched.count) merges \(plan.merges.count) unmatchedOld \(plan.unmatchedOld.count) unmatchedNew \(plan.unmatchedNew)\n"
                for old in rows {
                    let best = boxes.map { old.box.iou(with: $0) }.max() ?? 0
                    measuredBest.append(best)
                    let covering = boxes.filter { coverage(of: $0, by: old.box) >= 0.5 }.count
                    report += "  old \(old.id.uuidString.prefix(8)) \(old.state.rawValue) \(old.personName ?? "-") template \(old.isTemplate) bestIoU \(String(format: "%.3f", best)) coveredNew \(covering) ious \(boxes.map { String(format: "%.2f", old.box.iou(with: $0)) })\n"
                }
                for (index, new) in boxes.enumerated() {
                    report += "  new \(index) score \(String(format: "%.2f", analyzed[index].detScore)) area \(String(format: "%.3f", new.width * new.height))\n"
                }
            }
        }
        if mode == "measure" {
            print(report)
            try report.write(to: out.appendingPathComponent("measure.txt"), atomically: true, encoding: .utf8)
            return
        }

        var service = FaceIndexService(store: store, options: .pets(mode: .high))
        service.uprightBackupFolder = out.appendingPathComponent("Backups", isDirectory: true)
        let scan = try service.scan(stacks: stacks, analyzer: pool)
        report += "\nscan: processed \(scan.photosProcessed) rescanned \(scan.photosRescannedUpright) skipped \(scan.photosSkipped) failed \(scan.photosFailed) proposed \(scan.facesProposed) grouped \(scan.facesGrouped) moved \(scan.facesMoved)\n"
        report += "groups after: \(try groupCounts(writer))\n"

        for entry in chosen {
            let old = beforeRows[entry.key] ?? []
            let now = try faceRows(entry.key, writer: writer)
            report += "\n\(name(entry.path)) turns \(entry.turns) marker \(String(describing: try markerTurns(entry.key, writer: writer))) boxes \(old.count) -> \(now.count)\n"
            let nowIDs = Set(now.map(\.id))
            for row in old {
                if nowIDs.contains(row.id), let updated = now.first(where: { $0.id == row.id }) {
                    let moved = row.box.iou(with: updated.box)
                    let cos = zip(row.embedding ?? [], updated.embedding ?? []).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    report += "  kept \(row.id.uuidString.prefix(8)) \(row.state.rawValue)/\(updated.state.rawValue) person \(row.personName ?? "-") -> \(updated.personName ?? "-") iou(old,new) \(String(format: "%.2f", moved)) cos(old,new) \(String(format: "%.2f", cos))\n"
                } else {
                    report += "  GONE \(row.id.uuidString.prefix(8)) \(row.state.rawValue) person \(row.personName ?? "-") template \(row.isTemplate)\n"
                }
            }
            for row in now where !old.contains(where: { $0.id == row.id }) {
                report += "  new  \(row.id.uuidString.prefix(8)) \(row.state.rawValue) person \(row.personName ?? "-")\n"
            }
            try renderOverlay(path: entry.path, turns: entry.turns, old: old, now: now, out: out)
        }
        print(report)
        try report.write(to: out.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
    }

    private func coverage(of inner: NormalizedFaceBox, by outer: NormalizedFaceBox) -> Double {
        let overlap = inner.rect.intersection(outer.rect)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (inner.width * inner.height)
    }

    private func name(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func item(path: String) throws -> OrganizeItem {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        return OrganizeItem(
            primary: OrganizeFile(path: path, size: attributes[.size] as? Int64 ?? 0, modifiedAt: modified),
            kind: OrganizeFileClassifier.rawExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? .raw : .photo,
            captureDate: modified,
            hasCameraDate: false
        )
    }

    private func groupCounts(_ writer: any DatabaseWriter) throws -> String {
        try writer.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT name, face_count, is_roster, (SELECT COUNT(*) FROM face_templates t WHERE t.person_id = p.id) AS templates FROM people p ORDER BY is_roster DESC, name")
            let faces = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM faces") ?? -1
            let assigned = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM faces WHERE person_id IS NOT NULL") ?? -1
            return "\(rows.count) groups, \(faces) boxes, \(assigned) assigned: " + rows.map {
                "\($0["name"] as String)=\($0["face_count"] as Int)\(($0["is_roster"] as Int) == 1 ? "*" : "")t\($0["templates"] as Int)"
            }.joined(separator: " ")
        }
    }

    private func markerTurns(_ key: String, writer: any DatabaseWriter) throws -> Int? {
        try writer.read { try Int.fetchOne($0, sql: "SELECT camera_turns FROM pet_photo_orientation WHERE path_key = ?", arguments: [key]) }
    }

    private func faceRows(_ key: String, writer: any DatabaseWriter) throws -> [Row1] {
        try writer.read { database in
            try Row.fetchAll(database, sql: """
                SELECT f.id, f.box_x, f.box_y, f.box_w, f.box_h, f.state, f.embedding, p.name,
                       EXISTS(SELECT 1 FROM face_templates t WHERE t.face_id = f.id) AS template
                FROM faces f LEFT JOIN people p ON p.id = f.person_id WHERE f.photo_id = ?
                """, arguments: [key]).map { row in
                Row1(
                    id: UUID(uuidString: row["id"])!,
                    box: NormalizedFaceBox(x: row["box_x"], y: row["box_y"], width: row["box_w"], height: row["box_h"]),
                    personName: row["name"],
                    state: FaceState(rawValue: row["state"]) ?? .cached,
                    isTemplate: (row["template"] as Int) == 1,
                    embedding: (row["embedding"] as Data?).map(FaceRecord.embedding(from:))
                )
            }
        }
    }

    /// Draws the photo upright with the stored boxes on it the way the
    /// preview does: projected by the same camera turn.
    private func renderOverlay(path: String, turns: Int, old: [Row1], now: [Row1], out: URL) throws {
        guard let decoded = FaceImageDecoder.uprightDetectionImage(for: URL(fileURLWithPath: path), maximumPixelSize: 1400) else { return }
        let image = decoded.image
        let scale = 1000.0 / Double(max(image.width, image.height))
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ rows: [Row1], color: CGColor, lineWidth: CGFloat, labelled: Bool) {
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            for row in rows {
                let topLeft = FaceBoxProjection.rotatedTopLeftRect(FaceBoxProjection.topLeftRect(of: row.box), quarterTurnsCW: decoded.cameraTurns)
                let rect = CGRect(x: topLeft.minX * Double(width), y: (1 - topLeft.minY - topLeft.height) * Double(height), width: topLeft.width * Double(width), height: topLeft.height * Double(height))
                context.stroke(rect)
                if labelled {
                    let text = "\(row.personName ?? "-") \(row.state.rawValue)" as CFString
                    let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil), kCTForegroundColorAttributeName: color] as CFDictionary
                    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attributes)!)
                    context.textPosition = CGPoint(x: rect.minX + 4, y: rect.maxY - 22)
                    CTLineDraw(line, context)
                }
            }
        }
        draw(old, color: CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1), lineWidth: 2, labelled: false)
        draw(now, color: CGColor(red: 0.1, green: 1, blue: 0.2, alpha: 1), lineWidth: 4, labelled: true)
        guard let result = context.makeImage(), let png = FaceImageEncoding.pngData(result) else { return }
        try png.write(to: out.appendingPathComponent(name(path) + "_overlay.png"))
    }
}

private final class NoAnalyzer: FaceAnalyzing, @unchecked Sendable {
    let displayName = "none"
    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] { [] }
}
