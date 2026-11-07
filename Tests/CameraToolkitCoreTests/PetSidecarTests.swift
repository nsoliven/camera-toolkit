import CoreGraphics
import Foundation
@testable import CameraToolkitCore
import XCTest

/// The real pet sidecar, end to end through the line protocol. Skipped
/// unless the engine is installed — at the app's location, or wherever
/// `CT_PET_SIDECAR_ROOT` points (a scratch install made with
/// `CAMERA_TOOLKIT_PET_SIDECAR_ROOT=… scripts/setup-pet-sidecar.sh`).
final class PetSidecarTests: XCTestCase {
    private func installation() throws -> PetSidecarInstallation {
        let installation: PetSidecarInstallation
        if let root = ProcessInfo.processInfo.environment["CT_PET_SIDECAR_ROOT"], !root.isEmpty {
            installation = PetSidecarInstallation(root: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            installation = PetSidecarInstallation(
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            )
        }
        guard installation.isInstalled else {
            throw XCTSkip("Pet sidecar not installed — run \(PetSidecarInstallation.setupCommand) once")
        }
        return installation
    }

    /// A blank frame holds no dog; a crop's vector is DINOv2-base sized,
    /// unit length, and the same on a second call.
    func testThePetSidecarAnswersOverTheLineProtocol() throws {
        let pool = try PetSidecarPool(installation: installation())
        defer { pool.shutdown() }
        XCTAssertTrue(pool.displayName.contains("DINOv2"))

        let blank = try XCTUnwrap(Self.image(width: 800, height: 600) { context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        })
        XCTAssertEqual(try pool.analyze(blank, options: .pets()), [])

        let pattern = try XCTUnwrap(Self.image(width: 224, height: 224) { context in
            for band in 0..<8 {
                context.setFillColor(CGColor(red: CGFloat(band) / 8, green: 0.3, blue: 1 - CGFloat(band) / 8, alpha: 1))
                context.fill(CGRect(x: band * 28, y: 0, width: 28, height: 224))
            }
        })
        let first = try pool.embedCrop(pattern)
        let second = try pool.embedCrop(pattern)
        XCTAssertEqual(first.embedding.count, 1024)
        XCTAssertEqual(Double(FaceEmbeddingMath.cosine(first.embedding, first.embedding)), 1, accuracy: 1e-3)
        XCTAssertGreaterThan(FaceEmbeddingMath.cosine(first.embedding, second.embedding), 0.999)
        XCTAssertGreaterThan(first.quality, 0)
    }

    /// Opt-in, read-only: scans every JPEG in `CT_PET_SAMPLE_DIR` through
    /// the real decode → sidecar → pet index path into a throwaway index,
    /// and prints what it found. The folder is only read.
    func testScanningASampleFolderFindsAndGroupsDogs() throws {
        guard let folder = ProcessInfo.processInfo.environment["CT_PET_SAMPLE_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set CT_PET_SAMPLE_DIR to a folder of dog photos to run this")
        }
        let pool = try PetSidecarPool(installation: installation())
        defer { pool.shutdown() }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let stacks: [OrganizeStack] = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .sorted()
            .map { name in
                let url = root.appendingPathComponent(name)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let modified = attributes[.modificationDate] as? Date ?? Date()
                return OrganizeStack(items: [OrganizeItem(
                    primary: OrganizeFile(path: url.path, size: attributes[.size] as? Int64 ?? 0, modifiedAt: modified),
                    kind: .photo,
                    captureDate: modified,
                    hasCameraDate: false
                )])
            }
        try withTemporaryDirectory { scratch in
            let store = try PetIndexDatabase.open(url: scratch.appendingPathComponent(PetIndexDatabase.fileName))
            let report = try FaceIndexService(store: store, options: .pets(mode: .med)).scan(stacks: stacks, analyzer: pool)
            let groups = try store.otherGroups()
            print("pet sample scan: \(report.photosProcessed) photos, \(report.photosFailed) failed, \(report.facesDetected) dogs, groups \(groups.map { "\($0.name)=\($0.faceCount)" })")
            XCTAssertEqual(report.photosFailed, 0)
            XCTAssertGreaterThan(report.facesDetected, 0)
            let faces = try groups.flatMap { try store.faces(personID: $0.id) }
            for face in faces {
                XCTAssertEqual(face.model, PetFaceEngine.identifier)
                XCTAssertEqual(face.embedding?.count, 1024)
                XCTAssertNotNil(face.crop)
                XCTAssertTrue((0...1).contains(face.box.x) && face.box.x + face.box.width <= 1.0001)
            }
        }
    }

    func testAMissingInstallSaysWhatToRun() {
        XCTAssertThrowsError(try PetSidecarPool(installation: PetSidecarInstallation(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("no-pet-sidecar-\(UUID().uuidString)")
        ))) { error in
            XCTAssertEqual(error as? FaceIndexError, .engineNotInstalled(PetSidecarInstallation.notInstalledMessage))
        }
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(context)
        return context.makeImage()
    }
}
