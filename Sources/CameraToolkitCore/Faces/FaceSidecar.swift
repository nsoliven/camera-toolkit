import CoreGraphics
import Darwin
import Foundation

/// The one face engine: the reference InsightFace `buffalo_l` pack (SCRFD-10G
/// detection with five landmarks, ArcFace `w600k_r50` identity) run by
/// `insightface` itself inside a Python sidecar. Every grade uses it; grades
/// differ only in detector scales, size floors, and video sampling.
public enum FaceEngine {
    /// Stamped on every face row and every scanned photo. Rows from another
    /// engine are ignored by matching and grouping and re-scanned on the
    /// next pass, so an engine change never mixes embedding spaces.
    public static let identifier = "insightface/buffalo_l"
    public static let displayName = "InsightFace buffalo_l (SCRFD-10G + ArcFace w600k_r50)"
}

/// One face the engine found on an image, in the shape the index stores.
public struct AnalyzedFace: Equatable, Sendable {
    /// Normalized box, bottom-left origin (the Vision convention the rest
    /// of the app draws with).
    public var box: NormalizedFaceBox
    public var detScore: Double
    /// 512-d, L2-normalized.
    public var embedding: [Float]
    /// The embedding's norm before normalization — ArcFace's built-in
    /// quality signal (blurry, tiny, or occluded faces come out short).
    public var quality: Double
    /// The smaller side of the box in pixels of the image the engine saw.
    public var facePixels: Double
    /// JPEG of the aligned 112×112 crop the embedding was computed from.
    public var crop: Data?

    public init(
        box: NormalizedFaceBox,
        detScore: Double,
        embedding: [Float],
        quality: Double,
        facePixels: Double,
        crop: Data? = nil
    ) {
        self.box = box
        self.detScore = detScore
        self.embedding = embedding
        self.quality = quality
        self.facePixels = facePixels
        self.crop = crop
    }
}

/// Detect + align + embed for one decoded image. The sidecar in production;
/// a canned stub in tests.
public protocol FaceAnalyzing: Sendable {
    /// What the Jobs pane lists as the model that ran.
    var displayName: String { get }
    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace]
}

/// Where the sidecar lives on this Mac and whether it is ready.
public struct FaceSidecarInstallation: Equatable, Sendable {
    /// `scripts/setup-face-sidecar.sh` — the one-time install command the
    /// UI names when the sidecar is missing.
    public static let setupCommand = "scripts/setup-face-sidecar.sh"

    /// `…/CameraToolkit/face-sidecar`: the venv, the model pack, caches.
    public var root: URL

    public init(applicationSupport: URL) {
        root = applicationSupport.appendingPathComponent("CameraToolkit/face-sidecar", isDirectory: true)
    }

    public init(root: URL) {
        self.root = root
    }

    public var pythonURL: URL { root.appendingPathComponent("venv/bin/python") }
    public var packURL: URL { root.appendingPathComponent("models/buffalo_l", isDirectory: true) }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: packURL.appendingPathComponent("w600k_r50.onnx").path)
            && Self.scriptURL != nil
    }

    /// The bundled sidecar script.
    public static var scriptURL: URL? {
        Bundle.module.url(forResource: "face_sidecar", withExtension: "py")
    }

    /// The message the UI shows when a scan cannot start.
    public static let notInstalledMessage =
        "The face engine is not installed yet. Run \(setupCommand) once on this Mac, then scan again."
}

/// One sidecar process: launch, wait for its ready line, then serve one
/// request at a time over stdin/stdout.
final class FaceSidecarProcess: @unchecked Sendable {
    struct ReadyInfo: Sendable {
        var pack: String
        var insightface: String
        var onnxruntime: String
        var providers: [String]
    }

    private(set) var ready: ReadyInfo
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var buffer: [UInt8] = []
    private var recentStderr: [String] = []
    private let stderrLock = NSLock()
    private var nextID = 0

