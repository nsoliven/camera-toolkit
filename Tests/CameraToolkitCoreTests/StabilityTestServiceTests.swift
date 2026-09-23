import CameraToolkitCore
import Foundation
import XCTest

final class USBPortHealthParserTests: XCTestCase {
    /// The shape an `AppleUSB30XHCIARMPort` publishes — the bad-cable run
    /// pushed a port to 415 connects with 407 enumeration/address failures.
    func testPortCountersParseThePublishedDictionary() {
        let properties: [String: Any] = [
            "port-statistics": [
                "kPortStatConnectCount": NSNumber(value: 415),
                "kPortStatEnumerationFailureCount": NSNumber(value: 407),
                "kPortStatAddressFailureCount": NSNumber(value: 407),
                "kPortStatOverCurrentCount": NSNumber(value: 0),
                "kPortStatPowerStateTime": NSNumber(value: 123_456),
                "kPortStatEOF2ViolationCount": NSNumber(value: 3),
                "unrelated": "not a counter"
            ],
            "link-error-count": NSNumber(value: 12),
            "IOClass": "AppleUSB30XHCIARMPort"
        ]

        let counters = USBPortHealthParser.portCounters(properties)

        XCTAssertEqual(counters["kPortStatConnectCount"], 415)
        XCTAssertEqual(counters["kPortStatEnumerationFailureCount"], 407)
        XCTAssertEqual(counters["kPortStatAddressFailureCount"], 407)
        XCTAssertEqual(counters["kPortStatOverCurrentCount"], 0)
        XCTAssertEqual(counters["kPortStatPowerStateTime"], 123_456)
        XCTAssertEqual(counters["kPortStatEOF2ViolationCount"], 3)
        XCTAssertEqual(counters["link-error-count"], 12)
        XCTAssertNil(counters["unrelated"])
        XCTAssertNil(counters["IOClass"])
    }

    func testMissingKeysProduceEmptyCounters() {
        XCTAssertEqual(USBPortHealthParser.portCounters([:]), [:])
        XCTAssertEqual(USBPortHealthParser.portCounters(["port-statistics": "not a dictionary"]), [:])
        XCTAssertEqual(USBPortHealthParser.portCounters(["port-statistics": [:]]), [:])
    }

    func testDeltasReportOnlyRises() {
        let start: [String: Int64] = ["kPortStatConnectCount": 400, "link-error-count": 5]
        let end: [String: Int64] = [
            "kPortStatConnectCount": 415,
            "kPortStatEnumerationFailureCount": 407, // absent at baseline counts as new
            "link-error-count": 5
        ]

        let delta = USBPortHealthParser.delta(from: start, to: end)

        XCTAssertEqual(delta["kPortStatConnectCount"], 15)
        XCTAssertEqual(delta["kPortStatEnumerationFailureCount"], 407)
        XCTAssertNil(delta["link-error-count"], "unchanged counters are not a delta")
    }

    func testDeltaClampsACounterResetToZero() {
        let delta = USBPortHealthParser.delta(
            from: ["kPortStatConnectCount": 400],
            to: ["kPortStatConnectCount": 3]
        )
        XCTAssertNil(delta["kPortStatConnectCount"])
    }

    func testDeviceIdentityReadsTheBridgeProperties() {
        let identity = USBPortHealthParser.deviceIdentity([
            "idVendor": NSNumber(value: 0x0BDA),
            "idProduct": NSNumber(value: 0x9210),
            "bcdDevice": NSNumber(value: 0x2001),
            "kUSBSerialNumberString": "012345678930",
            "USB Vendor Name": "Realtek",
            "USB Product Name": "RTL9210",
            "UsbLinkSpeed": NSNumber(value: 10_000_000_000),
            "UsbPowerSinkAllocation": NSNumber(value: 250)
        ])

        XCTAssertEqual(identity.vendorID, 0x0BDA)
        XCTAssertEqual(identity.productID, 0x9210)
        XCTAssertEqual(identity.deviceVersionBCD, 0x2001)
        XCTAssertEqual(identity.serialNumber, "012345678930")
        XCTAssertEqual(identity.vendorName, "Realtek")
        XCTAssertEqual(identity.linkBitsPerSecond, 10_000_000_000)
        XCTAssertEqual(identity.powerSinkAllocation, 250)
    }

