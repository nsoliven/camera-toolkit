import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Clear from Card's wording for its checks: the sheet's three copies, the
/// running job's step and counts, and the finished job's per-copy results —
/// with the NAS reachable, unreachable, and some files skipped.
final class CardClearWordingTests: XCTestCase {
    private func request(nasReachable: Bool, driveName: String? = "Buffer", waiting: Int = 0) -> CardClearRequest {
        CardClearRequest(
            locationID: UUID(),
            locationName: "Card A",
            itemIDs: ["a"],
            fileCount: 165,
            byteCount: 4_000_000,
            events: [.init(name: "Beach Day", fileCount: 165, byteCount: 4_000_000)],
            waitingForNASFiles: waiting,
            driveName: driveName,
            nasReachable: nasReachable
        )
    }

    // MARK: Sheet

    func testSheetShowsTheDriveNASAndCardChecksInCheckOrder() {
        let lines = CardClearWording.sheetChecks(request(nasReachable: true))
        XCTAssertEqual(lines.map(\.systemImage), ["externaldrive", "server.rack", "sdcard"])
        XCTAssertEqual(lines.map(\.title), ["Buffer", "NAS", "Card A"])
        XCTAssertEqual(lines.map(\.detail), [
            "Re-read, must match the verified hash",
            "Re-read, must match the drive copy",
            "Must match the drive copy before it's deleted",
        ])
        XCTAssertFalse(lines.contains { $0.isWarning })
        XCTAssertEqual(CardClearWording.sheetRule(request(nasReachable: true)), "Each file is deleted only when it is safe on both Buffer and the NAS.")
    }

    func testSheetSaysTheRecordedHashStandsInWhenTheNASIsUnreachable() {
        let lines = CardClearWording.sheetChecks(request(nasReachable: false, driveName: nil))
        XCTAssertEqual(lines[0].title, "Drive")
        XCTAssertEqual(lines[1].detail, "Using the hash recorded at sync — NAS not reachable")
        XCTAssertTrue(lines[1].isWarning)
        XCTAssertFalse(lines[0].isWarning || lines[2].isWarning)
        XCTAssertEqual(CardClearWording.sheetRule(request(nasReachable: false, driveName: nil)), "Each file is deleted only when it is safe on both the drive and the NAS.")
    }

    // MARK: Running job

    private func update(step: String, checked: Int, cleared: Int = 0, skipped: Int = 0, total: Int = 165) -> FileOperationProgress {
        FileOperationProgress(
            phase: step == CardClearService.deletingStep ? CardClearService.removePhase : CardClearService.verifyPhase,
            currentPath: "DSC00001.ARW",
            processedFiles: cleared + skipped,
            totalFiles: total,
            telemetry: JobTelemetry(step: step, counters: [
                JobCounter(label: CardClearService.checkedCounter, value: checked),
                JobCounter(label: "Cleared", value: cleared),
                JobCounter(label: "Skipped", value: skipped),
            ])
        )
    }

    func testRunningNoteNamesTheCheckAndTheCounts() {
        XCTAssertEqual(
            CardClearWording.runningNote(update(step: CardClearService.checkingNASStep, checked: 40), driveName: "Buffer", nasReachable: true),
            "Clear from Card: Checking NAS copy · checked 40/165 on Buffer and the NAS"
        )
        XCTAssertEqual(
            CardClearWording.runningNote(update(step: CardClearService.checkingDriveStep, checked: 12, skipped: 2), driveName: "Buffer", nasReachable: true),
            "Clear from Card: Checking drive copy · checked 12/165 on Buffer and the NAS · 2 skipped"
        )
        XCTAssertEqual(
            CardClearWording.runningNote(update(step: CardClearService.deletingStep, checked: 165, cleared: 38, skipped: 2), driveName: "Buffer", nasReachable: true),
            "Clear from Card: Deleting from card · checked 165/165 on Buffer and the NAS · 38 cleared · 2 skipped"
        )
        // Deleting with nothing cleared yet still says so.
        XCTAssertTrue(
            CardClearWording.runningNote(update(step: CardClearService.deletingStep, checked: 165), driveName: nil, nasReachable: true)
                .hasSuffix("on the drive and the NAS · 0 cleared")
        )
    }

    func testRunningNoteSaysTheRecordedHashesWhenTheNASIsUnreachable() {
        XCTAssertEqual(
            CardClearWording.runningNote(update(step: CardClearService.checkingCardStep, checked: 7), driveName: "Buffer", nasReachable: false),
            "Clear from Card: Checking card file · checked 7/165 on Buffer and the recorded NAS hashes"
        )
    }

    // MARK: Finished job

