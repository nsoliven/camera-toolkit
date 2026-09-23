import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

@MainActor
final class StorageBottleneckAnalysisTests: XCTestCase {
    func testWiFiBeatsEveryOtherLinkAsTheBottleneck() {
        let card = makeTarget(id: "card", name: "LEXAR", roles: ["Camera Source"])
        let buffer = makeTarget(id: "buffer", name: "Buffer", roles: ["Buffer"], access: .readWrite)
        let nas = makeTarget(id: "nas", name: "nas_share", roles: ["Photo Library"], access: .readWrite)
        let results = [
            "card": result(read: 400e6),
            "buffer": result(read: 700e6, write: 640e6),
            "nas": result(read: 180e6, write: 190e6)
        ]
        let contexts = [
            "nas": linkContext(medium: .wifi, negotiatedMbps: 216, linkTypical: 9...18)
        ]

        let verdicts = StorageBottleneckAnalysis.verdicts(
            targets: [card, buffer, nas],
            results: results,
            contexts: contexts,
            transferQueue: nil
        )

        let archive = verdicts.first { $0.title == "Buffer → NAS" }
        XCTAssertEqual(archive?.bottleneck.cause, .wifi)
        XCTAssertTrue(archive?.headline.contains("Wi-Fi") == true)
        XCTAssertTrue(archive?.detail.contains("Ethernet") == true)

        let reading = verdicts.first { $0.title == "NAS → Mac" }
        XCTAssertEqual(reading?.bottleneck.cause, .wifi)
    }

    func testWiredNetworkIsTheBottleneckWhenDisksAreFaster() {
        let buffer = makeTarget(id: "buffer", name: "Buffer", roles: ["Buffer"], access: .readWrite)
        let nas = makeTarget(id: "nas", name: "nas_share", roles: ["Photo Library"], access: .readWrite)
        let results = [
            "buffer": result(read: 700e6, write: 640e6),
            "nas": result(read: 220e6, write: 200e6)
        ]
        let contexts = [
            "nas": linkContext(medium: .ethernet, negotiatedMbps: 1_000, linkTypical: 95...115)
        ]

        let verdicts = StorageBottleneckAnalysis.verdicts(
            targets: [buffer, nas],
            results: results,
            contexts: contexts,
            transferQueue: nil
        )

        let archive = verdicts.first { $0.title == "Buffer → NAS" }
        XCTAssertEqual(archive?.bottleneck.cause, .network)
        XCTAssertTrue(archive?.headline.contains("network") == true)
    }

    func testSlowNASUnderItsNetworkCeilingBlamesTheDisksNotTheWire() {
        let buffer = makeTarget(id: "buffer", name: "Buffer", roles: ["Buffer"], access: .readWrite)
        let nas = makeTarget(id: "nas", name: "nas_share", roles: ["Photo Library"], access: .readWrite)
        let results = [
            "buffer": result(read: 700e6, write: 640e6),
            "nas": result(read: 55e6, write: 50e6)
        ]
        let contexts = [
            "nas": linkContext(medium: .ethernet, negotiatedMbps: 1_000, linkTypical: 95...115)
        ]

        let verdicts = StorageBottleneckAnalysis.verdicts(
            targets: [buffer, nas],
            results: results,
            contexts: contexts,
            transferQueue: nil
        )

        let archive = verdicts.first { $0.title == "Buffer → NAS" }
        XCTAssertEqual(archive?.bottleneck.cause, .media)
        XCTAssertEqual(archive?.bottleneck.name, "nas_share write")
        XCTAssertTrue(archive?.headline.contains("not the wire") == true)
    }

    func testNegotiatedUSBLinkCanBeTheSlowestLink() {
        let card = makeTarget(id: "card", name: "Osmo360", roles: ["Camera Source"])
        let buffer = makeTarget(id: "buffer", name: "Buffer", roles: ["Buffer"], access: .readWrite)
        let results = [
            "card": result(read: 800e6),
            "buffer": result(read: 900e6, write: 850e6)
        ]
        let contexts = [
            "card": linkContext(
                medium: .usb,
                negotiatedMbps: 5_000,
                linkTypical: 350...500
            ),
            "buffer": linkContext(
                medium: .usb,
                negotiatedMbps: 10_000,
                linkTypical: 700...1_050
            )
        ]

        let verdicts = StorageBottleneckAnalysis.verdicts(
            targets: [card, buffer],
            results: results,
            contexts: contexts,
            transferQueue: nil
        )

        let ingest = verdicts.first { $0.title == "Card → Buffer" }
        XCTAssertEqual(ingest?.bottleneck.cause, .link)
        XCTAssertEqual(ingest?.bottleneck.name, "USB link")
        XCTAssertTrue(ingest?.detail.contains("5 Gb/s") == true)
    }

    func testUnmeasuredTargetsFallBackToTypicalFigures() {
        let card = makeTarget(id: "card", name: "LEXAR", roles: ["Camera Source"])
        let buffer = makeTarget(id: "buffer", name: "Buffer", roles: ["Buffer"], access: .readWrite)

        let verdicts = StorageBottleneckAnalysis.verdicts(
            targets: [card, buffer],
            results: [:],
            contexts: [:],
            transferQueue: nil
        )

        let ingest = verdicts.first { $0.title == "Card → Buffer" }
        XCTAssertNotNil(ingest)
        XCTAssertTrue(ingest?.links.allSatisfy { !$0.isMeasured } == true)
        XCTAssertTrue(ingest?.detail.contains("typical") == true || ingest?.detail.contains("Typical") == true)
    }

    // MARK: Fixtures

    private func makeTarget(
        id: String,
        name: String,
        roles: [String],
        access: StorageBenchmarkAccess = .readOnly
    ) -> StorageBenchmarkTarget {
        let root = URL(fileURLWithPath: "/Volumes/\(id)", isDirectory: true)
        return StorageBenchmarkTarget(
            id: id,
            name: name,
            volumeRoot: root,
            searchRoots: [root],
            writeDirectory: access == .readWrite ? root : nil,
            roleNames: roles,
            access: access,
            isAvailable: true,
            totalCapacity: nil,
            volumeInfo: nil
        )
    }

    private func result(read: Double, write: Double? = nil) -> StorageBenchmarkResult {
        StorageBenchmarkResult(
            read: StorageBenchmarkMeasurement(bytes: 1, duration: 1, bytesPerSecond: read),
            write: write.map { StorageBenchmarkMeasurement(bytes: 1, duration: 1, bytesPerSecond: $0) },
            sampledFileCount: 1
        )
    }

    private func linkContext(
        medium: StorageLinkContext.Medium,
        negotiatedMbps: Int64,
        linkTypical: ClosedRange<Double>
    ) -> StorageLinkContext {
        StorageLinkContext(
            medium: medium,
            headline: "fixture",
            detail: nil,
            detected: true,
            negotiatedBitsPerSecond: negotiatedMbps * 1_000_000,
            linkTypicalMBps: linkTypical,
            mediaTypicalReadMBps: 150...300,
            mediaTypicalWriteMBps: 150...250
        )
    }
}