    func testDeviceIdentityToleratesMissingKeys() {
        let identity = USBPortHealthParser.deviceIdentity([:])
        XCTAssertNil(identity.vendorID)
        XCTAssertNil(identity.serialNumber)
        XCTAssertNil(identity.linkBitsPerSecond)
    }

    func testBSDDiskNameParsing() {
        XCTAssertEqual(USBPortHealthProbe.bsdDiskName(mountSource: "/dev/disk8s2"), "disk8s2")
        XCTAssertNil(USBPortHealthProbe.bsdDiskName(mountSource: "//server/share"))
        XCTAssertNil(USBPortHealthProbe.bsdDiskName(mountSource: ""))
        XCTAssertNil(USBPortHealthProbe.bsdDiskName(mountSource: "/dev/"))
    }

    func testPortLabelFromDeviceLocation() {
        XCTAssertEqual(USBPortHealthParser.portLabel(forLocation: "02100000"), "USB-C port 2")
        XCTAssertEqual(USBPortHealthParser.portLabel(forLocation: "01200000"), "USB-C port 1")
        XCTAssertNil(USBPortHealthParser.portLabel(forLocation: nil))
        XCTAssertNil(USBPortHealthParser.portLabel(forLocation: "garbage"))
        XCTAssertNil(USBPortHealthParser.portLabel(forLocation: "00000000"))
    }
}

final class StabilityProfileTests: XCTestCase {
    func testQuickSchedulesWriteReadBurstInTwoMinutes() {
        let phases = StabilityProfile.quick.phases(canWrite: true)
        XCTAssertEqual(phases.map(\.kind), [.sustainedWrite, .sustainedRead, .mixedBurst])
        XCTAssertEqual(phases.reduce(0) { $0 + $1.seconds }, 120, accuracy: 0.001)
    }

    func testStandardSchedulesTheFullCycleInTenMinutes() {
        let phases = StabilityProfile.standard.phases(canWrite: true)
        XCTAssertEqual(
            phases.map(\.kind),
            [.sustainedWrite, .sustainedRead, .mixedBurst, .idleWatch]
        )
        XCTAssertEqual(phases.reduce(0) { $0 + $1.seconds }, 600, accuracy: 0.001)
    }

    func testSoakRepeatsTheStandardCycleThreeTimes() {
        let phases = StabilityProfile.soak.phases(canWrite: true)
        XCTAssertEqual(phases.count, 12)
        XCTAssertEqual(phases.reduce(0) { $0 + $1.seconds }, 1800, accuracy: 0.001)
    }

    func testReadOnlyDrivesGetReadAndBurstOnly() {
        for profile in StabilityProfile.allCases {
            let phases = profile.phases(canWrite: false)
            XCTAssertFalse(phases.isEmpty)
            XCTAssertTrue(phases.allSatisfy { $0.kind == .sustainedRead || $0.kind == .mixedBurst })
        }
    }
}

final class StabilityVerdictTests: XCTestCase {
    private func phase(
        _ kind: StabilityPhaseKind,
        typical: Double = 750_000_000,
        samples: Int = 12
    ) -> StabilityPhaseMetrics {
        StabilityPhaseMetrics(
            kind: kind,
            seconds: 60,
            bytesMoved: Int64(typical) * 60,
            samplesBytesPerSecond: Array(repeating: typical, count: samples),
            completed: true
        )
    }

    private func cleanSummary() -> StabilityRunSummary {
        StabilityRunSummary(
            phases: [
                phase(.sustainedWrite),
                phase(.sustainedRead),
                phase(.mixedBurst),
                phase(.idleWatch, typical: 0, samples: 0)
            ],
            finishedAllPhases: true
        )
    }

    func testCleanRunPasses() {
        let verdict = StabilityVerdict.evaluate(
            summary: cleanSummary(),
            typicalRangeMBps: 700...1_050
        )
        XCTAssertEqual(verdict.grade, .pass)
    }

