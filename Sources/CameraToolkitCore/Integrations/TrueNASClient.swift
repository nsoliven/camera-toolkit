import CryptoKit
import Foundation
import Security

public struct TrueNASCapacityReport: Equatable, Sendable {
    public var serverVersion: String
    public var dataset: String
    public var datasetMountpoint: String?
    public var datasetUsedBytes: Int64
    public var datasetAvailableBytes: Int64
    public var poolName: String
    public var poolStatus: String
    public var poolHealthy: Bool
    public var poolTotalBytes: Int64
    public var poolFreeBytes: Int64

    public var datasetTotalBytes: Int64 {
        datasetUsedBytes + datasetAvailableBytes
    }

    public init(
        serverVersion: String,
        dataset: String,
        datasetMountpoint: String?,
        datasetUsedBytes: Int64,
        datasetAvailableBytes: Int64,
        poolName: String,
        poolStatus: String,
        poolHealthy: Bool,
        poolTotalBytes: Int64,
        poolFreeBytes: Int64
    ) {
        self.serverVersion = serverVersion
        self.dataset = dataset
        self.datasetMountpoint = datasetMountpoint
        self.datasetUsedBytes = datasetUsedBytes
        self.datasetAvailableBytes = datasetAvailableBytes
        self.poolName = poolName
        self.poolStatus = poolStatus
        self.poolHealthy = poolHealthy
        self.poolTotalBytes = poolTotalBytes
        self.poolFreeBytes = poolFreeBytes
    }
}

