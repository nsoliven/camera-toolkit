import CameraToolkitCore
import Foundation

/// One file job waiting for the job gate.
struct QueuedFileJob {
    let id: UUID
    let action: JobAction
    /// Starts the job through `runBackgroundJob(jobID:)` with this id. It
    /// checks everything it acts on again first; when it decides there is
    /// nothing to do it simply does not start a job, and the queued row is
    /// closed with `skippedNote`.
    let start: @MainActor (UUID) -> Void
    let skippedNote: String
}

extension DashboardModel {
    /// Queues a file job behind whatever holds the job gate and shows it in
    /// Jobs as queued; with the gate free it starts at once. Used by the
    /// deleting and space-freeing jobs (Clear from Card, Take Off Drive, Free
    /// Up Source, Free Up Camera), whose typed confirmation happens before
    /// anything is queued.
    @discardableResult
    func enqueueFileJob(
        action: JobAction,
        queuedNote: String,
        detail: String,
        skippedNote: String = "Did not start: nothing was left to do. Nothing changed.",
        start: @escaping @MainActor (UUID) -> Void
    ) -> UUID {
        let id = UUID()
        // Below the running job and any older queued ones, so whatever picks
        // "the first running or queued job" still finds the running one.
        let position = jobs.firstIndex { $0.state != .running && $0.state != .queued } ?? jobs.endIndex
        jobs.insert(JobSnapshot(id: id, action: action, state: .queued, note: queuedNote, detail: detail), at: position)
        queuedFileJobs.append(QueuedFileJob(id: id, action: action, start: start, skippedNote: skippedNote))
        if isBusy || isStorageBenchmarkRunning {
            statusMessage = "Queued: \(queuedNote) It starts when the running job finishes."
        }
        startNextQueuedFileJobIfPossible()
        return id
    }

    /// After the gate frees: on a later turn, so a settling job's own
    /// follow-ups (the next pending transfer) keep their place.
    func scheduleQueuedFileJobs() {
        guard !queuedFileJobs.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.startNextQueuedFileJobIfPossible()
        }
    }

    func startNextQueuedFileJobIfPossible() {
        while !isBusy, !isStorageBenchmarkRunning, !queuedFileJobs.isEmpty {
            let next = queuedFileJobs.removeFirst()
            next.start(next.id)
            // It decided there was nothing to do: close its row.
            if let index = jobs.firstIndex(where: { $0.id == next.id && $0.state == .queued }) {
                jobs[index].state = .cancelled
                jobs[index].note = next.skippedNote
                jobs[index].finishedAt = Date()
            }
        }
    }

    /// Removes a job that has not started yet. Nothing ran.
    func cancelQueuedFileJob(id: UUID) {
        guard let position = queuedFileJobs.firstIndex(where: { $0.id == id }) else { return }
        queuedFileJobs.remove(at: position)
        if let index = jobs.firstIndex(where: { $0.id == id && $0.state == .queued }) {
            jobs[index].state = .cancelled
            jobs[index].note = "Cancelled before it started. Nothing changed."
            jobs[index].finishedAt = Date()
        }
    }
}
