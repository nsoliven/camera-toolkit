import CameraToolkitCore
import Foundation

/// One row of the Jobs window's list — a job this session runs or ran, or
/// one recorded in `job-history.sqlite` — whichever source knows it, merged
/// by id.
struct JobListEntry: Identifiable, Equatable {
    enum Status: Equatable {
        case queued
        case running(progress: Double)
        case ended(JobHistoryOutcome)
    }

    var id: UUID
    /// `JobAction.rawValue`.
    var kind: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: Status
    /// What the row's second line says after the time: "2.2 GB · 98 MB/s".
    var detail: String?
    /// How an ended job's outcome reads — "Done · 1 conflict" for a sync
    /// that only left conflicts. Nil while it runs.
    var display: JobOutcomeDisplay?

    var isActive: Bool {
        switch status {
        case .queued, .running: true
        case .ended: false
        }
    }

    var action: JobAction? { JobAction(rawValue: kind) }
}

/// The list's past jobs under one day heading.
struct JobListDay: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var title: String
    var entries: [JobListEntry]
}

/// Builds the Jobs window's list: running and queued jobs pinned on top,
/// then every past job newest first, grouped by day. Pure, so the merge
/// and grouping are tested without a window.
enum JobsList {
    struct Sections: Equatable {
        /// Running and queued jobs, running first.
        var active: [JobListEntry]
        var days: [JobListDay]

        var running: [JobListEntry] { active.filter { if case .running = $0.status { true } else { false } } }
        var queued: [JobListEntry] { active.filter { $0.status == .queued } }

        var all: [JobListEntry] { active + days.flatMap(\.entries) }
        var isEmpty: Bool { active.isEmpty && days.isEmpty }
    }

    /// `session` is this session's jobs (`DashboardModel.jobs`), `history`
    /// the recorded rows (already the recorder's live row for a job this
    /// session still records). A recorded row still marked running that no
    /// session job backs is a job a quit left behind: it is listed as
    /// interrupted, never as running.
    static func sections(
        session: [JobSnapshot],
        history: [JobHistoryJob],
        queueOrder: [UUID] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Sections {
        let recorded = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [JobListEntry] = []
        var seen: Set<UUID> = []
        for job in session {
            seen.insert(job.id)
            entries.append(entry(job, recorded: recorded[job.id], now: now))
        }
        for job in history where !seen.contains(job.id) {
            entries.append(entry(job, now: now))
        }
        // Running newest first, then queued in the order they will start.
        let running = entries.filter { if case .running = $0.status { true } else { false } }.sorted { $0.startedAt > $1.startedAt }
        // The queue's own order when it is known, else when each was queued.
        let rank = Dictionary(queueOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let queued = entries.filter { $0.status == .queued }.sorted {
            (rank[$0.id] ?? Int.max, $0.startedAt) < (rank[$1.id] ?? Int.max, $1.startedAt)
        }
        let active = running + queued
        let past = entries.filter { !$0.isActive }.sorted { $0.startedAt > $1.startedAt }
        return Sections(active: active, days: days(past, now: now, calendar: calendar))
    }

    static func entry(_ job: JobSnapshot, recorded: JobHistoryJob?, now: Date) -> JobListEntry {
        let status: JobListEntry.Status = switch job.state {
        case .queued: .queued
        case .running: .running(progress: min(max(job.progress, 0), 1))
        case .done: .ended(.succeeded)
        case .failed: .ended(.failed)
        case .cancelled: .ended(.cancelled)
        }
        var entry = JobListEntry(
            id: job.id,
            kind: job.action.rawValue,
            title: recorded?.title ?? job.action.displayName,
            startedAt: job.createdAt,
            endedAt: job.finishedAt,
            status: status,
            detail: recorded.flatMap { rowDetail($0, now: now) }
        )
        if recorded == nil, job.processedBytes > 0 {
            entry.detail = job.processedBytes.formattedBytes
        }
        if case .ended(let outcome) = status {
            entry.display = JobDetailFacts.outcomeDisplay(outcome, job: recorded)
        }
        return entry
    }

    static func entry(_ job: JobHistoryJob, now: Date) -> JobListEntry {
        // Running here means nothing in this session runs it.
        let outcome = job.outcome == .running ? JobHistoryOutcome.interrupted : job.outcome
        return JobListEntry(
            id: job.id,
            kind: job.kind,
            title: job.title,
            startedAt: job.startedAt,
            endedAt: job.endedAt,
            status: .ended(outcome),
            detail: rowDetail(job, now: now),
            display: JobDetailFacts.outcomeDisplay(outcome, job: job)
        )
    }

    /// "2.2 GB · 98 MB/s", or the files when nothing moved: "16,141 checked".
    static func rowDetail(_ job: JobHistoryJob, now: Date) -> String? {
        if JobHistoryItemOutcome.removes(job.kind), job.matchedExisting + job.failed > 0 {
            var parts = ["\(job.matchedExisting.formatted()) removed"]
            if job.failed > 0 { parts.append("\(job.failed.formatted()) skipped") }
            return parts.joined(separator: " · ")
        }
        let moved = job.transferBytes ?? job.bytesDone
        if moved > 0 {
            var parts = [job.bytesDone > 0 ? job.bytesDone.formattedBytes : moved.formattedBytes]
            if let rate = job.averageBytesPerSecond(now: now) {
                parts.append("\(JobThroughputFormat.rate(JobThroughputFormat.megabytes(rate))) MB/s")
            }
            return parts.joined(separator: " · ")
        }
        let already = job.matchedExisting + job.alreadyVerified
        if already > 0 { return "\(already.formatted()) checked" }
        if job.totalFiles > 0 { return "\(job.totalFiles.formatted()) files" }
        return nil
    }

    /// Past jobs under "Today", "Yesterday", then the date.
    static func days(_ entries: [JobListEntry], now: Date, calendar: Calendar) -> [JobListDay] {
        var result: [JobListDay] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.startedAt)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(JobListDay(day: day, title: dayTitle(day, now: now, calendar: calendar), entries: [entry]))
            }
        }
        return result
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated).month(.abbreviated).day()
        if !sameYear { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// The job a card transfer belongs to: the card copy that started with
    /// it (within two minutes), else the newest card copy started after it.
    static func transferJobID(for queue: TransferQueueSnapshot, in entries: [JobListEntry]) -> UUID? {
        let copies = entries.filter { $0.kind == JobAction.ingestCard.rawValue }
        if let match = copies.min(by: { abs($0.startedAt.timeIntervalSince(queue.createdAt)) < abs($1.startedAt.timeIntervalSince(queue.createdAt)) }),
           abs(match.startedAt.timeIntervalSince(queue.createdAt)) <= 120 {
            return match.id
        }
        return copies.filter { $0.startedAt >= queue.createdAt }.max { $0.startedAt < $1.startedAt }?.id
    }
}
