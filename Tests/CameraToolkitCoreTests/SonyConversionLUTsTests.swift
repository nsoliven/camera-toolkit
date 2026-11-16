@testable import CameraToolkitCore
import Foundation
import XCTest

/// The Sony s709 download: HTTPS only (redirects too), size capped while
/// it streams, pinned by SHA-256, and the archive's unpacked size checked
/// before anything is extracted. Served by a stub — no network.
final class SonyConversionLUTsTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (status: Int, headers: [String: String], body: Data, redirect: URL?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let answer = Self.responder?(request), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            if let redirect = answer.redirect {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        Stub.responder = nil
    }

    /// A zip holding one small `.cube`, built with ditto.
    private func makeArchive(in root: URL, cubeBytes: Int? = nil) throws -> Data {
        let pack = root.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        var text = "LUT_3D_SIZE 2\n"
        for i in 0..<8 { text += "\(i & 1) \((i >> 1) & 1) \((i >> 2) & 1)\n" }
        if let cubeBytes { text += "# " + String(repeating: "x", count: cubeBytes) + "\n" }
        try Data(text.utf8).write(to: pack.appendingPathComponent("Slog3-S-Gamut3.Cine_To_s709_V200.cube"))
        let zip = root.appendingPathComponent("archive-\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", pack.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    func testPinnedArchiveImportsAndAnyOtherFileIsRefused() async throws {
        try await withTemporaryDirectoryAsync { root in
            let archive = try makeArchive(in: root)
            Stub.responder = { _ in (200, ["Content-Type": "application/zip"], archive, nil) }
            let library = LUTLibrary(folder: root.appendingPathComponent("LUTs"))
            let url = URL(string: "https://sony.test/s709.zip")!
            let result = try await SonyConversionLUTs.download(
                from: url, expectedSHA256: LayoutMigrationHash.sha256(archive), into: library, session: session(), scratch: root
            )
            XCTAssertEqual(result.s709?.role, .conversion(.sLog3SGamut3Cine))

            do {
                _ = try await SonyConversionLUTs.download(from: url, expectedSHA256: String(repeating: "0", count: 64), into: library, session: session(), scratch: root)
                XCTFail("a file that is not the pinned archive must be refused")
            } catch {
                XCTAssertEqual(error as? SonyConversionLUTs.Failure, .checksumMismatch)
                XCTAssertTrue(error.localizedDescription.contains("Sony's LUT page"))
            }
        }
        XCTAssertEqual(SonyConversionLUTs.s709SHA256.count, 64)
        XCTAssertTrue(SonyConversionLUTs.s709SHA256.allSatisfy(\.isHexDigit))
    }

    func testARedirectAwayFromHTTPSIsRefused() async throws {
        try await withTemporaryDirectoryAsync { root in
            Stub.responder = { request in
                request.url?.scheme == "https"
                    ? (302, ["Location": "http://sony.test/plain.zip"], Data(), URL(string: "http://sony.test/plain.zip"))
                    : (200, [:], Data([0x50, 0x4B, 0x03, 0x04]), nil)
            }
            do {
                _ = try await SonyConversionLUTs.download(
                    from: URL(string: "https://sony.test/s709.zip")!, expectedSHA256: nil,
                    into: LUTLibrary(folder: root.appendingPathComponent("LUTs")), session: session(), scratch: root
                )
                XCTFail("an http redirect must stop the download")
            } catch {
                XCTAssertEqual(error as? SonyConversionLUTs.Failure, .insecureRedirect)
            }
            do {
                _ = try await SonyConversionLUTs.download(from: URL(string: "http://sony.test/s709.zip")!, into: LUTLibrary(folder: root.appendingPathComponent("LUTs")), session: session(), scratch: root)
                XCTFail("an http address is never fetched")
            } catch {
                XCTAssertEqual(error as? SonyConversionLUTs.Failure, .notHTTPS)
            }
        }
    }

    func testAnOversizedDownloadStopsWhileItStreams() async throws {
        try await withTemporaryDirectoryAsync { root in
            Stub.responder = { _ in (200, [:], Data(repeating: 0x50, count: 300_000), nil) }
            do {
                _ = try await SonyConversionLUTs.download(
                    from: URL(string: "https://sony.test/s709.zip")!, into: LUTLibrary(folder: root.appendingPathComponent("LUTs")),
                    session: session(), scratch: root, maximumBytes: 100_000
                )
                XCTFail("too big")
            } catch {
                XCTAssertEqual(error as? SonyConversionLUTs.Failure, .tooLarge)
            }
        }
    }

    func testTheUnpackedSizeIsCheckedBeforeExtracting() throws {
        try withTemporaryDirectory { root in
            let archive = try makeArchive(in: root, cubeBytes: 200_000)
            let totals = try SonyConversionLUTs.centralDirectoryTotals(archive)
            XCTAssertGreaterThanOrEqual(totals.entries, 1)
            XCTAssertGreaterThan(totals.bytes, 200_000)
            let zip = root.appendingPathComponent("big.zip")
            try archive.write(to: zip)
            let library = LUTLibrary(folder: root.appendingPathComponent("LUTs"))
            XCTAssertThrowsError(try SonyConversionLUTs.importArchive(at: zip, into: library, scratch: root, extractedLimit: 100_000)) {
                XCTAssertEqual($0 as? SonyConversionLUTs.Failure, .unpacksTooLarge)
            }
            XCTAssertTrue(library.list().isEmpty, "nothing imported")
            XCTAssertThrowsError(try SonyConversionLUTs.centralDirectoryTotals(Data("PK not really".utf8)))
        }
    }

    /// Opt-in: the real archive, downloaded by hand outside the repository,
    /// matches the pin and imports as the s709 conversion.
    ///     CT_SONY_S709_ZIP=/path/to/Slog3-S-Gamut3.Cine_To_s709_V200.zip swift test --filter SonyConversionLUTsTests
    func testTheRealArchiveMatchesThePin() throws {
        guard let path = ProcessInfo.processInfo.environment["CT_SONY_S709_ZIP"] else {
            throw XCTSkip("Set CT_SONY_S709_ZIP to check Sony's archive against the pin.")
        }
        try withTemporaryDirectory { root in
            let library = LUTLibrary(folder: root.appendingPathComponent("LUTs"))
            let result = try SonyConversionLUTs.importArchive(
                at: URL(fileURLWithPath: path), into: library, scratch: root, expectedSHA256: SonyConversionLUTs.s709SHA256
            )
            XCTAssertEqual(result.imported.count, 1)
            XCTAssertEqual(result.s709?.cubeSize, 33)
            XCTAssertEqual(result.s709?.role, .conversion(.sLog3SGamut3Cine))
        }
    }
}
