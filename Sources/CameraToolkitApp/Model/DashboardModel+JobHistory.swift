import CameraToolkitCore
import Foundation

/// Job history: every job this app runs is recorded into
/// `job-history.sqlite` beside the catalog (see `JobHistoryStore`), which
/// the Jobs window's History reads. Recording never touches the main
/// actor's time budget beyond creating the recorder: sampling runs on the
/// job's own threads, writes on the recorder's queue.
extension DashboardModel {
    /// Finished recorders kept in memory for their whole-run chart.
    static let finishedHistoryRecorderLimit = 3

    /// `job-history.sqlite` in the catalog's folder; nil while recording is
    /// off (tests, previews).
    var jobHistoryURL: URL? {
        guard jobHistoryEnabled else { return nil }
        return JobHistoryStore.defaultURL(catalogURL: URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath)))
    }

    /// Launch: open the store in the background, which marks jobs a quit
    /// or crash left running as interrupted and prunes old samples.
    func openJobHistorySoon() {
        guard let url = jobHistoryURL else { return }
        Task.detached(priority: .utility) {
            _ = JobHistoryStore.shared(at: url)
        }
    }

    /// A recorder for a job about to start; nil while recording is off.
    /// Nothing is written until the job starts (`JobHistoryRecorder.start`).
    func makeHistoryRecorder(action: JobAction, title: String) -> JobHistoryRecorder? {
        guard let url = jobHistoryURL else { return nil }
        let sampler = JobHistoryLoadSampler()
        return JobHistoryRecorder(
            storeURL: url,
            kind: action.rawValue,
            title: title,
            loadProbe: { sampler.sample() }
        )
    }

    /// The job's outcome goes to its recorder, which writes what it still
    /// holds. The last few finished recorders stay for their charts.
    func finishJobHistory(id: UUID, state: JobState, note: String) {
        guard let recorder = jobHistoryRecorders[id] else { return }
        let job = jobs.first { $0.id == id }
        recorder.finish(
            outcome: JobHistoryOutcome(state),
            note: note,
            totals: job.map {
                JobHistoryRecorder.Observation(
                    processedFiles: $0.processedFiles,
                    totalFiles: $0.totalFiles,
                    processedBytes: $0.processedBytes,
                    totalBytes: $0.totalBytes,
                    telemetry: $0.telemetry
                )
            }
        )
        jobHistoryFinishedOrder.removeAll { $0 == id }
        jobHistoryFinishedOrder.append(id)
        while jobHistoryFinishedOrder.count > Self.finishedHistoryRecorderLimit {
            jobHistoryRecorders[jobHistoryFinishedOrder.removeFirst()] = nil
        }
        jobHistoryRevision &+= 1
    }

    /// Every sample of a job this session recorded, in time order; nil
    /// when this session holds no recorder for it.
    func historySamples(for jobID: UUID) -> [JobHistorySample]? {
        jobHistoryRecorders[jobID]?.samples()
    }

    /// Quit: write what the recorders still buffer. A job still running
    /// stays marked running and becomes `interrupted` at the next launch.
    func flushJobHistory() {
        for recorder in jobHistoryRecorders.values {
            recorder.flush()
        }
    }
}

extension JobHistoryOutcome {
    init(_ state: JobState) {
        switch state {
        case .done: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .queued, .running: self = .running
        }
    }
}

extension BackgroundJobUpdate {
    /// This update's counters for a job recorder.
    var historyObservation: JobHistoryRecorder.Observation {
        JobHistoryRecorder.Observation(
            processedFiles: processedFiles,
            totalFiles: totalFiles,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            telemetry: telemetry
        )
    }
}

/// CPU and GPU load for a job recorder's samples — the counters the Jobs
/// window's hardware strip reads. One per recorder: it is only ever called
/// on that recorder's serial queue, and CPU load needs the previous ticks.
final class JobHistoryLoadSampler: @unchecked Sendable {
    private var previous: SystemLoadProbe.CPUTicks?

    func sample() -> JobHistoryRecorder.Load {
        let ticks = SystemLoadProbe.cpuTicks()
        let cpu = ticks.flatMap { current in previous.flatMap { SystemLoadProbe.cpuFraction(between: $0, and: current) } }
        previous = ticks
        return JobHistoryRecorder.Load(cpu: cpu, gpu: SystemLoadProbe.gpuFraction())
    }
}