    func testMountLossFails() {
        var summary = cleanSummary()
        summary.mountLost = true
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .fail)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("unmounted or disappeared") })
        XCTAssertTrue(verdict.advice.contains("cable"))
    }

    func testRisingEnumerationFailuresFailWithPlainAdvice() {
        var summary = cleanSummary()
        summary.counterDelta = [
            USBPortHealthSample.CounterKey.connectCount: 12,
            USBPortHealthSample.CounterKey.enumerationFailureCount: 12
        ]
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .fail)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("enumeration") })
        XCTAssertTrue(verdict.advice.contains("connection reset 12 times"))
        XCTAssertTrue(verdict.advice.contains("Replace the cable first"))
    }

    func testLinkErrorsAndOverCurrentFail() {
        var linkErrors = cleanSummary()
        linkErrors.counterDelta = [USBPortHealthSample.CounterKey.linkErrorCount: 2]
        XCTAssertEqual(StabilityVerdict.evaluate(summary: linkErrors).grade, .fail)

        var overCurrent = cleanSummary()
        overCurrent.counterDelta = [USBPortHealthSample.CounterKey.overCurrentCount: 1]
        XCTAssertEqual(StabilityVerdict.evaluate(summary: overCurrent).grade, .fail)
    }

    func testIOFailureFails() {
        var summary = cleanSummary()
        summary.failureMessage = "Could not write stability-test data (errno 5)"
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .fail)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("I/O failed") })
    }

    func testStallWarnsWithoutFailing() {
        var summary = cleanSummary()
        summary.stalls = [StabilityStall(phase: .sustainedWrite, seconds: 3)]
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .warning)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("No data moved") })
    }

    func testThroughputUnderHalfTheLinkTypicalWarns() {
        var summary = cleanSummary()
        summary.phases = [
            phase(.sustainedWrite, typical: 200_000_000),
            phase(.sustainedRead, typical: 200_000_000),
            phase(.mixedBurst, typical: 200_000_000)
        ]
        let verdict = StabilityVerdict.evaluate(
            summary: summary,
            typicalRangeMBps: 700...1_050
        )
        XCTAssertEqual(verdict.grade, .warning)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("under half") })
    }

    func testLargeMidRunSlowdownWarnsCarefully() {
        var slow = phase(.sustainedWrite, typical: 0, samples: 0)
        slow.samplesBytesPerSecond =
            Array(repeating: 900_000_000, count: 6)
            + Array(repeating: 200_000_000, count: 6)
        var summary = cleanSummary()
        summary.phases = [slow]
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .warning)
        let reason = verdict.reasons.first { $0.contains("Throughput fell") }
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("not a fault") ?? false)
        XCTAssertTrue(reason?.contains("cache") ?? false)
    }

    func testIncompleteRunWarns() {
        var summary = cleanSummary()
        summary.finishedAllPhases = false
        let verdict = StabilityVerdict.evaluate(summary: summary)
        XCTAssertEqual(verdict.grade, .warning)
    }
}

final class StabilityBoundedAreaTests: XCTestCase {
    func testAreaCapsAtEightGigabytes() {
        XCTAssertEqual(
            StabilityTestService.boundedAreaBytes(freeBytes: 64 * 1024 * 1024 * 1024),
            StabilityTestService.maximumTempAreaBytes
        )
    }

    func testAreaShrinksWhenFreeSpaceIsShort() {
        XCTAssertEqual(
            StabilityTestService.boundedAreaBytes(
                freeBytes: StabilityTestService.freeSpaceReserve + 512 * 1024 * 1024
            ),
            512 * 1024 * 1024
        )
    }

    func testAreaRefusesWhenItWouldBeTooSmall() {
        XCTAssertNil(
            StabilityTestService.boundedAreaBytes(
                freeBytes: StabilityTestService.freeSpaceReserve + 1
            )
        )
        XCTAssertNil(StabilityTestService.boundedAreaBytes(freeBytes: 0))
    }
}

final class StabilityTestServiceTests: XCTestCase {
    private func request(
        writeDirectory: URL? = nil,
        profile: StabilityProfile = .quick
    ) -> StabilityTestRequest {
        StabilityTestRequest(
            volumeRoot: URL(fileURLWithPath: "/Volumes/Fake", isDirectory: true),
            writeDirectory: writeDirectory,
            searchRoots: [],
            profile: profile,
            typicalRangeMBps: nil,
            cableLabel: "test cable",
            portLabel: "USB-C port 2"
        )
    }

    private func baselineSample() -> USBPortHealthSample {
        USBPortHealthSample(
            counters: [
                USBPortHealthSample.CounterKey.connectCount: 10,
                USBPortHealthSample.CounterKey.enumerationFailureCount: 0
            ],
            device: USBDeviceIdentity(
                vendorID: 0x0BDA, productID: 0x9210, serialNumber: "012345678930",
                vendorName: "Realtek", productName: "RTL9210",
                linkBitsPerSecond: 10_000_000_000
            ),
            portEntryID: 42,
            deviceLocation: "02100000"
        )
    }

