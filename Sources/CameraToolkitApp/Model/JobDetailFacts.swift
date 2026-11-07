import CameraToolkitCore
import Foundation

/// One labelled number in the Jobs window's readout row.
struct JobReadout: Equatable {
    var caption: String
    var value: String?
    var unit: String
    var prominent = false
    var faded = false
    var help: String
}

/// One cell of the tally under the speed card: what the job did to its
/// files and bytes.
struct JobTallyItem: Equatable {
    enum Tone: Equatable {
        case normal
        case warning
        case failure
    }

    var label: String
    var value: String
    var tone: Tone = .normal
    var help: String?
}

/// The words and numbers the Jobs window's detail pane shows, kept pure so
/// they are tested without a window. Every value comes from the job's own
/// counters or recorded samples; anything a job does not report is left
/// out, never shown as zero.
enum JobDetailFacts {
    // MARK: Readouts

    /// The readout row for a running job: the live monitor's smoothed
    /// "now" and average, the files rate, and the recorded peak.
    static func liveReadouts(_ readout: JobThroughputReadout, graph: JobSpeedGraph, job: JobSnapshot) -> [JobReadout] {
        let bytes = readout.unit == .megabytesPerSecond
        let format: (Double) -> String = { bytes ? JobThroughputFormat.rate($0) : JobThroughputFormat.itemRate($0) }
        let combined = job.telemetry?.transferBytes != nil
        let nowCaption = combined ? "now · combined" : "now"
        let running = job.state == .running || job.state == .queued
        var result: [JobReadout] = []
        // A finished job has no "now": its average leads.
        if running {
            result.append(JobReadout(
                caption: readout.heldFor.map { "\(nowCaption) · held \(JobActivityDetail.durationText($0))" } ?? nowCaption,
                value: readout.current.map(format),
                unit: readout.unit.axisLabel,
                prominent: true,
                faded: readout.isHeld,
                help: (readout.isHeld
                    ? "No progress reported for a few seconds — the last smoothed speed is held, not blanked."
                    : "Smoothed over about the last 5 seconds") + (combined ? " All parallel transfers together." : "")
            ))
        }
        result.append(JobReadout(
            caption: combined ? "average · combined" : "average",
            value: readout.average.map(format),
            unit: readout.unit.axisLabel,
            prominent: !running,
            help: "Everything this job has moved, over its elapsed time" + (combined ? ", all parallel transfers together" : "")
        ))
        if let peak = peakReadout(graph, kind: job.action.rawValue) { result.append(peak) }
        if let files = readout.filesPerSecond {
            result.append(JobReadout(
                caption: "files", value: JobThroughputFormat.itemRate(files), unit: filesUnit(job.action.rawValue),
                faded: readout.isHeld, help: "Finished files per second, smoothed"
            ))
        }
        if let frames = readout.framesPerSecond {
            result.append(JobReadout(caption: "video", value: JobThroughputFormat.itemRate(frames), unit: "frames/s", help: "Video frames decoded per second, smoothed"))
        }
        return result
    }

    /// The readout row for a finished job, from its row and its recorded
    /// samples: average, peak, and the files rate.
    static func finishedReadouts(job: JobHistoryJob, graph: JobSpeedGraph) -> [JobReadout] {
        var result: [JobReadout] = []
        let combined = job.transferBytes != nil
        if let rate = job.averageBytesPerSecond() {
            result.append(JobReadout(
                caption: combined ? "average · combined" : "average",
                value: JobThroughputFormat.rate(JobThroughputFormat.megabytes(rate)),
                unit: "MB/s",
                prominent: true,
                help: "Everything the job moved over its wall time" + (combined ? ", all parallel transfers together (copies and re-reads)" : "")
            ))
        } else if graph.metric == .filesPerSecond, let average = graph.average {
            result.append(JobReadout(
                caption: "average", value: JobThroughputFormat.itemRate(average), unit: filesUnit(job.kind), prominent: true,
                help: "Files finished over the job's whole time"
            ))
        }
        if let peak = peakReadout(graph, kind: job.kind) { result.append(peak) }
        let filesAlreadyLead = graph.metric == .filesPerSecond && job.averageBytesPerSecond() == nil
        if !filesAlreadyLead, let files = graph.averageFilesPerSecond {
            result.append(JobReadout(
                caption: "files", value: JobThroughputFormat.itemRate(files), unit: filesUnit(job.kind),
                help: "\(graph.filesDone.formatted()) files finished over the job's whole time"
            ))
        }
        return result
    }

