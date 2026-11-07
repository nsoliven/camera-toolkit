import AppKit
import AVFoundation
import CameraToolkitCore
import CoreImage
import ImageIO
import SwiftUI

/// Two copies of one file side by side — the drive's and the NAS's — each
/// read from its own location: its picture (a Photomator edit's own
/// render), its date, size and a SHA-256 computed now. For a conflict it
/// shows what changed (an edit's settings, by name) and offers Keep drive
/// version / Keep NAS version / Keep both; for copies that should be
/// identical it only shows them, with a pixel-difference check.
struct FileCompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: DashboardModel
    let request: CompareRequest

    @State private var loaded: CompareLoad?
    @State private var showDifference = false
    @State private var pendingChoice: ConflictChoice?
    @State private var resolving = false
    @State private var outcome: String?

    /// `preloaded` is a seam for the snapshot harness.
    init(model: DashboardModel, request: CompareRequest, preloaded: CompareLoad? = nil) {
        self.model = model
        self.request = request
        _loaded = State(initialValue: preloaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let loaded {
                verdict(loaded.comparison)
                HStack(alignment: .top, spacing: 16) {
                    side("On the drive", loaded.comparison.drive, image: loaded.driveImage, newer: loaded.comparison.newer == .drive, isDrive: true)
                    side("On the NAS", loaded.comparison.nas, image: loaded.nasImage, newer: loaded.comparison.newer == .nas, isDrive: false)
                }
                if request.mode == .viewOnly, loaded.difference != nil || loaded.differenceNote != nil {
                    pixelCheck(loaded)
                }
                settings(loaded.comparison)
            } else {
                ProgressView("Reading both copies from their own locations…")
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
            if let outcome {
                Label(outcome, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 860)
        .frame(minHeight: 520)
        .task { if loaded == nil { await load() } }
        .confirmationDialog(
            pendingChoice.map(Self.confirmTitle) ?? "",
            isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } }),
            titleVisibility: .visible
        ) {
            if let choice = pendingChoice {
                Button(Self.buttonTitle(choice)) { resolve(choice) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let choice = pendingChoice { Text(Self.confirmMessage(choice)) }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.mode == .conflict ? "Compare Versions" : "View Both Copies")
                    .font(.title2.weight(.semibold))
                Text(request.fileName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func verdict(_ comparison: FileComparison) -> some View {
        if comparison.identical {
            Label("Identical ✓ — same size and the same SHA-256, read from both locations just now. Nothing to do.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        } else if !comparison.drive.exists || !comparison.nas.exists {
            Label("One copy could not be read — see below.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label(Self.differenceSummary(comparison), systemImage: "arrow.left.arrow.right")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
        }
    }

    private func side(_ title: String, _ file: ComparedFile, image: CGImage?, newer: Bool, isDrive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                if newer {
                    Text("Newer")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.quinary, in: Capsule())
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .opacity(file.exists ? 1 : 0.3)
                }
            }
            .frame(height: 190)
            Text(file.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = file.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Modified").foregroundStyle(.secondary)
                        Text(file.modified?.formatted(date: .abbreviated, time: .standard) ?? "—")
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(file.size >= 1_000 ? "\(file.size.formattedBytes) (\(file.size.formatted()) bytes)" : file.size.formattedBytes).monospacedDigit()
                    }
                    GridRow {
                        Text("SHA-256").foregroundStyle(.secondary)
                        Text(file.shortHash.map { "\($0)…" } ?? "—")
                            .font(.callout.monospaced())
                            .help(file.sha256 ?? "")
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
            }
            HStack(spacing: 8) {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                }
                .disabled(!file.exists)
                if PhotoEditArchive.isPhotoEdit(file.path) {
                    Button("Open in Photomator", systemImage: "camera.filters") {
                        openWorkingCopy(file, label: isDrive ? "drive" : "NAS")
                    }
                    .disabled(!file.exists)
                    .help("Opens a working copy — this version's edit with a copy of its RAW, in the app's caches. The originals are not touched.")
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pixelCheck(_ loaded: CompareLoad) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show pixel difference", isOn: $showDifference)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(loaded.difference == nil)
            if let note = loaded.differenceNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showDifference, let difference = loaded.difference {
                Image(decorative: difference, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func settings(_ comparison: FileComparison) -> some View {
        if let differences = comparison.settingDifferences {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT CHANGED IN THE EDIT")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                if differences.isEmpty {
                    Text("The edit settings are the same; only the stored renders or bookkeeping differ.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Table(differences.indices.map { IndexedDifference(id: $0, difference: differences[$0]) }) {
                        TableColumn("Setting") { row in
                            Text(row.difference.key).font(.caption.monospaced()).help(row.difference.key)
                        }
                        .width(min: 180, ideal: 300)
                        TableColumn("On the drive") { row in
                            Text(row.difference.drive ?? "—").font(.caption.monospaced()).help(row.difference.drive ?? "Not in this version")
                        }
                        TableColumn("On the NAS") { row in
                            Text(row.difference.nas ?? "—").font(.caption.monospaced()).help(row.difference.nas ?? "Not in this version")
                        }
                    }
                    .frame(height: min(CGFloat(differences.count) * 22 + 30, 200))
                }
            }
        } else if let problem = comparison.settingsProblem {
            Text("The edit settings could not be compared: \(problem)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if request.mode == .conflict, let loaded, loaded.comparison.drive.exists, loaded.comparison.nas.exists, !loaded.comparison.identical, outcome == nil {
                Text("Nothing is deleted: the other version goes to the NAS's _Stale Copies or the drive's _Trash. ⌘Z undoes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ForEach(ConflictChoice.allCases, id: \.self) { choice in
                    Button(Self.buttonTitle(choice)) { pendingChoice = choice }
                        .disabled(resolving || model.isBusy)
                }
            } else {
                Spacer()
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(resolving)
        }
    }

    // MARK: - Actions

    private func load() async {
        let pair = request.pair
        let mode = request.mode
        loaded = await Task.detached(priority: .userInitiated) {
            CompareLoad.read(pair, wantsDifference: mode == .viewOnly)
        }.value
    }

    private func resolve(_ choice: ConflictChoice) {
        guard let loaded, let driveSHA = loaded.comparison.drive.sha256, let nasSHA = loaded.comparison.nas.sha256 else { return }
        resolving = true
        model.resolveConflict(
            request.pair, choice: choice, expectedDrive: driveSHA, expectedNAS: nasSHA, fileName: request.fileName
        ) { resolution in
            resolving = false
            if let resolution {
                outcome = resolution.steps.joined(separator: " ")
                Task { await load() }
            }
        }
    }

    /// A working folder under the app's caches holding a copy of the RAW
    /// beside this version's edit, both under the RAW's name so Photomator
    /// pairs them; opened in Photomator. Never beside the originals.
    private func openWorkingCopy(_ file: ComparedFile, label: String) {
        do {
            let folder = try CompareWorkingCopy.make(editPath: file.path, label: label)
            PhotomatorLauncher.open(folder.raw ?? folder.edit)
            outcome = "Opened a working copy of the \(label) version (in the app's caches). Edits there do not change either original."
        } catch {
            outcome = "Could not make a working copy: \(error.localizedDescription)"
        }
    }

    // MARK: - Words

    static func differenceSummary(_ comparison: FileComparison) -> String {
        var parts = ["The copies differ"]
        let delta = comparison.drive.size - comparison.nas.size
        if delta != 0 { parts.append("the drive copy is \(abs(delta).formatted()) bytes \(delta > 0 ? "larger" : "smaller")") }
        switch comparison.newer {
        case .drive: parts.append("the drive version was saved later")
        case .nas: parts.append("the NAS version was saved later")
        case nil: break
        }
        return parts.joined(separator: " — ") + "."
    }

    static func buttonTitle(_ choice: ConflictChoice) -> String {
        switch choice {
        case .keepDrive: "Keep Drive Version"
        case .keepNAS: "Keep NAS Version"
        case .keepBoth: "Keep Both"
        }
    }

    static func confirmTitle(_ choice: ConflictChoice) -> String {
        "\(buttonTitle(choice))?"
    }

    static func confirmMessage(_ choice: ConflictChoice) -> String {
        switch choice {
        case .keepDrive: "The NAS version moves to .Camera Toolkit/_Stale Copies on the NAS, and the drive version is copied to the NAS and verified. Nothing is deleted; ⌘Z undoes it."
        case .keepNAS: "The drive version moves to the drive's _Trash, and the NAS version is copied to the drive and verified. Nothing is deleted; ⌘Z undoes it."
        case .keepBoth: "The NAS version is renamed “… (NAS <date>)” and copied to the drive under that name; the drive version takes the original name on the NAS. Both versions end up on both sides; ⌘Z undoes it."
        }
    }
}

private struct IndexedDifference: Identifiable {
    var id: Int
    var difference: PhotoEditDifference
}

/// Both sides read off the main actor: the comparison, each side's picture
/// decoded from that side's own file, and — for copies that should match —
/// a pixel difference of the two pictures.
struct CompareLoad: @unchecked Sendable {
    var comparison: FileComparison
    var driveImage: CGImage?
    var nasImage: CGImage?
    var difference: CGImage?
    var differenceNote: String?

    static func read(_ pair: ConflictPair, wantsDifference: Bool) -> CompareLoad {
        let comparison = FileCompare.compare(drivePath: pair.drivePath, nasPath: pair.nasPath)
        var load = CompareLoad(
            comparison: comparison,
            driveImage: comparison.drive.exists ? CompareImage.decode(pair.drivePath) : nil,
            nasImage: comparison.nas.exists ? CompareImage.decode(pair.nasPath) : nil
        )
        if wantsDifference {
            if let left = load.driveImage, let right = load.nasImage {
                let result = CompareImage.difference(left, right)
                load.difference = result.image
                load.differenceNote = result.maximum == 0
                    ? "The two pictures differ in no pixel — the difference image is black."
                    : "The pictures differ by up to \(result.maximum) of 255 in some pixels."
            } else {
                load.differenceNote = "No picture to compare for this kind of file; the SHA-256s above decide."
            }
        }
        return load
    }
}

/// Pictures decoded straight from one file, with no cache in between, so
/// the two sides can never show the same decoded image.
enum CompareImage {
    static let maximumPixelSize = 1_200

    static func decode(_ path: String) -> CGImage? {
        if PhotoEditArchive.isPhotoEdit(path) {
            guard let archive = try? PhotoEditArchive(contentsOf: URL(fileURLWithPath: path)),
                  let data = try? archive.contents(of: PhotoEditArchive.thumbnailName),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return thumbnail(source)
        }
        let url = URL(fileURLWithPath: path)
        let kind = OrganizeFileClassifier.kind(forExtension: url.pathExtension)
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
            return try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary)
    }

    /// |left − right| per pixel (right scaled to left's size), and the
    /// largest channel difference anywhere.
    static func difference(_ left: CGImage, _ right: CGImage) -> (image: CGImage?, maximum: Int) {
        let a = CIImage(cgImage: left)
        var b = CIImage(cgImage: right)
        if a.extent.size != b.extent.size {
            b = b.transformed(by: CGAffineTransform(scaleX: a.extent.width / b.extent.width, y: a.extent.height / b.extent.height))
        }
        guard let filter = CIFilter(name: "CIDifferenceBlendMode") else { return (nil, -1) }
        filter.setValue(a, forKey: kCIInputImageKey)
        filter.setValue(b, forKey: kCIInputBackgroundImageKey)
        guard let output = filter.outputImage?.cropped(to: a.extent) else { return (nil, -1) }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var maximum = 0
        if let area = CIFilter(name: "CIAreaMaximum", parameters: [kCIInputImageKey: output, kCIInputExtentKey: CIVector(cgRect: output.extent)])?.outputImage {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(area, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            maximum = Int(pixel[0..<3].max() ?? 0)
        }
        return (context.createCGImage(output, from: output.extent), maximum)
    }
}

/// A Photomator working copy: a folder under the app's caches with a copy
/// of the edit and, when it is beside the edit, a copy of its RAW.
enum CompareWorkingCopy {
    struct Folder {
        var folder: URL
        var edit: URL
        var raw: URL?
    }

    static var root: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("CameraToolkit", isDirectory: true)
            .appendingPathComponent("Compare Working Copies", isDirectory: true)
    }

    /// The RAW beside an edit: same name without the edit extension, or any
    /// sibling sharing the edit's stem that is not itself an edit.
    static func raw(beside editPath: String) -> String? {
        let edit = URL(fileURLWithPath: editPath)
        let stem = edit.deletingPathExtension().lastPathComponent
        let folder = edit.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if siblings.contains(stem), !PhotoEditArchive.isPhotoEdit(stem) { return folder.appendingPathComponent(stem).path }
        let rawStem = (stem as NSString).deletingPathExtension
        return siblings
            .filter { ($0 as NSString).deletingPathExtension == rawStem && !PhotoEditArchive.isPhotoEdit($0) && !$0.hasPrefix(".") }
            .sorted()
            .first
            .map { folder.appendingPathComponent($0).path }
    }

    static func make(editPath: String, label: String, under base: URL = root) throws -> Folder {
        let folder = base
            .appendingPathComponent("\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")) \(label)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(6).description, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var raw: URL?
        var editName = URL(fileURLWithPath: editPath).lastPathComponent
        if let rawPath = Self.raw(beside: editPath) {
            let rawName = URL(fileURLWithPath: rawPath).lastPathComponent
            let target = folder.appendingPathComponent(rawName)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: rawPath), to: target)
            raw = target
            // Photomator pairs "<RAW name>.photo-edit" or "<stem>.photo-edit".
            if !editName.hasPrefix(rawName) { editName = "\((rawName as NSString).deletingPathExtension).\(PhotoEditArchive.extensionName)" }
        }
        let edit = folder.appendingPathComponent(editName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: editPath), to: edit)
        return Folder(folder: folder, edit: edit, raw: raw)
    }
}
