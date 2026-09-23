import Foundation

/// Persists the catalog-owned state off the main actor, one transaction per
/// save, writing only the rows that changed since the last successful
/// write.
///
/// `submit` hands over the latest in-memory state and returns at once;
/// saves submitted while one is running coalesce into the newest. The
/// writer keeps what it last wrote successfully as the diff base, so a
/// failed save changes nothing on disk and the next save retries the whole
/// difference. On a failure it also writes the unsaved state to a JSON
/// file in `emergencyFolder`, so an unexpected catalog error cannot lose
/// edits made before quitting.
public final class CatalogStateWriter: @unchecked Sendable {
    public let store: CatalogStateStore
    private let emergencyFolder: URL?
    private let queue = DispatchQueue(label: "CameraToolkit.CatalogStateWriter", qos: .utility)
    private let lock = NSLock()
    /// Only touched on `queue`.
    private var persisted: CatalogOwnedState
    private var pending: CatalogOwnedState?
    private var drainScheduled = false
    private let onResult: @Sendable (Result<CatalogStateChangeSummary, Error>) -> Void

    public init(
        store: CatalogStateStore,
        baseline: CatalogOwnedState,
        emergencyFolder: URL?,
        onResult: @escaping @Sendable (Result<CatalogStateChangeSummary, Error>) -> Void = { _ in }
    ) {
        self.store = store
        self.persisted = baseline.canonical().state
        self.emergencyFolder = emergencyFolder
        self.onResult = onResult
    }

    public func submit(_ state: CatalogOwnedState) {
        lock.lock()
        pending = state
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if shouldSchedule {
            queue.async { [self] in drain() }
        }
    }

    /// Blocks until every submitted state has been written (or failed).
    public func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let target = pending else {
                drainScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                let summary = try store.apply(from: persisted, to: target)
                persisted = target.canonical().state
                onResult(.success(summary))
            } catch {
                writeEmergencyCopy(of: target)
                onResult(.failure(error))
            }
        }
    }

    private func writeEmergencyCopy(of state: CatalogOwnedState) {
        guard let emergencyFolder else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let url = emergencyFolder.appendingPathComponent("unsaved-events-\(formatter.string(from: Date())).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: emergencyFolder, withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: url, options: .atomic)
    }
}
