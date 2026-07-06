import Foundation

public actor JobRunner {
    private var currentJob: JobSnapshot?
    private var history: [JobSnapshot] = []

    public init() {}

    public func snapshots() -> [JobSnapshot] {
        var all = history
        if let currentJob {
            all.insert(currentJob, at: 0)
        }
        return all
    }

    @discardableResult
    public func run(action: JobAction, operation: @Sendable (JobProgress) async throws -> Void) async -> JobSnapshot {
        var job = JobSnapshot(action: action, state: .running, progress: 0, note: "Starting")
        currentJob = job

        let progress = JobProgress { [weak self] value, note in
            await self?.updateCurrent(progress: value, note: note)
        }

        do {
            try await operation(progress)
            job = currentJob ?? job
            job.state = .done
            job.progress = 1
            job.note = "Done"
            job.finishedAt = Date()
        } catch is CancellationError {
            job = currentJob ?? job
            job.state = .cancelled
            job.note = "Cancelled"
            job.finishedAt = Date()
        } catch {
            job = currentJob ?? job
            job.state = .failed
            job.note = String(describing: error)
            job.finishedAt = Date()
        }

        currentJob = nil
        history.insert(job, at: 0)
        return job
    }

    private func updateCurrent(progress: Double, note: String?) {
        guard var job = currentJob else { return }
        job.progress = min(max(progress, 0), 1)
        if let note {
            job.note = note
        }
        currentJob = job
    }
}

public struct JobProgress: Sendable {
    private let updateHandler: @Sendable (Double, String?) async -> Void

    public init(updateHandler: @escaping @Sendable (Double, String?) async -> Void) {
        self.updateHandler = updateHandler
    }

    public func update(_ progress: Double, note: String? = nil) async {
        await updateHandler(progress, note)
    }
}