    /// A clean quick run on the fake clock: the workload moves fake bytes,
    /// counters stay flat, and the record comes back a pass.
    func testCleanRunPassesAndReportsLiveState() throws {
        try withTemporaryDirectory { root in
            let clock = StabilityFakeClock()
            let workload = FakeStabilityWorkload(clock: clock)
            let probe = FakeUSBProbe(baseline: baselineSample())
            let service = StabilityTestService(
                probe: probe,
                workloadFactory: { _, _ in workload },
                uptime: { clock.now },
                isMounted: { _ in true }
            )
            let updates = UpdateBox()

            let record = try service.run(request(writeDirectory: root)) { updates.append($0) }

            XCTAssertEqual(record.grade, .pass)
            XCTAssertEqual(record.cableLabel, "test cable")
            XCTAssertEqual(record.portLabel, "USB-C port 2")
            XCTAssertEqual(record.linkBitsPerSecond, 10_000_000_000)
            XCTAssertEqual(record.enclosure?.serialNumber, "012345678930")
            XCTAssertEqual(record.phases.map(\.kind), [.sustainedWrite, .sustainedRead, .mixedBurst])
            XCTAssertTrue(record.phases.allSatisfy(\.completed))
            XCTAssertEqual(record.durationSeconds, 120, accuracy: 0.001)
            XCTAssertTrue(updates.values.contains { $0.usbCountersAvailable })
            XCTAssertTrue(updates.values.contains { $0.detectedPortLabel == "USB-C port 2" })
            XCTAssertTrue(workload.calls.contains("cleanup"))
        }
    }

    /// The bad-cable signature: enumeration failures climb mid-run. The
    /// verdict fails and names the counter, the deltas land on the record,
    /// and the failure survives in history.
    func testRisingFailureCountersFailTheRun() throws {
        let clock = StabilityFakeClock()
        let workload = FakeStabilityWorkload(clock: clock)
        let probe = FakeUSBProbe(baseline: baselineSample())
        probe.onSamplePort = { call in
            var sample = self.baselineSample()
            if call >= 3 {
                sample.counters[USBPortHealthSample.CounterKey.connectCount] = 12
                sample.counters[USBPortHealthSample.CounterKey.enumerationFailureCount] = 12
            }
            return sample
        }
        let service = StabilityTestService(
            probe: probe,
            workloadFactory: { _, _ in workload },
            uptime: { clock.now },
            isMounted: { _ in true }
        )

        let record = try service.run(request())

        XCTAssertEqual(record.grade, .fail)
        XCTAssertTrue(record.completed, "rising counters fail the grade; the run itself still finishes")
        XCTAssertEqual(record.counterDeltas[USBPortHealthSample.CounterKey.enumerationFailureCount], 12)
        XCTAssertTrue(record.reasons.contains { $0.contains("enumeration") })
    }

    /// A vanished mount ends the run plainly instead of hanging — the
    /// workload's cleanup still runs and the record says what happened.
    func testMountDropFailsTheRunAndCleansUp() throws {
        let clock = StabilityFakeClock()
        let workload = FakeStabilityWorkload(clock: clock)
        let mounted = FlagBox()
        mounted.value = true
        let service = StabilityTestService(
            probe: FakeUSBProbe(baseline: baselineSample()),
            workloadFactory: { _, _ in workload },
            uptime: { clock.now },
            isMounted: { _ in mounted.value }
        )
        workload.afterSteps = { _ in mounted.value = false }

        let record = try service.run(request())

        XCTAssertEqual(record.grade, .fail)
        XCTAssertFalse(record.completed)
        XCTAssertTrue(record.reasons.contains { $0.contains("unmounted or disappeared") })
        XCTAssertTrue(workload.calls.contains("cleanup"))
    }

    /// Internal SSDs, network shares, and Thunderbolt chains without the
    /// USB entries answer "not available" — the run still grades drops,
    /// stalls, and throughput.
    func testNonUSBVolumeReportsCountersUnavailable() throws {
        let clock = StabilityFakeClock()
        let workload = FakeStabilityWorkload(clock: clock)
        let service = StabilityTestService(
            probe: FakeUSBProbe(baseline: nil),
            workloadFactory: { _, _ in workload },
            uptime: { clock.now },
            isMounted: { _ in true }
        )
        let updates = UpdateBox()

        let record = try service.run(request()) { updates.append($0) }

        XCTAssertFalse(updates.values.isEmpty)
        XCTAssertTrue(updates.values.allSatisfy { !$0.usbCountersAvailable })
        XCTAssertEqual(record.grade, .pass)
    }

