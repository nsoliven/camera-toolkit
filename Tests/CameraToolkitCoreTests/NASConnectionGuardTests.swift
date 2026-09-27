import CameraToolkitCore
import Foundation
import XCTest

final class NASConnectionGuardTests: XCTestCase {
    private func input(
        session: NASInterfaceKind? = .wifi,
        wired: Bool = true,
        inUse: Bool = false,
        automatic: Bool = true,
        share: Bool = true,
        user: Bool = false,
        limiter: NASReconnectRateLimiter.Verdict = .allowed
    ) -> NASWiFiGuard.Input {
        NASWiFiGuard.Input(
            sessionKind: session,
            hasWiredRoute: wired,
            nasInUse: inUse,
            automaticEnabled: automatic,
            hasShareAddress: share,
            userRequested: user,
            limiter: limiter
        )
    }

    // MARK: decision table

    func testNothingUnlessOnWiFiWithAWiredRoute() {
        for kind: NASInterfaceKind? in [.ethernet, .thunderbolt, .other, nil] {
            XCTAssertEqual(NASWiFiGuard.decide(input(session: kind)), .nothing, "\(String(describing: kind))")
            XCTAssertEqual(NASWiFiGuard.decide(input(session: kind, inUse: true, user: true)), .nothing)
        }
        XCTAssertEqual(NASWiFiGuard.decide(input(wired: false)), .nothing, "Wi-Fi is the only way there")
        XCTAssertEqual(NASWiFiGuard.decide(input(wired: false, user: true)), .nothing)
    }

    func testWiFiWithWiredRouteReconnectsWhenIdle() {
        XCTAssertEqual(NASWiFiGuard.decide(input()), .reconnect)
    }

    func testBusyShowsTheBannerEvenWhenAsked() {
        XCTAssertEqual(NASWiFiGuard.decide(input(inUse: true)), .banner(.nasInUse))
        XCTAssertEqual(NASWiFiGuard.decide(input(inUse: true, user: true)), .banner(.nasInUse))
    }

    func testNoShareAddressCanNeverReconnect() {
        XCTAssertEqual(NASWiFiGuard.decide(input(share: false)), .banner(.noShareAddress))
        XCTAssertEqual(NASWiFiGuard.decide(input(share: false, user: true)), .banner(.noShareAddress))
    }

    func testAutomaticOffOnlyAllowsTheUser() {
        XCTAssertEqual(NASWiFiGuard.decide(input(automatic: false)), .banner(.automaticOff))
        XCTAssertEqual(NASWiFiGuard.decide(input(automatic: false, user: true)), .reconnect)
    }

    func testLimiterVerdictsBecomeBanners() {
        XCTAssertEqual(NASWiFiGuard.decide(input(limiter: .gaveUp)), .banner(.gaveUp))
        XCTAssertEqual(NASWiFiGuard.decide(input(limiter: .tooSoon(until: Date()))), .banner(.rateLimited))
        XCTAssertEqual(NASWiFiGuard.decide(input(user: true, limiter: .gaveUp)), .reconnect, "the button always tries once more")
    }

    // MARK: rate limiting

    func testLimiterSpacesAttemptsAndGivesUpAfterTwoFailures() {
        var limiter = NASReconnectRateLimiter(minimumInterval: 120, maximumFailures: 2)
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(limiter.verdict(now: start, userRequested: false), .allowed)

        limiter.recordAttempt(at: start, userRequested: false)
        limiter.recordFailure()
        XCTAssertEqual(limiter.verdict(now: start.addingTimeInterval(30), userRequested: false), .tooSoon(until: start.addingTimeInterval(120)))
        XCTAssertEqual(limiter.verdict(now: start.addingTimeInterval(121), userRequested: false), .allowed)

        limiter.recordAttempt(at: start.addingTimeInterval(121), userRequested: false)
        limiter.recordFailure()
        XCTAssertEqual(limiter.verdict(now: start.addingTimeInterval(10_000), userRequested: false), .gaveUp, "never loops")
        XCTAssertEqual(limiter.verdict(now: start.addingTimeInterval(10_000), userRequested: true), .allowed)
    }