    static func peakReadout(_ graph: JobSpeedGraph, kind: String) -> JobReadout? {
        guard graph.summary == nil, let peak = graph.peak, let metric = graph.metric else { return nil }
        return JobReadout(
            caption: "peak",
            value: metric == .megabytesPerSecond ? JobThroughputFormat.rate(peak.value) : JobThroughputFormat.itemRate(peak.value),
            unit: metric == .megabytesPerSecond ? metric.unit : filesUnit(kind),
            help: "The fastest recorded moment, at \(JobActivityDetail.durationText(peak.t)) — each sample spans about five seconds"
        )
    }

    static func filesUnit(_ kind: String) -> String {
        kind == JobAction.faceScan.rawValue ? "photos/s" : "files/s"
    }

    // MARK: Tally

    /// What the job did to its files: for Sync to NAS, bytes copied against
    /// files already there and what was verified; for other jobs, files
    /// and bytes processed. Problems are always last.
    static func tally(job: JobHistoryJob?, live: JobSnapshot?, items: [JobHistoryItem] = []) -> [JobTallyItem] {
        var result: [JobTallyItem] = []
        if let job, job.kind == JobAction.syncBuffer.rawValue {
            result.append(JobTallyItem(
                label: "Copied",
                value: job.bytesDone > 0 ? "\(job.bytesDone.formattedBytes) · \(job.copied.formatted()) file\(job.copied == 1 ? "" : "s")" : (job.outcome == .running ? "Nothing yet" : "Nothing"),
                help: "\(job.bytesDone.formatted()) bytes written to the NAS"
            ))
            let verifiedBytes = (job.summary?.timings).map { $0.remoteVerifyBytes + $0.smbVerifyBytes }
                ?? live?.telemetry?.phases.filter { $0.label == "Verify" || $0.label == "Remote verify (NAS)" }.reduce(Int64(0)) { $0 + $1.bytes }
            if let verifiedBytes, verifiedBytes > 0 {
                let method = job.summary?.verifyMethod.map { $0 == "ssh" ? " on the NAS" : " over SMB" } ?? ""
                result.append(JobTallyItem(label: "Verified", value: "\(verifiedBytes.formattedBytes)\(method)", help: "Bytes checked against the drive's SHA-256 after copying"))
            }
            let already = job.matchedExisting + job.alreadyVerified
            if already > 0 {
                result.append(JobTallyItem(label: "Already there", value: "\(already.formatted()) file\(already == 1 ? "" : "s")", help: "Files the NAS already held — checked, not copied"))
            }
        } else if let job, JobHistoryItemOutcome.removes(job.kind), job.matchedExisting + job.failed > 0 {
            let removedBytes = items.filter { $0.outcome == .matched }.reduce(Int64(0)) { $0 + $1.byteCount }
            do {
                var value = "\(job.matchedExisting.formatted()) file\(job.matchedExisting == 1 ? "" : "s")"
                if removedBytes > 0 { value += " · \(removedBytes.formattedBytes)" }
                result.append(JobTallyItem(label: "Removed", value: value, help: "Files whose every copy matched, then removed"))
            }
            if job.failed > 0 {
                result.append(JobTallyItem(
                    label: "Skipped", value: "\(job.failed.formatted()) kept", tone: .warning,
                    help: "Files that did not pass a check; they were left where they were"
                ))
            }
            return result
        } else if let job {
            let files = job.totalFiles > 0 ? job.totalFiles : (live?.processedFiles ?? 0)
            if files > 0 {
                let done = live.map(\.processedFiles) ?? files
                result.append(JobTallyItem(label: "Files", value: live?.state == .running ? "\(done.formatted()) of \(files.formatted())" : files.formatted()))
            }
            if job.bytesDone > 0 {
                result.append(JobTallyItem(label: "Data", value: job.bytesDone.formattedBytes, help: "\(job.bytesDone.formatted()) bytes"))
            }
        } else if let live {
            if live.totalFiles > 0 || live.processedFiles > 0 {
                result.append(JobTallyItem(label: "Files", value: live.totalFiles > 0 ? "\(live.processedFiles.formatted()) of \(live.totalFiles.formatted())" : live.processedFiles.formatted()))
            }
            if live.processedBytes > 0 {
                result.append(JobTallyItem(label: "Data", value: live.processedBytes.formattedBytes))
            }
        }
        if let job {
            var problems: [String] = []
            if job.conflicts > 0 { problems.append("\(job.conflicts.formatted()) conflict\(job.conflicts == 1 ? "" : "s")") }
            if job.failed > 0 { problems.append("\(job.failed.formatted()) failed") }
            if !problems.isEmpty {
                result.append(JobTallyItem(
                    label: "Issues", value: problems.joined(separator: " · "), tone: job.failed > 0 ? .failure : .warning,
                    help: "Conflicts are left untouched; the Files list's Issues filter shows each one"
                ))
            }
        }
        return result
    }

