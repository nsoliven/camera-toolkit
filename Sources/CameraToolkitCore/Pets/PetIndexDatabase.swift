import Foundation
import GRDB

/// The pet index: dogs found in photos, their identity vectors, and the
/// pets the user named — in its own `pets.sqlite` beside the catalog.
///
/// It holds the same five tables as the catalog's face index
/// (`face_photos`, `people`, `faces`, `face_templates`, `face_rejections`)
/// so `FaceIndexStore` and `FaceIndexService` run on it unchanged, with
/// `PetFaceEngine.identifier` as the store's engine. Keeping it in its own
/// file is the safety line: a pet scan, re-match, or Clear can never touch
/// a catalog row, a face, or a named person, and the catalog schema does
/// not change at all.
///
/// The schema is created and upgraded by a GRDB `DatabaseMigrator`; every
/// migration is additive. An existing file is copied with SQLite's online
/// backup API before any pending migration runs, so a failed upgrade can
/// always be rolled back to the file as it was.
///
/// Like `duplicate-review.sqlite`, it shares the catalog's connection setup
/// (`CatalogDatabase`: WAL on a local volume, one writer per file,
/// checkpointed at quit).
public enum PetIndexDatabase {
    public static let fileName = "pets.sqlite"

    /// Where backups taken before a migration go: `Backups/` beside the
    /// pet index, the folder the catalog's own backups use.
    public static let backupFolderName = "Backups"

    /// `pets.sqlite` in the catalog's folder.
    public static func url(besideCatalog catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Opens (creating when missing) and migrates the pet index at `url`,
    /// then returns a store over it. An existing file with pending
    /// migrations is backed up first; the backup's location is returned
    /// through `backup`.
    public static func open(url: URL, backup: ((URL) -> Void)? = nil) throws -> FaceIndexStore {
        let made = try migrate(url: url)
        if let made { backup?(made) }
        return FaceIndexStore(url: url, engine: PetFaceEngine.identifier)
    }

    /// Runs every pending migration. Returns the backup written first, or
    /// nil when the file is new or already current.
    @discardableResult
    public static func migrate(url: URL, now: Date = Date()) throws -> URL? {
        try migrate(url: url, now: now, using: migrator)
    }

    /// `migrate(url:now:)` with a given migrator — the seam a test uses to
    /// leave a file one migration behind.
    static func migrate(url: URL, now: Date, using migrator: DatabaseMigrator) throws -> URL? {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let writer = try CatalogDatabase.writer(for: url)
        var backupURL: URL?
        if existed {
            let pending = try writer.read { database in
                try !migrator.hasCompletedMigrations(database)
            }
            if pending {
                backupURL = try backup(writer: writer, besides: url, now: now)
            }
        }
        try migrator.migrate(writer)
        return backupURL
    }

    /// Copies the live file with SQLite's backup API — never a file copy,
    /// which can miss pages still in the WAL — into
    /// `Backups/pets-<timestamp>.sqlite` and checks the copy's integrity.
    static func backup(writer: any DatabaseWriter, besides url: URL, now: Date) throws -> URL {
        let folder = url.deletingLastPathComponent().appendingPathComponent(backupFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var destination = folder.appendingPathComponent("pets-\(formatter.string(from: now)).sqlite")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = folder.appendingPathComponent("pets-\(formatter.string(from: now))-\(suffix).sqlite")
        }
        let copy = try DatabaseQueue(path: destination.path)
        try writer.backup(to: copy)
        let integrity = try copy.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        try copy.close()
        guard integrity == "ok" else {
            throw ToolkitError.commandFailed("The pet index backup failed its integrity check; nothing was migrated.")
        }
        return destination
    }

    /// The identifiers of every migration, oldest first — what the file's
    /// `grdb_migrations` table records once it is current.
    public static var migrationIdentifiers: [String] { migrator.migrations }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // The face index tables exactly as the catalog holds them today
        // (`CatalogStore.createSchema` plus its grafted columns), with the
        // pet engine as the row default.
        migrator.registerMigration("v1-face-index-tables") { database in
            try database.execute(sql: """
            CREATE TABLE face_photos (
                path_key TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                modified_at TEXT NOT NULL,
                taken_at TEXT,
                scan_grade TEXT NOT NULL DEFAULT 'none',
                face_count INTEGER NOT NULL DEFAULT 0,
                engine TEXT NOT NULL DEFAULT '',
                indexed_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX face_photos_file_key
                ON face_photos(file_name, byte_count, modified_at);
            CREATE TABLE people (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                is_roster INTEGER NOT NULL DEFAULT 0,
                face_count INTEGER NOT NULL DEFAULT 0,
                cover_face_id TEXT,
                suggested_person_id TEXT REFERENCES people(id) ON DELETE SET NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE faces (
                id TEXT PRIMARY KEY,
                photo_id TEXT NOT NULL,
                person_id TEXT,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_w REAL NOT NULL,
                box_h REAL NOT NULL,
                det_score REAL NOT NULL,
                match_score REAL,
                quality REAL,
                face_px REAL,
                embedding BLOB,
                model TEXT NOT NULL DEFAULT '\(PetFaceEngine.identifier)',
                state TEXT NOT NULL DEFAULT 'cached',
                scan_grade TEXT NOT NULL DEFAULT 'low',
                crop BLOB,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(photo_id) REFERENCES face_photos(path_key) ON DELETE CASCADE,
                FOREIGN KEY(person_id) REFERENCES people(id) ON DELETE SET NULL
            );
            CREATE INDEX faces_photo_id ON faces(photo_id);
            CREATE INDEX faces_person_id ON faces(person_id);
            CREATE INDEX faces_state ON faces(state);
            CREATE TABLE face_templates (
                person_id TEXT NOT NULL,
                face_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(person_id, face_id),
                FOREIGN KEY(person_id) REFERENCES people(id) ON DELETE CASCADE,
                FOREIGN KEY(face_id) REFERENCES faces(id) ON DELETE CASCADE
            );
            CREATE TABLE face_rejections (
                person_id TEXT NOT NULL,
                face_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(person_id, face_id),
                FOREIGN KEY(person_id) REFERENCES people(id) ON DELETE CASCADE,
                FOREIGN KEY(face_id) REFERENCES faces(id) ON DELETE CASCADE
            );
            CREATE INDEX face_rejections_face_id ON face_rejections(face_id);
            """)
        }
        return migrator
    }
}