    /// `startupTimeout` covers a cold CoreML compile; the cached second
    /// start takes well under a second.
    init(installation: FaceSidecarInstallation, startupTimeout: TimeInterval = 240) throws {
        guard let script = FaceSidecarInstallation.scriptURL else {
            throw FaceIndexError.engineFailed("The face sidecar script is missing from the app bundle.")
        }
        guard installation.isInstalled else {
            throw FaceIndexError.engineNotInstalled(FaceSidecarInstallation.notInstalledMessage)
        }
        // A sidecar that died mid-write must surface as an error, not a
        // SIGPIPE that kills the app.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = installation.pythonURL
        process.arguments = ["-u", script.path, "--root", installation.root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        // Placeholder until the sidecar's ready line arrives; every stored
        // property must exist before the read helpers below touch `self`.
        ready = ReadyInfo(pack: "", insightface: "", onnxruntime: "", providers: [])

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.noteStderr(text)
        }
        do {
            try process.run()
        } catch {
            throw FaceIndexError.engineFailed("Could not start the face sidecar: \(error.localizedDescription)")
        }

        let line = try readLine(timeout: startupTimeout)
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["event"] as? String == "ready" else {
            terminate()
            throw FaceIndexError.engineFailed("The face sidecar did not report ready. \(stderrTail())")
        }
        ready = ReadyInfo(
            pack: object["pack"] as? String ?? "",
            insightface: object["insightface"] as? String ?? "",
            onnxruntime: object["onnxruntime"] as? String ?? "",
            providers: object["providers"] as? [String] ?? []
        )
    }

    deinit {
        terminate()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        input.readabilityHandler = nil
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    /// Sends one request and returns its response object; throws on a
    /// sidecar error, a dead process, or a timeout.
    func request(_ body: [String: Any], timeout: TimeInterval = 120) throws -> [String: Any] {
        guard process.isRunning else {
            throw FaceIndexError.engineFailed("The face sidecar exited. \(stderrTail())")
        }
        nextID += 1
        var payload = body
        payload["id"] = nextID
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw FaceIndexError.engineFailed("Could not write to the face sidecar: \(error.localizedDescription) \(stderrTail())")
        }
        let line = try readLine(timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw FaceIndexError.engineFailed("The face sidecar returned an unreadable line.")
        }
        if let message = object["error"] as? String {
            throw FaceIndexError.engineFailed("Face sidecar: \(message)")
        }
        return object
    }

    private func readLine(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw FaceIndexError.engineFailed("Timed out waiting for the face sidecar. \(stderrTail())")
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready > 0 {
                let chunk = output.availableData
                if chunk.isEmpty {
                    throw FaceIndexError.engineFailed("The face sidecar closed its output. \(stderrTail())")
                }
                buffer.append(contentsOf: chunk)
            } else if ready < 0, errno != EINTR {
                throw FaceIndexError.engineFailed("Could not read from the face sidecar (errno \(errno)).")
            }
        }
    }

    private func noteStderr(_ text: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        recentStderr.append(contentsOf: text.split(separator: "\n").map(String.init))
        if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
    }

    private func stderrTail() -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return recentStderr.suffix(6).joined(separator: " | ")
    }
}

/// The production `FaceAnalyzing`: a small pool of sidecar processes so a
/// FAST pass keeps several decoders busy while the engine stays the single
/// reference implementation. `analyze` is safe to call from many threads.
public final class FaceSidecarPool: FaceAnalyzing, @unchecked Sendable {
    public let displayName: String
    public let installation: FaceSidecarInstallation
    private var idle: [FaceSidecarProcess]
    private let available: DispatchSemaphore
    private let lock = NSLock()

    /// Launches `processes` sidecars (each ~0.5 GB with models loaded) and
    /// waits until every one reports ready.
    public init(installation: FaceSidecarInstallation, processes: Int = 1) throws {
        self.installation = installation
        let count = max(1, processes)
        var launched: [FaceSidecarProcess] = []
        do {
            for _ in 0..<count {
                launched.append(try FaceSidecarProcess(installation: installation))
            }
        } catch {
            launched.forEach { $0.terminate() }
            throw error
        }
        idle = launched
        available = DispatchSemaphore(value: launched.count)
        let info = launched[0].ready
        let provider = info.providers.first.map { $0.replacingOccurrences(of: "ExecutionProvider", with: "") } ?? "CPU"
        displayName = "\(FaceEngine.displayName) · insightface \(info.insightface) · onnxruntime \(info.onnxruntime) \(provider)"
    }

