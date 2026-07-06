import CameraToolkitCore
import Foundation
import XCTest

final class ImmichClientTests: XCTestCase {
    func testNormalizesServerURLToAPIBase() throws {
        XCTAssertEqual(
            ImmichClient.normalizedAPIBaseURL("photos.local:2283")?.absoluteString,
            "http://photos.local:2283/api"
        )
        XCTAssertEqual(
            ImmichClient.normalizedAPIBaseURL("https://photos.example.com/api/")?.absoluteString,
            "https://photos.example.com/api"
        )
    }

    func testConnectionUsesStableEndpointsAndAPIKeyHeader() async throws {
        let transport = MockImmichTransport()
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        let report = try await client.testConnection()

        XCTAssertEqual(report.ping, "pong")
        XCTAssertEqual(report.version, "2.5.1")
        XCTAssertEqual(report.userName, "Nev")
        XCTAssertEqual(report.userEmail, "user@example.com")
        XCTAssertEqual(transport.requests.map(\.url?.path), [
            "/api/server/ping",
            "/api/server/version",
            "/api/users/me"
        ])
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(transport.requests[2].value(forHTTPHeaderField: "x-api-key"), "secret-key")
    }

    func testConnectionStopsWhenPingIsNotPong() async throws {
        let transport = MockImmichTransport()
        transport.bodyByPath["/api/server/ping"] = #"{"res":"maintenance"}"#
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        do {
            _ = try await client.testConnection()
            XCTFail("Expected ping failure")
        } catch {
            XCTAssertEqual(error as? ToolkitError, .commandFailed("Immich ping returned maintenance, expected pong"))
        }

        XCTAssertEqual(transport.requests.map(\.url?.path), ["/api/server/ping"])
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "x-api-key"))
    }

    func testConnectionFailsOnAuthenticatedHTTPError() async throws {
        let transport = MockImmichTransport()
        transport.statusCodeByPath["/api/users/me"] = 401
        let client = try ImmichClient(serverURL: "https://photos.example.com", apiKey: "secret-key", transport: transport)

        do {
            _ = try await client.testConnection()
            XCTFail("Expected authenticated endpoint failure")
        } catch {
            XCTAssertEqual(error as? ToolkitError, .commandFailed("Immich /users/me failed with HTTP 401"))
        }

        XCTAssertEqual(transport.requests.map(\.url?.path), [
            "/api/server/ping",
            "/api/server/version",
            "/api/users/me"
        ])
        XCTAssertEqual(transport.requests[2].value(forHTTPHeaderField: "x-api-key"), "secret-key")
    }
}

private final class MockImmichTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    var bodyByPath: [String: String] = [
        "/api/server/ping": #"{"res":"pong"}"#,
        "/api/server/version": #"{"major":2,"minor":5,"patch":1,"prerelease":null}"#,
        "/api/users/me": #"{"id":"00000000-0000-4000-8000-000000000000","email":"user@example.com","name":"Example User","isAdmin":true}"#
    ]
    var statusCodeByPath: [String: Int] = [:]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let path = request.url?.path, let body = bodyByPath[path] else {
            throw ToolkitError.commandFailed("Unexpected request \(request.url?.path ?? "")")
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCodeByPath[path] ?? 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