    func testChecksLineWithEveryCopyMatched() {
        let checks = CardClearChecks(checked: 165, driveMatched: 165, nasMatched: 165, nasReread: true, cardMatched: 165, cleared: 165, driveName: "Buffer")
        XCTAssertEqual(CardClearWording.checksLine(checks), "165 matched on Buffer ✓ · 165 matched on the NAS ✓ · 165 cleared")
        let lines = CardClearWording.finishedChecks(checks)
        XCTAssertEqual(lines.map(\.detail), ["165 matched ✓", "165 matched ✓", "165 cleared"])
        XCTAssertFalse(lines.contains { $0.isWarning })
    }

    func testChecksLineWithSomeSkipped() {
        let checks = CardClearChecks(checked: 165, driveMatched: 164, nasMatched: 163, nasReread: true, cardMatched: 162, cleared: 162, skipped: 3, driveName: "Buffer")
        XCTAssertEqual(CardClearWording.checksLine(checks), "164/165 matched on Buffer · 163/165 matched on the NAS · 162 cleared")
        let lines = CardClearWording.finishedChecks(checks)
        XCTAssertEqual(lines.map(\.detail), ["164 of 165 matched", "163 of 165 matched", "162 cleared · 3 stayed"])
        XCTAssertEqual(lines.map(\.isWarning), [true, true, true])
    }

    func testChecksLineWhenTheNASWasUnreachable() {
        let checks = CardClearChecks(checked: 10, driveMatched: 10, nasMatched: 0, nasReread: false, cardMatched: 10, cleared: 10)
        XCTAssertEqual(CardClearWording.checksLine(checks), "10 matched on the drive ✓ · NAS not reachable — recorded hashes used · 10 cleared")
        let nas = CardClearWording.finishedChecks(checks)[1]
        XCTAssertEqual(nas.detail, "Not reachable — recorded hashes used")
        XCTAssertTrue(nas.isWarning)
    }

    func testNothingCheckedHasNoChecksLine() {
        XCTAssertNil(CardClearWording.checksLine(CardClearChecks()))
        XCTAssertTrue(CardClearWording.finishedChecks(CardClearChecks()).isEmpty)
    }

    func testSummaryStatesPerCopyResultsAndKeepsSkipReasons() {
        var report = CardClearReport()
        report.cleared = ["/Volumes/Card/DCIM/DSC00001.ARW", "/Volumes/Card/DCIM/DSC00002.ARW"]
        report.clearedBytes = 4_096
        report.skipped = ["/Volumes/Card/DCIM/DSC00003.ARW": "DSC00003.ARW: The NAS copy differs from the drive copy."]
        report.checks = CardClearChecks(checked: 3, driveMatched: 3, nasMatched: 2, nasReread: true, cardMatched: 2, cleared: 2, skipped: 1, driveName: "Buffer")
        let line = CardClearWording.summary(CardClearOutcome(report: report, noLongerEligible: 0), locationName: "Card A")
        XCTAssertTrue(line.hasPrefix("Cleared 2 files"), line)
        XCTAssertTrue(line.contains("3 matched on Buffer ✓ · 2/3 matched on the NAS · 2 cleared."), line)
        XCTAssertTrue(line.contains("1 stayed on the card: 1 — DSC00003.ARW: The NAS copy differs from the drive copy."), line)
        XCTAssertFalse(line.contains("not reachable"), line)
    }

    func testSummarySaysPlainlyWhenRecordedHashesWereUsed() {
        var report = CardClearReport()
        report.cleared = ["/Volumes/Card/DCIM/DSC00001.ARW"]
        report.usedRecordedNASHashes = true
        report.checks = CardClearChecks(checked: 1, driveMatched: 1, nasReread: false, cardMatched: 1, cleared: 1, driveName: "Buffer")
        let line = CardClearWording.summary(CardClearOutcome(report: report, noLongerEligible: 0), locationName: "Card A")
        XCTAssertTrue(line.contains("1 matched on Buffer ✓ · NAS not reachable — recorded hashes used · 1 cleared."), line)
        XCTAssertTrue(line.contains("The NAS was not reachable, so the hashes Sync to NAS recorded were used"), line)
    }

    func testFinishedChecksSurviveTheJobHistoryRoundTrip() throws {
        let checks = CardClearChecks(checked: 5, driveMatched: 5, nasMatched: 4, nasReread: true, cardMatched: 4, cleared: 4, skipped: 1, driveName: "Buffer")
        let summary = JobHistorySummary(note: "Cleared 4 files.", cardClearChecks: checks)
        let decoded = try JSONDecoder().decode(JobHistorySummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.cardClearChecks, checks)
        // Rows from before this field still decode.
        let old = try JSONDecoder().decode(JobHistorySummary.self, from: Data(#"{"phases":[],"note":"x"}"#.utf8))
        XCTAssertNil(old.cardClearChecks)
    }
}
