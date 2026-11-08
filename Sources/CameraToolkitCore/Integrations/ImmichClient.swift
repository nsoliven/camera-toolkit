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

    public func albums() async throws -> [ImmichAlbum] {
        let response: [AlbumResponse] = try await get("/albums", authenticated: true)
        return response.map { ImmichAlbum(id: $0.id, name: $0.albumName) }
    }

    /// The albums one asset is in.
    public func albums(containingAsset assetID: String) async throws -> [ImmichAlbum] {
        try Self.validate(id: assetID, kind: "asset")
        let response: [AlbumResponse] = try await get("/albums?assetId=\(assetID)", authenticated: true)
        return response.map { ImmichAlbum(id: $0.id, name: $0.albumName) }
    }

    /// The server's external libraries.
    public func libraries() async throws -> [ImmichLibrary] {
        try await get("/libraries", authenticated: true)
    }

    public func library(id: String) async throws -> ImmichLibrary {
        try Self.validate(id: id, kind: "library")
        return try await get("/libraries/\(id)", authenticated: true)
    }

    /// Asks Immich to look through the library's folders again. The scan runs
    /// on the server after this returns; it reads the folders and adds, never
    /// touches, the files.
    public func requestLibraryScan(libraryID: String) async throws {
        try Self.validate(id: libraryID, kind: "library")
        let path = "/libraries/\(libraryID)/scan"
        guard let url = endpointURL(path) else {
            throw ToolkitError.commandFailed("Immich endpoint URL is not valid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (_, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolkitError.commandFailed("Immich response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ToolkitError.commandFailed("Immich \(path) failed with HTTP \(httpResponse.statusCode)")
        }
    }

    /// File extensions the server imports (`.arw`, `.mp4`, …), lower-cased.
    public func supportedMediaExtensions() async throws -> Set<String> {
        let response: ServerMediaTypesResponse = try await get("/server/media-types", authenticated: false)
        return Set((response.image + response.video).map { $0.lowercased() })
    }

    /// Every asset of one library, trashed and offline ones included, a page
    /// at a time. Uses the search fields that work on every server version
    /// this app targets; Immich marks them deprecated from v3.2 and plans to
    /// drop them in v4.
    public func libraryAssets(libraryID: String, pageSize: Int = 1_000) async throws -> [ImmichLibraryAsset] {
        try Self.validate(id: libraryID, kind: "library")
        var assets: [ImmichLibraryAsset] = []
        var page = 1
        // The bound only stops a server that never says "last page".
        for _ in 0..<Self.maximumAssetPages {
            let response: MetadataSearchResponse = try await post(
                "/search/metadata",
                body: MetadataSearchRequest(libraryId: libraryID, withDeleted: true, page: page, size: pageSize)
            )
            assets += response.assets.items
            guard let next = response.assets.nextPage.flatMap(Int.init) else { return assets }
            page = next
        }
        throw ToolkitError.commandFailed("Immich kept returning more pages of this library; stopped after \(Self.maximumAssetPages).")
    }

    private static let maximumAssetPages = 10_000

    private static func validate(id: String, kind: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw ToolkitError.commandFailed("Immich \(kind) ID is not valid")
        }
    }

    public func createAlbum(named name: String, assetIDs: [String] = []) async throws -> ImmichAlbum {
        let response: AlbumResponse = try await send(
            method: "POST",
            path: "/albums",
            body: CreateAlbumRequest(albumName: name, assetIds: assetIDs)
        )
        return ImmichAlbum(id: response.id, name: response.albumName)
    }

    /// Finds an album with exactly this name, or creates it.
    public func ensureAlbum(named name: String) async throws -> ImmichAlbum {
        if let existing = try await albums().first(where: { $0.name == name }) {
            return existing
        }
        return try await createAlbum(named: name)
    }

    public func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws -> ImmichAlbumAddResult {
        guard !assetIDs.isEmpty else { return ImmichAlbumAddResult() }
        try Self.validate(id: albumID, kind: "album")
        let response: [BulkIDResponse] = try await send(
            method: "PUT",
            path: "/albums/\(albumID)/assets",
            body: BulkIDsRequest(ids: assetIDs)
        )
        var result = ImmichAlbumAddResult()
        for item in response {
            if item.success {
                result.added += 1
            } else if item.error == "duplicate" {
                result.alreadyInAlbum += 1
            } else {
                result.failed[item.id] = item.error ?? "unknown"
            }
        }
        return result
    }

    private func endpointURL(_ path: String) -> URL? {
        URL(string: "\(apiBaseURL.absoluteString)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
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

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(method: "POST", path: path, body: body)
    }

    private func send<Body: Encodable, Response: Decodable>(method: String, path: String, body: Body) async throws -> Response {
        guard let url = endpointURL(path) else {
            throw ToolkitError.commandFailed("Immich endpoint URL is not valid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolkitError.commandFailed("Immich response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ToolkitError.commandFailed("Immich \(path) failed with HTTP \(httpResponse.statusCode)")
        }
        return try decoder.decode(Response.self, from: data)
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

private struct ServerMediaTypesResponse: Decodable {
    var image: [String]
    var video: [String]
}

private struct MetadataSearchRequest: Encodable {
    var libraryId: String
    var withDeleted: Bool
    var page: Int
    var size: Int
}

private struct MetadataSearchResponse: Decodable {
    struct Assets: Decodable {
        var items: [ImmichLibraryAsset]
        var nextPage: String?
    }

    var assets: Assets
}

private struct AlbumResponse: Decodable {
    var id: String
    var albumName: String
}

private struct CreateAlbumRequest: Encodable {
    var albumName: String
    var assetIds: [String]
}

private struct BulkIDsRequest: Encodable {
    var ids: [String]
}

private struct BulkIDResponse: Decodable {
    var id: String
    var success: Bool
    var error: String?
}

public struct ImmichLibrary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var importPaths: [String]
    public var exclusionPatterns: [String]
    public var assetCount: Int?

    public init(id: String, name: String, importPaths: [String], exclusionPatterns: [String] = [], assetCount: Int? = nil) {
        self.id = id
        self.name = name
        self.importPaths = importPaths
        self.exclusionPatterns = exclusionPatterns
        self.assetCount = assetCount
    }
}

/// One asset as a library scan left it. `isOffline` means the last scan
/// could not find the file at `originalPath`; Immich also trashes such an
/// asset, so `isTrashed` is true for it as well.
public struct ImmichLibraryAsset: Codable, Equatable, Sendable {
    public var id: String
    public var originalPath: String
    public var isOffline: Bool
    public var isTrashed: Bool

    public init(id: String, originalPath: String, isOffline: Bool = false, isTrashed: Bool = false) {
        self.id = id
        self.originalPath = originalPath
        self.isOffline = isOffline
        self.isTrashed = isTrashed
    }
}

public struct ImmichAlbum: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ImmichAlbumAddResult: Equatable, Sendable {
    public var added = 0
    public var alreadyInAlbum = 0
    public var failed: [String: String] = [:]

    public init() {}
}
