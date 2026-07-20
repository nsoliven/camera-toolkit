import XCTest
@testable import CameraToolkitApp

final class TransferQueueTests: XCTestCase {
    func testRunningQueueExplainsStartupAndSequentialDependencies() {
        let first = TransferQueueItem(relativePath: "DCIM/first.ARW", size: 100)
        let second = TransferQueueItem(relativePath: "DCIM/second.ARW", size: 200)
        let third = TransferQueueItem(relativePath: "DCIM/third.ARW", size: 300)
        let queue = TransferQueueSnapshot(
            sourcePath: "/Volumes/Camera",
            destinationPath: "/Volumes/Buffer/Card Copy",
            items: [first, second, third],
            totalBytes: 600
        )

        XCTAssertEqual(queue.statusText(for: first), TransferQueueItemStatusText(label: "Starting", detail: "opening drives"))
        XCTAssertEqual(queue.statusText(for: second), TransferQueueItemStatusText(label: "Waiting", detail: "for file 1"))
        XCTAssertEqual(queue.statusText(for: third), TransferQueueItemStatusText(label: "Waiting", detail: "for file 2"))
    }

    func testSidebarSummaryShowsActiveFileAndProgress() {
        let first = TransferQueueItem(relativePath: "DCIM/first.OSV", size: 100, copiedBytes: 100, state: .verified)
        let second = TransferQueueItem(relativePath: "DCIM/second.OSV", size: 200, copiedBytes: 50, state: .copying)
        let queue = TransferQueueSnapshot(
            sourcePath: "/Volumes/Camera",
            destinationPath: "/Volumes/Buffer",
            items: [first, second],
            progress: 0.25,
            totalBytes: 300
        )

        XCTAssertEqual(
            queue.sidebarSummary,
            TransferQueueSidebarSummary(detail: "Copying file 2 of 2", badge: "25%")
        )
    }

    func testSidebarSummaryKeepsCompletedTransferVisible() {
        let item = TransferQueueItem(relativePath: "DCIM/first.OSV", size: 100, copiedBytes: 100, state: .verified)
        let queue = TransferQueueSnapshot(
            state: .completed,
            sourcePath: "/Volumes/Camera",
            destinationPath: "/Volumes/Buffer",
            items: [item],
            progress: 1,
            totalBytes: 100
        )

        XCTAssertEqual(
            queue.sidebarSummary,
            TransferQueueSidebarSummary(detail: "1 file verified", badge: "Done")
        )
    }

    func testStoppedQueueDoesNotClaimUntouchedFilesAreStillWaiting() {
        let untouched = TransferQueueItem(relativePath: "DCIM/later.ARW", size: 300)
        let queue = TransferQueueSnapshot(
            state: .failed,
            sourcePath: "/Volumes/Camera",
            destinationPath: "/Volumes/Buffer/Card Copy",
            items: [untouched],
            totalBytes: 300
        )

        XCTAssertEqual(queue.statusText(for: untouched), TransferQueueItemStatusText(label: "Not started", detail: "transfer stopped"))
    }

    func testNextWaitingFileExplainsThatItIsOpeningAfterPriorCopyCompletes() {
        let copied = TransferQueueItem(relativePath: "DCIM/first.ARW", size: 100, copiedBytes: 100, state: .copied)
        let next = TransferQueueItem(relativePath: "DCIM/second.ARW", size: 200)
        let later = TransferQueueItem(relativePath: "DCIM/third.ARW", size: 300)
        let queue = TransferQueueSnapshot(
            sourcePath: "/Volumes/Camera",
            destinationPath: "/Volumes/Buffer/Card Copy",
            items: [copied, next, later],
            totalBytes: 600,
            phase: "Copying"
        )

        XCTAssertEqual(queue.statusText(for: next), TransferQueueItemStatusText(label: "Starting", detail: "opening next file"))
        XCTAssertEqual(queue.statusText(for: later), TransferQueueItemStatusText(label: "Waiting", detail: "for file 2"))
    }
}