    func testUserAttemptAndSuccessResetFailures() {
        var limiter = NASReconnectRateLimiter(minimumInterval: 0, maximumFailures: 2)
        let now = Date()
        limiter.recordFailure()
        limiter.recordFailure()
        XCTAssertEqual(limiter.verdict(now: now, userRequested: false), .gaveUp)
        limiter.recordAttempt(at: now, userRequested: true)
        XCTAssertEqual(limiter.consecutiveFailures, 0)
        limiter.recordFailure()
        limiter.recordSuccess()
        XCTAssertEqual(limiter.consecutiveFailures, 0)
        XCTAssertEqual(limiter.verdict(now: now, userRequested: false), .allowed)
    }

    // MARK: mount outcomes

    func testMountStatusClassification() {
        XCTAssertEqual(NASMountOutcome.classify(status: 0), .mounted)
        XCTAssertEqual(NASMountOutcome.classify(status: EEXIST), .alreadyMounted)
        XCTAssertEqual(NASMountOutcome.classify(status: EHOSTUNREACH), .unreachable)
        XCTAssertEqual(NASMountOutcome.classify(status: ETIMEDOUT), .unreachable)
        XCTAssertEqual(NASMountOutcome.classify(status: ECANCELED), .cancelled)
        XCTAssertEqual(NASMountOutcome.classify(status: EAUTH), .needsUserInteraction(code: EAUTH))
        XCTAssertEqual(NASMountOutcome.classify(status: -6003), .needsUserInteraction(code: -6003))
    }

    // MARK: speed-test math and labels

