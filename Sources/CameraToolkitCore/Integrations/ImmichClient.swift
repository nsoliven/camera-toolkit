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

public struct ImmichChecksumQuery: Codable, Equatable, Sendable {
    public var id: String
    public var checksum: String

    public init(id: String, checksum: String) {
        self.id = id
        self.checksum = checksum
    }
}

public struct ImmichChecksumResult: Equatable, Sendable {
    public var id: String
    public var isPresent: Bool
    public var assetID: String?
    public var isTrashed: Bool
    public var reason: String?

    public init(id: String, isPresent: Bool, assetID: String?, isTrashed: Bool, reason: String?) {
        self.id = id
        self.isPresent = isPresent
        self.assetID = assetID
        self.isTrashed = isTrashed
        self.reason = reason
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

    /// Uses Immich's stable pre-upload checksum endpoint. This only asks whether
    /// content already exists; it never uploads or changes an asset or album.
    public func checkBulkUpload(_ assets: [ImmichChecksumQuery]) async throws -> [ImmichChecksumResult] {
        guard !assets.isEmpty else { return [] }
        let response: AssetBulkUploadCheckResponse = try await post(
            "/assets/bulk-upload-check",
            body: AssetBulkUploadCheckRequest(assets: assets)
        )
        return response.results.map {
            ImmichChecksumResult(
                id: $0.id,
                isPresent: $0.action == "reject" && $0.reason == "duplicate" && $0.assetId != nil,
                assetID: $0.assetId,
                isTrashed: $0.isTrashed ?? false,
                reason: $0.reason
            )
        }
    }

    /// Uploads one original with a streamed multipart body, so multi-gigabyte
    /// clips never load into memory or a temporary file. Immich answers
    /// `duplicate` when identical content already exists.
    public func uploadAsset(
        fileURL: URL,
        deviceAssetID: String,
        deviceID: String = ImmichClient.deviceID,
        fileCreatedAt: Date,
        fileModifiedAt: Date
    ) async throws -> ImmichUploadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let upload = ImmichMultipartUpload(
            fields: [
                ("deviceAssetId", deviceAssetID),
                ("deviceId", deviceID),
                ("fileCreatedAt", Self.isoString(fileCreatedAt)),
                ("fileModifiedAt", Self.isoString(fileModifiedAt)),
                ("filename", fileURL.lastPathComponent)
            ],
            fileFieldName: "assetData",
            fileName: fileURL.lastPathComponent,
            mimeType: ImmichMultipartUpload.mimeType(for: fileURL),
            fileByteCount: byteCount
        )
        guard let url = endpointURL("/assets") else {
            throw ToolkitError.commandFailed("Immich endpoint URL is not valid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(upload.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(upload.contentLength), forHTTPHeaderField: "Content-Length")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBodyStream = upload.makeBodyStream(fileURL: fileURL)

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolkitError.commandFailed("Immich response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ToolkitError.commandFailed("Immich upload of \(fileURL.lastPathComponent) failed with HTTP \(httpResponse.statusCode)")
        }
        let decoded = try decoder.decode(AssetMediaResponse.self, from: data)
        return ImmichUploadResult(assetID: decoded.id, isDuplicate: decoded.status == "duplicate")
    }

    public func albums() async throws -> [ImmichAlbum] {
        let response: [AlbumResponse] = try await get("/albums", authenticated: true)
        return response.map { ImmichAlbum(id: $0.id, name: $0.albumName) }
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
        guard !albumID.isEmpty, albumID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw ToolkitError.commandFailed("Immich album ID is not valid")
        }
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

    public static let deviceID = "CameraToolkit"

    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

private struct AssetBulkUploadCheckRequest: Encodable {
    var assets: [ImmichChecksumQuery]
}

private struct AssetBulkUploadCheckResponse: Decodable {
    var results: [AssetBulkUploadCheckResult]
}

private struct AssetBulkUploadCheckResult: Decodable {
    var action: String
    var assetId: String?
    var id: String
    var isTrashed: Bool?
    var reason: String?
}

private struct AssetMediaResponse: Decodable {
    var id: String
    var status: String
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

public struct ImmichUploadResult: Equatable, Sendable {
    public var assetID: String
    public var isDuplicate: Bool

    public init(assetID: String, isDuplicate: Bool) {
        self.assetID = assetID
        self.isDuplicate = isDuplicate
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

/// A multipart/form-data body whose file part streams from disk.
public struct ImmichMultipartUpload: Sendable {
    public let boundary: String
    public let head: Data
    public let tail: Data
    public let fileByteCount: Int64

    public init(
        fields: [(String, String)],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileByteCount: Int64,
        boundary: String = "CameraToolkit-\(UUID().uuidString)"
    ) {
        self.boundary = boundary
        self.fileByteCount = fileByteCount
        var head = ""
        for (name, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.sanitized(name))\"\r\n\r\n\(Self.sanitized(value))\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.sanitized(fileFieldName))\"; filename=\"\(Self.sanitized(fileName))\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        self.head = Data(head.utf8)
        self.tail = Data("\r\n--\(boundary)--\r\n".utf8)
    }

    public var contentLength: Int64 {
        Int64(head.count) + fileByteCount + Int64(tail.count)
    }

    public func makeBodyStream(fileURL: URL) -> InputStream {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1 << 20, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            return InputStream(data: head + tail)
        }
        let pump = MultipartStreamPump(output: output, head: head, tail: tail, fileURL: fileURL)
        let thread = Thread { pump.run() }
        thread.qualityOfService = .utility
        thread.start()
        return input
    }

    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "arw": "image/x-sony-arw"
        case "dng": "image/x-adobe-dng"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "png": "image/png"
        case "tif", "tiff": "image/tiff"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        default: "application/octet-stream"
        }
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}

private final class MultipartStreamPump: @unchecked Sendable {
    private let output: OutputStream
    private let head: Data
    private let tail: Data
    private let fileURL: URL

    init(output: OutputStream, head: Data, tail: Data, fileURL: URL) {
        self.output = output
        self.head = head
        self.tail = tail
        self.fileURL = fileURL
    }

    func run() {
        output.open()
        defer { output.close() }
        guard write(head) else { return }
        do {
            try StreamingFileIO.readChunks(from: fileURL, chunkSize: 1 << 20) { chunk in
                guard self.write(chunk) else {
                    throw ToolkitError.commandFailed("The upload stream closed early.")
                }
            }
        } catch {
            return
        }
        _ = write(tail)
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { write($0) }
    }

    private func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
        var offset = 0
        var idleSince: Date?
        while offset < buffer.count {
            let written = output.write(base.advanced(by: offset), maxLength: buffer.count - offset)
            if written < 0 { return false }
            if written == 0 {
                if output.streamStatus == .closed || output.streamStatus == .error { return false }
                let started = idleSince ?? Date()
                idleSince = started
                if Date().timeIntervalSince(started) > 300 { return false }
                usleep(2_000)
                continue
            }
            idleSince = nil
            offset += written
        }
        return true
    }
}