    /// Stop is instant: the supervisor abandons the run, the workload's
    /// cleanup fires, and `run` rethrows CancellationError.
    func testCancelRunsCleanupAndRethrows() async throws {
        let workload = FakeStabilityWorkload(clock: nil) // real clock
        let service = StabilityTestService(
            probe: FakeUSBProbe(baseline: baselineSample()),
            workloadFactory: { _, _ in workload },
            isMounted: { _ in true }
        )
        let started = UpdateBox()
        let req = request()
        let run = Task {
            try service.run(req) { started.append($0) }
        }
        let deadline = Date().addingTimeInterval(10)
        while workload.calls.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        run.cancel()
        let result = await run.result

        guard case .failure(let error) = result else {
            return XCTFail("A cancelled run must not produce a record")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(workload.calls.contains("cleanup"))
    }

    /// A workload parked inside a step trips the watchdog, which returns a
    /// failed record naming the stall rather than hanging — and cleanup
    /// still runs within its bound.
    func testWatchdogTurnsAParkedStepIntoAFailureRecord() throws {
        let workload = FakeStabilityWorkload(clock: nil)
        workload.parkSteps = true
        let service = StabilityTestService(
            probe: FakeUSBProbe(baseline: baselineSample()),
            workloadFactory: { _, _ in workload },
            stallTimeout: 0.4
        )

        let record = try service.run(request())
        workload.release()

        XCTAssertEqual(record.grade, .fail)
        XCTAssertTrue(record.reasons.contains { $0.contains("stopped responding") })
        XCTAssertTrue(workload.calls.contains("cleanup"))
    }

    /// A workload I/O error ends the run with a plain failure.
    func testWorkloadErrorFailsTheRun() throws {
        try withTemporaryDirectory { root in
            let clock = StabilityFakeClock()
            let workload = FakeStabilityWorkload(clock: clock)
            workload.throwOnPhase = .sustainedWrite
            let service = StabilityTestService(
                probe: FakeUSBProbe(baseline: baselineSample()),
                workloadFactory: { _, _ in workload },
                uptime: { clock.now },
                isMounted: { _ in true }
            )

            let record = try service.run(request(writeDirectory: root))

            XCTAssertEqual(record.grade, .fail)
            XCTAssertTrue(record.reasons.contains { $0.contains("I/O failed") })
            XCTAssertTrue(workload.calls.contains("cleanup"))
        }
    }

    /// A stall under the stall-warning threshold is not a warning; a slow
    /// stretch is. The fake workload idles three fake seconds mid-write.
    func testAStallBecomesAWarningNotAFailure() throws {
        let clock = StabilityFakeClock()
        let workload = FakeStabilityWorkload(clock: clock)
        workload.idleSteps = 3 // three 1-second steps that move nothing
        let service = StabilityTestService(
            probe: FakeUSBProbe(baseline: baselineSample()),
            workloadFactory: { _, _ in workload },
            uptime: { clock.now },
            isMounted: { _ in true }
        )

        let record = try service.run(request())

        XCTAssertEqual(record.grade, .warning)
        XCTAssertTrue(record.reasons.contains { $0.contains("No data moved") })
    }
}

final class FileStabilityWorkloadTests: XCTestCase {
    private func writableRequest(_ directory: URL) -> StabilityTestRequest {
        StabilityTestRequest(
            volumeRoot: directory,
            writeDirectory: directory,
            searchRoots: [directory],
            profile: .quick
        )
    }