    func testSpeedMath() throws {
        XCTAssertEqual(try XCTUnwrap(NASSpeedTestMath.megabytesPerSecond(bytes: 64_000_000, seconds: 0.8)), 80, accuracy: 0.0001)
        XCTAssertNil(NASSpeedTestMath.megabytesPerSecond(bytes: 64_000_000, seconds: 0))
        XCTAssertNil(NASSpeedTestMath.megabytesPerSecond(bytes: 0, seconds: 1))
        XCTAssertNil(NASSpeedTestMath.megabytesPerSecond(bytes: 1, seconds: .infinity))
        XCTAssertEqual(NASSpeedTestMath.rateLabel(75.4), "75 MB/s")
        XCTAssertEqual(NASSpeedTestMath.rateLabel(8.26), "8.3 MB/s")
        XCTAssertEqual(NASSpeedTestMath.latencyLabel(milliseconds: 3.14), "3.1 ms")
        XCTAssertEqual(NASSpeedTestMath.latencyLabel(milliseconds: 42.6), "43 ms")
        let now = Date()
        XCTAssertEqual(NASSpeedTestMath.ageLabel(since: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(NASSpeedTestMath.ageLabel(since: now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(NASSpeedTestMath.ageLabel(since: now.addingTimeInterval(-7300), now: now), "2 h ago")

        let result = NASSpeedTestResult(bytes: 67_108_864, writeSeconds: 0.894, readSeconds: 0.6, smallWriteSeconds: 0.004, smallReadSeconds: 0.002, finishedAt: now)
        XCTAssertEqual(try XCTUnwrap(result.writeMegabytesPerSecond), 75.07, accuracy: 0.01)
        XCTAssertEqual(result.smallWriteMilliseconds, 4, accuracy: 0.0001)
    }

    func testStatusTitles() {
        var status = NASConnectionStatus()
        status.phase = .offline
        XCTAssertEqual(status.title, "NAS · Offline")

        status.phase = .connected
        status.snapshot = NASConnectionSnapshot(
            mountPoint: "/Volumes/share",
            mount: .mounted(NASMountSource(host: "nas.example", share: "share")),
            sessionInterfaces: [NASNetworkInterface(bsdName: "en7", kind: .ethernet, linkSpeedMbps: 1000)]
        )
        XCTAssertEqual(status.title, "NAS · Ethernet 1 GbE")
        status.speed = NASSpeedTestResult(bytes: 75_000_000, writeSeconds: 1, readSeconds: 1, smallWriteSeconds: 0.01, smallReadSeconds: 0.01, finishedAt: Date())
        XCTAssertEqual(status.title, "NAS · Ethernet 1 GbE · 75 MB/s")
        XCTAssertTrue(status.detail(now: Date()).contains("Speed test just now"))

        status.snapshot?.sessionInterfaces = [NASNetworkInterface(bsdName: "en0", kind: .wifi, linkSpeedMbps: 866)]
        status.speed = nil
        XCTAssertEqual(status.title, "NAS · Wi-Fi ⚠︎")
        XCTAssertFalse(status.isOnSlowWiFi, "no wired route")
        status.snapshot?.wiredRoutes = [NASNetworkInterface(bsdName: "en7", kind: .ethernet)]
        XCTAssertTrue(status.isOnSlowWiFi)
    }

    // MARK: temp-file cleanup

    func testTestFileNamePatternIsExact() {
        let id = UUID()
        XCTAssertTrue(NASSpeedTester.isTestFileName(NASSpeedTester.fileName(for: id)))
        XCTAssertTrue(NASSpeedTester.isTestFileName(".CameraToolkit-nettest-\(id.uuidString)"))
        XCTAssertFalse(NASSpeedTester.isTestFileName(".CameraToolkit-nettest-\(id.uuidString.lowercased())"))
        XCTAssertFalse(NASSpeedTester.isTestFileName(".CameraToolkit-nettest-\(id.uuidString).jpg"))
        XCTAssertFalse(NASSpeedTester.isTestFileName(".CameraToolkit-nettest-"))
        XCTAssertFalse(NASSpeedTester.isTestFileName(".CameraToolkit-nettest-not-a-uuid"))
        XCTAssertFalse(NASSpeedTester.isTestFileName("CameraToolkit-nettest-\(id.uuidString)"))
        XCTAssertFalse(NASSpeedTester.isTestFileName("x.CameraToolkit-nettest-\(id.uuidString)"))
        XCTAssertFalse(NASSpeedTester.isTestFileName("IMG_0001.JPG"))
    }

    func testCleanupRemovesOnlyExactlyMatchingRegularFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let stale = NASSpeedTester.fileName()
        let staleTwo = NASSpeedTester.fileName()
        let lookalikes = [
            ".CameraToolkit-nettest-\(UUID().uuidString.lowercased())",
            ".CameraToolkit-nettest-\(UUID().uuidString).mov",
            ".CameraToolkit-nettest-keep",
            "IMG_0001.JPG",
            ".DS_Store",
        ]
        for name in [stale, staleTwo] + lookalikes {
            XCTAssertTrue(fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8)))
        }
        // A folder and a symlink with matching names are left alone.
        let folderName = NASSpeedTester.fileName()
        try fm.createDirectory(at: root.appendingPathComponent(folderName), withIntermediateDirectories: false)
        let target = root.appendingPathComponent("IMG_0001.JPG")
        let linkName = NASSpeedTester.fileName()
        try fm.createSymbolicLink(at: root.appendingPathComponent(linkName), withDestinationURL: target)
        // A matching name one level down is never reached.
        let nested = root.appendingPathComponent("2026", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedName = NASSpeedTester.fileName()
        XCTAssertTrue(fm.createFile(atPath: nested.appendingPathComponent(nestedName).path, contents: Data()))

        let removed = NASSpeedTester.removeStaleTestFiles(in: root)

        XCTAssertEqual(Set(removed), [stale, staleTwo])
        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(left, Set(lookalikes + [folderName, linkName, "2026"]))
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: nested.appendingPathComponent(nestedName).path))
    }

    func testSpeedTestMeasuresAndLeavesNothingBehind() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: keep.path, contents: Data("keep".utf8)))
        let tester = NASSpeedTester(chunkBytes: 256 * 1024, chunkCount: 4, smallFileBytes: 512)

        let result = try tester.run(root: root)

        XCTAssertEqual(result.bytes, 1024 * 1024)
        XCTAssertGreaterThan(result.writeSeconds, 0)
        XCTAssertGreaterThan(result.readSeconds, 0)
        XCTAssertGreaterThan(result.smallWriteSeconds, 0)
        XCTAssertNotNil(result.writeMegabytesPerSecond)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.txt"])
    }

    func testSpeedTestOnAMissingFolderThrowsWithoutCreatingIt() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("gone", isDirectory: true)
        XCTAssertThrowsError(try NASSpeedTester(chunkBytes: 1024, chunkCount: 1).run(root: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASConnectionGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