    /// The worker count a scan should run: two sidecars pin the Neural
    /// Engine well ahead of NAS reads; the quiet pass keeps one.
    public static func processCount(for options: FaceScanOptions) -> Int {
        options.fast ? 2 : 1
    }

    /// Opens the pool for `options` or throws the install/start error.
    public static func open(applicationSupport: URL, options: FaceScanOptions) throws -> FaceSidecarPool {
        try FaceSidecarPool(
            installation: FaceSidecarInstallation(applicationSupport: applicationSupport),
            processes: processCount(for: options)
        )
    }

    public func shutdown() {
        lock.lock()
        let processes = idle
        idle = []
        lock.unlock()
        processes.forEach { $0.terminate() }
    }

    deinit {
        shutdown()
    }

    public func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        guard let jpeg = FaceImageEncoding.jpegData(image, quality: 0.95) else {
            throw FaceIndexError.engineFailed("Could not encode an image for the face sidecar.")
        }
        let response = try withProcess { process in
            try process.request([
                "op": "analyze",
                "image_b64": jpeg.base64EncodedString(),
                "det_sizes": options.detectorScales,
                "det_thresh": options.detScoreThreshold,
                "flip_tta": options.flipTTA,
            ])
        }
        return Self.faces(from: response)
    }

    /// Embeds an already-aligned 112×112 crop — the parity test's path.
    public func embedCrop(_ image: CGImage) throws -> (embedding: [Float], quality: Double) {
        guard let png = FaceImageEncoding.pngData(image) else {
            throw FaceIndexError.engineFailed("Could not encode a crop for the face sidecar.")
        }
        let response = try withProcess { process in
            try process.request(["op": "embed_crop", "image_b64": png.base64EncodedString()])
        }
        return (Self.floats(response["embedding"]), response["norm"] as? Double ?? 0)
    }

    private func withProcess<T>(_ body: (FaceSidecarProcess) throws -> T) throws -> T {
        available.wait()
        defer { available.signal() }
        lock.lock()
        guard let process = idle.popLast() else {
            lock.unlock()
            throw FaceIndexError.engineFailed("The face sidecar pool was shut down.")
        }
        lock.unlock()
        defer {
            lock.lock()
            idle.append(process)
            lock.unlock()
        }
        return try body(process)
    }

    /// Sidecar boxes are image pixels with a top-left origin; the index
    /// stores normalized boxes with a bottom-left origin.
    static func faces(from response: [String: Any]) -> [AnalyzedFace] {
        guard let width = response["width"] as? Double, let height = response["height"] as? Double,
              width > 0, height > 0,
              let faces = response["faces"] as? [[String: Any]] else { return [] }
        return faces.compactMap { face in
            guard let box = face["box"] as? [Double], box.count == 4 else { return nil }
            let x1 = max(0, min(width, box[0]))
            let y1 = max(0, min(height, box[1]))
            let x2 = max(0, min(width, box[2]))
            let y2 = max(0, min(height, box[3]))
            guard x2 > x1, y2 > y1 else { return nil }
            let embedding = floats(face["embedding"])
            guard !embedding.isEmpty else { return nil }
            let crop = (face["crop_b64"] as? String).flatMap { Data(base64Encoded: $0) }
            return AnalyzedFace(
                box: NormalizedFaceBox(
                    x: x1 / width,
                    y: 1 - y2 / height,
                    width: (x2 - x1) / width,
                    height: (y2 - y1) / height
                ),
                detScore: face["det_score"] as? Double ?? 0,
                embedding: embedding,
                quality: face["norm"] as? Double ?? 0,
                facePixels: min(x2 - x1, y2 - y1),
                crop: crop
            )
        }
    }

    private static func floats(_ value: Any?) -> [Float] {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
    }
}