    /// The write phase cycles through a bounded area: stepping past the
    /// cap wraps the offset instead of growing the file.
    func testWritePhaseCyclesWithinTheBoundedArea() throws {
        try withTemporaryDirectory { root in
            let areaBytes: Int64 = 24 * 1024 * 1024 // three 8 MB chunks
            let workload = FileStabilityWorkload(
                request: writableRequest(root),
                areaBytes: areaBytes
            )
            try workload.begin(phase: .sustainedWrite)
            var moved: Int64 = 0
            // More than the area — proves the offset wrapped.
            for _ in 0..<4 {
                moved += try workload.step(phase: .sustainedWrite) { false }
            }
            workload.end(phase: .sustainedWrite)

            XCTAssertEqual(moved, 32 * 1024 * 1024)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let temp = try XCTUnwrap(names.first { $0.hasPrefix(StabilityTestService.temporaryFilePrefix) })
            let size = try FileManager.default
                .attributesOfItem(atPath: root.appendingPathComponent(temp).path)[.size] as? Int64
            XCTAssertEqual(size, areaBytes, "the temp file never exceeds the bounded area")
            workload.cleanup()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    /// After a write phase, the read phase reads back the temp area —
    /// the writable path never touches existing media.
    func testReadPhaseReadsBackTheWrittenArea() throws {
        try withTemporaryDirectory { root in
            let workload = FileStabilityWorkload(
                request: writableRequest(root),
                areaBytes: 16 * 1024 * 1024
            )
            try workload.begin(phase: .sustainedWrite)
            _ = try workload.step(phase: .sustainedWrite) { false }
            workload.end(phase: .sustainedWrite)

            try workload.begin(phase: .sustainedRead)
            let read = try workload.step(phase: .sustainedRead) { false }
            workload.end(phase: .sustainedRead)

            XCTAssertGreaterThan(read, 0)
            workload.cleanup()
        }
    }

    /// A read-only drive never opens a write descriptor — the write phase
    /// refuses plainly — while reads sample the media already on it.
    func testReadOnlyDriveNeverWritesAndSamplesExistingMedia() throws {
        try withTemporaryDirectory { root in
            try writeFile(root.appendingPathComponent("clip.mov"), Data(count: 2 * 1024 * 1024))
            var request = writableRequest(root)
            request.writeDirectory = nil
            let workload = FileStabilityWorkload(request: request, areaBytes: 0)

            XCTAssertThrowsError(try workload.begin(phase: .sustainedWrite)) { error in
                XCTAssertTrue(error.localizedDescription.contains("never writes"))
            }

            try workload.begin(phase: .sustainedRead)
            var moved: Int64 = 0
            for _ in 0..<4 {
                moved += try workload.step(phase: .sustainedRead) { false }
            }
            workload.end(phase: .sustainedRead)

            XCTAssertGreaterThan(moved, 0)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: root.path),
                ["clip.mov"],
                "a read-only run leaves no files behind"
            )
            workload.cleanup()
        }
    }

    func testReadOnlyDriveWithNoMediaExplainsItself() throws {
        try withTemporaryDirectory { root in
            var request = writableRequest(root)
            request.writeDirectory = nil
            let workload = FileStabilityWorkload(request: request, areaBytes: 0)

            XCTAssertThrowsError(try workload.begin(phase: .sustainedRead)) { error in
                XCTAssertTrue(error.localizedDescription.contains("No readable media"))
            }
        }
    }

