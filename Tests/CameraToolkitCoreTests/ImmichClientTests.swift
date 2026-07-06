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
}

private final class MockImmichTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: String
        switch request.url?.path {
        case "/api/server/ping":
            body = #"{"res":"pong"}"#
        case "/api/server/version":
            body = #"{"major":2,"minor":5,"patch":1,"prerelease":null}"#
        case "/api/users/me":
            body = #"{"id":"00000000-0000-4000-8000-000000000000","email":"user@example.com","name":"Example User","isAdmin":true}"#
        default:
            throw ToolkitError.commandFailed("Unexpected request \(request.url?.path ?? "")")
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
