import CameraToolkitCore
import Foundation
import XCTest

final class ImmichUploadTests: XCTestCase {
    func testMultipartBodyStreamsFieldsFileAndClosingBoundary() throws {
        try withTemporaryDirectory { root in
            let file = try writeFile(root.appendingPathComponent("DSC00001.ARW"), Data(repeating: 0x42, count: 3_000_000))
            let upload = ImmichMultipartUpload(
                fields: [("deviceAssetId", "DSC00001.ARW-3000000"), ("deviceId", "CameraToolkit")],
                fileFieldName: "assetData",
                fileName: "DSC00001.ARW",
                mimeType: "image/x-sony-arw",
                fileByteCount: 3_000_000,
                boundary: "TEST"
            )
            let body = readAll(upload.makeBodyStream(fileURL: file))
            XCTAssertEqual(Int64(body.count), upload.contentLength)
            let head = String(decoding: body.prefix(upload.head.count), as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("--TEST\r\nContent-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\nDSC00001.ARW-3000000\r\n"))
            XCTAssertTrue(head.hasSuffix("name=\"assetData\"; filename=\"DSC00001.ARW\"\r\nContent-Type: image/x-sony-arw\r\n\r\n"))
            XCTAssertEqual(body.dropFirst(upload.head.count).prefix(3_000_000), Data(repeating: 0x42, count: 3_000_000))
            XCTAssertEqual(String(decoding: body.suffix(upload.tail.count), as: UTF8.self), "\r\n--TEST--\r\n")
        }
    }

    func testUploadReportsCreatedAndDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichUpload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile(root.appendingPathComponent("DSC00001.ARW"), "raw")
        let transport = RecordingImmichTransport()
        transport.responses["POST /api/assets"] = (201, #"{"id":"asset-1","status":"created"}"#)
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let created = try await client.uploadAsset(fileURL: file, deviceAssetID: "DSC00001.ARW-3", fileCreatedAt: Date(), fileModifiedAt: Date())
        XCTAssertEqual(created, ImmichUploadResult(assetID: "asset-1", isDuplicate: false))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertNotNil(request.httpBodyStream)

        transport.responses["POST /api/assets"] = (200, #"{"id":"asset-0","status":"duplicate"}"#)
        let duplicate = try await client.uploadAsset(fileURL: file, deviceAssetID: "DSC00001.ARW-3", fileCreatedAt: Date(), fileModifiedAt: Date())
        XCTAssertTrue(duplicate.isDuplicate)

        transport.responses["POST /api/assets"] = (500, "{}")
        do {
            _ = try await client.uploadAsset(fileURL: file, deviceAssetID: "x", fileCreatedAt: Date(), fileModifiedAt: Date())
            XCTFail("Expected an HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500"))
        }
    }

    func testEnsureAlbumReusesExistingAndAddsAssets() async throws {
        let transport = RecordingImmichTransport()
        transport.responses["GET /api/albums"] = (200, #"[{"id":"album-1","albumName":"Mountain Trip","assetCount":3}]"#)
        transport.responses["PUT /api/albums/album-1/assets"] = (200, #"[{"id":"a","success":true},{"id":"b","success":false,"error":"duplicate"},{"id":"c","success":false,"error":"no_permission"}]"#)
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "k", transport: transport)

        let album = try await client.ensureAlbum(named: "Mountain Trip")
        XCTAssertEqual(album.id, "album-1")
        let result = try await client.addAssets(["a", "b", "c"], toAlbum: album.id)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.alreadyInAlbum, 1)
        XCTAssertEqual(result.failed, ["c": "no_permission"])
        let put = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: [String]], ["ids": ["a", "b", "c"]])
    }

    func testEnsureAlbumCreatesMissingAlbum() async throws {
        let transport = RecordingImmichTransport()
        transport.responses["GET /api/albums"] = (200, "[]")
        transport.responses["POST /api/albums"] = (201, #"{"id":"album-9","albumName":"City Walk"}"#)
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "k", transport: transport)
        let album = try await client.ensureAlbum(named: "City Walk")
        XCTAssertEqual(album, ImmichAlbum(id: "album-9", name: "City Walk"))
        let create = try XCTUnwrap(transport.requests.last)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: create.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["albumName"] as? String, "City Walk")
    }

    private func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RecordingImmichTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var responses: [String: (Int, String)] = [:]

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    private func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        guard let (status, body) = responses[key] else {
            throw ToolkitError.commandFailed("Unexpected request \(key)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