    /// The burst phase runs parallel readers plus a writer; a short real
    /// burst on a real temp folder must move bytes and stop cleanly.
    func testMixedBurstMovesBytesAndStops() throws {
        try withTemporaryDirectory { root in
            let workload = FileStabilityWorkload(
                request: writableRequest(root),
                areaBytes: 32 * 1024 * 1024
            )
            try workload.begin(phase: .sustainedWrite)
            _ = try workload.step(phase: .sustainedWrite) { false }
            workload.end(phase: .sustainedWrite)

            try workload.begin(phase: .mixedBurst)
            var moved: Int64 = 0
            let deadline = Date().addingTimeInterval(2)
            while moved == 0, Date() < deadline {
                moved += try workload.step(phase: .mixedBurst) { false }
            }
            workload.end(phase: .mixedBurst)

            XCTAssertGreaterThan(moved, 0)
            workload.cleanup()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    /// Cleanup removes the temp file and any `._` AppleDouble twin.
    func testCleanupRemovesTheTempFileAndItsTwin() throws {
        try withTemporaryDirectory { root in
            let workload = FileStabilityWorkload(
                request: writableRequest(root),
                areaBytes: 16 * 1024 * 1024
            )
            try workload.begin(phase: .sustainedWrite)
            _ = try workload.step(phase: .sustainedWrite) { false }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let temp = try XCTUnwrap(names.first { $0.hasPrefix(StabilityTestService.temporaryFilePrefix) })
            let twin = root.appendingPathComponent("._\(temp)")
            try writeFile(twin, "x")

            workload.cleanup()

            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }
}

final class StabilityHistoryStoreTests: XCTestCase {
    private func record(
        cable: String = "Anker 1 m",
        uuid: String? = "VOLUME-A",
        serial: String? = "012345678930",
        finishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> StabilityTestRecord {
        StabilityTestRecord(
            finishedAt: finishedAt,
            profile: StabilityProfile.standard.rawValue,
            cableLabel: cable,
            portLabel: "USB-C port 2",
            grade: .pass,
            headline: "Stable under load",
            reasons: ["clean"],
            advice: "fine",
            phases: [
                StabilityPhaseRecord(
                    kind: .sustainedWrite, seconds: 180, bytesMoved: 100_000_000,
                    minBytesPerSecond: 700e6, typicalBytesPerSecond: 760e6,
                    maxBytesPerSecond: 800e6, completed: true
                )
            ],
            counterDeltas: [:],
            linkBitsPerSecond: 10_000_000_000,
            enclosure: USBDeviceIdentity(
                vendorID: 0x0BDA, productID: 0x9210, serialNumber: serial,
                productName: "RTL9210"
            ),
            volumeUUID: uuid,
            durationSeconds: 600,
            completed: true
        )
    }

    func testSaveLoadAndCompare() throws {
        try withTemporaryDirectory { root in
            let store = StabilityHistoryStore(
                url: root.appendingPathComponent("stability-tests.json")
            )
            try store.append(record(cable: "Anker 1 m", uuid: "VOLUME-A"))
            try store.append(record(cable: "Cheap grey", uuid: "VOLUME-B"))

            let history = store.load()
            XCTAssertEqual(history.records.count, 2)
            XCTAssertEqual(history.knownCableLabels, ["Anker 1 m", "Cheap grey"])

            let enclosure = USBDeviceIdentity(
                vendorID: 0x0BDA, productID: 0x9210, serialNumber: "012345678930"
            )
            // Same placeholder serial on two enclosures — the volume UUID
            // keeps their histories apart.
            XCTAssertEqual(
                history.records(forVolumeUUID: "VOLUME-A", enclosure: enclosure).map(\.cableLabel),
                ["Anker 1 m"]
            )
            // No UUID at all falls back to the enclosure identity tuple.
            let legacy = history.records(forVolumeUUID: nil, enclosure: enclosure)
            XCTAssertEqual(legacy.count, 2)
        }
    }

    func testAppendCapsAndSortsLabels() throws {
        try withTemporaryDirectory { root in
            let store = StabilityHistoryStore(
                url: root.appendingPathComponent("stability-tests.json")
            )
            for index in 0..<(StabilityHistoryStore.recordLimit + 5) {
                try store.append(record(cable: "cable \(index % 3)"))
            }
            let history = store.load()
            XCTAssertEqual(history.records.count, StabilityHistoryStore.recordLimit)
            XCTAssertEqual(history.knownCableLabels, ["cable 0", "cable 1", "cable 2"])
        }
    }

    func testCorruptOrMissingFileLoadsEmpty() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("stability-tests.json")
            let store = StabilityHistoryStore(url: url)
            XCTAssertTrue(store.load().records.isEmpty)

            try writeFile(url, "{ not json")
            XCTAssertTrue(store.load().records.isEmpty)
        }
    }

    /// A finished run persists through the store so history shows it.
    func testRunRecordRoundTripsThroughTheStore() throws {
        try withTemporaryDirectory { root in
            let clock = StabilityFakeClock()
            let workload = FakeStabilityWorkload(clock: clock)
            let service = StabilityTestService(
                probe: FakeUSBProbe(baseline: nil),
                workloadFactory: { _, _ in workload },
                uptime: { clock.now },
                isMounted: { _ in true }
            )
            let record = try service.run(StabilityTestRequest(
                volumeRoot: root,
                writeDirectory: nil,
                searchRoots: [root],
                profile: .quick,
                cableLabel: "Anker 1 m",
                portLabel: "USB-C port 1"
            ))
            let store = StabilityHistoryStore(
                url: root.appendingPathComponent("stability-tests.json")
            )
            try store.append(record)

            let loaded = store.load().records
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.cableLabel, "Anker 1 m")
            XCTAssertEqual(loaded.first?.grade, record.grade)
            XCTAssertEqual(loaded.first?.phases.count, record.phases.count)
        }
    }
}

/// The launch sweep must also catch the stability prefix — including its
/// `._` twins — and nothing else.
final class StabilityStaleFileSweepTests: XCTestCase {
    func testStaleStabilityFilesAreSweptByExactPrefixOnly() throws {
        try withTemporaryDirectory { root in
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
            let prefix = StabilityTestService.temporaryFilePrefix

            let stale = try writeFile(buffer.appendingPathComponent("\(prefix)abc.tmp"), "x")
            let twin = try writeFile(buffer.appendingPathComponent("._\(prefix)abc.tmp"), "x")
            let keepers = [
                try writeFile(buffer.appendingPathComponent("\(prefix)notes.txt"), "x"),
                try writeFile(buffer.appendingPathComponent("keep.tmp"), "x"),
                try writeFile(buffer.appendingPathComponent("._DSC00001.ARW"), "x"),
            ]

            let removed = StorageBenchmarkService().removeStaleTemporaryFiles(in: [buffer])

            XCTAssertEqual(
                Set(removed.map(\.lastPathComponent)),
                Set([stale.lastPathComponent, twin.lastPathComponent])
            )
            for url in keepers {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}

// MARK: - Test doubles

/// A lock-step clock the fake workload advances — one step is one fake
/// second, so a whole profile runs instantly.
private final class StabilityFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Collects the ~1 Hz updates the service emits.
private final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StabilityTestUpdate] = []

    var values: [StabilityTestUpdate] { lock.withLock { storage } }

    func append(_ update: StabilityTestUpdate) {
        lock.withLock { storage.append(update) }
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// Scripted port reads: the first `sample(volumeRoot:)` hands back the
/// baseline, then `samplePort(entryID:)` answers `onSamplePort` each tick.
private final class FakeUSBProbe: USBPortHealthProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: USBPortHealthSample?
    private var portCalls = 0
    var onSamplePort: ((Int) -> USBPortHealthSample?)?

    init(baseline: USBPortHealthSample?) {
        self.baseline = baseline
    }

    func sample(volumeRoot: URL) -> USBPortHealthSample? {
        lock.withLock { baseline }
    }

    func samplePort(entryID: UInt64) -> USBPortHealthSample? {
        lock.lock()
        defer { lock.unlock() }
        portCalls += 1
        if let onSamplePort {
            return onSamplePort(portCalls)
        }
        return baseline
    }
}

/// The fake workload: each `step` moves a fixed byte count and advances
/// the injected clock one second — a full profile runs in a blink. Hooks
/// script drops (idle steps), failures, and parked syscalls.
private final class FakeStabilityWorkload: StabilityWorkload, @unchecked Sendable {
    private let lock = NSLock()
    private let condition = NSCondition()
    private var released = false
    private(set) var callsStorage: [String] = []
    private var stepCount = 0
    let clock: StabilityFakeClock?
    /// Steps that return 0 before bytes start moving — the stall warning.
    var idleSteps = 0
    /// Step parks until `release()` — the dead-mount shape the watchdog bounds.
    var parkSteps = false
    var throwOnPhase: StabilityPhaseKind?
    var afterSteps: ((Int) -> Void)?

    init(clock: StabilityFakeClock?) {
        self.clock = clock
    }

    var calls: [String] { lock.withLock { callsStorage } }

    private func record(_ name: String) {
        lock.withLock { callsStorage.append(name) }
    }

    func begin(phase: StabilityPhaseKind) throws {
        record("begin:\(phase.rawValue)")
        if throwOnPhase == phase {
            throw ToolkitError.commandFailed("simulated I/O failure")
        }
    }

    func step(phase: StabilityPhaseKind, shouldStop: @Sendable () -> Bool) throws -> Int64 {
        if throwOnPhase == phase {
            throw ToolkitError.commandFailed("simulated I/O failure")
        }
        if parkSteps {
            condition.lock()
            while !released {
                condition.wait()
            }
            condition.unlock()
            return 0
        }
        let step = lock.withLock { () -> Int in
            stepCount += 1
            return stepCount
        }
        clock?.advance(by: 1)
        afterSteps?(step)
        if phase.movesBytes, step > idleSteps {
            return 1_000_000
        }
        return 0
    }

    func end(phase: StabilityPhaseKind) {
        record("end:\(phase.rawValue)")
    }

    func cleanup() {
        record("cleanup")
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