    /// "4 transfers in parallel · SSH verify · NAS SHA-256 (…) · 2 NAS batches"
    static func configuration(job: JobHistoryJob?, live: JobSnapshot?) -> String {
        var parts: [String] = []
        if let configuration = job?.configuration ?? live?.telemetry?.configuration { parts.append(configuration) }
        if let summary = job?.summary, let timings = summary.timings {
            if summary.verifyMethod == "ssh", !timings.verification.isEmpty { parts.append(timings.verification) }
            if timings.remoteBatches > 0 { parts.append("\(timings.remoteBatches) NAS batch\(timings.remoteBatches == 1 ? "" : "es")") }
            if timings.remoteFallbacks > 0 { parts.append("\(timings.remoteFallbacks) fell back to SMB") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Time

    /// "Today 12:31 – 12:33" or "Started 12:31".
    static func when(start: Date, end: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = JobsList.dayTitle(calendar.startOfDay(for: start), now: now, calendar: calendar)
        let startTime = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return "Started \(day == "Today" ? "" : "\(day) ")\(startTime)" }
        return "\(day) \(startTime) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Graph

    /// The sentence that stands in for the chart when a chart would say
    /// nothing.
    static func graphSummary(_ graph: JobSpeedGraph, kind: String, isLive: Bool) -> String? {
        guard let summary = graph.summary else { return nil }
        let unit = filesUnit(kind)
        switch summary {
        case .nothingMoved(let files, let rate):
            let rateText = rate.map { " at \(JobThroughputFormat.itemRate($0)) \(unit)" } ?? ""
            if isLive {
                return files > 0
                    ? "Checking — \(files.formatted()) files so far\(rateText), nothing copied yet."
                    : "Checking what needs copying…"
            }
            let place = kind == JobAction.syncBuffer.rawValue ? "on the NAS" : "there"
            return files > 0
                ? "Nothing to copy — every file was already \(place). Checked \(files.formatted()) files in \(JobActivityDetail.durationText(graph.duration))\(rateText)."
                : "Nothing to copy."
        case .tooShort(let duration):
            if isLive { return "Measuring speed…" }
            let average = graph.average.flatMap { value in
                graph.metric.map { $0 == .megabytesPerSecond ? "\(JobThroughputFormat.rate(value)) MB/s" : "\(JobThroughputFormat.itemRate(value)) \(unit)" }
            }
            return "Done in \(JobActivityDetail.durationText(duration)) — too quick to chart" + (average.map { ". Averaged \($0)." } ?? ".")
        case .noSamples:
            return isLive ? "Waiting for the job to report progress…" : "No speed was recorded for this job."
        }
    }

    /// The hover card's rows at `t`: the plotted rate and the other unit,
    /// files done, each phase's own speed, and the transfers busy. GPU load
    /// only for the jobs that use the GPU.
    static func hoverLines(sample: JobHistorySample?, t: Double, graph: JobSpeedGraph, kind: String) -> (title: String, rows: [(label: String, value: String)]) {
        let phases = graph.phases(at: t).map(\.label).joined(separator: " + ")
        let title = JobActivityDetail.durationText(t) + (phases.isEmpty ? "" : " · \(phases)")
        guard let sample else { return (title, [("", "No samples — nothing reported")]) }
        var rows: [(String, String)] = []
        let unit = filesUnit(kind)
        if graph.metric == .filesPerSecond {
            rows.append(("Speed", sample.filesPerSecond.map { "\(JobThroughputFormat.itemRate($0)) \(unit)" } ?? JobThroughputFormat.placeholder))
            if let bytes = sample.combined, bytes > 0 { rows.append(("Read", "\(JobThroughputFormat.rate(bytes)) MB/s")) }
        } else {
            rows.append(("Speed", sample.combined.map { "\(JobThroughputFormat.rate($0)) MB/s" } ?? JobThroughputFormat.placeholder))
            if let files = sample.filesPerSecond, files > 0 { rows.append(("Files", "\(JobThroughputFormat.itemRate(files)) \(unit)")) }
        }
        rows.append(("Done", "\(sample.doneFiles.formatted()) files" + (sample.doneBytes > 0 ? " · \(sample.doneBytes.formattedBytes)" : "")))
        let phaseRates: [(String, Double?)] = [
            ("Copy", sample.copy), ("Verify", sample.verify), ("Verify on NAS", sample.remoteVerify), ("Hash", sample.hash),
        ]
        for (label, rate) in phaseRates {
            if let rate { rows.append((label, "\(JobThroughputFormat.rate(rate)) MB/s")) }
        }
        if sample.activeTransfers > 0 {
            rows.append(("Transfers", "\(sample.activeTransfers) busy"))
        }
        if kind == JobAction.faceScan.rawValue, let gpu = sample.gpu {
            rows.append(("GPU", "\(Int((gpu * 100).rounded()))%"))
        }
        return (title, rows)
    }
}

/// How a job's ending is shown: its badge, symbol and tone. Presentation
/// only — the recorded outcome is unchanged.
struct JobOutcomeDisplay: Equatable {
    enum Tone: Equatable {
        case running
        case success
        case warning
        case failure
        case neutral
    }

    var label: String
    var symbol: String
    var tone: Tone
}

extension JobDetailFacts {
    /// A Sync to NAS whose only problem is files the NAS already holds in
    /// another version. Sync leaves those untouched and reports failure so
    /// the job is not mistaken for a clean run, but every file it did copy
    /// verified: the window shows it as done, with conflicts, not red.
    static func endedWithOnlyConflicts(_ job: JobHistoryJob) -> Bool {
        let summary = job.summary
        let note = summary?.note?.lowercased() ?? ""
        return job.outcome == .failed
            && job.conflicts > 0
            && job.failed == 0
            && (summary?.notAttempted ?? 0) == 0
            && (summary?.hashMismatches ?? 0) == 0
            && summary?.stoppedReason == nil
            && !note.contains("unreadable")
    }

    static func outcomeDisplay(_ outcome: JobHistoryOutcome, job: JobHistoryJob?) -> JobOutcomeDisplay {
        if let job, JobHistoryItemOutcome.removes(job.kind), outcome == .succeeded, job.failed > 0 {
            return JobOutcomeDisplay(label: "Done · \(job.failed.formatted()) skipped", symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        if let job, endedWithOnlyConflicts(job) {
            return JobOutcomeDisplay(
                label: "Done · \(job.conflicts.formatted()) conflict\(job.conflicts == 1 ? "" : "s")",
                symbol: "exclamationmark.triangle.fill",
                tone: .warning
            )
        }
        return switch outcome {
        case .running: JobOutcomeDisplay(label: "Running", symbol: outcome.symbol, tone: .running)
        case .succeeded: JobOutcomeDisplay(label: "Done", symbol: outcome.symbol, tone: .success)
        case .failed: JobOutcomeDisplay(label: "Failed", symbol: outcome.symbol, tone: .failure)
        case .cancelled: JobOutcomeDisplay(label: "Cancelled", symbol: outcome.symbol, tone: .neutral)
        case .interrupted: JobOutcomeDisplay(label: "Interrupted", symbol: outcome.symbol, tone: .warning)
        }
    }

    // MARK: Issues

    /// A job's closing note cut into what the issue section shows: one
    /// clause per line, plain plurals, and the report path pulled out for a
    /// Reveal button instead of printed inline.
    static func noteParts(_ note: String) -> (clauses: [String], reportPath: String?) {
        var text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var reportPath: String?
        if let range = text.range(of: " Details: ") {
            let path = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            reportPath = path.hasSuffix(".") && !path.hasSuffix(".json") ? String(path.dropLast()) : path
            text = String(text[..<range.lowerBound])
        }
        // "Sync to NAS for all events: …" — the job's title already says it.
        if let colon = text.range(of: ": "), text.distance(from: text.startIndex, to: colon.lowerBound) < 80,
           !text[..<colon.lowerBound].contains(".") {
            text = String(text[colon.upperBound...])
        }
        var clauses: [String] = []
        var current = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            switch character {
            case "(": depth += 1
            case ")": depth = max(depth - 1, 0)
            default: break
            }
            let endsClause = depth == 0 && (
                (character == "," && next < text.endIndex && text[next] == " ")
                    || (character == "." && (next == text.endIndex || text[next] == " "))
            )
            if endsClause {
                clauses.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = next
        }
        clauses.append(current)
        let tidy = clauses
            .map { plural($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (tidy, reportPath)
    }

    /// "1 conflict(s)" → "1 conflict", "3 folder(s)" → "3 folders".
    static func plural(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(\d[\d,]*) ([A-Za-z-]+)\(s\)"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text),
                  let number = Range(match.range(at: 1), in: text),
                  let word = Range(match.range(at: 2), in: text) else { continue }
            let one = text[number] == "1"
            result.replaceSubrange(whole, with: "\(text[number]) \(text[word])\(one ? "" : "s")")
        }
        return result
    }

    /// The issue section's one-line answer to "why did it end this way?".
    static func issueHeadline(_ job: JobHistoryJob) -> String {
        if JobHistoryItemOutcome.removes(job.kind), job.failed > 0, job.summary?.stoppedReason == nil {
            return "\(job.failed.formatted()) file\(job.failed == 1 ? "" : "s") skipped and kept — not every check passed, so nothing was removed for \(job.failed == 1 ? "it" : "them")"
        }
        if endedWithOnlyConflicts(job) {
            return "Finished — \(job.conflicts.formatted()) file\(job.conflicts == 1 ? "" : "s") left untouched because the NAS holds a different version"
        }
        switch job.outcome {
        case .failed:
            if let stopped = job.summary?.stoppedReason { return "Stopped: \(stopped)" }
            if job.failed > 0 { return "Finished with \(job.failed.formatted()) file\(job.failed == 1 ? "" : "s") failed" }
            return "Failed"
        case .interrupted: return "Interrupted — the app quit or crashed while it ran; verified files are skipped next time"
        case .cancelled: return "Cancelled before it finished"
        case .running, .succeeded: return "Finished with notes"
        }
    }

    /// What a file's problem means and what the owner can do about it.
    static func advice(for item: JobHistoryItem, kind: String = "") -> String {
        if JobHistoryItemOutcome.removes(kind) {
            return item.outcome == .failed || item.outcome == .conflict
                ? "Left where it was. Sync it again (or bring its copies back), then run the job again."
                : ""
        }
        return switch item.outcome {
        case .conflict:
            "The NAS already has a different file at this path. Neither copy was changed; keep the one you want and sync again."
        case .failed:
            "Not copied. Sync again — files already verified are skipped."
        default:
            ""
        }
    }
}
