import Foundation
import GRDB
import SQLite3
@testable import CameraToolkitCore
import XCTest

/// The Re-match path on a NAS-backed catalog: a stuttering volume answers
/// `BEGIN IMMEDIATE` with SQLITE_BUSY or SQLITE_IOERR, so the pass must
/// batch its writes into one transaction and retry transient refusals.
/// Every test here runs against a temporary catalog — never the owner's
/// library.
final class FaceIndexTransactionTests: XCTestCase {

    // MARK: - One transaction, not one per face

    /// A rebundle over many faces must issue a single BEGIN IMMEDIATE —
    /// the thousands-of-transactions shape is what choked the NAS.
    func testRebundleOfManyFacesCommitsInOneTransaction() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try seededStore(root: root, catalog: catalog, groups: 3, facesPerGroup: 40)

            let counter = BeginCounter()
            let queue = try makeQueue(catalog: catalog, trace: counter)
            let tracedStore = FaceIndexStore(url: catalog, queue: queue)
            let service = FaceIndexService(store: tracedStore)

            let before = counter.value
            let report = try service.rematchRoster()
            let begins = counter.value - before

            XCTAssertEqual(begins, 1, "a 120-face rebundle must not open one transaction per face")

            // All 120 unconfirmed faces were regrouped and still exist.
            let faces = try tracedStore.matchableFaces()
            XCTAssertEqual(faces.count, 120)
            XCTAssertTrue(faces.allSatisfy { $0.personID != nil })
            XCTAssertGreaterThanOrEqual(report.facesGrouped, 1)
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
        }
    }

    // MARK: - Transient BEGIN IMMEDIATE failures

    /// First BEGIN IMMEDIATE hits a busy lock; the busy callback releases
    /// the blocker and refuses once — the retry then commits cleanly and
    /// no face is lost. An event row in the same catalog survives.
    func testRematchRetriesBusyBeginAndPreservesData() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            configuration.catalogDatabasePath = root.appendingPathComponent("catalog.sqlite").path
            configuration.savedEvents = [
                SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_752_000_000)),
            ]
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let seedStore = FaceIndexStore(url: catalog)
            try seedFaces(store: seedStore, groups: 2, facesPerGroup: 30)
            // A confirmed roster face and a user-named group must survive
            // the retry untouched.
            let dad = try seedStore.createPerson(name: "Dad", isRoster: true)
            let dadPhoto = photoRecord("DAD0001.ARW")
            let dadFace = faceRecord(
                dadPhoto,
                embedding: testEmbedding(seed: 99),
                state: .confirmed,
                personID: dad.id
            )
            try seedStore.replaceFaces(photo: dadPhoto, faces: [dadFace])
            try seedStore.addTemplate(personID: dad.id, faceID: dadFace.id)
            let named = try seedStore.createPerson(name: "Aunt Bee", isRoster: false)
            let namedPhoto = photoRecord("NAM0001.ARW")
            let namedFace = faceRecord(
                namedPhoto,
                embedding: testEmbedding(seed: 88),
                state: .other,
                personID: named.id
            )
            try seedStore.replaceFaces(photo: namedPhoto, faces: [namedFace])
            // A real rejection row must survive the retry: ban a seeded
            // face from the named group. (Rejections against a dissolved
            // auto group cascade away with it, so the veto targets the
            // group that stays.)
            let seededGroup = try XCTUnwrap(seedStore.otherGroups().first { $0.id != named.id })
            let seededFace = try XCTUnwrap(seedStore.faces(personID: seededGroup.id).first)
            try seedStore.recordRejection(personID: named.id, faceID: seededFace.id)

            let blocker = try SQLiteBlocker(path: catalog.path)
            defer { blocker.close() }
            blocker.beginImmediate()

            var config = Configuration()
            config.foreignKeysEnabled = true
            // Refuse the momentary lock instead of waiting — the retry
            // above this is what a NAS needs.
            config.busyMode = .callback { _ in
                blocker.commit()
                return false
            }
            let queue = try DatabaseQueue(path: catalog.path, configuration: config)
            let service = FaceIndexService(store: FaceIndexStore(url: catalog, queue: queue))

            let report = try service.rematchRoster()
            XCTAssertGreaterThan(report.facesGrouped, 0)

            let verify = FaceIndexStore(url: catalog)
            XCTAssertEqual(try verify.matchableFaces().count, 61)
            XCTAssertEqual(try verify.face(id: dadFace.id)?.state, .confirmed)
            XCTAssertEqual(try verify.face(id: dadFace.id)?.personID, dad.id)
            XCTAssertEqual(try verify.person(named.id)?.name, "Aunt Bee")
            XCTAssertEqual(try verify.face(id: namedFace.id)?.personID, named.id)
            XCTAssertEqual(
                try verify.faceRejections().personIDsByFaceID[seededFace.id],
                [named.id],
                "the rejection row must survive the retried transaction"
            )
            // The event row in the same catalog is untouched.
            XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM events", database: catalog), 1)
            XCTAssertEqual(scalarString("SELECT name FROM events", database: catalog), "Beach Day")
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
        }
    }

    /// A lock that outlasts the retries still fails the job — with the
    /// original SQLite message — and the catalog is left exactly as the
    /// failed attempt found it: no half-applied group split.
    func testRematchFailsWithSQLiteMessageWhenBusyOutlastsRetries() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let seedStore = try seededStore(root: root, catalog: catalog, groups: 2, facesPerGroup: 30)
            let before = try seedStore.matchableFaces().map { ($0.id, $0.personID, $0.state) }

            let blocker = try SQLiteBlocker(path: catalog.path)
            defer { blocker.close() }
            blocker.beginImmediate()

            var config = Configuration()
            config.foreignKeysEnabled = true
            config.busyMode = .immediateError
            let queue = try DatabaseQueue(path: catalog.path, configuration: config)
            let service = FaceIndexService(store: FaceIndexStore(url: catalog, queue: queue))

            XCTAssertThrowsError(try service.rematchRoster()) { error in
                guard let databaseError = error as? DatabaseError else {
                    return XCTFail("expected DatabaseError, got \(error)")
                }
                XCTAssertEqual(databaseError.resultCode, .SQLITE_BUSY)
                XCTAssertTrue(
                    databaseError.message?.localizedCaseInsensitiveContains("locked") == true,
                    "the real SQLite message must reach the job — got \(databaseError)"
                )
            }

            blocker.commit()
            let after = try seedStore.matchableFaces().map { ($0.id, $0.personID, $0.state) }
            XCTAssertEqual(
                Set(after.map { "\($0.0)|\($0.1?.uuidString ?? "-")|\($0.2.rawValue)" }),
                Set(before.map { "\($0.0)|\($0.1?.uuidString ?? "-")|\($0.2.rawValue)" }),
                "a failed rebundle must roll back whole"
            )
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
        }
    }

    // MARK: - Retry policy unit coverage

    /// SQLITE_IOERR — the actual NAS failure — retries the same way BUSY
    /// does; a permanent refusal rethrows the original error, message and
    /// all, after the attempts run out. Non-transient errors never retry.
    func testTransactionRetryPolicy() throws {
        var attempts = 0
        let ioerr = DatabaseError(resultCode: .SQLITE_IOERR, message: "disk I/O error")
        let value = try CatalogTransactionRetry.run {
            attempts += 1
            if attempts == 1 { throw ioerr }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 2)

        attempts = 0
        XCTAssertThrowsError(try CatalogTransactionRetry.run { () throws -> Int in
            attempts += 1
            throw ioerr
        }) { error in
            XCTAssertEqual(attempts, CatalogTransactionRetry.maxAttempts)
            XCTAssertEqual((error as? DatabaseError)?.message, "disk I/O error")
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_IOERR)
        }

        attempts = 0
        let constraint = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE constraint failed")
        XCTAssertThrowsError(try CatalogTransactionRetry.run { () throws -> Int in
            attempts += 1
            throw constraint
        }) { error in
            XCTAssertEqual(attempts, 1, "non-transient errors must not retry")
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }

        // Raw result codes: extended IOERR variants classify transient too.
        XCTAssertTrue(CatalogTransactionRetry.isTransient(Int32(10)))       // SQLITE_IOERR
        XCTAssertTrue(CatalogTransactionRetry.isTransient(Int32(5)))        // SQLITE_BUSY
        XCTAssertTrue(CatalogTransactionRetry.isTransient(Int32(10 | (7 << 8)))) // SQLITE_IOERR_LOCK
        XCTAssertFalse(CatalogTransactionRetry.isTransient(Int32(19)))      // SQLITE_CONSTRAINT
        XCTAssertFalse(CatalogTransactionRetry.isTransient(Int32(1)))       // SQLITE_ERROR
    }

    // MARK: - Schema gate

    /// The Re-match gate: bootstrap creates the face tables, and only
    /// then does the schema check pass — so a catalog that already has
    /// them never pays bootstrap's second writer.
    func testFaceSchemaExistsOnlyAfterBootstrap() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            XCTAssertFalse(try FaceIndexStore(url: catalog).faceSchemaExists())

            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            XCTAssertTrue(try FaceIndexStore(url: catalog).faceSchemaExists())
            XCTAssertTrue(try FaceIndexService(catalogURL: catalog).faceSchemaExists())
        }
    }

    // MARK: - Helpers

    private func faceTestConfiguration(root: URL, catalog: URL) -> AppConfiguration {
        var configuration = testConfiguration(root: root)
        configuration.catalogDatabasePath = catalog.path
        return configuration
    }

    /// A bootstrapped catalog whose unnamed "Person N" groups already hold
    /// embedded faces — the shape a Re-match rebundles.
    private func seededStore(
        root: URL,
        catalog: URL,
        groups: Int,
        facesPerGroup: Int
    ) throws -> FaceIndexStore {
        _ = try CatalogStore(url: catalog).bootstrap(
            configuration: faceTestConfiguration(root: root, catalog: catalog),
            createBackup: false,
            createLibraryFolders: false
        )
        let store = FaceIndexStore(url: catalog)
        try seedFaces(store: store, groups: groups, facesPerGroup: facesPerGroup)
        return store
    }

    /// Inserts `groups` auto-named clusters of `facesPerGroup` faces each.
    /// Every face carries a distinct-seed embedding clustered near its
    /// group's seed so the regroup has real work to do.
    private func seedFaces(store: FaceIndexStore, groups: Int, facesPerGroup: Int) throws {
        for groupIndex in 0..<groups {
            let group = try store.createPerson(name: "Person \(groupIndex + 1)", isRoster: false)
            let photo = photoRecord("GRP\(groupIndex)_0001.ARW")
            let faces = (0..<facesPerGroup).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(
                        x: Double(index % 10) * 0.09,
                        y: Double(index / 10) * 0.12,
                        width: 0.05,
                        height: 0.06
                    ),
                    embedding: testEmbedding(seed: UInt64(1000 + groupIndex), noise: 0.05),
                    state: .other,
                    personID: group.id
                )
            }
            try store.replaceFaces(photo: photo, faces: faces)
        }
    }

    private func makeQueue(catalog: URL, trace: BeginCounter) throws -> DatabaseQueue {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: catalog.path, configuration: config)
        // The trace hook lives on the queue's single writer connection —
        // once set it sees every statement that connection runs.
        try queue.write { database in
            database.trace { event in
                if case .statement(let statement) = event {
                    trace.record(statement.sql)
                }
            }
        }
        return queue
    }

    private func photoRecord(_ name: String) -> FacePhotoRecord {
        let path = "/tmp/faces/\(name)"
        return FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey(path),
            path: path,
            fileName: name,
            byteCount: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
    }

    private func faceRecord(
        _ photo: FacePhotoRecord,
        box: NormalizedFaceBox = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        detScore: Double = 0.9,
        embedding: [Float]? = nil,
        state: FaceState = .cached,
        personID: UUID? = nil
    ) -> FaceRecord {
        FaceRecord(
            photoID: photo.pathKey,
            personID: personID,
            box: box,
            detScore: detScore,
            embedding: embedding,
            state: state,
            photoPath: photo.path
        )
    }

    /// A deterministic 512-d vector; `noise` perturbs a copy of the same
    /// seed's vector so faces cluster without colliding.
    private func testEmbedding(seed: UInt64, noise: Float = 0) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var vector = (0..<512).map { _ in
            Float(generator.next() >> 40) / Float(1 << 24) * 2 - 1
        }
        if noise > 0 {
            var noiseGenerator = SplitMix64(seed: seed ^ 0x9E3779B97F4A7C15)
            for index in vector.indices {
                vector[index] += noise * (Float(noiseGenerator.next() >> 40) / Float(1 << 24) * 2 - 1)
            }
        }
        return FaceEmbeddingMath.l2Normalized(vector)
    }

    private func scalarInt(_ sql: String, database url: URL) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { return -1 }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private func scalarString(_ sql: String, database url: URL) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

/// Counts `BEGIN` statements seen by a GRDB trace hook.
private final class BeginCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0

    func record(_ sql: String) {
        guard sql.uppercased().hasPrefix("BEGIN") else { return }
        lock.lock()
        begins += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return begins
    }
}

/// A second raw-sqlite connection that holds the write lock — the NAS
/// busy stutter made concrete. `commit()` releases it.
private final class SQLiteBlocker: @unchecked Sendable {
    private var database: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw XCTSkip("Could not open blocker connection")
        }
        sqlite3_busy_timeout(database, 0)
        self.database = database
    }

    /// RESERVED lock: another connection's BEGIN IMMEDIATE gets SQLITE_BUSY.
    func beginImmediate() {
        sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
    }

    func commit() {
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
    }

    func close() {
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
        database = nil
    }
}

/// Deterministic PRNG for synthetic embeddings — no crypto needed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