public enum TrueNASJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([TrueNASJSONValue])
    case object([String: TrueNASJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TrueNASJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TrueNASJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct TrueNASClient: Sendable {
    private let webSocketURL: URL
    private let username: String
    private let apiKey: String
    private let pinnedCertificateSHA256: String

    public init(
        serverURL: String,
        username: String,
        apiKey: String,
        pinnedCertificateSHA256: String = ""
    ) throws {
        guard let webSocketURL = Self.normalizedWebSocketURL(serverURL) else {
            throw ToolkitError.commandFailed("The TrueNAS server URL is not valid.")
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ToolkitError.commandFailed("Save a TrueNAS API key first.")
        }
        self.webSocketURL = webSocketURL
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmedKey
        self.pinnedCertificateSHA256 = Self.normalizedFingerprint(pinnedCertificateSHA256)
    }

    public func readCapacity(dataset: String, smbShareName: String? = nil) async throws -> TrueNASCapacityReport {
        let preferredDataset = dataset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredDataset.isEmpty, !preferredDataset.contains("/") {
            throw ToolkitError.commandFailed("Enter the full TrueNAS dataset name, such as pool/photos.")
        }

        let delegate = PinnedCertificateDelegate(expectedFingerprint: pinnedCertificateSHA256)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: webSocketURL)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await authenticate(socket: socket)
        let version = try await call(socket: socket, id: 3, method: "system.version", params: .array([]))
        let dataset: String
        let datasetResult: TrueNASJSONValue
        if preferredDataset.isEmpty {
            let shareName = smbShareName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !shareName.isEmpty else {
                throw ToolkitError.commandFailed("Enter a dataset, or choose a library folder on a mounted SMB share so Camera Toolkit can detect it.")
            }
            let shareResult = try await call(
                socket: socket,
                id: 4,
                method: "sharing.smb.query",
                params: .array([
                    .array([.array([.string("name"), .string("="), .string(shareName)])]),
                    .object(["get": .bool(true)])
                ])
            )
            guard case .object(let shareObject) = shareResult,
                  let sharePath = Self.stringValue(shareObject["path"]) else {
                throw ToolkitError.commandFailed("TrueNAS could not match the mounted SMB share \(shareName). Enter the dataset manually in Settings.")
            }
            if let shareDataset = Self.stringValue(shareObject["dataset"]), !shareDataset.isEmpty {
                dataset = shareDataset
                datasetResult = try await call(
                    socket: socket,
                    id: 5,
                    method: "pool.dataset.query",
                    params: .array([
                        .array([.array([.string("id"), .string("="), .string(dataset)])]),
                        .object([
                            "get": .bool(true),
                            "extra": .object([
                                "retrieve_children": .bool(false),
                                "properties": .array([
                                    .string("used"),
                                    .string("available"),
                                    .string("mountpoint")
                                ])
                            ])
                        ])
                    ])
                )
            } else {
                let datasets = try await call(
                    socket: socket,
                    id: 5,
                    method: "pool.dataset.query",
                    params: .array([
                        .array([]),
                        .object([
                            "extra": .object([
                                "flat": .bool(true),
                                "retrieve_children": .bool(false),
                                "properties": .array([
                                    .string("used"),
                                    .string("available"),
                                    .string("mountpoint")
                                ])
                            ])
                        ])
                    ])
                )
                guard let match = Self.matchingDataset(in: datasets, sharePath: sharePath),
                      case .object(let datasetObject) = match,
                      let detectedDataset = Self.stringValue(datasetObject["id"]) else {
                    throw ToolkitError.commandFailed("TrueNAS returned the SMB share, but no dataset mountpoint matched \(sharePath). Enter the dataset manually in Settings.")
                }
                dataset = detectedDataset
                datasetResult = match
            }
        } else {
            dataset = preferredDataset
            datasetResult = try await call(
                socket: socket,
                id: 4,
                method: "pool.dataset.query",
                params: .array([
                    .array([.array([.string("id"), .string("="), .string(dataset)])]),
                    .object([
                        "get": .bool(true),
                        "extra": .object([
                            "retrieve_children": .bool(false),
                            "properties": .array([
                                .string("used"),
                                .string("available"),
                                .string("mountpoint")
                            ])
                        ])
                    ])
                ])
            )
        }

        let poolName = String(dataset.split(separator: "/", maxSplits: 1).first ?? "")
        let poolResult = try await call(
            socket: socket,
            id: 6,
            method: "pool.query",
            params: .array([
                .array([.array([.string("name"), .string("="), .string(poolName)])]),
                .object([
                    "get": .bool(true),
                    "select": .array([
                        .string("name"),
                        .string("status"),
                        .string("healthy"),
                        .string("size"),
                        .string("free")
                    ])
                ])
            ])
        )

        return try Self.capacityReport(
            dataset: dataset,
            versionResult: version,
            datasetResult: datasetResult,
            poolResult: poolResult
        )
    }

    public static func normalizedWebSocketURL(_ serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard var components = URLComponents(string: candidate), components.host != nil else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https", "wss":
            components.scheme = "wss"
        default:
            return nil
        }
        components.path = "/api/current"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func certificateFingerprint(serverURL: String) async throws -> String {
        guard let socketURL = normalizedWebSocketURL(serverURL),
              var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false) else {
            throw ToolkitError.commandFailed("The TrueNAS server URL is not valid.")
        }
        components.scheme = "https"
        components.path = "/api/versions"
        guard let probeURL = components.url else {
            throw ToolkitError.commandFailed("The TrueNAS certificate URL is not valid.")
        }

        let delegate = CertificateCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        _ = try? await session.data(for: request)
        guard let fingerprint = delegate.capturedFingerprint else {
            throw ToolkitError.commandFailed("Could not read the TrueNAS TLS certificate.")
        }
        return fingerprint
    }

    static func capacityReport(
        dataset: String,
        versionResult: TrueNASJSONValue,
        datasetResult: TrueNASJSONValue,
        poolResult: TrueNASJSONValue
    ) throws -> TrueNASCapacityReport {
        guard case .object(let datasetObject) = datasetResult else {
            throw ToolkitError.commandFailed("TrueNAS did not return the configured dataset \(dataset).")
        }
        guard case .object(let poolObject) = poolResult else {
            throw ToolkitError.commandFailed("TrueNAS did not return the pool for \(dataset).")
        }
        guard let used = capacityValue(datasetObject["used"]),
              let available = capacityValue(datasetObject["available"]),
              used >= 0,
              available >= 0 else {
            throw ToolkitError.commandFailed("TrueNAS returned incomplete dataset capacity values.")
        }
        guard let poolTotal = capacityValue(poolObject["size"]),
              let poolFree = capacityValue(poolObject["free"]),
              poolTotal > 0,
              poolFree >= 0 else {
            throw ToolkitError.commandFailed("TrueNAS returned incomplete pool capacity values.")
        }

        return TrueNASCapacityReport(
            serverVersion: stringValue(versionResult) ?? "Unknown",
            dataset: stringValue(datasetObject["id"]) ?? dataset,
            datasetMountpoint: propertyStringValue(datasetObject["mountpoint"]),
            datasetUsedBytes: used,
            datasetAvailableBytes: available,
            poolName: stringValue(poolObject["name"]) ?? String(dataset.split(separator: "/").first ?? ""),
            poolStatus: stringValue(poolObject["status"]) ?? "UNKNOWN",
            poolHealthy: boolValue(poolObject["healthy"]) ?? false,
            poolTotalBytes: poolTotal,
            poolFreeBytes: min(poolFree, poolTotal)
        )
    }

    static func matchingDataset(
        in datasets: TrueNASJSONValue,
        sharePath: String
    ) -> TrueNASJSONValue? {
        guard case .array(let candidates) = datasets else { return nil }
        let normalizedSharePath = normalizedServerPath(sharePath)
        return candidates.compactMap { candidate -> (value: TrueNASJSONValue, mountpoint: String)? in
            guard case .object(let object) = candidate,
                  let mountpoint = propertyStringValue(object["mountpoint"]) else {
                return nil
            }
            let normalizedMountpoint = normalizedServerPath(mountpoint)
            guard normalizedSharePath == normalizedMountpoint
                    || normalizedSharePath.hasPrefix(normalizedMountpoint + "/") else {
                return nil
            }
            return (candidate, normalizedMountpoint)
        }.max { lhs, rhs in
            lhs.mountpoint.count < rhs.mountpoint.count
        }?.value
    }

    private func authenticate(socket: URLSessionWebSocketTask) async throws {
        if !username.isEmpty {
            let login = try? await call(
                socket: socket,
                id: 1,
                method: "auth.login_ex",
                params: .array([
                    .object([
                        "mechanism": .string("API_KEY_PLAIN"),
                        "username": .string(username),
                        "api_key": .string(apiKey),
                        "login_options": .object([
                            "user_info": .bool(false)
                        ])
                    ])
                ])
            )
            if let login, Self.isAuthenticated(login) {
                return
            }
        }

        let legacyLogin = try await call(
            socket: socket,
            id: 2,
            method: "auth.login_with_api_key",
            params: .array([.string(apiKey)])
        )
        guard Self.isAuthenticated(legacyLogin) else {
            throw ToolkitError.commandFailed("TrueNAS rejected the API key or username.")
        }
    }

    private func call(
        socket: URLSessionWebSocketTask,
        id: Int64,
        method: String,
        params: TrueNASJSONValue
    ) async throws -> TrueNASJSONValue {
        let request = RPCRequest(jsonrpc: "2.0", id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolkitError.commandFailed("Could not encode the TrueNAS request.")
        }
        try await socket.send(.string(string))

        while true {
            let message = try await socket.receive()
            let responseData: Data
            switch message {
            case .data(let data):
                responseData = data
            case .string(let string):
                responseData = Data(string.utf8)
            @unknown default:
                continue
            }
            let response = try JSONDecoder().decode(RPCResponse.self, from: responseData)
            guard response.id == id else { continue }
            if let error = response.error {
                throw ToolkitError.commandFailed("TrueNAS \(method) failed: \(error.message)")
            }
            return response.result ?? .null
        }
    }

    private static func isAuthenticated(_ value: TrueNASJSONValue) -> Bool {
        if case .bool(true) = value { return true }
        guard case .object(let object) = value,
              let responseType = stringValue(object["response_type"])?.uppercased() else {
            return false
        }
        return responseType == "SUCCESS" || responseType == "AUTH_SUCCESS"
    }

    private static func capacityValue(_ value: TrueNASJSONValue?) -> Int64? {
        if case .object(let object) = value {
            return integerValue(object["value"]) ?? integerValue(object["rawvalue"])
        }
        return integerValue(value)
    }

    private static func integerValue(_ value: TrueNASJSONValue?) -> Int64? {
        switch value {
        case .int(let value): value
        case .double(let value): Int64(value)
        case .string(let value): Int64(value)
        default: nil
        }
    }

    private static func stringValue(_ value: TrueNASJSONValue?) -> String? {
        if case .string(let value) = value { return value }
        return nil
    }

    private static func propertyStringValue(_ value: TrueNASJSONValue?) -> String? {
        if case .object(let object) = value {
            return stringValue(object["value"]) ?? stringValue(object["rawvalue"])
        }
        return stringValue(value)
    }

    private static func boolValue(_ value: TrueNASJSONValue?) -> Bool? {
        if case .bool(let value) = value { return value }
        return nil
    }

    private static func normalizedServerPath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        value.uppercased().filter(\.isHexDigit)
    }
}

private struct RPCRequest: Encodable {
    var jsonrpc: String
    var id: Int64
    var method: String
    var params: TrueNASJSONValue
}

private struct RPCResponse: Decodable {
    var jsonrpc: String?
    var id: Int64?
    var result: TrueNASJSONValue?
    var error: RPCError?
}

private struct RPCError: Decodable {
    var code: Int?
    var message: String
}

private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint.uppercased().filter(\.isHexDigit)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if !expectedFingerprint.isEmpty {
            guard certificateFingerprint(trust: trust) == expectedFingerprint else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

private final class CertificateCaptureDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?

    var capturedFingerprint: String? {
        lock.withLock { fingerprint }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let captured = certificateFingerprint(trust: trust)
        lock.withLock { fingerprint = captured }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private func certificateFingerprint(trust: SecTrust) -> String? {
    guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let certificate = certificates.first else { return nil }
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
    return digest.map { String(format: "%02X", $0) }.joined()
}
