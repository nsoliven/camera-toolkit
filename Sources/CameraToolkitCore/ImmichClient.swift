import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public struct ImmichConnectionReport: Equatable, Sendable {
    public var baseURL: String
    public var ping: String
    public var version: String
    public var userName: String
    public var userEmail: String

    public init(baseURL: String, ping: String, version: String, userName: String, userEmail: String) {
        self.baseURL = baseURL
        self.ping = ping
        self.version = version
        self.userName = userName
        self.userEmail = userEmail
    }
}

public struct ImmichClient: Sendable {
    private let apiBaseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport
    private let decoder: JSONDecoder

    public init(serverURL: String, apiKey: String, transport: HTTPTransport = URLSession.shared) throws {
        guard let normalizedURL = Self.normalizedAPIBaseURL(serverURL) else {
            throw ToolkitError.commandFailed("Immich server URL is not valid")
        }
        self.apiBaseURL = normalizedURL
        self.apiKey = apiKey
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    public func testConnection() async throws -> ImmichConnectionReport {
        let ping: ServerPingResponse = try await get("/server/ping", authenticated: false)
        guard ping.res == "pong" else {
            throw ToolkitError.commandFailed("Immich ping returned \(ping.res), expected pong")
        }

        let version: ServerVersionResponse = try await get("/server/version", authenticated: false)
        let user: ImmichUserResponse = try await get("/users/me", authenticated: true)

        return ImmichConnectionReport(
            baseURL: apiBaseURL.absoluteString,
            ping: ping.res,
            version: version.displayString,
            userName: user.name,
            userEmail: user.email
        )
    }

    public static func normalizedAPIBaseURL(_ serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate), components.host != nil else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/api") {
            path += "/api"
        }
        components.path = path
        components.query = nil
        components.fragment = nil

        return components.url
    }

    private func get<T: Decodable>(_ path: String, authenticated: Bool) async throws -> T {
        guard let url = URL(string: "\(apiBaseURL.absoluteString)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") else {
            throw ToolkitError.commandFailed("Immich endpoint URL is not valid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolkitError.commandFailed("Immich response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ToolkitError.commandFailed("Immich \(path) failed with HTTP \(httpResponse.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct ServerPingResponse: Decodable {
    var res: String
}

private struct ServerVersionResponse: Decodable {
    var major: Int
    var minor: Int
    var patch: Int
    var prerelease: Int?

    var displayString: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }
}

private struct ImmichUserResponse: Decodable {
    var id: String
    var email: String
    var name: String
    var isAdmin: Bool
}
