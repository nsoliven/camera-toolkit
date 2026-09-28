import CameraToolkitCore
import Foundation
import Observation

/// One recorded job opened in History: its row, samples, files, and the
/// structures the chart and table draw from — built off the main actor.
struct JobHistoryDetail: Sendable {
    var job: JobHistoryJob
    var samples: [JobHistorySample]
    var items: [JobHistoryItem]
    var flights: JobHistoryFlightIndex
    var chart: JobHistoryChartData

    init(job: JobHistoryJob, samples: [JobHistorySample], items: [JobHistoryItem], now: Date = Date()) {
        self.job = job
        self.samples = samples
        self.items = items
        flights = JobHistoryFlightIndex(items)
        chart = JobHistoryChartData(samples: samples, duration: max(job.duration(now: now), items.map(\.end).max() ?? 0))
    }
}

/// What the Jobs window's History reads: the recorded jobs, newest first,
/// and the detail of the one opened. Reads only — every write goes through
/// the job recorders in Core. Reads run detached; a store that cannot be
/// opened shows as a message, never an error dialog.
@MainActor
@Observable
final class JobHistoryBrowser {
    private(set) var jobs: [JobHistoryJob] = []
    private(set) var hasLoaded = false
    private(set) var message: String?
    private(set) var detail: JobHistoryDetail?
    private(set) var isLoadingDetail = false

    @ObservationIgnored private let model: DashboardModel

    init(model: DashboardModel) {
        self.model = model
    }

    /// Reloads the list. Jobs this session still records are shown as the
    /// recorder holds them, which is newer than their last write.
    func reload() async {
        guard let url = model.jobHistoryURL else {
            jobs = []
            hasLoaded = true
            message = "Job history is recorded by the installed app only."
            return
        }
        let loaded = await Task.detached(priority: .utility) { () -> Result<[JobHistoryJob], JobHistoryReadError> in
            guard let store = JobHistoryStore.shared(at: url) else { return .failure(.unavailable) }
            do {
                return .success(try store.jobs())
            } catch {
                return .failure(.read(error.localizedDescription))
            }
        }.value
        hasLoaded = true
        switch loaded {
        case .success(let rows):
            jobs = rows.map { row in model.jobHistoryRecorders[row.id]?.currentJob() ?? row }
            message = nil
        case .failure(let error):
            message = error.message
        }
    }

    /// Opens `id`'s detail. A job still running is reread on every call,
    /// so polling it keeps the chart growing.
    func open(_ id: UUID?) async {
        guard let id else {
            detail = nil
            return
        }
        guard let url = model.jobHistoryURL else { return }
        if detail?.job.id != id { isLoadingDetail = true }
        let live = model.jobHistoryRecorders[id]
        let liveJob = live?.currentJob()
        let liveSamples = live?.samples()
        let loaded = await Task.detached(priority: .userInitiated) { () -> JobHistoryDetail? in
            guard let store = JobHistoryStore.shared(at: url),
                  let job = liveJob ?? (try? store.job(id: id)) else { return nil }
            // A recorder in memory has every sample, including those not
            // written yet; the file rows come from the store.
            let samples = liveSamples ?? ((try? store.samples(jobID: id)) ?? [])
            let items = (try? store.items(jobID: id)) ?? []
            return JobHistoryDetail(job: job, samples: samples, items: items)
        }.value
        isLoadingDetail = false
        detail = loaded
    }

    /// True while `job` is still running in this app.
    func isLive(_ job: JobHistoryJob) -> Bool {
        job.outcome == .running && model.jobHistoryRecorders[job.id] != nil
    }
}

enum JobHistoryReadError: Error, Sendable {
    case unavailable
    case read(String)

    var message: String {
        switch self {
        case .unavailable: "The job history database could not be opened. Jobs still run; they are not recorded."
        case .read(let detail): "Could not read the job history: \(detail)"
        }
    }
}
