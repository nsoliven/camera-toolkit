import CameraToolkitCore
import Foundation

extension DashboardModel {
    /// Like `runBackgroundJob`, for work that awaits network calls such as
    /// Immich uploads. It shares the single-job gate, job list, and activity log.
    func runAsyncJob<Result: Sendable>(
        action: JobAction,
        runningNote: String,
        logTitle: String,
        logDetail: String,
        operation: @escaping @Sendable (@escaping @Sendable (BackgroundJobUpdate) -> Void) async throws -> Result,
        completion: @escaping (Result) throws -> String
    ) {
        guard !isBusy, !isStorageBenchmarkRunning else {
            statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }
        isBusy = true
        statusMessage = runningNote

        let jobID = UUID()
        jobs.insert(
            JobSnapshot(
                id: jobID,
                action: action,
                state: .running,
                progress: 0.02,
                note: runningNote,
                detail: logDetail
            ),
            at: 0
        )

        let progressHandler: @Sendable (BackgroundJobUpdate) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.updateJob(id: jobID, update: update)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try await operation(progressHandler)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await worker.value
                let summary = try completion(result)
                statusMessage = summary
                finishJob(id: jobID, action: action, state: .done, note: summary, logTitle: logTitle, logDetail: logDetail)
                startNextPendingTransferIfPossible()
            } catch {
                let summary = error.localizedDescription
                statusMessage = summary
                finishJob(id: jobID, action: action, state: .failed, note: summary, logTitle: logTitle, logDetail: logDetail)
            }
        }
    }
}
